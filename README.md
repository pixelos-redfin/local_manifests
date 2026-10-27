# local_manifests

repo local manifests and release scripts for PixelOS on Google Pixel 5 (redfin).

## Setup

```bash
repo init -u https://github.com/PixelOS-AOSP/android_manifest.git -b seventeen --git-lfs --depth=1
git clone git@github.com:pixelos-redfin/local_manifests.git .repo/local_manifests
repo sync -c --no-tags
# KernelSU-Next derives its version from its commit count and tags
git -C kernel/google/redbull/KernelSU-Next fetch --unshallow --tags github
ln -s .repo/local_manifests/scripts/sign_release.sh .
ln -s .repo/local_manifests/scripts/upload_build.sh .
```

## Release

```bash
source build/envsetup.sh
lunch custom_redfin cp2a user
m pixelos
./sign_release.sh          # signed full + incremental OTA, images, factory zip, feed (incremental only)
./upload_build.sh          # uploads releases/redfin/latest
```

`sign_release.sh` forces vbmeta flags to 0: the device tree disables
verification unless `WITH_AVB=true`, and such a build never boots with a
locked bootloader.

## Factory image

`scripts/factory/make_factory.sh <release dir>` (run by `sign_release.sh`)
builds `redfin-factory-<tag>.zip` with `flash-all.sh`/`flash-all.bat`,
`avb_pkmd.bin` and the image zip. `flash-all` checks the device, installs the
PixelOS AVB key, flashes with a wipe and offers to relock. Firmware is not
included: the Pixel 5 bootloader only accepts Google's packed bootloader and
radio images, so the phone must be on stock Android 14 (UP1A.231105.001.B2).

Signing keys live in `~/.android-certs` and are never committed.
Never publish the zips in `out/`: they are signed with the AOSP test key.

## Updater feed

`pixelos-ota/API/updater/redfin.json` only carries the incremental OTA from
the previous release (a GitHub release asset; full OTAs exceed the 2 GiB
limit). Full installs use the factory image.
