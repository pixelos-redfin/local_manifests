#!/usr/bin/env bash
# Build a Google-style factory image zip from a signed release directory:
#   redfin-factory-<tag>.zip
#     redfin-<tag>/flash-all.sh, flash-all.bat, avb_pkmd.bin,
#                  image-redfin-<tag>.zip
# Firmware is not included: the Pixel 5 bootloader only takes Google's
# packed bootloader/radio images, so the phone must be on stock A14 first.
# Usage: make_factory.sh <release dir>   (e.g. $RELEASES/20261027-1820)
set -euo pipefail

TOP=/serverhive2/unseenpixel/pixelos
KEYS=${KEYS:-$HOME/.android-certs}
BIN=$TOP/out/host/linux-x86/bin
HERE=$(dirname "$(readlink -f "$0")")
export PATH=$BIN:$PATH

die() { echo "Error: $*" >&2; exit 1; }

DEST=$(readlink -f "${1:?usage: $0 <release dir>}")
TAG=$(basename "$DEST")
TF=$DEST/signed-target_files.zip
OUTZIP=$DEST/redfin-factory-$TAG.zip
[ -f "$TF" ] || die "no signed-target_files.zip in $DEST"
[ -e "$OUTZIP" ] && die "$OUTZIP already exists"

WORK=$(mktemp -d "$DEST/.factory.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PKG=$WORK/redfin-$TAG
mkdir -p "$PKG"

echo ">> Checking the AVB key"
avbtool extract_public_key --key "$KEYS/avb.pem" --output "$WORK/pkmd.bin"
cmp -s "$WORK/pkmd.bin" "$KEYS/avb_pkmd.bin" || die "avb_pkmd.bin does not match avb.pem"
unzip -q -j "$TF" IMAGES/vbmeta.img -d "$WORK"
avbtool info_image --image "$WORK/vbmeta.img" | grep -q "Public key (sha1): *$(sha1sum < "$KEYS/avb_pkmd.bin" | cut -d' ' -f1)" \
    || die "vbmeta.img of $TAG is not signed with avb.pem"
# Flags other than 0 disable verification; such a build never boots locked.
avbtool info_image --image "$WORK/vbmeta.img" | grep -q '^Flags: *0$' \
    || die "vbmeta.img of $TAG has verification disabled, it cannot boot with a locked bootloader"
cp "$KEYS/avb_pkmd.bin" "$PKG/"

FIRMWARE=$(unzip -Z1 "$TF" 'RADIO/*.img' | sed 's|^RADIO/||' | tr '\n' ' ')
[ -n "$FIRMWARE" ] || die "no firmware in RADIO/"

echo ">> Building image-redfin-$TAG.zip"
img_from_target_files "$TF" "$PKG/image-redfin-$TAG.zip" >/dev/null
# fastboot update does not flash firmware, so drop it from the image zip.
zip -q -d "$PKG/image-redfin-$TAG.zip" $FIRMWARE

echo ">> Writing flash-all scripts"
sed -e "s/@TAG@/$TAG/" "$HERE/flash-all.sh" > "$PKG/flash-all.sh"
sed -e "s/@TAG@/$TAG/" -e 's/$/\r/' "$HERE/flash-all.bat" > "$PKG/flash-all.bat"
chmod 755 "$PKG/flash-all.sh"

echo ">> Packing $(basename "$OUTZIP")"
(cd "$WORK" && zip -q -r -0 -X "$OUTZIP.tmp" "redfin-$TAG")
mv "$OUTZIP.tmp" "$OUTZIP"
(cd "$DEST" && sha256sum "$(basename "$OUTZIP")" > "$(basename "$OUTZIP").sha256")

echo "Factory image: $OUTZIP"
