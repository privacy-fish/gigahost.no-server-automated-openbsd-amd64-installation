#!/usr/bin/env bash
# Summary: wrapper for remastering an OpenBSD miniroot/installer image.
# On OpenBSD it calls the native vnd/rdsetroot path; on Linux it boots the local
# OpenBSD builder VM and remasters the image there.
set -euo pipefail

usage() {
  # Print CLI help and use exit code 2 to signal invalid arguments.
  cat <<'EOF'
usage: remaster-openbsd-install-img.sh [-i miniroot79.img] [-c host.conf] [-o host-miniroot.img] [-b openbsd-builder.raw]
EOF
  exit 2
}

IMAGE=tmp/cache/openbsd/7.9/amd64/miniroot79.img
CONF=tmp/build/openbsd-canary.mail.privacy.fish-openbsd-dev.conf
OUT=tmp/dist/openbsd-canary.mail.privacy.fish-openbsd-dev-miniroot79.img
BUILDER=
BUILDER_LOGIN=root
BUILDER_PASSWORD=${OPENBSD_BUILDER_PASSWORD:-secret}
MEM=1024M

# Parse common remaster inputs plus QEMU-builder connection settings.
while getopts 'i:c:o:b:l:p:m:h' opt; do
  case "$opt" in
    i) IMAGE=$OPTARG ;;
    c) CONF=$OPTARG ;;
    o) OUT=$OPTARG ;;
    b) BUILDER=$OPTARG ;;
    l) BUILDER_LOGIN=$OPTARG ;;
    p) BUILDER_PASSWORD=$OPTARG ;;
    m) MEM=$OPTARG ;;
    h|*) usage ;;
  esac
done

[ -n "$IMAGE" ] || usage
[ -n "$CONF" ] || usage
[ -n "$OUT" ] || usage
[ -r "$IMAGE" ] || { echo "installer image not found: $IMAGE" >&2; exit 1; }
[ -r "$CONF" ] || { echo "install config not found: $CONF" >&2; exit 1; }

# Resolve helper scripts relative to this wrapper, regardless of caller cwd.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# On OpenBSD, use native vnconfig/rdsetroot directly unless a builder image was
# explicitly supplied. exec replaces this wrapper and preserves its exit status.
if [ "$(uname -s)" = OpenBSD ] && [ -z "$BUILDER" ]; then
  exec "$SCRIPT_DIR/remaster-openbsd-install-img-native-openbsd.sh" \
    -i "$IMAGE" \
    -c "$CONF" \
    -o "$OUT"
fi

# On Debian/Linux, default to the cached OpenBSD builder image and delegate to
# the Python/QEMU implementation that performs OpenBSD-only filesystem edits.
if [ -z "$BUILDER" ]; then
  BUILDER=tmp/cache/openbsd-builder-7.9-amd64.raw
fi
[ -n "$BUILDER" ] || { echo "Debian/Linux remastering needs a builder image; default is tmp/cache/openbsd-builder-7.9-amd64.raw" >&2; usage; }
[ -r "$BUILDER" ] || { echo "builder image not found: $BUILDER" >&2; exit 1; }
[ -n "$BUILDER_PASSWORD" ] || usage

# Hand off all validated arguments to the Python remaster driver.
exec python3 "$SCRIPT_DIR/remaster-openbsd-install-img-via-qemu.py" \
  --source "$IMAGE" \
  --conf "$CONF" \
  --output "$OUT" \
  --builder-image "$BUILDER" \
  --builder-login "$BUILDER_LOGIN" \
  --builder-password "$BUILDER_PASSWORD" \
  --mem "$MEM"
