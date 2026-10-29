#!/usr/bin/env bash
# Publish a signed release's incremental OTA to the Updater feed together
# with its changelog. Write the changelog first to <release dir>/changelog.md;
# every update must replace the previous one. Installation guides in
# <release dir>/INSTALL_<lang>.md are attached to the GitHub release and
# shown in its notes; the Updater changelog stays the changelog only.
# Usage: publish_update.sh [release dir]   (default: $RELEASES/latest)
set -euo pipefail

RELEASES=${RELEASES:-/serverhive2/unseenpixel/releases/redfin}
OTA=${OTA:-/serverhive2/unseenpixel/pixelos-ota}
REPO=pixelos-redfin/pixelos-ota

die() { echo "Error: $*" >&2; exit 1; }

DEST=$(readlink -f "${1:-$RELEASES/latest}")
TAG=$(basename "$DEST")
INC=$(cd "$DEST" && ls -- *-to-"$TAG"-incremental.zip 2>/dev/null || true)
LOG=$DEST/changelog.md
FEED=$OTA/API/updater/redfin.json
CHANGELOG=$OTA/API/updater/changelogs/redfin.md

[ -n "$INC" ] || die "no incremental OTA in $DEST (the feed only carries deltas)"
[ -f "$DEST/redfin.json" ] || die "no redfin.json in $DEST"
[ -s "$LOG" ] || die "write the changelog for $TAG to $LOG first"

git -C "$OTA" pull -q --ff-only
cmp -s "$LOG" "$CHANGELOG" && die "$LOG is the previous changelog, write the one for $TAG"
for other in "$RELEASES"/*/changelog.md; do
    [ "$other" != "$LOG" ] && cmp -s "$other" "$LOG" && die "$LOG is the changelog of $(basename "$(dirname "$other")"), write the one for $TAG"
done

NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT
cp "$LOG" "$NOTES"
GUIDES=()
for g in "$DEST"/INSTALL_*.md; do
    [ -f "$g" ] || continue
    grep -q '{[A-Z_]*}' "$g" && die "$(basename "$g") still has template placeholders"
    GUIDES+=("$g")
    lang=$(basename "$g" .md); lang=${lang#INSTALL_}
    case $lang in
        ru) summary="Инструкция по установке (русский)" ;;
        *) summary="Installation guide ($lang)" ;;
    esac
    printf '\n\n<details>\n<summary>%s</summary>\n\n%s\n\n</details>\n' "$summary" "$(cat "$g")" >> "$NOTES"
done

echo ">> Creating GitHub release $TAG"
gh release create "$TAG" -R "$REPO" --title "$TAG" --notes-file "$NOTES" "$DEST/$INC" "${GUIDES[@]}"

echo ">> Checking the download"
url=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["files"][0]["url"])' "$DEST/redfin.json")
sum=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["files"][0]["sha256"])' "$DEST/redfin.json")
[ "$(curl -sfL "$url" | sha256sum | cut -d' ' -f1)" = "$sum" ] || die "downloaded $INC does not match redfin.json"

echo ">> Updating feed and changelog"
cp "$DEST/redfin.json" "$FEED"
cp "$LOG" "$CHANGELOG"
git -C "$OTA" add "$FEED" "$CHANGELOG"
git -C "$OTA" commit -q -m "redfin: Push $TAG incremental"
git -C "$OTA" push -q origin HEAD:seventeen

echo "Published $TAG: https://github.com/$REPO/releases/tag/$TAG"

"$(dirname "$(readlink -f "$0")")/tg_notify.py" "🚀 PixelOS redfin $TAG is live in the Updater
$INC
https://github.com/$REPO/releases/tag/$TAG" "$LOG"
