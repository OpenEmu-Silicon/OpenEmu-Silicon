<p align="center">
  <img width="301" height="91" alt="OpenEmu-Silicon logo" src="https://github.com/user-attachments/assets/e4c7ee8d-b526-4fa7-bf61-153dc1594372" />
</p>

<h3 align="center">OpenEmu, updated to run natively on Apple Silicon.</h3>

<p align="center">
  The classic Mac emulator, actively maintained for M-series Macs. Fast, native, no Rosetta.
</p>

<p align="center">
  <a href="https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/OpenEmu-Silicon/OpenEmu-Silicon?style=for-the-badge&label=release"></a>
  <a href="https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases/latest"><img alt="Downloads of the latest release" src="https://img.shields.io/github/downloads/OpenEmu-Silicon/OpenEmu-Silicon/latest/total?style=for-the-badge&label=latest%20release%20downloads"></a>
  <a href="https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/OpenEmu-Silicon/OpenEmu-Silicon?style=for-the-badge"></a>
</p>

<p align="center">
  <img alt="Apple Silicon native" src="https://img.shields.io/badge/Apple%20Silicon-native-000000?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="macOS 11 and later" src="https://img.shields.io/badge/macOS-11%2B-0A84FF?style=for-the-badge&logo=apple&logoColor=white">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-BSD--3--Clause%20%2B%20core%20licenses-blue?style=for-the-badge"></a>
</p>

<p align="center">
  <a href="https://discord.gg/HvWfVkMUK"><img alt="Join the Discord" src="https://img.shields.io/badge/Join%20the%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white"></a>
  <a href="https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases/latest"><img alt="Download" src="https://img.shields.io/badge/Download%20the%20latest%20DMG-2ea44f?style=for-the-badge&logo=github&logoColor=white"></a>
  <a href="https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki"><img alt="Read the wiki" src="https://img.shields.io/badge/Read%20the%20Wiki-555555?style=for-the-badge&logo=gitbook&logoColor=white"></a>
</p>

<p align="center">
  <img width="2276" height="1550" alt="OpenEmu-Silicon game library" src="https://github.com/user-attachments/assets/3797ba95-3e8c-49f6-9d3d-ab1cca6e70b9" />
</p>

---

## Overview

