# Third-party notices and license inventory — PRIVATE SOURCE REVIEW

**Scope:** This source-only staging package for 3DS-Azahar-Core v220 and
3DS-System-Plugin v24. This is a technical inventory, **not** a license for the
entire repository and **not** a legal determination that a compiled plugin can
be redistributed. Eligible original integration contributions have been designated **BSD-3-Clause**
(Copyright 2026 Derek Hugger), subject to verified ownership and the explicit
scope in `LICENSING.md`. Original licensable artwork rights have a separate
**CC BY 4.0** permission described in `ARTWORK_LICENSE.md`; third-party
photo-reference and console-design rights are not thereby cleared.

## Third-party MATERIAL actually inside this source archive

| Included path | Source / rights noted in retained files | Treatment |
|---|---|---|
| `3DS-Azahar-Core/azcore/AzaharCore/OfficialABI/libretro.h` | libretro API; copyright 2010–2024 RetroArch team; MIT-style permission grant | Full copyright/license notice already appears in the header; preserve unchanged. |
| `3DS-Azahar-Core/azcore/AzaharCore/OfficialABI/libretro_vulkan.h` | libretro Vulkan API; copyright 2010–2020 RetroArch team; MIT-style permission grant | Full copyright/license notice already appears in the header; preserve unchanged. |
| `3DS-Azahar-Core/azcore/AzaharCore/VulkanSDK/include/**` (49 files) | Khronos Vulkan-Headers; copyright lines and SPDX markers in each source file | 33 files state `Apache-2.0`, 16 state `Apache-2.0 OR MIT`. The Apache-2.0 full text retained at `3DS-Azahar-Core/azcore/AzaharCore/Vulkan/MoltenVK-LICENSE.txt` can be consulted for the Apache option. Preserve all existing per-file notices. The vendored `vulkan_core.h` reports `VK_HEADER_VERSION 328`; its *exact upstream SDK/release provenance and file-level notice obligations still need confirmation*. |
| `3DS-Azahar-Core/azcore/AzaharCore/Vulkan/MoltenVK-LICENSE.txt` | Apache License, Version 2.0 text | Retained license text only; **no** `libMoltenVK.dylib` is shipped here. Does not establish the rights or provenance of the development binary. |
| `3DS-Azahar-Core/azcore/AzaharCore/libretro.h` | Project's shortened libretro ABI declarations | Treat as API-derived material under libretro API **MIT** provenance, not as BSD-only project code. **Copyright (C) 2010–2024 The RetroArch team** and the full MIT permission/warranty notice are preserved in the co-distributed `OfficialABI/libretro.h` file (see its opening comment); `OfficialABI/libretro_vulkan.h` retains its own original notice. The shortened header currently lacks an in-file notice, so a focused header-attribution decision remains before public source release. Do not modify the frozen header silently. |
| `3DS-System-Plugin/Resources/**` (active 3DS artwork, mask, UI metadata) | Original illustration by Derek Hugger; mask generated with ChatGPT assistance from his artwork and supplied red-dot template; scope and credit at `ARTWORK_LICENSE.md` | CC BY 4.0 selected only for Derek Hugger's licensable original rights in the four explicitly listed graphics; earlier photo tracing remains a source-publication hold. |

The original Core adapter and System Plugin source also appear in the archive.
Eligible original portions are designated BSD-3-Clause by Derek Hugger,
subject to file/section provenance review. This notice does **not** license
third-party material included in the same source files. The generated OpenEmu SDK frameworks and the emulator/MoltenVK
binaries are intentionally omitted. No OpenEmu SDK source tree is vendored here.

### License evidence provenance

- `docs/licensing/AZAHAR-PINNED-ROOT-LICENSE-reference.txt` is an **unaltered
  reference copy** of `LICENSE.txt` from the pinned Azahar tree: the GNU GPL
  **Version 3** text followed by upstream icon attribution. This file is
  documentation about an **external dependency**, not a new license grant for
  the integration project and not evidence that the frontend icons are included.
- `docs/licensing/LICENSE-EVIDENCE-REPORT.json` records 67 collected candidate
  files and the collector's 51-submodule verification. Candidate files include
  tools and placeholders; they are not a definitive list of active link inputs.
- `docs/LICENSING_AUDIT-v220-v24.md` provides the full detailed review.

