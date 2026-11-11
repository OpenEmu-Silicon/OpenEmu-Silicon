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

# 3DS Core for OpenEmu — developer handoff (v220)

## Status and scope

This is an experimental Apple Silicon core using Azahar's **libretro Vulkan**
renderer, MoltenVK, and OpenEmu's standard bitmap presentation. It is paired
with the independently built **3DS-System-Plugin v24**. This is not an official
OpenEmu release or notarized. A fresh checkout can be generated only after
recording real upstream pins and explicit reviewed repository URLs.
The user confirmed v218/v22 Xcode build/gameplay, and v217/v21 Bluetooth
controller input and save-state restoration. v219/v23 subsequently passed a Mac compile and gameplay smoke test;
**v220/v24 still require a native test**, and multi-game testing is recommended.

## First review / safety boundaries

1. Start with `README.md`, then the existing `azcore/Azahar.xcodeproj`,
   `azcore/AzaharCore/AzaharGameCore.mm`, and
   `azcore/AzaharCore/AzaharOfficialVulkanABI.mm`.
2. Keep the **Vulkan/MoltenVK** hardware handshake, readback, bitmap
   frame consumer, and software fallback intact. v202–v206 private Metal
   probes are diagnostics, not an alternative visible renderer.
3. The host caches the owned bitmap pointer and row pitch; do not change
   `bufferSize`, reallocate the host bitmap in-session, or replace pitched
   copies with whole-buffer `memcpy`.
4. A 180-frame native screen-rectangle startup dwell precedes 2x Retina
   publication. It is a workaround based on the tested OpenEmu implementation,
   not a general OpenEmu contract.
5. Fullscreen Scale 1x can become 2x apparent size when the high-resolution
   `screenRect` is exposed. This needs host-side logical/physical geometry
   separation; v219 does not pretend to fix it.
6. Core options include 1x–6x internal resolution, Off/SBS Half/SBS Full/
   Anaglyph stereo and depth, real controller input, shaders and save states.
   A game restart may be necessary when SBS Full changes logical width.

## Required source layout (NOT all bundled in the ZIP)

```
workspace/
  3DS-Azahar-Core/
    azcore/Azahar.xcodeproj
    azcore/patch-azahar-full-stereo-v199.py
  3DS-System-Plugin/
    Nintendo3DSSystemPlugin.xcodeproj
  orig_source/
    azahar-git/                   # recursively initialized submodules
    OpenEmu-Silicon-main/         # OpenEmu-SDK and system sources
```

Build and install instructions live in `README.md`. Both projects currently
expect the upstream checkout in `orig_source`. The **Core build modifies its
local Azahar checkout** by applying the idempotent stereo geometry patch;
start from a clean upstream checkout when documenting your changes.

## Repeatability and audit commands

```sh
python3 tools/run-source-checks.py
python3 tools/capture-source-revisions.py --strict --output source-revisions.json
python3 azcore/verify-source-layout.py
```

Run commands from inside `3DS-Azahar-Core`. The source manifest is read-only
by default; it records the actual upstream commits, submodule revisions, a
count of local modifications, and the local stereo patch SHA-256. **Before a
GitHub publication, capture real commit IDs on the Mac**, pin/record these
revisions, and review the expected dirty state from applying the stereo patch.
Do not substitute a guessed revision for an unknown checkout.

The portable tests compile host-independent snippets of production algorithms;
only an Apple Silicon Mac running Xcode can verify actual ObjC++/Vulkan link,
plugin launch, hardware frame presentation and gameplay. Run the fullscreen
scale reproduction, normal/SBS Full, save/restore, controllers and games before
release. Inspect `V219 BUILD_ID`, `V213 RELEASE_HEALTH`, `V209 SESSION_AUDIT`
and final hardware teardown in the runtime log.

## Publication blockers / maintainer decisions

- Pin actual OpenEmu and Azahar source/submodule commits and document any
  local modifications beyond the v199 stereo patch.
- Review licensing, copyrights and redistribution of Azahar, libretro,
  MoltenVK, Vulkan-Headers and prebuilt development frameworks. The presence
  of a binary or source file in a developer ZIP is **not** a grant of rights.
- Decide whether to build the upstream Azahar dylib from pinned source rather
  than distributing a prebuilt seed binary; audit bundled artifacts.
- Confirm compatibility with OpenEmu's plugin loading, code signing and host
  geometry behavior with the OpenEmu maintainer.
- Produce a fresh-checkout macOS build, then independently test a second Mac.

`CHANGELOG.txt` is historical; its older instructions may be superseded by
current README and this handoff guide. No game ROMs, firmware, saves or user
logs should be committed to a public repository.

## Source lock next step (v217)

Read **`FRESH_CHECKOUT.md`**. `tools/source-lock.py` supports `inspect`,
`capture`, `verify`, and fail-closed `bootstrap`. The v217 ZIP deliberately
does not include made-up source commits or a potentially private Git remote.
The known v199 stereo patch is accepted as the sole expected upstream edit
only when its bytes match what a clean checkout would contain after applying
that reviewed patch. Test the full build in a new Mac workspace.
