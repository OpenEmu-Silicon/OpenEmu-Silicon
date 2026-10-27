# MAME Core for OpenEmu-Silicon

This directory contains the OpenEmu MAME core wrapper, based on OpenEmu/UME-Core, with the small changes needed to build natively on Apple Silicon against this fork.

Status: WIP. The core builds as arm64 and loads as `org.openemu.MAME`, but polygonal 3D arcade rendering still needs validation/debugging. Use Sega Virtua Racing as the main repro case from issue #500.

## Source dependency

The MAME headless source is intentionally not committed here because it is very large. Prepare it with:

```sh
./Scripts/prepare-mame-core.sh
```

That clones `OpenEmu-Silicon/mame` (MAME 0.289 plus the headless OSD, branch `mame0289-headless`) at the pinned commit in `deps-mame-revision.txt` into `MAME/deps/mame`. No local patches are applied; the fixes the old 0.250 patch carried (including the V60 fix for Virtua Racing / Sega Model 1 graphics on aarch64) are upstream in 0.289. Checkouts that still carry that old patch are cleaned up automatically.

MAME no longer ships an arcade-only subtarget, so the fork generates `src/mame/arcade.flt` with `src/osd/headless/generate-arcade-flt.sh`. Re-run it when moving the fork to a newer MAME version.

## Build

To reproduce the full local build:

```sh
./Scripts/build-mame-core.sh
```

The script automatically mirrors the checkout to a temporary no-space path when the repository path contains whitespace, because MAME's project generator cannot reliably build from paths such as `Open Emu`.

The script does the following:

1. Prepares `MAME/deps/mame` if needed.
2. Builds `mamearcade_headless.dylib` as arm64 with the headless OSD.
3. Builds `OpenEmuBase.framework` into the same DerivedData path.
4. Builds `MAME.oecoreplugin`.

Product path:

```text
MAME/build/XcodeDerived/Build/Products/Release/MAME.oecoreplugin
```

## Manual build notes

```sh
cd MAME/deps/mame
make NOWERROR=1 REGENIE=1 macosx_arm64_clang \
  OSD="headless" verbose=1 TARGETOS="macosx" CONFIG="release" \
  TARGET=mame SUBTARGET=arcade MACOSX_DEPLOYMENT_TARGET=12.0 \
  -j"$(sysctl -n hw.ncpu)"
install_name_tool -id mamearcade_headless.dylib mamearcade_headless.dylib
```

Then build `OpenEmuBase` and the `MAME` project with the same `-derivedDataPath`.

## Local testing

Install the built plugin with the repo helper, which avoids stale bundle merges:

```sh
./Scripts/install-core.sh MAME --release
./Scripts/verify-core-installed.sh MAME --release
```

Use a MAME 0.250-compatible ROM set. Validate both:

- A known sprite-based arcade game, to confirm the core path works.
- Sega Virtua Racing, to investigate the missing polygon issue from #500.