## EXTERNAL source dependencies — fetched separately, NOT shipped in this ZIP

| Dependency | Exact pin / source | Known issue still to resolve for binary distribution |
|---|---|---|
| Azahar + 51 recursive submodules | `a5c3d4f8eb34493f37479158128de134c3e700a9`; pins in `source-lock.json`; checkout from `https://github.com/azahar-emu/azahar` | Root license reference contains GPLv3 text; libretro modification header states GPLv2-or-later. Precise license grants and binary link composition are not yet fully established. |
| OpenEmu-Silicon SDK | `2b1c21c2c336ad4fb98b5722e0b8ef8963ca5369`; `https://github.com/OpenEmu-Silicon/OpenEmu-Silicon` | SDK/source file-level notices and compiled-framework obligations must be honored. |
| MoltenVK | `https://github.com/KhronosGroup/MoltenVK` | Development library was removed from this source ZIP. Version, source/build provenance, binary composition and corresponding license/notice obligations still need a reproducible plan. |

### What the isolated macOS linker-map audit established

The earlier evidence-only inventory of 51 Azahar submodules is **not** a list
of linked dependencies. Later **Gates 3–5** went further: the isolated
macOS `citra_libretro` link map selected **53 archive members** from five
libraries, traced to the pinned sources:

| Library | Selected objects | Source license finding |
|---|---:|---|
| FAAD2 (`libfaad2.a`) | 18 | Inspected source files say **GPLv2 or later**, and carry attribution including Nero AG / M. Bakker. Preserve the original full notices. |
| SoundTouch (`libSoundTouch.a`) | 8 | **LGPLv2.1 or later**; statically linked in this representative build. Relink capability proved, but recipient distribution materials remain open. |
| zstd (`libzstd.a`) | 24 | Source candidates traced in Gate 5; license options include BSD-style terms. |
| zstd seekable (`libzstd_seekable.a`) | 2 | License options include BSD-style terms. |
| xxHash (`libxxhash.a`) | 1 | Library source **BSD 2-Clause**; distinguish from GPL-covered xxHash CLI/test files. |

These **53 selected members are proven for the inspected isolated linker map**, not a full inventory of every compiled or dynamically loaded component of a future release binary. They do not establish legal compliance of a distributable plugin. See
`docs/BINARY-DISTRIBUTION-RELEASE-GATE-v220-v24.md`, `docs/SOUNDTOUCH-GATE8-RELINK-RESULT-v220-v24.md`, and `docs/CONSOLIDATED-BATCH9-RESULT-2026-11-08.md`.

The source ZIP contains no compiled FAAD2, SoundTouch, zstd, xxHash, Azahar,
MoltenVK, or OpenEmu SDK libraries. Those dependencies are fetched and built
separately. **Do not apply their binary distribution obligations to this
source-only archive as though those binaries were included**; evaluate the
actual distributed artifact when preparing a binary release. All relevant
upstream source and copyright notices must still be honored.

## Publication hold points

1. Decide and document the integration code's license and third-party code
   provenance, respecting the pinned Azahar GPL terms and actual linked inputs.
2. Resolve any incompatible license combinations that are **actually** linked.
3. Capture an exact MoltenVK release/source pin, proper build or distribution
   route and required notices; verify the source-only Mac build.
4. Identify exact Vulkan SDK header provenance and keep file-level notices.
5. Artwork license and mask provenance recorded (CC BY 4.0 for rights licensor controls); **separately resolve the older stock-photo tracing and any third-party rights** before public source release.
6. Review the **final** source repository/binary composition before a public
   release. A private review repository may be created while these remain open.

This project is not presented as an official OpenEmu or Nintendo release.
No ROMs, firmware, keys or game images are included.

## November 8, 2026 source-build evidence update

Consolidated Batch 9 downloaded this repository source ZIP (SHA-256
`aa284f596219dbb0d69d5aab4a52312114dd2925ac48e250b8dc629525d18b8d`),
verified 51 pinned Azahar submodules, built the Core and arm64 System Plugin,
and demonstrated a modified SoundTouch object was selected by a temporary
relink. It verified the presence of license files for FAAD2, SoundTouch, zstd
and xxHash, **not** complete binary notice/license clearance. The original
source and installed plugins were unmodified. See
`docs/CONSOLIDATED-BATCH9-RESULT-2026-11-08.md` and `LICENSING.md`.
