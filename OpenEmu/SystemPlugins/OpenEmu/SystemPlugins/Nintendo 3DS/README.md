## v220 / v24 — release handoff and evidence preparation

**Functional code freeze:** Core v219 / System Plugin v23 compiled and worked
in OpenEmu on the tested Xcode 27.2 Mac. The v219 diagnostic session contained
1,280 hardware frames, zero GPU readback/copy/pitch failures, successful
save-state writing, and clean teardown. The System Plugin produced no Xcode
warnings; the Core still displayed a nonfatal upstream duplicate-static-library
linker warning and a generic recommended-settings notice. These are not
proof of a clean independent build.

**This update changes no emulation behavior.** v220/v24 adds the read-only
`tools/workspace-report.py` report, `DEPENDENCY_REVIEW.md` (license evidence
and unresolved rights/provenance questions) and updated handoff instructions.
No framebuffer/Metal/Vulkan, input, controller artwork, shader, save, audio,
patching, dependency binaries or Xcode build phases were changed. v220/v24
still require a Mac build and validation before being accepted.

From either plugin folder, run `python3 tools/workspace-report.py` to see whether
your *real* upstream folders are Git checkouts. This prints a sanitized JSON
report without local absolute paths, remote URLs, or user names. If revisions
are available, use `tools/source-lock.py capture/verify`; if not, preserve the
working trees and report the missing provenance. Read `RELEASE_READINESS.md`
and `DEPENDENCY_REVIEW.md` before publishing anything.

## Release-candidate build-warning cleanup (v219/v23)

**v219/v23 update:** Xcode header-map settings have been modernized, the System
Plugin explicitly rechecks OpenEmu Swift frameworks on each build, and the
Core no longer declares itself to be an `OEAudioBuffer`. Only historical
v106–v108 constant-zero Vulkan safety-gate warnings are locally suppressed;
those safety gates and the live renderer are unchanged. The Azahar upstream
static-library duplicate warning and Xcode's App Intents metadata notice are
unmodified and documented for future upstream/toolchain review. The v218/v22
pair successfully compiled and ran on the user's Mac; the subsequent
v219/v23 pair also compiled and ran successfully, with a clean 1,280-frame
Core session. The new v220/v24 pair still needs native Mac testing.


See [`RELEASE_READINESS.md`](RELEASE_READINESS.md) for source locking,
third-party artifact inventory and the macOS fresh-build checklist.
Run `python3 tools/release-gate.py` for a **read-only** readiness report;
PENDING gates are expected until real Git pins, fresh Xcode compilation,
and maintainer/license approval. Working runtime code remains unchanged.
Paired project: Core v220.

# Nintendo 3DS System Plugin for OpenEmu — v24

This repository component provides **OpenEmu system registration, controller metadata, artwork, and input forwarding** for the separate `3DS-Azahar-Core`. The System Plugin does not emulate 3DS hardware; it accompanies the core.

v24 retains the Mac-tested v23 controller integration and the v19 SDK-sensitive
framework rebuild path, with explicit every-build SDK verification and modern
Xcode header-map settings. Artwork, controls, mappings and highlight
coordinates are unchanged.

## Architecture / reviewer map

| Path | Responsibility | Important invariants |
| --- | --- | --- |
| `OE3DSSystemController.swift` | OpenEmu system registration entry point | Principal class name must match `Nintendo3DS-Info.plist` |
| `OE3DSSystemResponder.h` | Ordered UI key enum and companion-core selector protocol | Enum ordering must exactly match manifest; selector names are compatibility ABI |
| `OE3DSSystemResponder.m` | OpenEmu button, axis, and touch forwarding | Start→libretro 10, Select→11; ZL/ZR are separate, analog axes are signed |
| `Resources/Nintendo3DS-Info.plist` | Plugin metadata and **22 ordered control IDs** | Renumbering breaks stored bindings; Home was removed in v17 |
| `Resources/*Mappings.plist` | Default controller and keyboard bindings | Preserve names and key values unless intentionally remapping |
| `Resources/Controller-Preferences.plist` | Control highlight positions | Coordinates are in artwork *point* units |
| `Resources/controller_3ds@2x.png` and mask | Retina controller illustration | PNG images are 744×851 pixels / 372×425.5 points |
| `Frameworks/` | OpenEmu development frameworks, rebuilt when the Xcode SDK changes | Preserve symlinks; review license and provenance before publication |
| `tests/v24_contract_test.py` | Portable source/manifest/resource checks | These do not replace Mac/Xcode tests |

## Control-order contract

**The enum order is a serialized UI contract, not the libretro numbering.** `OEGenericControlNamesKey` in `Resources/Nintendo3DS-Info.plist` and the `OE3DSButton` enum are both ordered lists of 22 identifiers. OpenEmu binds the listed inputs by UI position. Do not reorder or alphabetize either list when cleaning source.

The first 10 controls (D-pad, A/B/X/Y, L/R) use existing NDS button selectors. Start at UI ordinal 12 maps to core button 10; Select at ordinal 13 maps to core button 11. ZL/ZR at ordinals 10/11 use `didChange3DSExtraButton` instead. Circle Pad and C-stick direction bindings occupy ordinals 14–21 and send signed axis values 0–3 using `didChange3DSAnalogAxis`. The responder combines opposite directions so releasing one direction does not incorrectly clear the other.

