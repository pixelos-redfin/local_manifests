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
./sign_release.sh          # signed full + incremental OTA, images, feed
./upload_build.sh          # uploads releases/redfin/latest
```

Signing keys live in `~/.android-certs` and are never committed.
Never publish the zips in `out/`: they are signed with the AOSP test key.
