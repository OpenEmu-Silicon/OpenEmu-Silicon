## Latest review outcome (Core v220 / System Plugin v24)

The **v219/v23 functional pair is user-tested**: both built on Xcode 27.2,
and the user reports normal OpenEmu gameplay. The latest inspected v219 session
reported 1,280 frames and zero readback/copy/pitch errors, save-state write and
clean shutdown. The v220/v24 changes are limited to version markers, portable
tests, documentation and the read-only upstream workspace report; **a native
v220/v24 build has not been verified yet**. The upstream exact Git commits,
independent fresh-checkout build and release rights are still OPEN. The two
remaining Core Xcode notices are a duplicate-static-library linker warning
in the upstream Azahar build and the project's recommended-settings prompt.

Start with [`DEPENDENCY_REVIEW.md`](DEPENDENCY_REVIEW.md) and run
`python3 tools/workspace-report.py`, then follow `FRESH_CHECKOUT.md`.
Do not publish development archives or inferred license claims as a release.

# 3DS System Plugin for OpenEmu — developer handoff (v24)

## Status and scope

This companion system plugin registers Nintendo 3DS games, artwork, keyboard
and gamepad bindings. Emulation and GPU rendering live in **3DS-Azahar-Core
v220**, not in this plugin. v23 fixed Xcode header-map settings and
makes the SDK-aware framework check explicitly run every build, without
changing the user-tested controller functionality.

## Review order / contracts

- `OE3DSSystemController.swift` — OpenEmu's minimal system registration.
- `OE3DSSystemResponder.h` — the 22-item ordered control enum and client ABI.
- `OE3DSSystemResponder.m` — UI key → libretro mapping; Start/Select UI
  ordinals 12/13 → libretro 10/11, ZL/ZR separate, two signed analog axes.
- `Resources/Nintendo3DS-Info.plist` — the enum-order source of truth;
  preserving its order is critical for saved bindings.
- `Resources/Controller-Preferences.plist` — mapping positions in **artwork
  point units**, not physical @2x PNG pixels. The original high-res drawing,
  mask and highlight coordinates must not be rescaled or reordered.
- `prepare-openemu-frameworks.sh` — regenerates SDK-sensitive Swift
  frameworks on Xcode changes, using the local OpenEmu source checkout.

**Do not** renumber the control enum, reintroduce the nonfunctional Home UI
button, alter the custom client selectors or change analog cancellation logic
as a cosmetic refactor. The default artwork/mappings are tested by SHA-256.

## Source structure and checks

```
workspace/
  3DS-System-Plugin/
    Nintendo3DSSystemPlugin.xcodeproj
    Frameworks/                   # temporary local build dependencies
  3DS-Azahar-Core/
  orig_source/
    azahar-git/
    OpenEmu-Silicon-main/         # OpenEmu-SDK project and sources
```

```sh
python3 tools/run-source-checks.py
python3 tools/capture-source-revisions.py --strict --output source-revisions.json
./build-system-plugin.sh
```

Source checks are portable; the final command needs Xcode and an Apple Silicon
Mac. `prepare-openemu-frameworks.sh` rebuilds OpenEmuBase and OpenEmuSystem
against the active SDK. The ZIP's framework copies are **development-only**
and are not a substitute for pinning/building the framework sources.

After a fresh build, verify all 22 Controls UI highlights, analog directions,
ZL/ZR, Start/Select, touchscreen clicks, external Bluetooth controller,
keyboard presets and loading games. v23 was tested on the Mac;
v24 still requires its own native Mac build.

## Publication blockers / maintainer decisions

- Identify exact upstream OpenEmu and Azahar commit/submodule revisions.
- Confirm required OpenEmu SDK API/ABI version and supported installation path.
- Choose a supported framework distribution approach; review licenses and
  ownership of included control artwork and existing frameworks.
- Follow the OpenEmu maintainer's code-signing/notarization workflow.
- Independently test a fresh checkout under supported Xcode versions.

No ROMs or user data should be published. Historical numbered tests under
`tests/historical/` intentionally refer to earlier plugin contracts and are
not release gates for v24.

## Fresh checkout review (v24)

Use the canonical Core v220 source-lock manifest and the documented
`FRESH_CHECKOUT.md` process to reconstruct upstream sources before building.
The System Plugin's own `tools/source-lock.py` performs the same checks if
`--lock` points to the Core manifest. Neither source-lock command changes
registered control ordinals, artwork, framework binaries or dispatch.