The nonfunctional Home entry was removed in v17. That shifted analog ordinals from v16; existing user-specific analog key bindings may need reassignment after upgrading. **v24 does not shift any identifiers relative to v17.** Touchscreen clicks use `didTouchScreenPoint`/`didReleaseTouch`; the core performs game-level handling.

## Build / installation on the tested OpenEmu configuration

1. Use an Apple Silicon Mac with Xcode. Extract the development ZIP with framework symlinks preserved.
2. Open `Nintendo3DSSystemPlugin.xcodeproj` and build Release, or run `./build-system-plugin.sh` in Terminal. This helper performs an **ad-hoc** signature; it does *not* notarize the output or create a trusted public distribution signature.
3. Quit OpenEmu. On the tested configuration, place `Nintendo 3DS.oesystemplugin` in `OpenEmu.app/Contents/PlugIns/Systems/`, replacing the older system plugin. The Application Support plugin folder did not work for this configuration. Modifying a signed app bundle may affect its signature: coordinate public installation/signing with the OpenEmu maintainers.
4. Install the compatible 3DS-Azahar-Core separately and verify the Controls UI, analog sticks, Start/Select, ZL/ZR, touch input, game loading and shutdown.

Starting in **v19**, the **System Plugin** also needs the sibling `orig_source/OpenEmu-Silicon-main` checkout so it can rebuild OpenEmuBase and OpenEmuSystem with the locally installed Xcode SDK. Previously bundled framework binaries are still included for development continuity, but they cannot be assumed compatible with future SDK releases. These are development artifacts, not an approved long-term public source-dependency strategy. For GitHub, confirm OpenEmu source/API compatibility, redistribute dependencies only under permitted licenses, and ideally make frameworks reproducible from an upstream pinned revision. Do not delete framework symlinks just because Finder displays them as aliases.

## Tests and release gates

Run `python3 tools/run-source-checks.py` to validate plist/enum control agreement, controller and keyboard references, unique artwork positions, frozen v15/v17 assets, and compile/run isolated C versions of the actual button/axis mapping helpers (requires a C compiler). This test is not a full macOS build. The release ZIP must preserve framework binaries and UNIX symlink nodes. A real Xcode Release build and OpenEmu test remain required before publication.

### Public handoff checklist (pending maintainer review)

- [ ] Record the exact compatible OpenEmu SDK/source commit and framework provenance.
- [ ] Review upstream artwork and framework redistribution permissions; add appropriate project license/attribution with the developer.
- [ ] Build cleanly from a fresh checkout without relying on a developer's private folders.
- [ ] Test all 22 control highlights and saved custom bindings with the intended OpenEmu release.
- [ ] Have the OpenEmu maintainers determine official signing, notarization, packaging, and supported installation path.

`CHANGELOG.txt` records current and historical System Plugin changes. No ROM or 3DS copyrighted game content is included.

## Xcode 27.2 / Swift module rebuild (v19)

`OpenEmuBase.swiftmodule` and `OpenEmuSystem.swiftmodule` are compiled artifacts tied to a specific Xcode/SDK. Xcode 27.2 rejected the prebuilt v18 modules with `SDK does not match` / `built for incompatible target`. **The first build phase in the v19 Xcode project automatically repairs this:** it runs `prepare-openemu-frameworks.sh`, builds the `OpenEmuSystem` scheme (including its `OpenEmuBase` dependency) from the upstream OpenEmu-SDK project using the active Xcode, then replaces the local framework copies with `ditto` so their symlinks stay valid. It uses an SDK/Xcode fingerprint so subsequent builds reuse the compatible frameworks. The first build after upgrading Xcode is longer than a normal System Plugin build.

Keep `orig_source/OpenEmu-Silicon-main/` **beside** `3DS-System-Plugin/`, matching the core's established layout. Alternatively set `OPENEMU_SOURCE` to the root of the OpenEmu source checkout. Do not copy just `.swiftmodule` files; the binary frameworks need to match them. This local source build is for development and not a final license or signing policy.

## v20 GitHub handoff and source provenance

- `DEVELOPER_HANDOFF.md` explains the 22-control ABI, stable artwork positioning,
  source responsibilities and remaining publication gates.
- `python3 tools/run-source-checks.py` runs the maintained portable tests,
  including the compiled mapping test. Xcode build and UI testing remain required.
- `python3 tools/capture-source-revisions.py --strict --output source-revisions.json`
  captures real upstream Git commits/submodules from the developer's `orig_source`
  checkouts without downloading or changing them. Do not invent commit pins.
- The v19 framework rebuild script and Xcode target settings are unchanged.
  v20 updates responder diagnostic version strings only, not control dispatch.

## v21 source-lock and fresh-checkout tooling

`tools/source-lock.py` implements the same source-lock schema as Core v217.
Review **`FRESH_CHECKOUT.md`** for the full process. The preferred canonical
lock file lives in the sibling Core folder: use `--lock` when calling this
plugin's source-lock tool, or run capture/bootstrap from the Core. Neither
command changes controller mappings or artwork. Upstream commits and clone
URLs still must be recorded from the working Mac before publishing GitHub
source. A successful Git clone is not proof of a compatible Xcode build.
