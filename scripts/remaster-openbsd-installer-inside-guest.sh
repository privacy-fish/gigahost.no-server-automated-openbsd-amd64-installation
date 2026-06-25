#!/bin/sh
# Summary: guest-side OpenBSD remaster logic run inside the builder VM.
# It mounts the attached installer/miniroot image, injects auto_install.conf into
# the RAMDISK kernel with rdsetroot/vnconfig, and writes a serial boot config.
set -ex

# This script runs inside the temporary OpenBSD builder VM, not on Linux.
# Linux cannot safely edit OpenBSD FFS images or bsd.rd, so the host-side Python
# helper boots OpenBSD, attaches the installer/miniroot image as a second disk,
# then uploads this script and the rendered auto_install.conf content.
PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Fail early if the builder image is missing the native OpenBSD tools we need.
command -v rdsetroot
command -v vnconfig

mkdir -p /mnt

# The Python wrapper replaces this marker with the rendered per-host installer
# answers before uploading the script to the builder VM.
cat > /tmp/auto_install.conf <<'__AUTO_INSTALL_CONF__'
__AUTO_INSTALL_CONF_PLACEHOLDER__
__AUTO_INSTALL_CONF__

MOUNTED=
BSDRD=

# Builder disk is normally sd0; the attached installer/miniroot image is normally
# sd1. Prefer second disks so we do not accidentally touch the builder image.
for DEV in /dev/sd1a /dev/wd1a /dev/sd2a /dev/wd2a /dev/sd0a /dev/wd0a; do
  [ -e "$DEV" ] || continue

  if mount "$DEV" /mnt 2>/tmp/mount.err; then
    echo "mounted candidate installer filesystem from $DEV"
    find /mnt -maxdepth 3 -type f -print >&2 || true

    # installXX.img usually stores bsd.rd below /VERSION/ARCH/bsd.rd.
    # minirootXX.img stores the ramdisk kernel as /bsd. Support both layouts.
    for P in /mnt/*/*/bsd.rd /mnt/bsd.rd /mnt/bsd; do
      if [ -f "$P" ]; then
        BSDRD=$P
        MOUNTED=$DEV
        break
      fi
    done

    [ -n "$MOUNTED" ] && break
    umount /mnt
  fi
done

if [ -z "$MOUNTED" ]; then
  echo 'could not find mounted installer/miniroot image with bsd.rd or bsd' >&2
  cat /tmp/mount.err >&2 || true
  sysctl hw.disknames >&2 || true
  mount >&2 || true
  exit 1
fi

echo "mounted installer image from $MOUNTED; ramdisk kernel=$BSDRD"

# Keep temporary expansion work on the builder disk, not inside the tiny
# miniroot filesystem. miniroot79.img is intentionally only a few MB and often
# has no spare room for an uncompressed kernel plus extracted ramdisk.
#
# Important miniroot detail: amd64 minirootXX.img stores the RAMDISK kernel as
# /bsd, but /auto_install.conf must live inside that kernel's built-in RAM disk
# (see autoinstall(8)). A plain /mnt/auto_install.conf file on the miniroot FFS
# partition is ignored after /bsd boots, so we still need rdsetroot injection.
# The /bsd file is gzip-compressed; rdsetroot only works after gunzip.
WORK=/tmp/remaster-work
rm -rf "$WORK"
mkdir -p "$WORK/rdroot"

# Force serial-console boot for headless bare-metal rescue use. The boot target
# is relative to the mounted filesystem root, e.g. /bsd or /7.9/amd64/bsd.rd.
BOOT_BSDRD=${BSDRD#/mnt}
if mkdir -p /mnt/etc && cat > /mnt/etc/boot.conf <<__BOOT_CONF__
set tty com0
stty com0 115200
boot $BOOT_BSDRD
__BOOT_CONF__
then
  echo "wrote /etc/boot.conf for serial boot"
else
  echo "warning: could not write /etc/boot.conf; continuing with default miniroot boot" >&2
fi

# Some OpenBSD installer kernels are stored gzip-compressed, others are plain
# kernels. rdsetroot needs the plain kernel, so normalize to a work copy first
# and remember whether to gzip the result back into place.
COMPRESSED=0
# OpenBSD gzip -t can be unreliable for this boot-loader gzip payload, but
# file(1) identifies miniroot /bsd correctly as gzip-compressed data.
if file "$BSDRD" | grep -qi 'gzip compressed'; then
  COMPRESSED=1
  gzip -dc "$BSDRD" > "$WORK/bsd.rd"
else
  cp "$BSDRD" "$WORK/bsd.rd"
fi

# Extract the kernel ramdisk, mount it through vnd(4), inject the autoinstall
# answers at /auto_install.conf, then rebuild the ramdisk into the kernel.
rdsetroot -x "$WORK/bsd.rd" "$WORK/ramdisk.fs"
vnconfig vnd0 "$WORK/ramdisk.fs"
mount /dev/vnd0a "$WORK/rdroot"
cp /tmp/auto_install.conf "$WORK/rdroot/auto_install.conf"
sync
umount "$WORK/rdroot"
vnconfig -u vnd0
rdsetroot "$WORK/bsd.rd" "$WORK/ramdisk.fs"

if [ "$COMPRESSED" = 1 ]; then
  # Match OpenBSD's amd64 miniroot build: strip nonessential sections before
  # recompressing so the replacement /bsd still fits in the tiny filesystem.
  if command -v objcopy >/dev/null 2>&1; then
    objcopy -g -x -R .comment -R .SUNW_ctf \
      -K rd_root_size -K rd_root_image \
      "$WORK/bsd.rd" "$WORK/bsd.strip"
    gzip -9cn "$WORK/bsd.strip" > "$BSDRD"
  else
    gzip -9cn "$WORK/bsd.rd" > "$BSDRD"
  fi
else
  cp "$WORK/bsd.rd" "$BSDRD"
fi

rm -rf "$WORK"
sync
umount /mnt
sync
