#!/usr/bin/env bash
# PixelOS factory image installer for the Pixel 5 (redfin).
# Flashes PixelOS, installs the PixelOS verified boot key and wipes the
# device. The phone must already run the latest stock Android 14 firmware
# (UP1A.231105.001.B2); the bootloader refuses single firmware partitions.
# Needs Android platform-tools 35 or newer.
set -euo pipefail
cd "$(dirname "$0")"

TAG=@TAG@
IMAGE=image-redfin-$TAG.zip

die() { echo; echo "Error: $*" >&2; exit 1; }
ask() { local a; read -rp "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
getvar() { fastboot getvar "$1" 2>&1 | sed -nE "s/^$1: *//p" | head -1; }

command -v fastboot >/dev/null || die "fastboot not found. Install Android platform-tools and add them to PATH."
fb_ver=$(fastboot --version | sed -nE 's/^fastboot version ([0-9]+).*/\1/p')
[ "${fb_ver:-0}" -ge 35 ] || die "fastboot is too old (${fb_ver:-unknown}). Update Android platform-tools to 35 or newer."
for f in "$IMAGE" avb_pkmd.bin; do
    [ -f "$f" ] || die "missing $f. Extract the whole factory zip first."
done

echo "PixelOS $TAG for Pixel 5 (redfin)"
echo
echo "Put the phone in bootloader mode (power off, hold Power + Volume Down) and connect it."
echo "Waiting for the device..."
until fastboot devices | grep -q fastboot; do sleep 1; done

product=$(getvar product)
[ "$product" = redfin ] || die "this is '$product', not a Pixel 5 (redfin). Nothing was flashed."
[ "$(getvar unlocked)" = yes ] || die "the bootloader is locked. Enable OEM unlocking in Developer options, then run: fastboot flashing unlock"

echo
echo "Bootloader: $(getvar version-bootloader)   Modem: $(getvar version-baseband)"
echo "The phone must have been updated to the latest stock Android 14 (UP1A.231105.001.B2)"
echo "before installing PixelOS. If unsure, flash it first from https://flash.android.com"
echo
echo "WARNING: this erases ALL data on the phone and installs PixelOS $TAG."
ask "Continue?" || { echo "Cancelled. Nothing was flashed."; exit 0; }

echo
echo ">> Installing the PixelOS verified boot key"
fastboot erase avb_custom_key
fastboot flash avb_custom_key avb_pkmd.bin

echo ">> Flashing PixelOS and wiping data"
fastboot -w --skip-reboot update "$IMAGE"
fastboot reboot-bootloader
sleep 5
until fastboot devices | grep -q fastboot; do sleep 1; done

echo
echo "PixelOS is installed."
echo
echo "You can now relock the bootloader. A locked bootloader verifies PixelOS on every"
echo "boot and blocks tampering. The phone will show a yellow 'different operating"
echo "system' notice at boot; that is expected. Locking wipes the phone again, so do it now."
if ask "Lock the bootloader now? Confirm on the phone with Volume keys + Power."; then
    fastboot flashing lock
    echo "Locked. Choose Start on the phone to boot PixelOS."
    echo "Keep OEM unlocking enabled until you have checked that PixelOS boots."
else
    fastboot reboot
    echo "Booting PixelOS. To lock later: reboot to bootloader and run: fastboot flashing lock"
fi
