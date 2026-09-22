# RetroAchievements — User and Contributor Guide

[RetroAchievements](https://retroachievements.org) is a community platform that adds an achievement system to classic games played through emulators. OpenEmu-Silicon integrates RA support through [rcheevos](https://github.com/RetroAchievements/rcheevos), the same client library used by RetroArch and other supported emulators.

This guide is for **users and contributors** — people who want to earn achievements, test RA behavior, or report issues. If you're a developer looking to integrate rcheevos into a new core, see [retroachievements-implementation-guide.md](retroachievements-implementation-guide.md) instead. For native compliance evidence and #438 verification results, see [retroachievements-compliance-evidence.md](retroachievements-compliance-evidence.md).

---

## Table of Contents

- [Core Support Status](#core-support-status)
- [Getting Started](#getting-started)
- [Testing Achievement Behavior](#testing-achievement-behavior)
- [Reporting RA Issues](#reporting-ra-issues)
- [Filing RA-Side Tickets](#filing-ra-side-tickets)
- [Working with the RA Community](#working-with-the-ra-community)
- [Contributing as an RA Liaison](#contributing-as-an-ra-liaison)

---

## Core Support Status

RA integration is rolling out in phases. See [issue #258](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/258) for the full rollout tracker.

| Core | System(s) | RA Status |
|------|-----------|-----------|
| mGBA | Game Boy Advance, Game Boy, Game Boy Color | ✅ Supported |
| Gambatte | Game Boy, Game Boy Color | ✅ Supported |
| FCEU | NES / Famicom | ✅ Supported |
| Nestopia | NES / Famicom, Famicom Disk System | ✅ Supported |
| SNES9x | SNES / Super Famicom | ✅ Supported |
| BSNES | SNES / Super Famicom | ✅ Supported |
| Mupen64Plus | Nintendo 64 | ✅ Supported |
| GenesisPlus | Genesis / Mega Drive, Master System, Game Gear, SG-1000, Sega CD | ✅ Supported |
| picodrive | Sega 32X | ✅ Supported |
| Mednafen | PlayStation, Saturn, PC Engine / TurboGrafx-16, PC Engine CD / TurboGrafx-CD, PC-FX, Atari Lynx, Neo Geo Pocket, Virtual Boy, WonderSwan | ✅ Supported |
| Stella | Atari 2600 | ✅ Supported |
| ProSystem | Atari 7800 | ✅ Supported |
| DeSmuME | Nintendo DS | ✅ Supported |
| PPSSPP | PSP | ✅ Supported |
| CrabEmu | ColecoVision | ✅ Supported |
| blueMSX | MSX, ColecoVision | ✅ Supported |
| O2EM | Odyssey² / Videopac+ | ✅ Supported |
| VecXGL | Vectrex | ✅ Supported |
| PokeMini | Pokémon Mini | ✅ Supported |
| Potator | Watara Supervision | ✅ Supported |
| Flycast | Dreamcast | � Planned |
| Dolphin | GameCube, Wii | 🔲 Planned |
| Atari800 | Atari 5200, Atari 8-bit | 🔲 Planned |
| Bliss, 4DO | Various | 🔲 Planned |

**Legend:**
- ✅ Supported — integrated and tested against known achievement sets
-  Planned — tracked in the rollout issue; contributors welcome

> **Note:** The native-core hardcore compliance rollout was tracked in #438. The main P0 enforcement work is complete for supported native RA cores; remaining work is focused on manual verification evidence, submission-readiness documentation, and follow-up polish before the official RetroAchievements listing.

---

## Getting Started

### What you need

- A RetroAchievements account — free at [retroachievements.org](https://retroachievements.org)
- A ROM of a game with an achievement set (browse the [game list](https://retroachievements.org/gameList.php))
- A version of OpenEmu-Silicon with RA enabled (all recent releases include it)

### Enabling RA in OpenEmu-Silicon

1. Open **OpenEmu-Silicon → Preferences → Achievements**
2. Log in with your RetroAchievements credentials
3. Your token is stored securely in the macOS keychain

Once logged in, achievement notifications appear as an overlay during gameplay and as system notifications. Earned achievements sync to your retroachievements.org profile.

---

## Testing Achievement Behavior

Good RA testing is methodical. For each core you're testing:

### Basic smoke test

1. Launch a game with a known achievement set in the relevant core.
2. Verify the achievement list loads (you should see it in the achievements panel if applicable, or confirm on retroachievements.org after login).
3. Trigger a simple, early-game achievement by following its known trigger condition (listed on the achievement's page on retroachievements.org).
4. Verify the achievement notification fires and the achievement is marked earned on retroachievements.org.

### After a core update

When a core submodule is bumped, repeat the smoke test for the affected core before the update is considered clean. If you discover a regression, note:
- Core version before and after the bump
- Which achievement(s) were affected
- Whether the regression is in achievement triggering, memory reading, or server communication

### What to document

For each test session, post findings as a comment on the relevant GitHub issue (or open one):
- Core name and commit hash or version
- macOS version and chip generation
- Game title and region
- Achievement name and trigger condition
- Pass / fail, and any console or log output

---

## Reporting RA Issues

Before opening an issue, check [existing RA issues](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues?q=is%3Aopen+label%3Aretro-achievements) — your issue may already be tracked.

When you do open an issue, use the **Bug Report** template and include:
- Whether this is in a supported core (see the table above)
- Whether the issue occurs with RA **disabled** too — this helps determine if it's an RA-specific regression
- The game title, achievement name, and the expected trigger condition
- Your RA account username (so the maintainer can check your profile if needed)

Apply the `retro-achievements` label plus the relevant core label.

---

## Filing RA-Side Tickets

Not every RA bug belongs in OpenEmu-Silicon's issue tracker. If the problem is in the achievement set itself — wrong memory address, wrong trigger condition, wrong point value — file it on the RetroAchievements side.

To file an RA-side ticket:
1. Go to the game's page on retroachievements.org
2. Click the achievement in question
3. Use the **Open Ticket** button (requires an RA account)
4. Select the correct type (Achievement did not trigger / Achievement triggered at the wrong time / etc.)
5. Include the emulator name (**OpenEmu-Silicon**) and version in the ticket body

When you file an RA-side ticket related to OpenEmu-Silicon, link to it from the corresponding GitHub issue here so the resolution can be tracked in both places.

---

## Working with the RA Community

RetroAchievements has a large, active community of achievement set developers who have strong motivation to make sure emulators work correctly. This is a valuable contributor pipeline for OpenEmu-Silicon.

### Where RA developers hang out

- **RetroAchievements forums** — retroachievements.org/forums, especially the **Emulator Support** board
- **RetroAchievements Discord** — the `#coders` channel is where achievement set developers and emulator integration developers interact
- **Individual achievement set threads** — each game has its own thread where set authors discuss known issues

### When OpenEmu-Silicon gains official RA listing

Post in the RA **Emulator Support** forum to announce it. The RA team actively spotlights newly listed emulators — coordinate with RA staff via their Discord to time the announcement. Frame it as: here's what's supported, here's what's in progress, here's how to file issues.

RA achievement set developers will file bugs against OpenEmu-Silicon when they find them. When they do:
- Treat them as high-quality reporters — they understand the memory conditions deeply
- Ask for the achievement name, game title, and expected trigger condition
- Tag the issue `retro-achievements` + the relevant core label

---

## Contributing as an RA Liaison

An RA Liaison is a community role for people who want to help maintain the bridge between OpenEmu-Silicon and the RetroAchievements community. It doesn't require writing code.

**What it involves:**
- Testing newly integrated cores against known achievement sets and documenting results
- Monitoring the RA forums and Discord for OpenEmu-Silicon mentions and bug reports
- Filing or triaging GitHub issues when RA bugs are reported in the RA community
- Helping distinguish emulator bugs (file here) from achievement set bugs (file upstream with RA)
- Maintaining the RA compatibility table in the wiki

**How to get started:**
Open a Discussion and introduce yourself. If you've already tested a core and documented results, that's the fastest way to demonstrate fit.

---

*Questions? Open a [Discussion](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/discussions) or comment on [issue #258](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/258).*
