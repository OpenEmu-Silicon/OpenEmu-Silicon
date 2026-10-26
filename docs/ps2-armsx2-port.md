# PlayStation 2 core: ARMSX2 port

How to help build the PS2 core. Read this first, then pick an issue from the [work breakdown](#work-breakdown). The decision and its reasons are in [ADR-0006](adr/0006-ps2-core-from-armsx2.md).

## Status

| Item | State |
|---|---|
| PS2 system plugin and button mapping | Exists (`OpenEmu/SystemPlugins/PlayStation 2`) and ships in the app (it was left out of the app bundle until item 2) |
| Engine builds for arm64 | Proven in a spike (libretro target, no Qt) |
| Engine runs a game fast on Apple Silicon | Proven standalone: one game, about 60 fps |
| Engine pin and build script | Built and run on a Mac (`Scripts/build-armsx2-core.sh`) |
| OpenEmu core plugin | Builds, installs, loads a BIOS and boots a game into its code (item 2). No picture, sound or input yet |
| Heavy 3D games | Untested |

Nothing in this port is released. The first release will be marked Experimental.

## Why ARMSX2

Upstream PCSX2 has no arm64 recompiler for the vector units, so a core built on it falls back to an interpreter and runs demanding games badly. [ARMSX2](https://github.com/ARMSX2/ARMSX2) (GPL-3.0, fork of PCSX2) has ARM64 recompilers for the EE, IOP and both vector units, and a Metal renderer. See the ADR for the numbers.

## What exists to build from

- **The old OpenEmu bridge:** [`OpenEmu/PCSX2-Core`](https://github.com/OpenEmu/PCSX2-Core). About 1,150 lines of OpenEmu glue in `Classes/PCSX2GameCore.mm` (load, run, pause, reset, save state, disc swap, display modes, input) plus its host hooks. Use it as the template.
- **A fork with an arm64 evaluation branch:** `nickybmon/PCSX2-Core`, branch `arm64-evaluation` (arm64 switches, deployment target, JIT entitlement). Written for the old upstream engine, so use it for ideas, not as a base.
- **A Metal-rendering core to copy the pattern from:** `Dolphin/DolphinGameCore.mm` and `Dolphin/DolHost.mm` (`OEGameCoreRenderingMetal2`, host sets a Metal layer and texture).
- **The retired plan:** issues #323 to #327 (closed). Useful for the link-error catalog in #323 and #324, which describes the old bridge, not ARMSX2.

## How the old bridge maps onto ARMSX2

Measured by comparing the old bridge's source with ARMSX2 at commit `65fd14b`. Nothing here has been compiled together yet.

**Ports with little or no change**
- Engine control. The bridge uses 21 `VMManager` calls. All but `Internal::GetElfOverride` exist in ARMSX2 with the same signatures.
- Host hooks. The engine library needs 54 host functions (found by listing symbols the engine objects call but do not define). The old bridge already has 24: render window, VM start/stop/pause/resume, save-state events, run on CPU thread, error reports, and similar.
- Settings. Both use an INI settings object registered with `Host::Internal::SetBaseSettingsLayer`.
- Controller state. ARMSX2 has `Pad::SetControllerState`. The bridge's own 760-line copy of `Pad.cpp` should not be needed.
- OpenEmu-side glue: disc count and swap, display modes, error reporting.

**Needs changes**
- Metal output. The old bridge forked the whole Metal device file. The OpenEmu change is one step: in `EndPresent`, blit the drawable into OpenEmu's Metal texture before presenting. ARMSX2's `GSDeviceMTL.mm` has the same `EndPresent` shape (around line 1852). Patch it behind a build flag instead of forking the file.
- Data paths. The engine writes a persisted vector-unit JIT cache under its data folder. Point its data root at OpenEmu's support folder.
- Input wiring. Replace `pad->Set(...)` with `Pad::SetControllerState`, and check analog sticks and pressure.
- Small stubs (Discord, ImGui, achievements, GS capture, GS dump replay). Check each against ARMSX2. Some may be unneeded.

**Missing**
- 30 host functions. Most are no-ops (clipboard, text input, file picker, fullscreen, exit, game list). `SetPadVibration` is new and can drive rumble. ARMSX2's `pcsx2-libretro/Main.cpp` defines almost all of them and is a ready template.
- Audio. The old bridge replaced the sound mixer with its own copy. ARMSX2 has a new NEON mixer and sends audio through `AudioStream` (Cubeb, SDL, Oboe, Null backends). Add one OpenEmu backend that writes into the OpenEmu audio ring buffer (`OERingBuffer`).
- Build. The old Xcode project lists every engine source by hand (about 415 files) and drifted out of date. Build the engine with CMake (the libretro target shows it builds without Qt) and wrap it in a thin Xcode project. Turning off the Vulkan and OpenGL options to drop `shaderc` and `molten-vk` is untested.

## Try the engine yourself

You need a PS2 BIOS dump and a game image from a console and discs you own. Do not share or commit them.

Build the engine library (Apple Silicon, Xcode, Homebrew):

```bash
git clone --depth 1 https://github.com/ARMSX2/ARMSX2.git
brew install cmake shaderc molten-vk sdl3
# plutovg and plutosvg are vendored in 3rdparty/. Build both and install them to a
# private prefix, then pass that prefix in CMAKE_PREFIX_PATH.
cmake -S ARMSX2 -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_PREFIX_PATH="<your-prefix>;/opt/homebrew" \
  -DENABLE_QT_UI=OFF -DENABLE_SDL_FRONTEND=OFF -DENABLE_LIBRETRO=ON \
  -DENABLE_GSRUNNER=OFF -DENABLE_TESTS=OFF -DENABLE_RECOMPILER_TEST_HOOKS=OFF \
  -DDISABLE_ADVANCE_SIMD=ON -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON
cmake --build build --target pcsx2-libretro -j
```

The result is `build/pcsx2-libretro/armsx2_libretro.dylib`, a Mach-O arm64 library. It is a build proof, not a core we ship. The `pcsx2-gsrunner` target does not link on macOS yet (`Host::SetPadVibration` is undefined).

Measure speed with the official macOS nightly from the ARMSX2 releases page. Put a BIOS file in a data folder and run:

```bash
mkdir -p ~/ps2-test/data/bios ~/ps2-test/data/inis
cp /path/to/your/scph39001.bin ~/ps2-test/data/bios/
printf '[UI]\nSetupWizardIncomplete = false\n[Filenames]\nBIOS = scph39001.bin\n' > ~/ps2-test/data/inis/PCSX2.ini
/path/to/ARMSX2.app/Contents/MacOS/ARMSX2 -datapath ~/ps2-test/data \
  -logfile ~/ps2-test/emulog.txt -batch -fastboot -- /path/to/game.iso
```

The log prints a `PerfLog:` line every 30 seconds (fps, EE, GS, VU, GPU) and a session average at shutdown.

## Work breakdown

All items live as checkboxes in one tracker issue, so there is one place to look. To take an item, comment on the tracker with the item number. Open a separate issue only when an item turns up a bug that needs its own discussion, and link it from the tracker. Items 1 and 2 come first. Items 3 to 7 can run in parallel once item 2 boots a BIOS.

1. **Vendoring and engine build.** Pin an ARMSX2 commit. Build the engine with CMake as libraries the plugin can link, Metal only if possible. Decide how the engine lives in the repo (see ADR open decisions). Done when: the engine builds from a clean clone with one script, and the pinned commit is recorded.
2. **Core plugin skeleton.** Port the old bridge onto ARMSX2: the 24 existing host hooks, the 30 missing ones, `VMManager` calls, settings and data paths. Add the `OpenEmu + PCSX2` scheme (or the name `Scripts/verify.sh` expects). Done when: the plugin installs, loads a BIOS and reaches the boot screen with no video output required.
3. **Metal output.** Patch `EndPresent` behind a flag to blit into OpenEmu's texture. Done when: the game picture shows in the OpenEmu window and resizes correctly.
4. **Audio.** Add an OpenEmu `AudioStream` backend writing to `OERingBuffer`. Done when: game audio plays without crackle at full speed and during pause and resume.
5. **Input and rumble.** Map `OEPS2Button` to `Pad::SetControllerState`, including analog and pressure. Implement `SetPadVibration`. Done when: a DualShock 4 and a keyboard both play a game.
6. **Saves and discs.** Save states, memory cards, disc swap and display modes through OpenEmu paths. Done when: save and load state work after a relaunch, and memory cards persist.
7. **JIT and threading review.** Prove the recompilers run inside the helper process. Review thread hand-offs between engine threads and OpenEmu. Run the adversarial reviewer on the result. Done when: a 30 minute session runs with no crash or hang.
8. **Compatibility and speed matrix.** Run a list of games (light and demanding) and record fps and problems. Good for contributors with their own game libraries. Done when: a table of results is in the tracker.
9. **Packaging and Experimental release.** Bundle the linked libraries (SDL3, libpng, libjpeg, libwebp, zstd, lz4, freetype) inside the plugin, sign, add the appcast and credits (GPL notice, ARMSX2 and PCSX2). A maintainer cuts the release. Done when: a clean install picks up the core from the appcast.

## Branching

All PS2 work lands on the long-lived integration branch `feat/ps2-core`, not on `main`. The core takes time and is not releasable until it works end to end. When it is ready, one PR merges `feat/ps2-core` into `main`, and a maintainer decides when.

- Branch from `feat/ps2-core` and open your PR against `feat/ps2-core`.
- Keep `feat/ps2-core` current with `main` (`git fetch origin && git merge origin/main`), so the final merge stays small.
- Never ship or release from `feat/ps2-core`. Release only from `main`.

## Ground rules

- Pin to a commit. Do not track ARMSX2 nightlies.
- No BIOS files, game images or save data in the repo, issues or PRs.
- Do not use the libretro target as the integration path.
- Keep ARMSX2 patches small and behind a flag, so a version bump stays cheap.
- Follow the repo's PR and issue rules in `AGENTS.md`. Link PRs to the tracker with `Related to #N`, and tick the item when its PR merges.

## Known unknowns

- Metal backend behavior when drawing into a host-supplied texture.
- Recompilers and the persisted JIT cache inside the OpenEmu helper app.
- Heavy 3D titles (the old plan's worst cases: God of War, Shadow of the Colossus, Gran Turismo 4).
- Build with Vulkan and OpenGL turned off.
- How closely ARMSX2 tracks upstream over time.
