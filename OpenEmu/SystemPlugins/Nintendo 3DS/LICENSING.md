# Licensing and rights scope — Azahar/OpenEmu integration

**Copyright (c) 2026 Derek Hugger — original eligible integration contributions.**

The `LICENSE` file contains the standard **BSD 3-Clause** license selected by Derek Hugger for **copyrightable original integration contributions that he owns and has authority to license**. It is not a declaration that every file, entire adapter implementation, third-party excerpt, asset, or compiled plugin is BSD-licensed. Where a file contains material from another copyright holder, that holder's existing rights and terms remain in force. A missing copyright header is not evidence of independent authorship.

## Project-specific BSD-3-Clause scope

The intended coverage is independently licensable original OpenEmu/Azahar integration code, project-specific tests, configurations and build helpers, to the extent owned by Derek Hugger. File/section provenance review remains open for the large Core adapter, Vulkan ABI bridge and any portions adapted from OpenEmu sample code. Do not strip or replace inherited notices and do not add `SPDX-License-Identifier: BSD-3-Clause` indiscriminately to entire files pending that review.

## Material *not* licensed by this grant

- **Azahar** and its source modifications, including changes to GPL-covered libretro code, retain their applicable upstream GPL and per-file license notices. Upstream sources are fetched at the pins in `source-lock.json`; they are not relicensed here.
- **OpenEmu-Silicon SDK** and framework-derived interfaces retain the applicable upstream licensing, copyright and attribution obligations.
- **libretro API headers/declarations**, including `OfficialABI/libretro.h`, `OfficialABI/libretro_vulkan.h` and the local shortened `AzaharCore/libretro.h`, must be considered under their libretro API origin and applicable MIT-style notices. See `THIRD_PARTY_NOTICES.md` and `docs/SOURCE-PROVENANCE-REVIEW-v220-v24.md`.
- **Khronos Vulkan headers**, **MoltenVK**, **SoundTouch**, **FAAD2**, **zstd**, **xxHash**, and other third-party libraries have their own copyright and licensing conditions. The exact linked binary must be reviewed before distribution.
- **Controller illustration, mask, pixel-art icon and matching library image** are **not licensed under BSD 3-Clause**. CC BY 4.0 has been selected for the licensable original artwork rights Derek Hugger controls in the exact assets identified in `ARTWORK_LICENSE.md`. The mask was generated with ChatGPT assistance from his illustration and red-dot template. The historical stock-photo tracing and possible third-party rights remain disclosed and subject to review before public release.
- Any third-party material or excerpts identified by subsequent file-level investigation remain governed by the relevant holders' rights regardless of where located.

## Source repository versus compiled plugins

The source-only repository contains no bundled emulator dylib, prebuilt SDK frameworks, ROMs, keys or game saves. Its source build has been technically demonstrated (see `docs/CONSOLIDATED-BATCH9-RESULT-2026-11-08.md`); this does **not** grant a license for separately obtained upstream code or clear redistribution of combined binaries.

A public binary package would require exact third-party notices and full applicable license texts, corresponding source and build/relink materials, a recipient-usable SoundTouch modification path, and a review of signing/Gatekeeper behavior. The isolated SoundTouch relink tests (Gates 6B, 8 and Batch 9) prove technical capability, **not** a complete LGPL-2.1 distribution arrangement. See `docs/BINARY-DISTRIBUTION-RELEASE-GATE-v220-v24.md`.

## Review references

- `LICENSE` — full BSD-3-Clause terms for eligible original contributions.
- `THIRD_PARTY_NOTICES.md` — included headers and pinned external dependencies.
- `docs/BSD3-SCOPE-DECISION-v220-v24.md` and `docs/BSD3-FILE-BY-FILE-TRIAGE-v220-v24.csv` — historical triage; **not a final authorship certification**.
- `ARTWORK_LICENSE.md` — CC BY 4.0 artwork scope and external-rights limits.
- `ARTWORK_CREDITS.md` — authorship, AI-assisted mask provenance and historical photo-reference review.
- `PUBLICATION_CHECKLIST.md` — release hold points.

**Status as of 2026-11-08:** Private publication review. No public source or binary release authorization is claimed. This record is engineering documentation, not legal advice.
