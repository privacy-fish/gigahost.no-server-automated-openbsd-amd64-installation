#!/usr/bin/env bash
# Summary: native OpenBSD remaster path for admin machines already running OpenBSD.
# It copies the installer image, mounts it with vnd(4), injects auto_install.conf
# into bsd.rd, writes serial boot config, and detaches everything cleanly.
set -euo pipefail

usage() {
  # Print CLI help and use exit code 2 to signal invalid arguments.
  cat <<'EOF'
usage: remaster-openbsd-install-img-native-openbsd.sh -i install79.img -c host.conf -o host-install.img
EOF
  exit 2
}

IMAGE=
CONF=
OUT=

# Parse the source installer image, answer file, and output image path.
while getopts 'i:c:o:h' opt; do
  case "$opt" in
    i) IMAGE=$OPTARG ;;
    c) CONF=$OPTARG ;;
    o) OUT=$OPTARG ;;
    h|*) usage ;;
  esac
done

[ -n "$IMAGE" ] || usage
[ -n "$CONF" ] || usage
[ -n "$OUT" ] || usage
[ -r "$IMAGE" ] || { echo "cannot read image: $IMAGE" >&2; exit 1; }
[ -r "$CONF" ] || { echo "cannot read conf: $CONF" >&2; exit 1; }

[ "$(uname -s)" = OpenBSD ] || { echo "native remaster must run on OpenBSD" >&2; exit 1; }
command -v rdsetroot >/dev/null
command -v vnconfig >/dev/null

# Work on a copy so the official installer image remains unchanged.
mkdir -p "$(dirname -- "$OUT")"
cp "$IMAGE" "$OUT"

VND=
MNT=
WORK=
cleanup() {
  # Best-effort cleanup for every exit path: unmount filesystems, detach vnds,
  # and remove temporary directories. set +e prevents cleanup failures from
  # hiding the original error.
  set +e
  if [ -n "$MNT" ] && mount | grep -q " on $MNT "; then umount "$MNT"; fi
  if [ -n "$WORK" ] && mount | grep -q " on $WORK/rdroot "; then umount "$WORK/rdroot"; fi
  vnconfig -u vnd1 >/dev/null 2>&1 || true
  if [ -n "$VND" ]; then vnconfig -u "$VND" >/dev/null 2>&1 || true; fi
  [ -n "$MNT" ] && rm -rf "$MNT"
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

# Attach the copied installer image as a vnd(4) disk and prepare temp work dirs.
VND=vnd0
vnconfig "$VND" "$OUT"
MNT=$(mktemp -d /tmp/openbsd-install-img.XXXXXXXXXX)
WORK=$(mktemp -d /tmp/openbsd-rd.XXXXXXXXXX)
mkdir -p "$WORK/rdroot"

mount "/dev/${VND}a" "$MNT"
BSDRD=
# OpenBSD install images may place bsd.rd at the root or under version/arch.
for P in "$MNT"/*/*/bsd.rd "$MNT"/bsd.rd; do
  if [ -f "$P" ]; then
    BSDRD=$P
    break
  fi
done
[ -n "$BSDRD" ] || { echo "could not find bsd.rd in installer image" >&2; exit 1; }

# Make the image boot through the serial console and explicitly boot bsd.rd.
BOOT_BSDRD=${BSDRD#"$MNT"}
mkdir -p "$MNT/etc"
cat > "$MNT/etc/boot.conf" <<EOF
set tty com0
stty com0 115200
boot $BOOT_BSDRD
EOF

# Unpack bsd.rd, mount its embedded ramdisk, copy in auto_install.conf, then
# repack bsd.rd and write it back into the mounted installer image.
gzip -dc "$BSDRD" > "$WORK/bsd.rd"
rdsetroot -x "$WORK/bsd.rd" "$WORK/ramdisk.fs"
vnconfig vnd1 "$WORK/ramdisk.fs"
mount /dev/vnd1a "$WORK/rdroot"
cp "$CONF" "$WORK/rdroot/auto_install.conf"
sync
umount "$WORK/rdroot"
vnconfig -u vnd1
rdsetroot "$WORK/bsd.rd" "$WORK/ramdisk.fs"
gzip -9c "$WORK/bsd.rd" > "$WORK/bsd.rd.gz"
cp "$WORK/bsd.rd.gz" "$BSDRD"
sync
umount "$MNT"
vnconfig -u "$VND"
# From here on cleanup is complete manually, so disable the EXIT trap.
trap - EXIT
rm -rf "$MNT" "$WORK"

# Print the remastered image path for callers that chain this command.
echo "$OUT"
