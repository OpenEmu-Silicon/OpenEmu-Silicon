# PlayStation 2 core (PCSX2.oecoreplugin)

OpenEmu wrapper around the [ARMSX2](https://github.com/ARMSX2/ARMSX2) engine, a GPL-3.0 fork of PCSX2 with ARM64 recompilers and a Metal renderer. Work is tracked in [#769](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/769). Read [`docs/ps2-armsx2-port.md`](../docs/ps2-armsx2-port.md) and [ADR-0006](../docs/adr/0006-ps2-core-from-armsx2.md) first.

**Status: experimental and unreleased.** Items 1 to 5 of #769 and most of item 6 are in. The core boots a BIOS and games, draws through OpenEmu's Metal texture, plays sound, and takes keyboard and controller input, save states, rumble, fast-forward, slow motion, frame step and disc swap.

| Checked in the app (Dragon Quest VIII, Apple Silicon) | Result |
|---|---|
| Boot, picture, sound | Works. 60 fps in the title screens and cutscenes, no sound overruns. |
| Keyboard | Works: Start, Cross and the left stick moved the title menu. |
| Resume from a save state | Works (loads an existing state, picture and speed normal). |
| Memory cards | The two 8 MB card files persist across launches. A game saving to its card has not been tried. |

Not yet checked: D-pad and right stick, rumble on a real controller, saving a state and loading it in the same session, disc swap and display modes, heavy 3D games, long sessions (item 7), or any game other than Dragon Quest VIII (items 7 and 8). There is a single short hitch of about 3 seconds just after Start on the Dragon Quest VIII title screen, probably the game loading; it has not been traced.

## Source dependency

The engine source is not committed here (about 560 MB). It is fetched from a fork at the commit pinned in `deps-armsx2-revision.txt`:

```sh
./Scripts/prepare-armsx2-core.sh
```

That puts it in `PCSX2/deps/armsx2` (gitignored). Small changes to the engine are patches in `PCSX2/patches/*.patch` or commits in the fork.

## Build

```sh
brew install cmake
./Scripts/build-armsx2-core.sh
```

Stage 1 first builds the third-party libraries the engine needs (libpng, libjpeg-turbo, libwebp, zstd, lz4, freetype, SDL3) from pinned source archives as static libraries for macOS 13 (`Scripts/build-armsx2-deps.sh`), so the plugin needs nothing from Homebrew at run time and loads on the macOS versions OpenEmu supports. It then builds the engine with CMake and writes `PCSX2/build/engine.xcconfig` (compile flags) and `PCSX2/build/engine-link.rsp` (link line), which `PCSX2.xcodeproj` reads. Stage 2 builds `PCSX2.oecoreplugin`. Install it with `./Scripts/install-core.sh PCSX2` and confirm with `./Scripts/verify-core-installed.sh PCSX2`.

You need a PS2 BIOS dump (for example `scph39001.bin`) in OpenEmu's PlayStation 2 BIOS folder. Do not commit or share BIOS files or game images.

## Files

| File | What it does |
|---|---|
| `PCSX2GameCore.{h,mm}` | The `OEGameCore`: finds a BIOS, starts and stops the engine, pause and reset, input, save states, disc swap, rumble and speed controls. |
| `OEHost.{h,cpp}` | The engine's `Host::` callbacks and its CPU thread, adapted from ARMSX2's `pcsx2-libretro/Main.cpp`. |
| `Info.plist` | Registers the core for `openemu.system.ps2`. |
| `deps-armsx2-revision.txt` | The pinned engine commit. |

## Why the engine is built in its "libretro" mode

`ENABLE_LIBRETRO=ON` is an engine setting meaning "the host owns pads, audio and video". It declares `Host::SetPadVibration` (our rumble hook, item 5), embeds the shaders and game database in the binary, and leaves the frontend callbacks to us. We do not build or use the libretro target or API.
