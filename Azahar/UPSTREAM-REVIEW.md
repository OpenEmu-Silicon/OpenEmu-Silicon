# Azahar 3DS Core v220 — upstream review handoff

**Status: working standalone Core; REVIEW-ONLY initial submission, not yet a drop-in build target of OpenEmu-Silicon's own workspace.**

This folder contributes the **Core only** from the independently verified `3DS-Azahar-Core` project. The companion Nintendo 3DS **System Plugin v24 is not included in this PR** and is planned for separate coordination against the System Plugin work already underway. Do not infer that the OpenEmu-Silicon host will automatically register or build this Core merely because the `Azahar/` directory exists.

## What has been tested

- Apple Silicon macOS: OpenEmu plugin successfully built from a separate clean pinned checkout, then exercised in a working OpenEmu installation (9 sessions and 41,715 delivered hardware frames across the broader test set, with no recorded GPU readback/copy/pitch failures).
- Vulkan rendering via MoltenVK, 1×–6× Azahar internal render resolution, stereo Off / Side-by-Side Half / Side-by-Side Full / Anaglyph, OpenEmu shaders, controls, audio, game saves and OpenEmu save states.
- Separate consolidated fresh-source batch verified the pins, compiled both plugins and demonstrated replacement/relinking of a modified SoundTouch object. These tests were run in the independent development workspace, **not from this OpenEmu-Silicon fork**.
- Tested on six user-owned games; this is not a general compatibility certification.

## Existing implementation and key difference from #814

`azcore/AzaharCore/AzaharGameCore.mm` is an `OEGameCore` subclass wrapping Azahar's **libretro C API internally**. The plugin builds and bundles `azahar_libretro.dylib`; it does **not** use OpenEmu's removed generic RetroArch/Bridge app support and does not require a separate RetroArch installation. Frame transfer uses Azahar's Vulkan rendering path and an OpenEmu-compatible bitmap interface. This is a deliberately different approach than the direct-engine architecture outlined in issue #814, offered to maintainers for review and adaptation rather than represented as compliant with every proposed implementation step.

The existing Xcode project is at `Azahar/azcore/Azahar.xcodeproj` (not `Azahar/Azahar.xcodeproj`). No OpenEmu-Silicon app workspace, Core updater/appcast, CI pipeline, or official signing paths have been modified by this submission.

## Rebuilding and source pins

- `source-lock.json` pins Azahar to `a5c3d4f8eb34493f37479158128de134c3e700a9`, OpenEmu-Silicon to `2b1c21c2c336ad4fb98b5722e0b8ef8963ca5369`, 51 recursive Azahar submodules, and the stereo patch. That older OpenEmu pin is the **validated standalone baseline**, not necessarily the current PR target.
- To reproduce the **original validated standalone layout**, keep `Azahar/` as the Core project and populate the sibling `orig_source/azahar-git` and `orig_source/OpenEmu-Silicon-main` directories using the source-lock workflow. `azcore/Azahar.xcodeproj` still refers to these standalone source paths, so it does not yet build automatically from the current fork's OpenEmu SDK checkout.
- `azcore/patch-azahar-full-stereo-v199.py` is intentionally preserved to patch the libretro integration in a fresh Azahar checkout. Maintainers should review and upstream-structure any changes to the source fetching and build wiring before merging.
- **All** original Core test files are retained under `azcore/tests/`, including the 20 version-specific regression tests under `azcore/tests/historical/`. Historical tests reflect earlier implementation stages and are preserved for completeness; they are not all intended to pass against v220. On a source-only checkout, `python3 tools/run-source-checks.py` currently reports 17 passing portable tests and one expected failure: `v220_hardened_contract_test.py` asserts that the *built* `AzaharCore/azahar_libretro.dylib` exists. Do **not** commit a binary to satisfy that check; run it after a local Mac build or separate source-only and post-build assertions during upstream integration.
- No generated Azahar engine checkout, prebuilt `.dylib`, `.oecoreplugin`, MoltenVK binary, ROM/game dump, firmware, keys, saves or logs are included.

## Requested maintainer decisions

1. Whether the self-contained libretro wrapper is acceptable as the core's long-term architecture, or should be adapted.
2. How best to connect this existing `Azahar/azcore/Azahar.xcodeproj` project to the OpenEmu-Silicon workspace and shared build scripts, and whether to use the organization's Azahar engine fork.
3. Core updater/appcast, signing, build provenance, and runtime-distribution strategy.
4. Coordination with Nintendo 3DS System Plugin development; the completed v24 System Plugin can be provided separately.
5. Dependency/source attribution and binary license obligations before a publicly shipped binary. See `LICENSING.md` and `THIRD_PARTY_NOTICES.md`; original integration code is scoped under BSD-3-Clause only where licensable, and upstream dependencies remain governed by their own licenses. No blanket copyright clearance or binary-distribution permission is implied.

## AI use disclosure

ChatGPT helped create and debug the integration, write instrumentation and tests, and prepare documentation and licensing inventory. The project owner directed the design and performed Mac compilation and extensive manual gameplay testing. An AI-assisted origin should be considered when reviewing, refactoring, or accepting this contribution.

Related to OpenEmu-Silicon/OpenEmu-Silicon#814.
