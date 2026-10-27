#!/usr/bin/env bash
# Sign the latest redfin build with the private keys in $KEYS and produce
# a full OTA, an incremental OTA from the previous release, fastboot images
# and an Updater feed entry.
#
# Every release keeps its signed target_files in $RELEASES/<tag>/; the next
# release diffs against $RELEASES/latest. Never delete those or the keys.
set -euo pipefail

TOP=/serverhive2/unseenpixel/pixelos
KEYS=${KEYS:-$HOME/.android-certs}
RELEASES=${RELEASES:-/serverhive2/unseenpixel/releases/redfin}
OTA_REPO_URL=https://github.com/pixelos-redfin/pixelos-ota/releases/download
OUT=$TOP/out/target/product/redfin
BIN=$TOP/out/host/linux-x86/bin
TF=$OUT/obj/PACKAGING/target_files_intermediates/custom_redfin-target_files.zip
AVB_ALGO=SHA256_RSA4096
export PATH=$BIN:$PATH

die() { echo "Error: $*" >&2; exit 1; }

[ -f "$KEYS/releasekey.pk8" ] || die "no keys in $KEYS"
[ -f "$TF" ] || die "no target_files at $TF"

# The PixelOS package of the same build gives us the release name.
NAME=$(find "$OUT" -maxdepth 1 -name 'PixelOS_redfin-*.zip' -printf '%T@ %f\n' | sort -n | tail -1 | cut -d' ' -f2-)
[ -n "$NAME" ] || die "no PixelOS_redfin-*.zip in $OUT"
[ "$OUT/$NAME" -nt "$TF" ] || die "$NAME is older than target_files, rebuild first"
[[ "$NAME" =~ ^PixelOS_redfin-([0-9.]+)-([0-9]{8}-[0-9]{4})\.zip$ ]] || die "unexpected name $NAME"
VERSION=${BASH_REMATCH[1]}
TAG=${BASH_REMATCH[2]}

DEST=$RELEASES/$TAG
[ -e "$DEST" ] && die "$DEST already exists"
PREV=""
[ -e "$RELEASES/latest/signed-target_files.zip" ] && PREV=$(readlink -f "$RELEASES/latest")
mkdir -p "$DEST"

# The device tree builds vbmeta with --flags 3 (verification disabled)
# unless WITH_AVB=true; a locked bootloader refuses that, so force 0.
# testkey -> releasekey, platform -> platform, ... comes from -d.
# APEXes get their own container and payload keys, and every APK signed
# with a public in-tree key outside build/make/target/product/security is
# moved to releasekey.
args=()
while read -r apex; do
    args+=(--extra_apks "$apex.apex=$KEYS/$apex"
           --extra_apex_payload_key "$apex.apex=$KEYS/$apex.pem")
done < "$KEYS/apex.list"
while read -r apk; do
    args+=(--extra_apks "$apk=$KEYS/releasekey")
done < <(unzip -p "$TF" META/apkcerts.txt \
    | grep -v -e 'certificate="PRESIGNED"' -e 'certificate="build/make/target/product/security/' \
    | sed -nE 's/^name="([^"]+)".*/\1/p')

echo ">> Signing target_files ($TAG)"
sign_target_files_apks -o -d "$KEYS" "${args[@]}" \
    --avb_vbmeta_key "$KEYS/avb.pem" --avb_vbmeta_algorithm $AVB_ALGO \
    --avb_vbmeta_extra_args "--flags 0" \
    --avb_vbmeta_system_key "$KEYS/avb.pem" --avb_vbmeta_system_algorithm $AVB_ALGO \
    --avb_boot_key "$KEYS/avb.pem" --avb_boot_algorithm $AVB_ALGO \
    "$TF" "$DEST/signed-target_files.zip"

echo ">> Building full OTA"
ota_from_target_files -k "$KEYS/releasekey" \
    "$DEST/signed-target_files.zip" "$DEST/$NAME"

INC=""
if [ -n "$PREV" ]; then
    PREV_TAG=$(basename "$PREV")
    INC=PixelOS_redfin-$VERSION-$PREV_TAG-to-$TAG-incremental.zip
    echo ">> Building incremental OTA from $PREV_TAG"
    ota_from_target_files -k "$KEYS/releasekey" -i "$PREV/signed-target_files.zip" \
        "$DEST/signed-target_files.zip" "$DEST/$INC"
fi

echo ">> Extracting fastboot images"
unzip -q -j "$DEST/signed-target_files.zip" \
    IMAGES/boot.img IMAGES/dtbo.img IMAGES/vendor_boot.img IMAGES/vbmeta.img -d "$DEST"

echo ">> Building factory image"
KEYS=$KEYS "$(dirname "$(readlink -f "$0")")/factory/make_factory.sh" "$DEST"

# The feed only carries the incremental from the previous release: full
# OTAs exceed GitHub's 2 GiB release asset limit and go out via the
# factory image instead.
if [ -n "$INC" ]; then
    echo ">> Generating Updater feed"
    python3 -I "$TOP/packages/apps/Updater/tools/pixelos_feed.py" generate-ota "$DEST/$INC" \
        --url "$OTA_REPO_URL/$TAG/$INC" --version "$VERSION" --output "$DEST/redfin.json"
fi

ln -sfn "$TAG" "$RELEASES/latest"

echo
echo "Release $TAG ready in $DEST"
ls -lh "$DEST"
echo
if [ -n "$INC" ]; then
    echo "Publish: gh release create $TAG -R pixelos-redfin/pixelos-ota $DEST/$INC"
    echo "         cp $DEST/redfin.json ../pixelos-ota/API/updater/redfin.json, update changelog, push"
else
    echo "No previous release: nothing for the Updater feed (incremental only)."
fi
echo "Upload:  ./upload_build.sh $DEST"
