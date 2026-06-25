#!/usr/bin/env bash
# Summary: poll generated host vars until all servers answer as OpenBSD over SSH.
# Use this after flashing/rebooting to detect successful autoinstall, or timeout
# so automation can destroy/create fresh hardware instead of debugging forever.
set -euo pipefail

usage() {
  # Print CLI help and use exit code 2 to signal invalid arguments.
  cat <<'EOF'
usage: wait-for-openbsd-servers.sh [-g 'tmp/build/*.vars'] [-i 10] [-t 1800] [-k ~/.ssh/id_ed25519]
EOF
  exit 2
}

VARS_GLOB='tmp/build/*.vars'
INTERVAL=10
TIMEOUT=1800
KEY=$HOME/.ssh/id_ed25519
REMOTE_CMD='uname -s; hostname; ifconfig em0 2>/dev/null | sed -n "1,6p"'

# Parse host vars glob, polling interval/timeout, and SSH identity.
while getopts 'g:i:t:k:h' opt; do
  case "$opt" in
    g) VARS_GLOB=$OPTARG ;;
    i) INTERVAL=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;
    k) KEY=$OPTARG ;;
    h|*) usage ;;
  esac
done

[ -r "$KEY" ] || { echo "cannot read ssh key: $KEY" >&2; exit 1; }

# Expand the glob after assigning it. Keep this unquoted intentionally.
# shellcheck disable=SC2206
VARS_FILES=( $VARS_GLOB )
if [ ${#VARS_FILES[@]} -eq 0 ] || [ ! -e "${VARS_FILES[0]}" ]; then
  echo "no vars files matched: $VARS_GLOB" >&2
  exit 1
fi

HOSTS_TMP=$(mktemp)
trap 'rm -f "$HOSTS_TMP"' EXIT

# Read each Terraform vars file once into a simple host/ip/path table. The main
# polling loop consumes this table instead of repeatedly sourcing files.
for vars in "${VARS_FILES[@]}"; do
  [ -f "$vars" ] || continue
  hostname=
  ipv4=
  # shellcheck disable=SC1090
  . "$vars"
  [ -n "${hostname:-}" ] || { echo "missing hostname in $vars" >&2; exit 1; }
  [ -n "${ipv4:-}" ] || { echo "missing ipv4 in $vars" >&2; exit 1; }
  printf '%s %s %s\n' "$hostname" "$ipv4" "$vars" >> "$HOSTS_TMP"
done

TOTAL=$(wc -l < "$HOSTS_TMP" | tr -d ' ')
[ "$TOTAL" -gt 0 ] || { echo "no hosts found in $VARS_GLOB" >&2; exit 1; }

echo "waiting for $TOTAL OpenBSD server(s) from $VARS_GLOB"

# Track elapsed time and ready hosts using shell variables only, keeping this
# portable to minimal admin environments.
START=$(date +%s)
READY_LIST=
READY_COUNT=0

is_ready_seen() {
  # Return success if the hostname is already present in READY_LIST. Spaces on
  # both sides avoid partial matches, e.g. "web1" matching "web10".
  case " $READY_LIST " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Keep polling until all hosts answer as OpenBSD or the timeout expires.
while [ "$READY_COUNT" -lt "$TOTAL" ]; do
  now=$(date +%s)
  if [ $((now - START)) -gt "$TIMEOUT" ]; then
    echo "timeout after ${TIMEOUT}s; ready $READY_COUNT/$TOTAL" >&2
    exit 1
  fi

  while read -r host ip vars; do
    # Skip hosts that have already succeeded in an earlier pass.
    if is_ready_seen "$host"; then
      continue
    fi

    # Attempt a short SSH connection. Failures are expected while machines are
    # rebooting/installing, so errors are redirected and converted to empty out.
    out=$(ssh \
      -i "$KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      root@"$ip" "$REMOTE_CMD" 2>/dev/null || true)

    os=$(printf '%s\n' "$out" | sed -n '1p')
    remote_host=$(printf '%s\n' "$out" | sed -n '2p')
    # The first remote line is authoritative for readiness; hostname is kept for
    # debug visibility in the captured output but not required to match here.
    if [ "$os" = OpenBSD ]; then
      READY_LIST="$READY_LIST $host"
      READY_COUNT=$((READY_COUNT + 1))
      echo "$host $ip ready"
    fi
  done < "$HOSTS_TMP"

  [ "$READY_COUNT" -eq "$TOTAL" ] && break
  sleep "$INTERVAL"
done

echo "all $TOTAL OpenBSD server(s) ready"
