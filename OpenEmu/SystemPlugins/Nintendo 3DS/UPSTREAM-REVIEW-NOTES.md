# Nintendo 3DS System Plugin v24 — OpenEmu-Silicon review handoff

## Intent and relationship to the Core PR

This directory provides the **complete, frozen standalone System Plugin v24 source**, relocated from the original private repository's `3DS-System-Plugin/` directory, for technical review as a separate pull request. The paired **Azahar Core v220** is submitted independently from the `feat/azahar-core` branch against `feat/3ds-core`. The System Plugin PR is intended for **upstream `main`**, if the maintainers agree (OpenEmu-Silicon issue #814, item 1).

**All 46 files from the original System Plugin folder are included byte-for-byte, including the 9 historical test files, 7 current tests, hidden Git configuration, source/build tooling, Xcode project, and all active assets.** Six additional source-project license/provenance files are copied here, and this reviewer note is new. The original Core v220 / System Plugin v24 development trees and verified builds are unmodified.

## Avoiding duplicate 3DS System Plugins

- The `Resources/Nintendo3DS-Info.plist` identifier is **`openemu.system.3ds`**, matching the existing 3DS proposal in OpenEmu/OpenEmu pull request #5157. These are **alternative implementations of one system**, not distinct systems to register simultaneously.
- The System Plugin's bundle identifier is **`org.openemu.system.nintendo3ds`**; `OE3DSSystemController.swift` and `OE3DSSystemResponder.m/.h` implement the related controller and responder.
- A maintainer should compare existing 3DS System Plugin work before merging, preserve stable identifiers, and choose the mapping, art, and project integration appropriate to this Core. **Do not add or register a second conflicting `openemu.system.3ds` definition.**
- If the `Nintendo 3DS/` folder already exists in the target `main` branch, review the existing implementation first; do not blindly overwrite it with this upload.

## Status and what is (and is not) demonstrated

- The standalone v24 System Plugin and companion v220 Core were independently compiled on Apple Silicon and successfully used in OpenEmu, including gamepad and keyboard mappings, stereo, high resolution, save states, and several game sessions. See the technical acceptance and Batch 9 records in the original project's review documentation; these results do **not** mean this relocated tree has been built as part of the upstream OpenEmu-Silicon Xcode workspace.
- The existing `Nintendo3DSSystemPlugin.xcodeproj` and scripts are preserved as they were tested. **Upstream project/workspace registration, system constants, assets integration and any shared application metadata remain to be reviewed/integrated**. This is a review handoff, not a claim that the main OpenEmu app now builds the 3DS System Plugin automatically.
- `README.md`, `RELEASE_READINESS.md`, and `FRESH_CHECKOUT.md` are historical **standalone-folder documents**. Some refer to `3DS-System-Plugin/`, sibling `3DS-Azahar-Core/`, or earlier pending verification steps; the independent acceptance was subsequently completed. For building the unmodified standalone version, follow those original workspace assumptions. Do not interpret old text as a new verification failure.
- The original System Plugin files are supplied **without compiled binaries, generated frameworks, game ROMs, keys, firmware, or personal diagnostics**.
- **Source-only test caveat:** six of the seven current offline tests pass against this package. The preserved `tests/v24_contract_test.py` fails in a public source-only checkout because it expects an old `Artwork-References/Original-3DS-Controller.png` that was deliberately not part of the private GitHub source snapshot or the public upload. We do not ship that older reference image due to its unresolved reference-photo rights; do not interpret this as a runtime regression. Maintainers may choose to make the test conditional, but the frozen test is preserved for handoff.

## Licensing and artwork

- `LICENSE`/`LICENSING.md`: BSD 3-Clause applies only to Derek Hugger's independently licensable original software contributions. OpenEmu-derived interfaces retain their own upstream notices and permissions.
- `ARTWORK_LICENSE.md` and `ARTWORK_CREDITS.md`: Derek Hugger's original rights in the specified 3DS controller artwork and pixel-art icon are licensed CC BY 4.0. The mask was generated with ChatGPT assistance from Derek's illustration and red-dot template. The documented earlier third-party photo-reference concern is **not asserted to be legally resolved** by this permission or by later personal photographs. References to original `3DS-System-Plugin/Resources/...` paths in the copied licenses now correspond to this directory's `Resources/...` files.
- `DEPENDENCIES_AND_ARTWORK.md` and `THIRD_PARTY_NOTICES.md` retain the original dependency/source review context, including Core-related details. No GPL-covered Azahar engine or third-party binary is part of this System Plugin upload.

## AI use disclosure

ChatGPT assisted with source implementation, troubleshooting, release tests, controller-mask generation, documentation, and PR packaging. Derek Hugger supplied the original controller illustration, template and pixel icon, directed implementation, compiled and tested the result on his Apple Silicon Mac, and authorized the stated code/artwork license choices subject to their documented limits.

## Reviewer questions

1. Does `main` already contain a 3DS system definition or in-flight change that should be adapted rather than duplicated?
2. Where should this project's Xcode target, system registration constant, and resource-copy settings be integrated into upstream?
3. Should the System Plugin PR land before, alongside, or after the Core PR against `feat/3ds-core`?

Related to OpenEmu-Silicon/OpenEmu-Silicon#814; upstream OpenEmu/OpenEmu#5157 is the overlapping 3DS System Plugin proposal.
