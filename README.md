# local_manifests

repo local manifests and release scripts for PixelOS on Google Pixel 5 (redfin).

## Setup

```bash
repo init -u https://github.com/PixelOS-AOSP/android_manifest.git -b seventeen --git-lfs --depth=1
git clone https://github.com/pixelos-redfin/local_manifests.git -b seventeen .repo/local_manifests
repo sync -c --no-tags
# KernelSU-Next derives its version from its commit count and tags
git -C kernel/google/redbull/KernelSU-Next fetch --unshallow --tags github
ln -s .repo/local_manifests/scripts/sign_release.sh .
ln -s .repo/local_manifests/scripts/upload_build.sh .
ln -s .repo/local_manifests/scripts/publish_update.sh .
```

## Release

```bash
source build/envsetup.sh
lunch custom_redfin cp2a user
m pixelos
./sign_release.sh          # signed full + incremental OTA, images, factory zip, feed (incremental only)
./upload_build.sh          # uploads releases/redfin/latest
# write releases/redfin/latest/changelog.md (replaces the previous one)
./publish_update.sh        # GitHub release + Updater feed + changelog
```

`sign_release.sh` forces vbmeta flags to 0: the device tree disables
verification unless `WITH_AVB=true`, and such a build never boots with a
locked bootloader.

## Build progress

`scripts/buildwatch.sh [log]` shows a live progress bar (percent, steps, ETA from
the measured rate, current target) for a build logged with `m … > log 2>&1`;
`--events` prints one line per 10% and on errors/finish, `--once` the current state.
Without a log it picks the newest of `~/telegram_bot/logs/*.log` and `~/logs/build-*.log`.
`--status` prints one short line (running build, or its result for 10 min) for the
Claude Code status line: `"statusLine": {"type": "command", "command": "~/.claude/statusline.sh", "refreshInterval": 2}`.

```bash
ln -s .repo/local_manifests/scripts/buildwatch.sh buildwatch
m pixelos > ~/logs/build-pixelos.log 2>&1 &  ./buildwatch ~/logs/build-pixelos.log
```

## Upstream check

`scripts/check_upstream.sh` compares the PixelOS-AOSP forks (frameworks_base,
vendor_custom, Updater, Settings) with upstream `seventeen` and sends the
result to Telegram; keybox/attestation commits are flagged as "do not merge".
Runs weekly from cron (Mondays 09:00 UTC):

```
0 9 * * 1 PATH=/usr/local/bin:/usr/bin:/bin <tree>/.repo/local_manifests/scripts/check_upstream.sh >> ~/logs/check_upstream.log 2>&1
```

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
limit). Full installs use the factory image. Every update replaces
`changelogs/redfin.md`; `publish_update.sh` refuses to publish without a new one.
