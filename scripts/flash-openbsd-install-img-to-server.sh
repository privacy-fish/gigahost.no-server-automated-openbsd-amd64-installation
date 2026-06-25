#!/usr/bin/env bash
# Summary: destructively stream a remastered OpenBSD installer image to a server.
# The target must be in Gigahost rescue SSH; this writes the chosen disk with dd,
# syncs, and reboots so the real hardware starts OpenBSD autoinstall.
set -euo pipefail

usage() {
  # Print CLI help and use exit code 2 to signal invalid arguments.
  cat <<'EOF'
usage: flash-openbsd-install-img-to-server.sh [-i host-install.img] [-v host.vars] [-d /dev/sda] [-k ~/.ssh/id_ed25519]
       flash-openbsd-install-img-to-server.sh -i host-install.img -a admin_ip -d /dev/sda [-k ~/.ssh/id_ed25519]
EOF
  exit 2
}

IMAGE=tmp/dist/openbsd-canary.mail.privacy.fish-openbsd-dev-miniroot79.img
VARS=tmp/build/openbsd-canary.mail.privacy.fish-openbsd-dev.vars
ADMIN_IP=
DISK=/dev/sda
KEY=$HOME/.ssh/id_ed25519

# Parse image, host vars/Admin IP, destructive target disk, and SSH identity.
while getopts 'i:v:a:d:k:h' opt; do
  case "$opt" in
    i) IMAGE=$OPTARG ;;
    v) VARS=$OPTARG ;;
    a) ADMIN_IP=$OPTARG ;;
    d) DISK=$OPTARG ;;
    k) KEY=$OPTARG ;;
    h|*) usage ;;
  esac
done

[ -n "$IMAGE" ] || usage
[ -n "$DISK" ] || usage
[ -r "$IMAGE" ] || { echo "cannot read image: $IMAGE" >&2; exit 1; }
[ -r "$KEY" ] || { echo "cannot read ssh key: $KEY" >&2; exit 1; }

# If a vars file is available, load the target rescue IP from its ipv4 value.
# A manually supplied -a ADMIN_IP takes precedence over the vars-derived IP.
if [ -n "$VARS" ]; then
  [ -f "$VARS" ] || { echo "vars file not found: $VARS" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$VARS"
  : "${ipv4:?missing ipv4 in vars file}"
  ADMIN_IP=${ADMIN_IP:-$ipv4}
fi
[ -n "$ADMIN_IP" ] || usage

# Calculate local metadata for logging and for later operator verification.
if command -v sha256sum >/dev/null 2>&1; then
  SHA=$(sha256sum "$IMAGE" | awk '{print $1}')
else
  SHA=$(sha256 -q "$IMAGE")
fi
if SIZE=$(stat -c '%s' "$IMAGE" 2>/dev/null); then
  :
else
  SIZE=$(stat -f '%z' "$IMAGE")
fi

# Show the destructive target details before any upload/write occurs.
echo "target admin: root@$ADMIN_IP"
echo "target disk:  $DISK"
echo "image:        $IMAGE"
echo "image size:   $SIZE"
echo "image sha256: $SHA"
echo

# SSH options favor unattended rescue access and avoid modifying known_hosts.
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# Check the remote machine and destructive target before streaming bytes.
ssh "${SSH_OPTS[@]}" root@"$ADMIN_IP" \
  "set -e; uname -a; lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,ROTA,TRAN; test -b '$DISK'"

# Stream the raw image directly into dd. For miniroot images this is only a few
# MiB and avoids an unnecessary /dev/shm staging step on the rescue system.
echo "streaming image directly to $ADMIN_IP:$DISK"
cat "$IMAGE" | ssh "${SSH_OPTS[@]}" root@"$ADMIN_IP" \
  "set -e; /bin/dd of='$DISK' bs=4M conv=fsync status=progress; sync; reboot"

echo "flash finished; server should be rebooting into OpenBSD autoinstall"
