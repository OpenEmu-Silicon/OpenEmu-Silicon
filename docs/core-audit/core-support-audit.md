# Core Support Gap Analysis

_Last updated: 2026-06-08_

This document explains what OpenEmu-Silicon currently supports, what appears to be missing from upstream OpenEmu history, and what work should be prioritized next.

It is **not** a release-process document. For the current core release mechanics, use the `/release-core` command (maintainer-only) and the scripts under `Scripts/`.

Supporting evidence:

- `docs/core-audit/local-inventory.md` — parsed local repo inventory.
- `docs/core-audit/upstream-research.md` — upstream OpenEmu research notes.
- `docs/adr/0004-core-update-channel-ownership.md` — why this fork owns its own appcast URLs.

## Plain-English summary

OpenEmu-Silicon is **not missing many classic OpenEmu cores**. Most of the old OpenEmu submodule cores are already present here, and many have working Apple Silicon appcasts.

The important gaps are narrower:

1. **Arcade / MAME** — user-provided Apple Silicon port exists and has been tested, but it still needs first-class repo/release integration.
2. **Commodore 64** — UI/system plugin exists, but no core ships at all since RetroArch core support was removed in v1.3.1; `OpenEmu/VICE-Core` is the best native lead to investigate (#546).
3. **PlayStation 2 / VMU** — system plugins exist, but these should not be treated as near-term native-core work.
4. **Metadata drift** — a few appcast / plist / `oecores.xml` mismatches should be cleaned up or intentionally documented.

## The mental model

OpenEmu has three separate layers:

| Layer | What it means | Example |
|---|---|---|
| **System plugin** | The console/platform exists in the OpenEmu UI. | `OpenEmu/SystemPlugins/Arcade/` means Arcade appears as a system. |
| **Core source** | Emulator wrapper/source exists somewhere in the repo. | `DeSmuME/` or `MAME/MAME.xcodeproj`. |
| **Release/update metadata** | Users can download/update that core through `oecores.xml` and `Appcasts/*.xml`. | `Appcasts/mednafen.xml` points to a released plugin zip. |

Those layers can disagree. Most confusion comes from treating them as the same thing.

For example:

| System | UI/system plugin? | Core source? | Released to users? | Meaning |
|---|---:|---:|---:|---|
| Nintendo DS | Yes | Yes, DeSmuME | Yes | Released through the native DeSmuME appcast/update path. |
| Arcade | Yes | Yes, local MAME project from user-provided OpenEmu/UME-Core guidance | Not yet | Tested as working; needs repo/release integration and remaining fixes. |
| Commodore 64 | Yes | Not yet | No | No core ships; investigate native `VICE-Core` (#546). |
| PlayStation 2 | Yes | No local release-ready core | No | Research/out-of-scope for now. |

## Current support state

### Covered native systems

These systems have local native core coverage and appcast/update metadata:

| System(s) | Core(s) |
|---|---|
| 3DO | 4DO |
| Atari 2600 | Stella |
| Atari 5200 / Atari 8-bit | Atari800 |
| Atari 7800 | ProSystem |
| Atari Jaguar | VirtualJaguar |
| Atari Lynx | Mednafen |
| ColecoVision | JollyCV, CrabEmu, blueMSX |
| Dreamcast | Flycast |
| Famicom Disk System | Nestopia |
| Game Boy / Game Boy Color | Gambatte |
| Game Boy Advance | mGBA |
| GameCube / Wii | Dolphin |
| Game Gear / Master System / SG-1000 / Genesis / Sega CD/Mega CD | Genesis Plus GX |
| Intellivision | Bliss |
| MSX | blueMSX |
| Neo Geo Pocket | Mednafen |
| NES | Nestopia, FCEU |
| Nintendo 64 | Mupen64Plus |
| Nintendo DS | DeSmuME |
| Odyssey² | O2EM |
| PC Engine / PC Engine CD / PC-FX | Mednafen |
| PlayStation / Virtual Boy / WonderSwan | Mednafen |
| Pokémon Mini | PokeMini |
| PSP | PPSSPP |
| Sega 32X | Picodrive |
| Saturn | Mednafen |
| SNES | SNES9x, BSNES |
| Supervision | Potator |
| Vectrex | VecXGL |

### In progress

| System | Core | State |
|---|---|---|
| Arcade | MAME / UME-Core lineage | User-provided Apple Silicon port has been tested as working. Local `MAME/MAME.xcodeproj` exists, but it is not wired into `OpenEmu-metal.xcworkspace`, `oecores.xml`, or `Appcasts/`. Remaining work is first-class integration, updater support, and known graphics fixes. |

### UI-visible but no native shipped core

| System | Current interpretation |
|---|---|
| Commodore 64 | System plugin exists. No core ships in this fork at all; native VICE port tracked in #546. |
| PlayStation 2 | System plugin exists. Upstream OpenEmu has experimental/research repos, but no local release-ready native core. Keep out of release planning unless explicitly prioritized. |
| VMU | System plugin exists. Treat as Dreamcast peripheral / not expected as standalone native core unless a specific product decision changes this. |

## Upstream comparison

Most old OpenEmu submodule cores are already present locally:

| Upstream core family | Local state |
|---|---|
| 4DO, Atari800, Bliss, blueMSX, BSNES, CrabEmu, FCEU, Gambatte, GenesisPlus, JollyCV, Mednafen, mGBA, Mupen64Plus, Nestopia, O2EM, Picodrive, PokeMini, Potator, ProSystem, SNES9x, Stella, VecXGL, VirtualJaguar | Present |
| DeSmuME | Present and released |
| Reicast | Not carried forward; superseded by Flycast |
| Frodo-Core / VirtualC64-Core | Stale/local-historical references only; not recommended as the first C64 path. `OpenEmu/VICE-Core` is the better native candidate to investigate. |

OpenEmu org repos worth knowing about:

| Repo | Why it matters |
|---|---|
| `OpenEmu/UME-Core` | Main historical lead for native Arcade/MAME support. |
| `OpenEmu/VICE-Core` | Best native C64 lead. Investigation in `docs/core-audit/vice-core-investigation.md` found the VICE 3.4 headless library builds on Apple Silicon, but the plugin project still needs porting. |
| `OpenEmu/VirtualC64-Core` | Older WIP/not-working C64 reference; do not prioritize unless VICE-Core proves unusable. |
| `OpenEmu/PCSX2-Core` / `OpenEmu/Play-Core` | PS2 research leads, not near-term release candidates. |
| `OpenEmu/Reicast-Core` | Historical Dreamcast lead; Flycast is the better current path. |

Deprecated upstream cores that should generally **not** be ported:

| Deprecated | Replacement |
|---|---|
| Higan | BSNES |
| VisualBoyAdvance | mGBA |
| NeoPop | Mednafen |
| TwoMbit | Genesis Plus GX |
| Yabause | Mednafen |

## Recommended next work

### 1. Arcade / MAME: audit and integrate if viable

Why this matters:

- Arcade has a system plugin.
- A local `MAME/MAME.xcodeproj` exists.
- A user provided Apple Silicon porting guidance based on the original OpenEmu MAME/UME-Core work.
- The port has been tested as working, but still has known graphics/update integration work remaining.

Do next:

1. Capture the current working state from the user-provided port: source provenance, exact build steps, known-good ROMs, and known failures.
2. Confirm whether local `MAME/` maps cleanly to `OpenEmu/UME-Core` and what changes were needed for Apple Silicon.
3. Add proper workspace integration once the local project builds reproducibly from repo source.
4. Add `Appcasts/mame.xml` and an `oecores.xml` entry only after there is a tested distributable plugin.
5. Validate real Arcade ROM loading, controls, save states, polygon rendering, and rotated/TATE games.

### 2. Nintendo DS / DeSmuME: released

Current state:

- DeSmuME has been migrated from the original OpenEmu/TASEmulators path.
- NDS system plugin exists.
- `oecores.xml` lists DeSmuME.
- `Appcasts/desmume.xml` now points at a signed DeSmuME 0.9.14 release asset.
- Release verification passed with `./Scripts/verify.sh --core DeSmuME --release`.

Remaining validation before broadly advertising the core should focus on runtime coverage: ROM boot, video, audio, input, save state save/load, and dual-screen display.

### 3. Commodore 64: port native VICE-Core if prioritized

Why this matters:

- C64 appears in the app UI.
- No native C64 core currently ships.
- Historical leads exist, but none look obviously ready.

Investigation result:

- `OpenEmu/VICE-Core` is viable enough to continue as a native porting project.
- The VICE 3.4 headless library built successfully on Apple Silicon with CMake.
- The OpenEmu plugin project is still x86_64-only and uses stale framework/appcast settings.
- Keyboard/modifier handling is unfinished and should be treated as a major runtime validation area.

Do next:

1. Open a focused implementation issue for porting native VICE-Core to Apple Silicon.
2. Use `docs/core-audit/vice-core-investigation.md` as the handoff.
3. Treat `VirtualC64-Core` as fallback/reference only because it is older and marked WIP/not working.
4. Do not prioritize Frodo unless a concrete maintained OpenEmu repo/path is found.

### 4. PS2 and VMU: keep out of normal release planning

Why this matters:

- Their system plugins can make them look like missing core work.
- They are not equivalent to MAME or DeSmuME in readiness.

Recommendation:

- PS2: research only unless deliberately prioritized.
- VMU: likely not a standalone console target.

### 5. Metadata cleanup

The audit found several mismatches. All have been resolved (as of 2026-06-08):

| Mismatch | Resolution |
|---|---|
| Mednafen plist registers Saturn, but `oecores.xml` did not advertise it. | Saturn added to Mednafen's system list and description in `oecores.xml`. |
| `oecores.xml` advertised Picodrive for Sega CD, but Picodrive source plist only registers 32X. Sega CD is covered by Genesis Plus GX. | Removed Sega CD from Picodrive in `oecores.xml`; updated description to "Sega 32X emulator". |
| Flycast appcast URL had `?v=2` in `oecores.xml` but not in the plugin plist. | Removed `?v=2` from `oecores.xml`; URL now matches the plugin plist and the actual filename. |
| `.gitmodules` had stale entries for Reicast, Frodo-Core, and VirtualC64-Core with no corresponding directories. | All three entries removed from `.gitmodules`. |

## Suggested issues

1. **Arcade — finish native MAME/UME-Core integration and updater path** — #500
2. **Commodore 64 — investigate native VICE-Core integration** — #542; follow-up port issue #546
3. **Core metadata — reconcile `oecores.xml`, appcasts, and core plists** — #543 _(resolved 2026-06-08)_
4. **System plugins — classify UI-visible systems without native cores** — #544 _(resolved 2026-06-08)_

## Bottom line

The project does **not** need a broad “port every old OpenEmu core” effort. Most of that work is already present.

The real plan should be:

1. Finish MAME's first-class integration/updater path from the tested user-provided port.
2. Investigate native C64 through `OpenEmu/VICE-Core` first.
3. Keep PS2/VMU out of near-term scope unless deliberately prioritized.
4. Clean up metadata drift so the UI, source tree, updater, and wiki tell the same story.
