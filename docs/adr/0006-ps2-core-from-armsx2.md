# ADR-0006: Build the PlayStation 2 core on ARMSX2

## Status

Accepted (direction). The open decisions at the end are still to be made by the maintainer.

## Context

PlayStation 2 has a system plugin but no core. The earlier plan (issues #323 to #327) wrapped upstream PCSX2 through the old `OpenEmu/PCSX2-Core` bridge. Its own evaluation found three problems:

- The bridge did not link for arm64. About 30 symbols were missing, and the project file was four months behind upstream.
- Upstream PCSX2 has no arm64 vector-unit recompiler (microVU) and no arm64 FPU recompiler. The plan accepted an interpreter fallback, which would make demanding 3D games slow or unplayable.
- Upstream cadence on arm64 was uncertain.

[ARMSX2](https://github.com/ARMSX2/ARMSX2) is a GPL-3.0 fork of PCSX2 that targets ARM64. It ships ARM64 recompilers for the main CPU (EE), the IOP and both vector units, ARM NEON code for the sound and graphics paths, and a Metal renderer. It publishes a macOS arm64 build daily.

A spike on 2026-10-21 (commit `65fd14b`, Apple Silicon Mac, macOS 26) found:

- The engine builds cleanly as a native arm64 library with plain CMake and no Qt.
- The official macOS nightly, same commit, ran Ratchet & Clank: Going Commando with a US BIOS at 58.2 fps average over a 153 second session (target 60). The log showed the Metal renderer and the ARM64 recompilers active. Main CPU use was 12 to 29 percent.
- The tester confirmed the picture, sound and controls worked in play.
- The vector-unit counter read 0 percent throughout, which looks like a measurement gap or a light scene. Heavy titles are untested.
- OpenEmu's helper app already carries the entitlements the nightly asks for (`allow-jit`, `disable-library-validation`).

## Decision

Replace the PCSX2 plan with a native core built on ARMSX2. Reuse the existing OpenEmu `PCSX2-Core` bridge as the template for the OpenEmu side, and port it onto ARMSX2 instead of writing a new wrapper.

- Do not use ARMSX2's libretro target or API. The libretro bridge is being removed. We do build the engine with its `ENABLE_LIBRETRO` setting on, because that is the engine's "host owns pads, audio and video" mode (it declares `Host::SetPadVibration` and embeds the shaders); see `PCSX2/README.md`.
- Do not copy the old bridge's forked copies of engine files (Metal device, SPU2 mixer, `Pad.cpp`). They are stale against ARMSX2. Patch ARMSX2's own files with small, flagged changes instead.
- Pin ARMSX2 to a specific commit, never a branch or the nightly channel.
- Develop on a long-lived integration branch, `feat/ps2-core`, and merge it into `main` in one PR once the core works end to end. This is an exception to the usual "no long-lived branches" habit, because the core cannot be released in pieces.
- Ship as Experimental first.

The full map and work breakdown are in [`docs/ps2-armsx2-port.md`](../ps2-armsx2-port.md).

## Consequences

**Easier:**
- No interpreter-only vector unit. The recompilers already exist.
- A Metal renderer that fits the Dolphin pattern (`OEGameCoreRenderingMetal2`).
- About 1,150 lines of existing OpenEmu glue port over with edits.

**Harder:**
- ARMSX2 is a young fork with heavy changes and daily nightlies. Upgrades will be deliberate, not routine.
- The old audio mixer copy and the hand-listed Xcode source list cannot be reused. Audio needs a new backend and the engine needs a CMake-based build.
- The project takes a dependency on a young fork. Its README says AI tools are used in its development.

**Risks accepted:**
- JIT behavior inside the OpenEmu helper process is unproven.
- Threading between the engine's CPU, graphics and audio threads and OpenEmu's threads is the likeliest source of crashes.
- Compatibility beyond one tested game is unknown.

## Decisions on the open questions

Decided 2026-10-26 while starting work item 1.

1. **How to vendor the engine:** do not copy it into the repo. This is the same pattern as the MAME and FBNeo cores. `PCSX2/deps-armsx2-revision.txt` and `Scripts/prepare-armsx2-core.sh` record a fork URL and a full commit SHA, and the script fetches exactly that commit (shallow) into the gitignored `PCSX2/deps/armsx2/`. `Scripts/build-armsx2-core.sh` builds it. The engine is about 560 MB and is not a core we edit wholesale, so ADR-0001's flattening does not fit it.
2. **Renderer:** Metal only. The build sets `USE_VULKAN=OFF`, and OpenGL is already off on macOS.
3. **Where the engine lives:** a fork that holds our small flagged patches, with this repo pinning it. The fork is `OpenEmu-Silicon/armsx2` (a fork of `ARMSX2/ARMSX2`), set by `REMOTE` in `Scripts/prepare-armsx2-core.sh`. A small patch that is not yet in the fork can sit in `PCSX2/patches/*.patch`, which the prepare script applies in name order.
