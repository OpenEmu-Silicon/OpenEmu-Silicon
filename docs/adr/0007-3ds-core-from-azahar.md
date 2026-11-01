# ADR-0007: Build the Nintendo 3DS core on Azahar

## Status

Proposed (direction). The open decisions at the end are still to be made by the maintainer. Nothing in this ADR has been built or run yet.

## Context

OpenEmu-Silicon has no Nintendo 3DS system plugin and no 3DS core. Issue #176 (Azahar, closed as not planned) and issue #812 (Panda3DS, open) both asked for one.

Two engines were looked at:

- **Panda3DS** (GPL-3.0). An HLE emulator with a ready OpenEmu plugin in an unreviewed upstream PR (`wheremyfoodat/Panda3DS#845`). Its README says many games do not boot, and its last release is v0.9 (December 2024). The plugin runs on the OpenGL renderer only; the Metal renderer does not work yet. It needs about 25 submodules.
- **Azahar** (GPL-3.0, a Citra successor). Far better compatibility and active releases (stable 2126.2 on 2026-10-08, 2127 alphas since). Its core is already separate from its frontends.

A source read of Azahar at commit `01623d2` (2026-10-29), without its submodules, found:

- The emulator is split into libraries (`core`, `video_core`, `audio_core`, `input_common`, `common`). The entry point is `Core::System::Load(EmuWindow&, path)` with `RunLoop`, `Reset`, `SaveState` and `LoadState`. Qt, CLI, Android and libretro are frontends on top.
- OpenGL is switched off on Apple in its CMake file, and its renderer needs OpenGL 4.3 (macOS stops at 4.1). On macOS it uses the Vulkan renderer through MoltenVK, or a software renderer.
- The Vulkan code already makes a Metal surface from a `CAMetalLayer` (`WindowSystemType::MacOS`). That is the same shape as `Dolphin/DolHost.mm` here.
- The 3DS two-screen layouts (default, single, large, side by side, hybrid, custom) are built into the core.
- Audio has several sinks (cubeb, SDL2, OpenAL, null, libretro). Touch, mic and gyro have hooks.
- Frontend-driven running is already supported: Azahar's libretro frontend calls `System::RunLoop()` once per frame until a frame is submitted, with its own frame limiter and audio stretching turned off. Save states have in-memory `SaveStateBuffer()` and `LoadStateBuffer()` calls, used after waiting for pending asynchronous kernel work.
- Each rendered frame is an offscreen image that `PresentWindow::CopyToSwapchain` copies to the window. That is the place to patch, as PS2's `EndPresent` patch does.
- The audio sink interface is small, and its libretro implementation is 27 lines.
- The CPU recompiler (Dynarmic with Oaknut) maps its code memory with `MAP_JIT` on Apple.
- At the pinned commit there are 52 submodule entries, about 560 MB when fetched shallow. They stay on their original hosts when the main repo is forked.
- Azahar has an AI use policy (`AI-POLICY.md`, effective 2026-03-20). It rejects AI-written submissions of any real size. Patches from this repo would not be accepted upstream, so we carry them ourselves.

Someone outside the project says they have Azahar running in OpenEmu. We have not seen their code. This ADR and the port doc are written so their work can be checked against the plan and so they can fill in what is missing.

## Decision

Build the 3DS core natively on Azahar, using the same pattern as FBNeo and the PlayStation 2 core:

