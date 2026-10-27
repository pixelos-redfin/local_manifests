#!/usr/bin/env bash
set -euo pipefail

# Configuration
PRODUCT_DIR="${1:-/serverhive2/unseenpixel/releases/redfin/latest}"
PRODUCT_DIR=$(readlink -f "$PRODUCT_DIR")
GDRIVE_REMOTE="gdrive:PixelOS/redfin"

if [ ! -d "$PRODUCT_DIR" ]; then
    echo "Error: Directory '$PRODUCT_DIR' not found."
    exit 1
fi

echo "Scanning '$PRODUCT_DIR' for build artifacts..."

# 1. Find the latest PixelOS ROM zip
LATEST_ZIP=$(find "$PRODUCT_DIR" -maxdepth 1 -name "PixelOS_redfin-*.zip" ! -name "*incremental*" -type f -printf "%T@ %p\n" | sort -n | tail -1 | cut -d' ' -f2-)

if [ -z "$LATEST_ZIP" ]; then
    # Fallback to any custom zip if PixelOS named zip isn't found
    LATEST_ZIP=$(find "$PRODUCT_DIR" -maxdepth 1 -name "*.zip" ! -name "*target_files*" ! -name "*ota*" -type f -printf "%T@ %p\n" | sort -n | tail -1 | cut -d' ' -f2-)
fi

if [ -z "$LATEST_ZIP" ]; then
    echo "Error: No ROM zip package found in $PRODUCT_DIR"
    exit 1
fi

ZIP_BASENAME=$(basename "$LATEST_ZIP")
echo "Latest ROM zip: $ZIP_BASENAME"

# 2. Extract build timestamp from filename or file modification date
# e.g. PixelOS_redfin-17.0-20261021-1639.zip -> 2026-10-21_1639
if [[ "$ZIP_BASENAME" =~ ([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{4}) ]]; then
    DATE_TAG="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}_${BASH_REMATCH[4]}"
elif [[ "$ZIP_BASENAME" =~ ([0-9]{4})([0-9]{2})([0-9]{2}) ]]; then
    DATE_TAG="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
else
    DATE_TAG=$(date -r "$LATEST_ZIP" +"%Y-%m-%d_%H%M")
fi

DEST_FOLDER="${GDRIVE_REMOTE}/${DATE_TAG}"
echo "Target Google Drive Folder: ${DEST_FOLDER}"

# 3. Verify all required files exist
REQUIRED_FILES=(
    "boot.img"
    "dtbo.img"
    "vendor_boot.img"
    "vbmeta.img"
    "$ZIP_BASENAME"
)
# Factory image (flash-all installer) from factory/make_factory.sh, if built
FACTORY_ZIP=$(basename "$(ls "$PRODUCT_DIR"/redfin-factory-*.zip 2>/dev/null | tail -1)" 2>/dev/null || true)
[ -n "$FACTORY_ZIP" ] && REQUIRED_FILES+=("$FACTORY_ZIP" "$FACTORY_ZIP.sha256")

MISSING=0
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$PRODUCT_DIR/$f" ]; then
        echo "Warning: Required file '$f' is missing in $PRODUCT_DIR"
        MISSING=1
    fi
done

echo ""
echo "Files to upload:"
for f in "${REQUIRED_FILES[@]}"; do
    if [ -f "$PRODUCT_DIR/$f" ]; then
        SIZE=$(ls -lh "$PRODUCT_DIR/$f" | awk '{print $5}')
        echo "  - $f ($SIZE)"
    fi
done

echo ""
echo "Starting upload to Google Drive (${DEST_FOLDER})..."

# 4. Upload exactly the required files
INCLUDES=()
for f in "${REQUIRED_FILES[@]}"; do
    INCLUDES+=(--include "/$f")
done
rclone copy -P --max-depth 1 "${INCLUDES[@]}" "$PRODUCT_DIR" "$DEST_FOLDER"

echo ""
echo "=========================================================="
echo " Upload complete!"
echo " Folder: ${DEST_FOLDER}"
echo "=========================================================="
echo ""
echo "Contents in ${DEST_FOLDER}:"
rclone ls "$DEST_FOLDER"

echo ""
echo "Generating shareable link for ROM zip..."
rclone link "${DEST_FOLDER}/${ZIP_BASENAME}" || true
