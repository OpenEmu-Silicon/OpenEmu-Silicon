# Nintendo 3DS core: Azahar port

How to help build the 3DS core. Read this first, then pick an item from the [work breakdown](#work-breakdown). The decision and its reasons are in [ADR-0007](adr/0007-3ds-core-from-azahar.md).

If you already have Azahar running in OpenEmu, compare your work with this page. [What the host must provide](#what-the-host-must-provide) and [The patch points](#the-patch-points-in-azahar) are checklists. Tick off what you have, add what is missing, and correct anything here that is wrong. Your design wins where it is better.

## In plain English

A 3DS emulator is a lot of machinery: an ARM CPU recompiler, a model of the 3DS graphics chip, an audio engine, the 3DS operating system's services, and save data handling. Azahar already has all of it, and it already keeps the emulator apart from its windows and menus. So we do not write an emulator. We write the thin layer that lets OpenEmu run it:

1. **Start it and run it.** Load a game, run frames, pause, reset, stop.
2. **Show it.** Azahar draws with Vulkan (through MoltenVK on a Mac). OpenEmu wants a Metal texture. We copy one into the other.
3. **Hear it.** Hand Azahar's sound to OpenEmu's audio buffer.
4. **Control it.** Turn OpenEmu's buttons, sticks and mouse clicks into 3DS buttons, circle pad and bottom-screen touches.
5. **Save it.** Save states and in-game saves go to OpenEmu's folders.
6. **Package it.** Build the engine and its libraries from pinned source, bundle everything in one plugin, sign it.

The PlayStation 2 core ([#769](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/769)) is the same job for a different engine, and it is further along. 3DS follows the same plan. The biggest differences are that a 3DS has two screens and a touch screen, and that Azahar draws with Vulkan where ARMSX2 draws with Metal.

## Status

| Item | State |
|---|---|
| Fork of the engine | Done: [`OpenEmu-Silicon/azahar`](https://github.com/OpenEmu-Silicon/azahar), a fork of `azahar-emu/azahar` (default branch `master`). The pinned commit below exists in the fork. |
| Pinned commit | `219d743a1e698101fe1ab8bef43e6563126c3c27`, the Azahar 2126.2 release (stable, 2026-10-08). The fork does not carry upstream's tags, so pin the commit, not the tag. |
| 3DS system plugin | Does not exist in this repo. A draft is in `OpenEmu/OpenEmu#5157` (unreviewed). |
| Engine builds for arm64 as static libraries | Not proven by us. Azahar's own CI builds a Qt-free macOS arm64 build (libretro), so a Qt-free build is a supported shape. |
| Engine runs a game on Apple Silicon | Official Azahar macOS builds exist. Not measured by us. |
| OpenEmu core plugin | Not started in this repo. An outside contributor reports a working build; we have not seen it. |
| Heavy 3D games, stereo 3D, camera | Untested |

Nothing in this port is released. The first release will be marked Experimental.

## Why Azahar

[Azahar](https://github.com/azahar-emu/azahar) (GPL-3.0) is the maintained successor to Citra. The other candidate, Panda3DS, runs far fewer games (its README says "many don't boot") and its OpenEmu plugin is an unreviewed upstream PR. See the ADR for the comparison.

## Follow the PS2 pattern

Everything that connects the core to this repo goes through the fork, the way PS2 goes through `OpenEmu-Silicon/armsx2`. Do not copy Azahar source into this repo, and do not point anything at `azahar-emu/azahar` directly.

| Piece | PS2 (what exists, on `feat/ps2-core`) | 3DS (what to build) |
|---|---|---|
| Engine fork | `OpenEmu-Silicon/armsx2` | `OpenEmu-Silicon/azahar` (exists) |
| Pin | `PCSX2/deps-armsx2-revision.txt` and `REVISION=` in the prepare script | `Azahar/deps-azahar-revision.txt` and `REVISION=` in `Scripts/prepare-azahar-core.sh` |
| Fetch | `Scripts/prepare-armsx2-core.sh`: shallow fetch of the pinned commit into `PCSX2/deps/armsx2` (gitignored), check the commit, apply `PCSX2/patches/*.patch` with `git apply` | Same, into `Azahar/deps/azahar`, **plus** `git submodule update --init --recursive --depth 1` (Azahar has 52 submodule entries). See [Submodules](#submodules-and-the-snapshot). |
| Our changes to the engine | Small flagged patches in `PCSX2/patches/`, for example `0001-openemu-metal-output.patch` behind `OE_METAL_OUTPUT` | Same: `Azahar/patches/0001-openemu-vulkan-output.patch` behind an `OE_OUTPUT` flag. The fork stays an untouched snapshot of the pinned release. |
| Third-party libraries | `Scripts/build-armsx2-deps.sh` builds each library from a pinned archive with a SHA-256, as static libraries for macOS 13, so the plugin needs no Homebrew | Same idea. Azahar's CMake downloads MoltenVK at configure time (see below), so fetch and verify it ourselves instead. |
| Engine build | `Scripts/build-armsx2-core.sh`: CMake to static libraries, then compile Metal shaders, then generate Xcode inputs | `Scripts/build-azahar-core.sh`: the same stages. Azahar appears to build its shaders at run time (it bundles glslang, SPIR-V tools and sirit), so there may be no separate shader step. Check this in item 2. |
| Xcode glue | `Scripts/gen-armsx2-xcconfig.py` reads the engine's `compile_commands.json` and link line and writes `engine.xcconfig` and `engine-link.rsp`, so the project never drifts from CMake | Reuse the idea: copy the script and point it at an Azahar target |
| Plugin | `PCSX2/PCSX2.xcodeproj`, `PCSX2GameCore.{h,mm}` (about 600 lines), `OEHost.{h,cpp}` (about 670 lines), `Info.plist` | `Azahar/Azahar.xcodeproj`, `AzaharGameCore.{h,mm}`, a host file, `Info.plist` |
| Tracker and branch | Issue #769, branch `feat/ps2-core`, ADR-0006, port doc | Issue #814, branch `feat/3ds-core`, ADR-0007, this doc |

One thing **not** to copy: PS2 builds its engine with `ENABLE_LIBRETRO=ON`, because in ARMSX2 that switch means "the host owns pads, audio and video". In Azahar the same switch means something different and unwanted: it defines `HAVE_LIBRETRO` in every library and makes the Vulkan renderer take a device and images from a libretro frontend (`LibRetroVKInstance`, `libretro_vk.cpp`). Build Azahar with it **off**, and use its normal macOS Vulkan path with a `CAMetalLayer`.

## What exists to build from

Read these in this repo before writing anything. Each shows one part of the job already done.

| Need | Look at | What it shows |
|---|---|---|
| A big engine kept in a fork, pinned by commit, built by script, wrapped by a thin Xcode plugin | `FBNeo/`, `Scripts/prepare-fbneo-core.sh`, `Scripts/build-fbneo-core.sh`, `FBNeo/deps-fbneo-revision.txt` | The fork-and-pin pattern, the two-stage build, the empty appcast until first release, the CI job for a core that is not in the matrix |
| The same pattern with CMake, bundled libraries and a small engine patch | the PS2 core on `feat/ps2-core` (`PCSX2/`, `Scripts/*armsx2*`, `PCSX2/patches/`), [PS2 port doc](ps2-armsx2-port.md), [ADR-0006](adr/0006-ps2-core-from-armsx2.md), tracker #769 | The work breakdown and branching to copy. Its game core is the closest model for 3DS. |
| A core that draws into OpenEmu's Metal texture | `Dolphin/DolphinGameCore.mm`, `Dolphin/DolHost.mm`, and the PS2 core's `createMetalTextureWithDevice:` | `gameCoreRendering` returns `OEGameCoreRenderingMetal2`. The core makes a sizing `CAMetalLayer` or view for the engine and hands OpenEmu a texture. PS2 alternates two textures and tells OpenEmu which one is ready. |
| A two-screen system with touch and display modes | `OpenEmu/SystemPlugins/NDS/` and `DeSmuME/src/frontend/cocoa/openemu/NDSGameCore.h` | `didTouchScreenPoint:` / `didReleaseTouch`, mouse-to-touch mapping, "Display Modes" for layouts |
| The host hooks a Citra-family engine needs | Azahar's own `src/citra_libretro/` (about 4,300 lines) | Every callback the engine needs, worked out once. Read it. Do not build or ship it (see Ground rules). |
| A system plugin with no core yet | `OpenEmu/SystemPlugins/PlayStation 2/` | The files a system plugin needs |

## How the PS2 core is built, and what 3DS does differently

Read `PCSX2/PCSX2GameCore.mm` and `PCSX2/OEHost.cpp` on `feat/ps2-core` first. This is what they do and where Azahar differs. This comparison comes from reading both code bases. Nothing here has been run on the 3DS side.

| Area | PS2 core | 3DS with Azahar | What it means |
|---|---|---|---|
| Who runs the loop | The engine runs on its own CPU thread and paces itself. OpenEmu's `executeFrame` only drains audio. | Azahar's own libretro frontend does the opposite: every frame it calls `System::RunLoop()` until the window reports "a frame was submitted", with Azahar's frame limiter and audio stretching turned **off** (`frame_limit = 0`). | 3DS can be driven one frame at a time from `executeFrame`. That makes pause, frame step, speed changes and rewind easier than PS2. Free-running on its own thread, the PS2 way, also works. Choose in item 3 and write down why. |
| Metal pacing quirk | `[self.renderDelegate suspendFPSLimiting]`, because OpenEmu's Metal renderer waits for a signal only OpenGL cores send | Same problem expected for any `Metal2` core | Copy the PS2 workaround, or check whether it is still needed. |
| Picture | A patch in the engine's Metal "present" step renders into one of two OpenEmu textures, alternating, and OpenEmu is told which is ready | The engine renders into its own offscreen image (`Frame`), and `PresentWindow::CopyToSwapchain` copies it to the swapchain. That copy is where the patch goes: copy into an OpenEmu texture instead. | The same idea, but Vulkan to Metal needs a bridge. See [the patch points](#the-patch-points-in-azahar). |
| Audio | A Null engine backend keeps sound in a ring. `executeFrame` pulls it, converts float to 16-bit, writes to OpenEmu's ring, and drops it when speed is not 1x. | Azahar's audio sink interface is small: it hands the sink 16-bit stereo, and a sink can ask for samples to be pushed to it (`ImmediateSubmission`, `PushSamples`). Azahar's libretro sink is 27 lines. | Easier than PS2. Add one OpenEmu sink and register it. |
| Input | `Pad::SetControllerState(player, input, value)` called from the responder methods | Azahar reads input through factories (`ButtonDevice`, `AnalogDevice`, `MotionDevice`). The libretro frontend registers three. Touch goes through `EmuWindow::TouchPressed/TouchMoved/TouchReleased`. | Register an "openemu" factory set that reads a small input state we update from the responder. Touch needs the layout (see below). |
| Save states | Engine writes its own zip on its CPU thread. The core blocks until done. A resume state may arrive before the VM exists, so it waits up to 30 s. | Azahar has `SaveStateBuffer()` and `LoadStateBuffer()` (in memory). The libretro frontend first runs `RunLoop()` until no asynchronous kernel work is pending (up to 5 s), because saving mid-operation is unsafe. | The same "wait until ready" care. The buffer API means no engine patch is needed. Write the buffer to OpenEmu's file. |
| Disc and games | `.m3u` playlist, disc swap, cue to bin | One cartridge file per game, no disc swap. 3DS cartridge formats are loaded by NCCH, 3DSX and ELF loaders. | Simpler. A compressed Azahar format exists; decide whether to accept it. |
| Rumble | `Host::SetPadVibration` becomes an `OEGameCoreRumble` notification | The 3DS has no rumble | Not needed. |
| Settings and folders | Engine INI under OpenEmu's support folder, set by `OEHost::Initialize` | Azahar has `FileUtil::SetUserPath(dir)` (the libretro frontend uses it) and a `Settings::values` struct | Point the user directory at OpenEmu's support folder. Do not touch a standalone Azahar's settings. |
| Window | A plain `NSView` as the engine's render surface, even though the picture goes to a texture | An `EmuWindow` subclass with `WindowSystemType::MacOS` and a `CAMetalLayer` as `render_surface` | Same trick. The Vulkan code already makes a Metal surface from that layer. |
| Fixed size | 640 by 448 | The size depends on the layout and the internal resolution setting | Azahar needs resizing support PS2 does not. See [open question: texture size](#known-unknowns). |
| JIT | Recompilers inside the helper process (unproven yet) | Azahar's CPU recompiler (Dynarmic, with the Oaknut assembler) maps JIT memory with `MAP_JIT` on Apple, which is the form Apple's hardened runtime allows with the `allow-jit` entitlement | Same entitlement as PS2. Proving it in the helper is item 8. |

## What the host must provide

The architecture the core must supply. For each row, the Azahar side is from reading its source at the pinned commit; the OpenEmu side is from this repo. Mark each row with what you have working.

| Part | What Azahar expects | What OpenEmu offers | Notes |
|---|---|---|---|
| Window | A subclass of `Frontend::EmuWindow`: `PollEvents`, `MakeCurrent`, `DoneCurrent`, `SwapBuffers`, a `WindowSystemInfo` (type, surface, scale), and a size. Azahar's libretro window is 348 lines. | `OEGameCore` has no window, so the core makes a layer or view (as Dolphin and PS2 do) | `WindowSystemType::MacOS`, `render_surface` = `CAMetalLayer`. |
| Video | Vulkan renderer through MoltenVK. OpenGL is switched off on Apple (it needs 4.3, macOS has 4.1). A software renderer exists. | Metal texture from `createMetalTextureWithDevice:`, `gameCoreRendering` = `OEGameCoreRenderingMetal2` | The seam is `PresentWindow::CopyToSwapchain`. |
| Run loop | `Core::System::Load(window, path)`, then `RunLoop()` repeatedly. Frame pacing is Azahar's frame limiter unless `frame_limit` is 0. | `executeFrame`, paced by OpenEmu at the core's `frameInterval` | Choose frame-driven or free-running. |
| Audio | A sink (`GetNativeSampleRate`, `SetCallback`, optional `ImmediateSubmission` and `PushSamples`) registered in `sink_details.cpp` | `getAudioBuffer:` or the ring buffer | Azahar's native rate is the sink's rate. Resampling is Azahar's job. |
| Input | Button, analog and motion devices from `input_common` factories, plus `TouchPressed` and friends on the window | `OESystemResponder` and a 3DS responder client protocol | The responder client does not exist yet. Model it on `OENDSSystemResponderClient.h`. |
| Touch | A point inside the bottom screen of the **current** layout | `mouseDownAtPoint:` and `mouseUpAtPoint` in the responder | OpenEmu sends a point in the displayed picture. Convert it to the engine's framebuffer coordinates, then through the layout, using the engine's own `IsWithinTouchscreen` and `ClipToTouchScreen` (they exist on `EmuWindow`). |
| Mic, camera, motion | Mic and motion hooks exist in the libretro frontend. Camera has a factory interface. | Permission prompts and helper entitlements | Defer. Do not block the first release. |
| Applets | Software keyboard and Mii selector have a default implementation (`core/frontend/applets/default_applets.cpp`). Azahar's libretro frontend registers neither of its own. | None | Check what the defaults do when a game asks for text or a Mii. A real keyboard UI is later work. |
| Layouts | Default, single, large, side, hybrid, custom (`LayoutOption`), set through settings; the window calls `UpdateCurrentFramebufferLayout(w, h)` | "Display Modes" through `displayModeInfo` | The NDS window-size exemptions in `OpenEmu/GameWindowController.swift` (near lines 279 and 347) exist because layout changes break sizing. Expect the same here. |
| Saves | `SaveStateBuffer()` and `LoadStateBuffer()`; in-game saves on a virtual SD card and NAND under the user directory | `saveStateToFileAtURL`, `batterySavesDirectory`, `supportDirectory` | Wait for pending asynchronous kernel work before saving. |
| Settings | A `Settings::values` struct filled before `System::Load`, then `ApplySettings()` | `Info.plist` options and display modes | Fill the struct in code. Do not read a user's standalone Azahar config. |
| Games | NCCH (`.3ds`, `.cci`, `.cxi`, `.app`), `.3dsx`, `.elf`, and a network "artic" source (do not enable) | The system plugin's file suffixes, import and hashing | Encrypted dumps need keys (open decision 3). |
| JIT | Dynarmic ARM64 recompiler (`use_cpu_jit` is on by default) | The helper app carries `allow-jit` and `disable-library-validation` (per ADR-0006) | Prove it in the helper. A slower interpreter is the fallback. |

## The patch points in Azahar

Where our code touches Azahar, found by reading the pinned source. Keep each change small, behind a flag, as a `.patch` file. Line numbers are left out on purpose, since they move.

1. **Output.** `video_core/renderer_vulkan/vk_present_window.cpp`, `PresentWindow::CopyToSwapchain(Frame*)`. Each rendered frame is an offscreen image (`Frame::image`) that this function copies to the swapchain. Add a flagged path that copies it into an OpenEmu-owned image instead. That image comes from OpenEmu's `MTLTexture`, brought into Vulkan with MoltenVK's `VK_EXT_metal_objects` import (or exported the other way). **Check that the MoltenVK version supports this; if not, the fallback is a read-back and `replaceRegion`, which is slow.** Azahar has an `async_presentation` setting (a present thread); turning it off puts the copy on the emulation thread, which is simpler to start with.
2. **Surface.** `video_core/renderer_vulkan/vk_platform.cpp` already builds a Metal surface from a `CAMetalLayer`. With the output patch the swapchain may not be needed. Keep it for the first spike so the engine behaves as it does on desktop.
3. **Audio.** `audio_core/sink_details.cpp`. Add an OpenEmu sink entry beside Cubeb, OpenAL, SDL2 and Null, following `libretro_sink.{h,cpp}`.
4. **Input.** Register a factory set the way `citra_libretro/input/input_factory.cpp` does (button, analog, motion). A patch is not needed if this lives in our code.
5. **Settings and folders.** Set `Settings::values` and call `FileUtil::SetUserPath(...)` from our code before `System::Load`. Mirror `citra_libretro/core_settings.cpp`: it sets `frame_limit = 0`, turns audio stretching off, and chooses the graphics API.
6. **Build.** Azahar's top-level CMake needs at least one frontend target to build libraries. Turning off Qt, SDL2, Cubeb, OpenAL, libusb, tests, the room server, web services, scripting, the GDB stub and Discord should leave the library targets (`citra_core`, `video_core`, `audio_core`, `input_common`, `common`). Whether this configures cleanly at the pin is the first thing item 2 must prove.

## Submodules and the snapshot

Forking `azahar` into the org snapshots Azahar's own source. It does **not** snapshot its submodules: they are separate repositories that the fork still points at on their original hosts. At the pinned commit there are 52 submodule entries (nested ones included), among them boost, dynarmic, oaknut, glslang, spirv-tools, vulkan-headers, sirit, cryptopp, libressl, fmt, soundtouch, faad2, teakra, zstd, enet, xxHash, SDL2, openal-soft, cubeb, libusb and more. A fresh shallow fetch of all of them is about 560 MB. Desktop-only ones (SDL2, openal-soft, cubeb, libusb, discord-rpc, Qt-related) are not needed for a core and can be skipped.

- A network hiccup failed one submodule (`teakra`) in a trial fetch; a second run succeeded. The prepare script must retry.
- If a submodule host removes or rewrites a commit, the pin breaks. To make the snapshot real, mirror the submodules we use into the org and point the fork's `.gitmodules` at the mirrors. This is open decision 7 in the ADR.
- Pin by commit, never by branch. Record every submodule commit by letting the fork's gitlinks do it; do not run `git submodule update --remote`.

## MoltenVK

Azahar's CMake downloads `MoltenVK-all.tar` (v1.4.1) from the Khronos GitHub release during configure, unless `USE_SYSTEM_MOLTENVK` is set. A build that fetches an unpinned binary at configure time breaks reproducibility and the supply-chain rule used for the PS2 libraries. Do what `build-armsx2-deps.sh` does: fetch it once from a pinned URL, check a SHA-256, and point CMake at it. The dynamic library then ships inside the plugin.

## Everything a new core and a new system touch

Use this as a checklist so nothing is forgotten. File names are from this repo today.

**System plugin** (item 1 below)
- `OpenEmu/SystemPlugins/Nintendo 3DS/`: `3DS-Info.plist`, controller and keyboard mapping plists, responder, responder client protocol, system controller, artwork. Copy the shape of `PlayStation 2/` and `NDS/`.
- `OpenEmu/OpenEmu.xcodeproj`: a new `.oesystemplugin` target and its entry in the "Copy System Plugins to App Plugins" phase.
- `OpenEmu-SDK/OpenEmuBase/OESystemConstants.{h,m}`: a system identifier constant (`openemu.system.3ds`).
- `OpenEmu/ScreenScraperClient.swift` and `OpenEmu/LibretroThumbnailsClient.swift`: the system's ScreenScraper id and thumbnails name. Check both against the services.
- `OpenEmu/AppDelegate.swift`: the diagnostics roll-up list of systems.
- `AGENTS.md` and `README.md`: the supported-cores table.

**Core plugin** (items 2 to 11)
- `Azahar/`: `AzaharGameCore.{h,mm}`, a host file, `Info.plist` (`OEGameCoreClass`, `OESystemIdentifiers`, `OEProjectURL`, `SUFeedURL`), `Azahar.xcodeproj` with a shared scheme, `deps-azahar-revision.txt`, `patches/`, `README.md`, `.gitignore` for `deps/` and `build/`.
- `Scripts/prepare-azahar-core.sh`, `Scripts/build-azahar-core.sh`, a deps script for pinned third-party and MoltenVK downloads, and a copy of `gen-armsx2-xcconfig.py` adapted to Azahar.
- `Scripts/core.sh`, `Scripts/install-core.sh`, `Scripts/verify-core-installed.sh`: make sure they know the core builds through its own script. Check what `FBNeo` and PS2 do in each.
- `.github/workflows/build-check.yml`: a detect flag and a build job for the core, as FBNeo has (`fbneo` output and `build-fbneo` job). Check `Scripts/detect-core-changes.py` too.
- `Appcasts/azahar.xml`: an empty channel until first release, so `Scripts/check-core-feed-urls.sh` passes. PS2 did this in commit `c2de32783`.
- `oecores.xml`: an entry once the core ships.
- Release: a `cores-vX.Y.Z` asset and the appcast item, cut by a maintainer.
- Credits and GPL notice for Azahar and Citra.

## How reliably will it work?

This is a judgment from reading code, not a measurement. It will be replaced by the compatibility matrix (item 10).

**Overall:** expect a PS2-like path. The pieces are well understood, most have a template in this repo or in Azahar, and nothing needs an engine rewrite. Expect Experimental at first. Many games should run. It will not match standalone Azahar on features (hotkeys, per-game settings, cheats, amiibo, camera, stereo 3D, mic) in the first release.

| Area | Confidence | Why |
|---|---|---|
| Engine builds as libraries on macOS arm64 | Medium to high | Azahar builds for macOS arm64 itself, in CI and in releases. The unknown is whether a build with no Qt or SDL frontend configures cleanly. |
| Boots and runs games | High, once built | The engine is mature, and the libretro frontend already drives it with a host-owned window. |
| Speed | Medium | Azahar runs well on Apple Silicon in official builds, but our wrapper and the Vulkan to Metal copy add cost. Unmeasured. |
| Vulkan output into OpenEmu's Metal texture | Medium | A clean place to patch exists, and Dolphin and PS2 show the pattern. The Vulkan to Metal bridge and texture resizing are unproven. This is the main risk. |
| JIT in the helper app | Medium to high | Same entitlement as PS2. Azahar's JIT uses `MAP_JIT`. Needs a real run. |
| Audio | High | Small sink interface, small libretro example. Risk is only crackle at speed changes. |
| Buttons and sticks | High | Direct mapping, with NDS and PS2 as models. |
| Touch and layouts | Medium | Touch must follow the layout and the window size. NDS has known resize problems in this app. |
| Save states | Medium to high | An in-memory API exists. The care is waiting for pending kernel work. |
| In-game saves | High | They live in Azahar's virtual SD and NAND folders. Point those at OpenEmu's folder. |
| Game compatibility | Medium to high | It is as good as Azahar's, with variation per game, and it needs a matrix. |
| Long sessions | Unknown | Thread hand-offs and Vulkan resource lifetimes are the likely crash sources. |
| Encrypted dumps and system files | Unknown | Needs a decision and a test. |
| Keeping up with Azahar | Medium | A fork plus small patches is cheap to carry. Upstream will not take our patches (its AI policy), so version bumps are ours. |

What would change this outlook: if the Vulkan to Metal bridge needs a read-back, speed falls and the core may need an Experimental label for longer. If a fresh 2127 stable changes the renderer, a bump costs more.

## Try the engine yourself

You need your own 3DS game dump from a console you own. Do not share or commit it, and do not commit keys.

The engine is CMake. These switches are read from Azahar's `CMakeLists.txt` at the pin. This is a starting point and has not been run by us:

- Off: `ENABLE_QT`, `ENABLE_SDL2`, `ENABLE_TESTS`, `ENABLE_ROOM`, `ENABLE_ROOM_STANDALONE`, `ENABLE_WEB_SERVICE`, `ENABLE_SCRIPTING`, `ENABLE_GDBSTUB`, `ENABLE_CUBEB`, `ENABLE_OPENAL`, `ENABLE_LIBUSB`, `ENABLE_DISCORD_RPC`.
- On: `ENABLE_VULKAN`. `ENABLE_OPENGL` cannot be turned on for Apple.
- Not set: `ENABLE_LIBRETRO` (see [Follow the PS2 pattern](#follow-the-ps2-pattern)).
- `CITRA_WARNINGS_AS_ERRORS` is on by default. Newer Xcode versions may warn where Azahar's CI did not.
- `USE_SYSTEM_MOLTENVK` with a pinned copy (see [MoltenVK](#moltenvk)).
- macOS deployment target: Azahar's CMake sets a minimum of macOS 13.4 for non-libretro builds. Check that against OpenEmu's own target.

Official Azahar macOS builds are a good baseline for speed on your machine before you build anything.

## Work breakdown

All items live as checkboxes in one tracker issue, [#814](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/814). To take one, comment with the item number. Items 1 to 3 come first. Items 4 to 9 can run in parallel once item 3 boots a game.

1. **3DS system plugin.** Add the files above. Done when: the 3DS system appears in the app with controls configurable and no core installed.
2. **Pin the fork and build the engine.** In `OpenEmu-Silicon/azahar`, pin `219d743a`. Write `prepare-azahar-core.sh` (fetch the commit and submodules, retry on network errors, apply patches) and `build-azahar-core.sh`. Build the engine libraries with the switches above, with MoltenVK and other downloads pinned and checked. Generate the Xcode inputs from CMake. Settle the submodule mirror question. Done when: the engine builds from a clean clone with one script and the pinned commit is recorded.
3. **Core plugin skeleton and headless boot.** `AzaharGameCore`, an `EmuWindow` subclass with a `CAMetalLayer`, `System::Load`, the run model (frame-driven or free-running, with the reason written down), pause, reset, stop, user directory into OpenEmu's folders, `Info.plist`, `Azahar.xcodeproj` and its scheme. Done when: `Scripts/core.sh Azahar` ends in ALL PASS and a game's code runs, with no video or sound required.
4. **Vulkan output into OpenEmu's Metal texture.** The output patch in `PresentWindow::CopyToSwapchain`, texture creation and resizing, and the Metal pacing workaround. Done when: the picture shows in the OpenEmu window, the window resizes correctly, and the engine is not waiting on OpenEmu.
5. **Audio.** An OpenEmu sink writing to the ring buffer. Done when: audio plays without crackle at full speed and across pause, resume and speed changes.
6. **Input, touch and layouts.** The 3DS responder client, button and stick mapping, an input factory, bottom-screen touch through the active layout, and Display Modes for layouts. Done when: a game is playable with a keyboard and a controller, touch works in at least two layouts, and window resizing behaves.
7. **Saves.** Save states (including loading one after a relaunch), in-game saves on the virtual SD and NAND, and the wait for pending kernel work. Done when: save and load state work after a relaunch and in-game saves persist.
8. **JIT and threading review.** Prove the recompiler and MoltenVK run inside the helper process. Review thread hand-offs between engine threads, the present thread and OpenEmu. Run the adversarial reviewer on the result. Done when: a 30 minute session runs with no crash or hang.
9. **Keys, system files and game formats.** Decide and implement how encrypted dumps and any needed system files are handled (open decisions 3 and 4), and make import, hashing and artwork recognize the 3DS formats. Done when: a clean install can import and start a dump of each supported format with the documented setup.
10. **Compatibility and speed matrix.** Run light and demanding games and record fps and problems. Good for contributors with their own libraries. Done when: a results table is in the tracker.
11. **Packaging and Experimental release.** Bundle the libraries and MoltenVK inside the plugin, sign it, add the appcast, credits and GPL notice. A maintainer cuts the release. Done when: a clean install picks up the core from the appcast.
12. **Later, not blocking release.** Microphone, camera, motion beyond the basics, stereo 3D, higher internal resolution settings, a real software keyboard, and the other layouts.

## Branching

All 3DS core work lands on the long-lived integration branch `feat/3ds-core`, not on `main`. This is the same exception made for PS2: the core cannot be released in pieces.

- Branch from `feat/3ds-core` and open your PR against it.
- Keep `feat/3ds-core` current with `main` (`git fetch origin && git merge origin/main`), so the final merge stays small.
- Item 1 (the system plugin) may go straight to `main`, since a system can ship ahead of its core.
- Never ship or release from `feat/3ds-core`. Release only from `main`.

## Ground rules

- Every engine connection goes through `OpenEmu-Silicon/azahar`. Pin a commit. Do not track Azahar's `master`, alphas or nightlies, and do not point scripts at `azahar-emu/azahar`.
- No game dumps, keys, firmware or save data in the repo, issues or PRs.
- Do not build, ship or depend on Azahar's libretro target or the libretro API, and do not turn on `ENABLE_LIBRETRO`. #721 removed that path.
- Keep Azahar patches small and behind a flag so a version bump stays cheap.
- Do not download unpinned binaries at build time. Pin, check a hash, and cache.
- Azahar's `AI-POLICY.md` applies to Azahar's own repository. Our patches live in our repo and are not sent upstream. Say in each PR how AI was used.
- Follow the repo's PR and issue rules in `AGENTS.md`. Link PRs to the tracker with `Related to #N`, and tick the item when its PR merges.

## Known unknowns

- Whether a Qt-free, SDL-free macOS build configures and builds only the library targets at the pin. Not run by us.
- MoltenVK's Metal-object import and export support at the version we pin, and the speed of the Vulkan to Metal copy.
- Whether OpenEmu accepts a Metal texture that changes size mid-game (layout or resolution change). The PS2 core uses a fixed size and does not tell us.
- Whether to drive Azahar one frame at a time or let it run on its own thread.
- Dynarmic and the JIT inside the OpenEmu helper app.
- What an encrypted dump needs on a fresh install (keys, system files, first-time setup). Azahar's libretro frontend can report that it "was unable to locate a 3DS system archive", so some titles may need system files.
- The macOS version floor and the final size of the plugin.
- Whether the outside contributor's build matches this design. Ask them for a branch or notes.