- Keep the engine in the fork `OpenEmu-Silicon/azahar` (it exists; a fork of `azahar-emu/azahar`, default branch `master`), pinned to one commit recorded in `Azahar/deps-azahar-revision.txt`. Fetch it with a `Scripts/prepare-azahar-core.sh` script. Do not flatten it into the repo. Every connection to the engine goes through the fork, never straight to upstream.
- Pin the Azahar 2126.2 release commit (`219d743a1e698101fe1ab8bef43e6563126c3c27`, present in the fork; the fork has no upstream tags), not `master` or an alpha. Update on purpose, not on a schedule.
- Keep the fork an untouched snapshot of the pinned release. Our changes to the engine are small flagged patches in `Azahar/patches/`, applied by the prepare script, the way PS2 does it.
- Build the engine as static libraries with CMake (Qt, SDL, audio backends, tests, room, web services and scripting off, Vulkan on, OpenGL not available), wrapped by a thin Xcode project that makes `Azahar.oecoreplugin`. Same two-stage shape as `Scripts/build-fbneo-core.sh` and the PS2 `Scripts/build-armsx2-core.sh`.
- Do **not** set Azahar's `ENABLE_LIBRETRO`. PS2 sets the equivalent ARMSX2 switch to mean "the host owns pads, audio and video". In Azahar it makes the Vulkan renderer take its device and images from a libretro frontend, which is the wrong path.
- Fetch third-party downloads from pinned sources with a checked hash. Azahar's CMake downloads MoltenVK at configure time; replace that with a pinned copy.
- Use the Vulkan renderer through MoltenVK. Send its final image into OpenEmu's Metal texture with a small patch behind a build flag, as the PS2 core does.
- Keep Azahar patches small and flagged, as `patches/*.patch` or fork commits.
- Do **not** use the libretro build or the libretro API. #721 removed the libretro bridge. Azahar's libretro frontend is a reference to read, not a path to ship.
- Add a 3DS system plugin first. It can ship ahead of the core, as PS2 did.
- Ship as Experimental first.
- Develop on a long-lived integration branch (`feat/3ds-core`) and merge it into `main` in one PR when the core works end to end.

The full map and work breakdown are in [`docs/3ds-azahar-port.md`](../3ds-azahar-port.md).

## Consequences

**Easier:**
- A mature engine with real compatibility, so a 3DS system is worth shipping.
- Dual-screen layout is a core feature. OpenEmu chooses a layout and size and does not have to compose two screens itself.
- The Metal surface path exists in Azahar and the same idea already works for Dolphin and (in progress) PS2.
- The libretro frontend (about 4,300 lines) is a worked example of every host hook the engine needs: window, input, touch, audio, mic, settings, Vulkan present.

**Harder:**
- The engine is large (36 submodules) and brings MoltenVK, SDL, OpenAL or cubeb, boost and more. Packaging and signing will take work.
- Presenting Vulkan output into a host-owned Metal texture inside the helper process is unproven.
- A 3DS needs more input than any core here: two screens, touch, circle pad and C-stick, motion, mic, optionally a camera and stereo 3D.
- ROM formats, encrypted dumps and keys need decisions (see below).
- We cannot send patches upstream under Azahar's AI policy.

**Risks accepted:**
- JIT behavior inside the OpenEmu helper process is unproven.
- Threading between Azahar's CPU, GPU and audio threads and OpenEmu's threads is the likeliest source of crashes.
- Compatibility and speed on this hardware are unmeasured.
- A second person may already have a different design. This ADR does not override their work. It sets the bar their work is checked against.

## Open decisions

1. **Where the engine lives.** Fork at `OpenEmu-Silicon/azahar` pinned by commit (recommended, same as FBNeo and PS2), or flatten it into the repo (ADR-0001).
2. **Rendering.** Vulkan through MoltenVK only (recommended), or also the software renderer as a fallback.
3. **Encrypted games and keys.** Azahar has a build option that bundles a default keys blob (on by default). Decide whether to ship, require the user to supply, or turn it off. This needs a maintainer decision before release.
4. **System files.** Whether the first release requires any system files (firmware, NAND) or runs titles without them. Needs a spike.
5. **Layout.** Which 3DS layout is the default, and how layout changes interact with the NDS window-size exemptions in `GameWindowController.swift`.
6. **Submodule mirrors.** Forking Azahar snapshots its source but not its submodules. Mirror the ones we use into the org and repoint the fork's `.gitmodules` (a real snapshot, more upkeep), or rely on the original hosts with retries (cheaper, the pin can break if a host rewrites history).
7. **Existing outside work.** Whether to build on the other contributor's branch once it is seen, and under what pin and review rules.
