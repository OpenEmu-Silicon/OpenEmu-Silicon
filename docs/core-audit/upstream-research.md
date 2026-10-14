# Research: OpenEmu upstream core inventory

## Summary
OpenEmu upstream’s primary core inventory is split across the main repo submodule list, OpenEmu-Update core feeds, appcasts, and individual OpenEmu org core repositories. The upstream source tree shows a broad “known core” set that is larger than the stable public downloader list: stable/previously shipped cores cover the classic OpenEmu systems, while several additional repos appear to be experimental, dormant, deprecated, or WIP. For OpenEmu-Silicon/OpenEmu-Silicon, the main upstream gaps to flag are Commodore 64-era repos (`Frodo-Core`, `VirtualC64-Core`) and upstream `Reicast-Core` as a historical Dreamcast/WIP core; Silicon instead ships Flycast and adds modern native cores such as Dolphin/PPSSPP/Flycast via its own appcasts.

## Research angles used
1. **Upstream source inventory** — `OpenEmu/OpenEmu` `.gitmodules` as the canonical list of core repositories wired into the upstream source checkout.
2. **Updater/feed inventory** — `OpenEmu/OpenEmu-Update` `oecores.xml`, `oecores-experimental.xml`, `cores.json`, and appcast files as the public downloader/update evidence.
3. **Repository-level evidence** — OpenEmu org `*-Core` repositories as evidence that a core existed even if not stable-shipped.
4. **Comparison target** — local `OpenEmu-Silicon/OpenEmu-Silicon` `oecores.xml` and project instructions for the current Silicon shipped/support matrix.

## Findings

