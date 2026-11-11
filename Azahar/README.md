# Nintendo 3DS core (Azahar.oecoreplugin)

OpenEmu wrapper around the [Azahar](https://github.com/azahar-emu/azahar) engine (GPL-2.0-or-later, a Citra successor). Work is tracked in [#814](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/814). Read [`docs/3ds-azahar-port.md`](../docs/3ds-azahar-port.md) and [ADR-0007](../docs/adr/0007-3ds-core-from-azahar.md) first.

**Status: boots and draws, no sound or input yet.** Items 2, 3 and most of 4 of #814 are in: the engine is pinned and builds from a clean clone with one script, and the core plugin loads a game, runs it, and gives OpenEmu the picture as a Metal texture. Checked with `OE_HEADLESS_SHOT_DIR=<dir> ./Scripts/headless/run.sh Azahar --rom <file> --frames 300 --hash-at 300`: the devkitPro homebrew launcher (`boot.3dsx`) draws both screens (400 by 480), the picture changes frame to frame, and the run ends with no crash. Not yet checked inside the OpenEmu window. There is no sound, input, touch or saves; those are items 5 to 7.

## How it runs

Frame-driven. OpenEmu's game loop calls `executeFrame`, and each call runs the engine until it has drawn one frame (`AzaharHost::RunFrame`). Azahar's own libretro frontend runs the engine the same way. It keeps pause, reset, frame step and speed changes in OpenEmu's hands, with no second thread to hand frames over from. OpenEmu paces the loop, so the engine's own frame limiter is off. `AzaharGameCore.mm` includes no engine headers; `AzaharHost.cpp` is the only code that does.

## Source dependency

The engine source is not committed here (about 560 MB with its submodules). It is fetched from the fork `OpenEmu-Silicon/azahar` at the commit pinned in `deps-azahar-revision.txt`:

```sh
./Scripts/prepare-azahar-core.sh
```

That puts it in `Azahar/deps/azahar` (gitignored). Our changes to the engine are patches in `Azahar/patches/*.patch`, applied in name order. The fork itself stays an untouched snapshot of the Azahar 2126.2 release. Updating means merging upstream Azahar into the fork and bumping the revision in the script and in `deps-azahar-revision.txt`.

Azahar's CMake refuses to configure unless every submodule is present, so the script fetches all of them. It ignores your global git config while it does so (a global "LFS required" setting breaks teakra's checkout on a Mac without `git-lfs`).

## Build

```sh
brew install cmake
./Scripts/build-azahar-core.sh
```

This fetches the source, installs a MoltenVK copy checked against a pinned SHA-256 (`Scripts/build-azahar-deps.sh`; Azahar's own CMake would download it with no check), then configures the engine with no Qt, no desktop frontends and **`ENABLE_LIBRETRO` off**, and builds the engine libraries (`citra_core`, `video_core`, `audio_core`, `input_common`, `citra_common`, `network`) into `Azahar/build/engine`. It writes the built commit to `Azahar/build/ENGINE_COMMIT`. The first run takes a while.

## Files

| File | What it does |
|---|---|
| `deps-azahar-revision.txt` | The pinned fork commit |
| `patches/0001-openemu-host-hooks.patch` | Engine patch behind `OE_HOST`: load MoltenVK from the plugin bundle, and tell the host when a frame has been drawn |
| `patches/0002-openemu-metal-texture-output.patch` | Engine patch behind `OE_HOST`: instead of copying each finished frame to a swapchain, wait for the GPU and take the frame's `MTLTexture` straight from MoltenVK (`VK_EXT_metal_objects`, no copy) |
| `AzaharGameCore.{h,mm}` | The OpenEmu game core (no engine headers) |
| `AzaharHost.{h,cpp}` | The engine side: settings, the window the engine draws into, load, run one frame |
| `Azahar.xcodeproj` | Thin Xcode project; reads `build/engine.xcconfig` and `build/engine-link.rsp` |
| `Info.plist` | Core registration for `openemu.system.3ds`; update feed is `Appcasts/azahar.xml` (empty until release) |
| `../Scripts/gen-azahar-xcconfig.py` | Writes the Xcode inputs from the CMake build |
| `../Scripts/prepare-azahar-core.sh` | Fetches the pinned commit, all submodules, applies patches |
| `../Scripts/build-azahar-deps.sh` | Installs the pinned MoltenVK |
| `../Scripts/build-azahar-core.sh` | Configures and builds the engine libraries |