OpenEmu-Silicon is a community-maintained fork of [OpenEmu](https://github.com/OpenEmu/OpenEmu) for M-series Macs. You get the same library-first experience Mac users loved: drop in your games, get cover art, pick a system, and play. It now runs natively on Apple Silicon, with new cores, fixes, and features added on top.

It runs on macOS 11.0 (Big Sur) and later, and has been tested on macOS Sequoia and macOS 26 (Tahoe). The installer is signed and notarized, so there is no Gatekeeper workaround.

## Features

- **Native Apple Silicon.** ARM64 build with Metal rendering. No Rosetta required.
- **30+ systems.** NES, SNES, Game Boy, GBA, N64, Nintendo DS, PlayStation, Dreamcast, GameCube/Wii, and more. See [Supported Systems](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Supported-Systems).
- **RetroAchievements.** Earn achievements on 9 cores, covering NES, SNES, Game Boy, GBA, Genesis, N64, PlayStation, and more.
- **Automatic cover art.** Box art and metadata pulled in through ScreenScraper.
- **Save states and persistent saves.** Pick up where you left off.
- **Controller support.** Mapping for the controllers Mac players actually use.
- **Cheats.** Built-in cheat database integration.
- **Easy updates.** Emulation cores update on their own, without a full app release.
- **Free and open source.** No ads, no paywall, and it stays that way.

## Install

**Download:** grab the latest signed DMG from the [Releases](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases) page.

**Homebrew:**

```bash
brew tap OpenEmu-Silicon/OpenEmu-Silicon https://github.com/OpenEmu-Silicon/OpenEmu-Silicon
brew install --cask openemu-silicon
```

Requires an Apple Silicon Mac (M1, M2, M3, M4) running macOS 11.0 or later. Coming from the original OpenEmu? Read [Migrating from OpenEmu](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Migrating-from-OpenEmu) first.

## Supported Systems

30+ systems work today. A handful have known issues (PSP, Saturn, Game Boy Color categorization), and PS2 and Commodore 64 have no core yet. Full working status, BIOS requirements, and what's planned are on the [Supported Systems](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Supported-Systems) wiki page.

## Known Issues

- **Save state compatibility.** Save states from certain older cores are incompatible with current ARM64 builds and will crash if loaded. On launch, the app detects these and shows a warning. **Back up your save states before your first launch.** See [Migrating from OpenEmu](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Migrating-from-OpenEmu) for the list and instructions.
- Input Monitoring permission may need to be granted manually in System Settings → Privacy & Security.
- A few cores have quirks on Apple Silicon that are still being investigated. See the [open issues](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues).

---

## Community

The Discord is the best place to get help, follow development, try early builds, and talk to the people working on the project. You don't need to write code to be part of it.

- **Testers:** try new builds and cores before release and report what breaks.
- **Contributors:** talk through a fix or feature before you open a PR.
- **Players:** ask questions, share setups, and tell us which systems you want improved.

<p align="center">
  <a href="https://discord.gg/HvWfVkMUK"><img alt="Join the Discord" src="https://img.shields.io/badge/Join%20the%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white"></a>
</p>

## Contributing

Issues, PRs, and testing feedback are all welcome, and there are plenty of ways to help that don't involve code.

| Role | What it involves |
|------|------------------|
| **Compatibility Tester** | Test games on the latest build and document results |
| **Issue Triager** | Reproduce bugs, label issues, close duplicates |
| **RetroAchievements Liaison** | Test achievements per core and keep the compatibility table current |
| **Docs and Wiki** | Keep install guides and core pages accurate |
| **Code Contributor** | Bug fixes, features, core updates |

Start with [`CONTRIBUTING.md`](.github/CONTRIBUTING.md). It covers dev setup, branch and PR rules, and each role in more detail. Looking for a first task? Check issues labeled [`good first issue`](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/labels/good%20first%20issue).

**Found a bug?** Open an issue with your Mac model, macOS version, and the system and game you were running. That context is the most useful thing you can give. Please read the [Reporting Problems guide](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Troubleshooting:-Reporting-Problems) first.

## Documentation

| Doc | What's in it |
|-----|-------------|
| [Wiki](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki) | User guides: getting started, BIOS files, importing, CD games, controllers, troubleshooting |
| [Migrating from OpenEmu](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Migrating-from-OpenEmu) | What carries over from the original OpenEmu, what doesn't, and how to back up |
| [Supported Systems](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki/Supported-Systems) | Every system: status, known issues, in-progress cores, BIOS requirements |
| [`CONTRIBUTING.md`](.github/CONTRIBUTING.md) | Dev setup and how to contribute |
| [`CREDITS.md`](.github/CREDITS.md) | Everyone who contributed: the original OpenEmu team, the ARM64 port, core sources, illustrators, and this repo's contributors |

---

## About This Project

OpenEmu is still some of the best software on the Mac. [stuartcarnie](https://github.com/stuartcarnie) brought Metal rendering in 2019, [MaddTheSane](https://github.com/MaddTheSane) started porting the cores to ARM64 in 2021, and [cyco](https://github.com/cyco), [clobber](https://github.com/clobber), [J-rg](https://github.com/J-rg), and the OpenEmu team built the app, plugin system, and library over more than a decade. Everything here builds on their work.

The original project went quiet around 2024, and its last official release (December 2023) was Intel-only. [bazley82](https://github.com/bazley82) assembled the team's ARM64 core work into a downloadable build in early 2026. This fork picks up from there, adding RetroAchievements, ScreenScraper cover art, Flycast for Dreamcast, fixes to saves, system detection and core updates, and macOS 26 support.

**Lineage:** [OpenEmu/OpenEmu](https://github.com/OpenEmu/OpenEmu) (original) → [bazley82/OpenEmuARM64](https://github.com/bazley82/OpenEmuARM64) (ARM64 build) → this repo, maintained by [@nickybmon](https://github.com/nickybmon) and contributors.

### AI-Assisted Development

Most of the code here is still the original team's, and the architecture is unchanged. I use AI tools to help write and debug code. I review and test every change and make the final calls on direction and quality.

---

## License

This project is a derivative of [OpenEmu](https://github.com/OpenEmu/OpenEmu). Most of the main app and SDK still carries the OpenEmu Team's original **BSD 3-Clause** copyright header, which is what actually governs those files. See [`LICENSE`](LICENSE) for the full text and how it applies. Individual emulation cores carry their own licenses (GPL v2, MPL 2.0, LGPL 2.1, and others). See each core's directory for details.

Note: [picodrive](https://github.com/notaz/picodrive) includes a non-commercial clause. This project is and will remain free.