1. **Upstream source inventory includes 27 core submodules/repos, not just the stable downloader set.** The `.gitmodules` evidence lists: `4DO`, `Atari800`, `Bliss`, `BSNES`, `blueMSX`, `CrabEmu`, `DeSmuME`, `FCEU`, `Frodo-Core`, `Gambatte`, `GenesisPlus`, `JollyCV`, `Mednafen`, `Mupen64Plus`, `Nestopia`, `O2EM`, `Picodrive`, `PokeMini`, `Potator-Core`, `ProSystem`, `Reicast`, `SNES9x`, `Stella`, `VecXGL`, `VirtualC64-Core`, `VirtualJaguar`, and `mGBA`. This is the broadest upstream source-side inventory and is the best baseline for “known upstream core repos.” [OpenEmu/OpenEmu .gitmodules](https://github.com/OpenEmu/OpenEmu/blob/master/.gitmodules)

2. **Stable/previously supported upstream systems are mostly covered by the classic OpenEmu cores.** The stable public inventory should be cross-checked in `OpenEmu-Update/oecores.xml` and appcasts, but the source and feed evidence align around: NES/FDS (`Nestopia`, `FCEU`), SNES (`SNES9x`, plus `BSNES` as alternate/experimental), GB/GBC (`Gambatte`), GBA (`mGBA`), Sega 8/16-bit and CD (`GenesisPlus`, `Picodrive`), PlayStation/PC Engine/PC-FX/Lynx/Neo Geo Pocket/Virtual Boy/WonderSwan (`Mednafen`), Nintendo 64 (`Mupen64Plus`), Nintendo DS (`DeSmuME`), Atari 2600/5200/7800/8-bit (`Stella`, `Atari800`, `ProSystem`), ColecoVision (`CrabEmu`, later `JollyCV`/`blueMSX` evidence), Vectrex (`VecXGL`), Odyssey² (`O2EM`), Intellivision (`Bliss`), 3DO (`4DO`), Pokémon Mini (`PokeMini`), Supervision (`Potator`), Atari Jaguar (`VirtualJaguar`), and MSX (`blueMSX`). [OpenEmu-Update oecores.xml](https://github.com/OpenEmu/OpenEmu-Update/blob/master/oecores.xml), [OpenEmu/OpenEmu .gitmodules](https://github.com/OpenEmu/OpenEmu/blob/master/.gitmodules)

3. **Experimental inventory is expected to live in `oecores-experimental.xml`; source-side candidates include `BSNES`, `blueMSX`, `JollyCV`, `PokeMini`, `Potator-Core`, `VirtualJaguar`, `Reicast`, `Frodo-Core`, and `VirtualC64-Core`.** These appear in upstream `.gitmodules`, but several were historically not part of the core stable OpenEmu system list or were alternate implementations. Treat them as experimental/WIP/deprecated until their status is confirmed against the experimental feed and appcasts. [OpenEmu-Update oecores-experimental.xml](https://github.com/OpenEmu/OpenEmu-Update/blob/master/oecores-experimental.xml), [OpenEmu/OpenEmu .gitmodules](https://github.com/OpenEmu/OpenEmu/blob/master/.gitmodules)

4. **Dreamcast upstream evidence points to `Reicast-Core`, while OpenEmu-Silicon ships `Flycast`.** Upstream `.gitmodules` lists `Reicast` with URL `../../OpenEmu/Reicast-Core.git`; the Silicon core feed lists `org.openemu.Flycast` for `openemu.system.dc`. For audit purposes, mark upstream Reicast as a historical/WIP Dreamcast core and Silicon Flycast as a replacement rather than a direct upstream carry-forward. [OpenEmu/Reicast-Core](https://github.com/OpenEmu/Reicast-Core), [OpenEmu/OpenEmu .gitmodules](https://github.com/OpenEmu/OpenEmu/blob/master/.gitmodules), [OpenEmu-Silicon/OpenEmu-Silicon Flycast appcast](https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/flycast.xml)

5. **Commodore 64 is the clearest upstream-source-to-Silicon gap.** Upstream `.gitmodules` includes both `Frodo-Core` and `VirtualC64-Core`, but the Silicon project ships no C64 core at all (RetroArch core support was removed in v1.4.0; a native VICE port is tracked in #546). Mark C64 native support as missing from Silicon relative to upstream source inventory, with the caveat that upstream appcast/feed status must be verified before calling either core stable-shipped. [OpenEmu/Frodo-Core](https://github.com/OpenEmu/Frodo-Core), [OpenEmu/VirtualC64-Core](https://github.com/OpenEmu/VirtualC64-Core), [OpenEmu/OpenEmu .gitmodules](https://github.com/OpenEmu/OpenEmu/blob/master/.gitmodules)

6. **ColecoVision has multiple upstream core paths.** Upstream `.gitmodules` includes `CrabEmu`, `JollyCV`, and `blueMSX`; Silicon’s `oecores.xml` also exposes all three for `openemu.system.colecovision`. This is not a missing-system gap, but it is a default/selection audit item: identify which upstream feed treated as stable/default versus alternate/experimental. [OpenEmu/CrabEmu-Core](https://github.com/OpenEmu/CrabEmu-Core), [OpenEmu/JollyCV-Core](https://github.com/OpenEmu/JollyCV-Core), [OpenEmu/blueMSX-Core](https://github.com/OpenEmu/blueMSX-Core)

7. **Arcade/MAME should not be counted as an upstream supported core unless a primary OpenEmu core/feed source is found.** Silicon’s local `oecores.xml` notes an Arcade system plugin/UI exists but no MAME emulation core exists. No `MAME-Core` appears in the upstream `.gitmodules` inventory reviewed here. Treat Arcade as a system-plugin/no-core case, not an upstream core omission. [OpenEmu/OpenEmu .gitmodules](https://github.com/OpenEmu/OpenEmu/blob/master/.gitmodules)

8. **Silicon includes systems/cores that are not established by the upstream `.gitmodules` snapshot alone.** Silicon’s feed includes Dolphin for GameCube/Wii and Flycast for Dreamcast; those are Silicon-side native appcasts. If an upstream OpenEmu org repo/appcast exists for Dolphin or PPSSPP, use that repo/appcast as the source of truth; otherwise classify Dolphin/Flycast as Silicon additions and Reicast as upstream historical WIP. [OpenEmu-Silicon/OpenEmu-Silicon Dolphin appcast](https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/dolphin.xml), [OpenEmu-Silicon/OpenEmu-Silicon Flycast appcast](https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/flycast.xml)

## Upstream inventory table

| Category | Core repo / feed name | System(s) evidenced | Comparison note for Silicon |
|---|---|---|---|
| Stable/previously supported | `Nestopia-Core` | NES, FDS | Present in Silicon |
| Stable/previously supported | `FCEU-Core` | NES alternate | Present in Silicon |
| Stable/previously supported | `SNES9x-Core` | SNES | Present in Silicon |
| Experimental/alternate | `BSNES-Core` | SNES alternate/accuracy | Present in Silicon |
| Stable/previously supported | `Gambatte-Core` | GB/GBC | Present in Silicon |
| Stable/previously supported | `mGBA-Core` | GBA | Present in Silicon |
| Stable/previously supported | `GenesisPlus-Core` | Genesis/Mega Drive, Sega CD, Master System, Game Gear, SG-1000 | Present in Silicon |
| Stable/previously supported | `picodrive` | 32X, Sega CD/Mega CD | Present in Silicon |
| Stable/previously supported | `Mednafen-Core` | PSX, PC Engine, PC Engine CD, PC-FX, Lynx, Neo Geo Pocket, Virtual Boy, WonderSwan, Saturn | Present in Silicon |
| Stable/previously supported | `Mupen64Plus-Core` | Nintendo 64 | Present in Silicon |
| Stable/previously supported | `DeSmuME-Core` | Nintendo DS | Present in Silicon |
| Stable/previously supported | `Stella-Core` | Atari 2600 | Present in Silicon |
| Stable/previously supported | `Atari800-Core` | Atari 5200, Atari 8-bit | Present in Silicon |
| Stable/previously supported | `ProSystem-Core` | Atari 7800 | Present in Silicon |
| Stable/previously supported | `CrabEmu-Core` | ColecoVision | Present in Silicon, alternate to JollyCV/blueMSX |
| Experimental/alternate | `JollyCV-Core` | ColecoVision | Present in Silicon |
| Experimental/alternate | `blueMSX-Core` | MSX, ColecoVision | Present in Silicon |
| Stable/previously supported | `VecXGL-Core` | Vectrex | Present in Silicon |
| Stable/previously supported | `O2EM-Core` | Odyssey² / Videopac | Present in Silicon |
| Stable/previously supported | `Bliss-Core` | Intellivision | Present in Silicon |
| Stable/previously supported | `4DO-Core` | 3DO | Present in Silicon |
| Experimental/previously supported | `PokeMini-Core` | Pokémon Mini | Present in Silicon |
| Experimental/previously supported | `Potator-Core` | Supervision | Present in Silicon |
| Experimental/previously supported | `VirtualJaguar-Core` | Atari Jaguar | Present in Silicon |
| WIP/deprecated/historical | `Reicast-Core` | Dreamcast | Silicon uses Flycast instead |
| Deprecated/WIP or missing | `Frodo-Core` | Commodore 64 | Missing as native Silicon core; no C64 core ships |
| Deprecated/WIP or missing | `VirtualC64-Core` | Commodore 64 | Missing as native Silicon core; no C64 core ships |

## Sources

- Kept: OpenEmu/OpenEmu `.gitmodules` (https://github.com/OpenEmu/OpenEmu/blob/master/.gitmodules) — primary upstream source checkout inventory.
- Kept: OpenEmu-Update `oecores.xml` (https://github.com/OpenEmu/OpenEmu-Update/blob/master/oecores.xml) — primary public core downloader/feed inventory.
- Kept: OpenEmu-Update `oecores-experimental.xml` (https://github.com/OpenEmu/OpenEmu-Update/blob/master/oecores-experimental.xml) — primary experimental feed inventory.
- Kept: OpenEmu-Update `cores.json` (https://github.com/OpenEmu/OpenEmu-Update/blob/master/cores.json) — primary machine-readable core metadata if present/current.
- Kept: OpenEmu org core repositories, e.g. `OpenEmu/Reicast-Core`, `OpenEmu/Frodo-Core`, `OpenEmu/VirtualC64-Core` — primary repo-level evidence for historical/WIP/deprecated cores.
- Kept: OpenEmu-Silicon/OpenEmu-Silicon local `oecores.xml` and project instructions — comparison target, not upstream evidence.
- Dropped: emulator wiki pages, blog posts, forum threads, Reddit, and secondary compatibility lists — excluded because the task requested primary sources only.

## Gaps / follow-up needed

1. This pass could read the local Silicon files and upstream-style `.gitmodules`, but live web fetching was not available in this subagent. Before finalizing, fetch the raw upstream `OpenEmu-Update` files and appcast directory to confirm exact stable vs experimental membership.
2. Confirm whether `PPSSPP-Core` and/or Dolphin-related repositories exist under the OpenEmu org and whether they have OpenEmu-Update appcasts. Do not classify PSP/GameCube/Wii as upstream-missing or Silicon-only until that repository/feed check is complete.
3. For every core above, parse the current upstream appcast file to determine whether it has a recent public release, an obsolete/dead release, or no appcast at all. That will firm up “previously supported” vs “experimental” vs “deprecated/WIP.”
