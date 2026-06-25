#!/usr/bin/env bash
# Summary: download and verify official OpenBSD installer media into tmp/cache.
# The default path fetches the small miniroot image used for network autoinstall;
# the full install ISO is optional and normally not needed for Gigahost canaries.
set -euo pipefail

usage() {
  # Print CLI help and use exit code 2 to signal invalid arguments.
  cat <<'EOF'
usage: download-openbsd-install-img.sh [-v 7.9] [-m mirror] [-o tmp/cache/openbsd/7.9/amd64] [-I]
EOF
  exit 2
}

VERSION=7.9
ARCH=amd64
MIRROR=https://cdn.openbsd.org/pub/OpenBSD
OUTDIR=
DOWNLOAD_ISO=0

# Parse options first so all derived paths below reflect user overrides.
# Gigahost hardware servers are amd64, so architecture is fixed here.
while getopts 'v:m:o:Ih' opt; do
  case "$opt" in
    v) VERSION=$OPTARG ;;
    m) MIRROR=${OPTARG%/} ;;
    o) OUTDIR=$OPTARG ;;
    I) DOWNLOAD_ISO=1 ;;
    h|*) usage ;;
  esac
done

# OpenBSD release files omit the dot in the install image name, e.g. 7.9 -> 79.
REL=${VERSION/./}
OUTDIR=${OUTDIR:-tmp/cache/openbsd/$VERSION/$ARCH}
BASE="$MIRROR/$VERSION/$ARCH"
IMG="miniroot${REL}.img"
ISO="install${REL}.iso"

mkdir -p "$OUTDIR"

fetch() {
  # Download one URL to one output path, resuming partial .tmp downloads.
  # Existing non-empty files are trusted so repeated runs are cheap/idempotent.
  local url=$1 out=$2
  if [ -s "$out" ]; then
    echo "exists: $out"
    return 0
  fi
  echo "downloading: $url"
  curl -fL -C - --retry 3 --retry-delay 2 -o "$out.tmp" "$url"
  mv "$out.tmp" "$out"
}

# Fetch the installer image and optional ISO before fetching checksum metadata.
fetch "$BASE/$IMG" "$OUTDIR/$IMG"
if [ "$DOWNLOAD_ISO" = 1 ]; then
  fetch "$BASE/$ISO" "$OUTDIR/$ISO"
fi
fetch "$BASE/SHA256" "$OUTDIR/SHA256"
fetch "$BASE/SHA256.sig" "$OUTDIR/SHA256.sig"

# Verify the installer image when the mirror's SHA256 file contains an entry.
# SHA256.sig is downloaded for external/signify verification, but this script
# only compares the plain hash to keep dependencies portable.
if grep -q "($IMG)" "$OUTDIR/SHA256"; then
  echo "verifying SHA256 for $IMG"
  expected=$(sed -n "s/^SHA256 ($IMG) = //p" "$OUTDIR/SHA256" | head -1)
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$OUTDIR/$IMG" | awk '{print $1}')
  else
    actual=$(sha256 -q "$OUTDIR/$IMG")
  fi
  if [ "$expected" != "$actual" ]; then
    echo "SHA256 mismatch for $OUTDIR/$IMG" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
else
  echo "warning: $IMG not found in SHA256; skipped hash check" >&2
fi

# Print the downloaded image path for callers that capture this script's output.
echo "$OUTDIR/$IMG"
