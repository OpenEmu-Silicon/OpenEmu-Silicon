# CONTEXT.md — OpenEmu-Silicon shared vocabulary

The terms below show up across the app code, the issue tracker, commit messages, and release notes. Use them precisely. When you write code, comments, PR descriptions, or release notes, reach for these words rather than inventing synonyms.

This file is the source of truth for what each term means *in this codebase*. If you find the codebase using a term differently than what's written here, that's drift — flag it before assuming either is correct.

---

## Emulation layer

| Term | Meaning |
|---|---|
| **core** | An emulator backend for one or more game systems. There is one core per top-level directory (e.g. `Dolphin/`, `Flycast/`, `Mednafen/`). Some cores cover multiple systems (Mednafen covers PSX, Saturn, WonderSwan, Lynx). |
| **plugin** / **`.oecoreplugin`** | The packaged build of a core — a macOS bundle that the host app loads at runtime. Lives at `~/Library/Application Support/OpenEmu/Cores/<Name>.oecoreplugin` once installed. |
| **system** | A console or platform (NES, SNES, Genesis, etc.). Multiple cores can support the same system; a core can support multiple systems. |
| **native core** | A core that subclasses `OEGameCore` directly (Mednafen, Mupen64Plus, BSNES, Snes9x, Genesis Plus GX, etc.). Owns its own frame loop and integrates cross-cutting services in-tree. Every core this fork ships is a native core. |

## Process and runtime

| Term | Meaning |
|---|---|
| **host app** | The main `OpenEmu.app` — the library, preferences, controllers UI, save state browser. |
| **helper / broker / `OpenEmuHelperApp`** | The sandboxed XPC process that actually runs an emulator core. Lives in `OpenEmu/broker/`. The host app and helper communicate via XPC; the helper isolates crashes so a bad core can't take down the library. |
| **rcheevos** | The vendored C library that talks to the RetroAchievements service. Built into the helper. Cores integrate it directly. |

## Update / distribution

| Term | Meaning |
|---|---|
| **Sparkle** | The third-party macOS update framework the app uses. Reads `appcast.xml` to decide whether an update is available. |
| **appcast** | The XML feed that tells Sparkle about new app versions. Top-level `appcast.xml` for the host app; one file per core under `Appcasts/` for individual core updates. |
| **EdDSA signature** | The Sparkle update signature on each appcast entry. Generated from the actual artifact by the release workflow — never hand-edited. |
| **CoreUpdater** | The in-app component that checks each core's appcast and installs updates. Loads cores from `~/Library/Application Support/OpenEmu/Cores/`. |
| **cores release** | A standalone release that ships only updated `.oecoreplugin` bundles, with no host-app rebuild. Tagged `cores-vX.Y.Z`. |
| **app release** | A full host-app release. Tagged `vX.Y.Z`. |
| **Homebrew cask** | `Casks/openemu-silicon.rb` — the cask formula used to install via Homebrew. The DMG SHA256 in here is updated by the release workflow. |

## Signing / distribution chain

| Term | Meaning |
|---|---|
| **Developer ID signing** | The Apple Developer ID certificate used to sign the app for distribution outside the Mac App Store. Cert lives as `DEVELOPER_ID_CERT_BASE64` in repo secrets. |
| **hardened runtime** | The macOS code-signing flag required for notarization. All shipped binaries must build with this on. The historic notarization failure was a missing hardened runtime entitlement. |
| **notarization** | Apple's automated malware scan. The release workflow submits the signed app to Apple, waits for a clean ticket, then staples the ticket onto the DMG. |
| **stapling** | Attaching the notarization ticket to the artifact so macOS can verify offline. |

## Code organization

| Term | Meaning |
|---|---|
| **OpenEmu-SDK** | Shared protocols and types that both the host app and core plugins import. Treat as a public ABI — breaking changes ripple to every core. |
| **OpenEmuKit** | UI components shared across the host app. |
| **OpenEmu-Shaders** | The Metal shader library used by the renderer. |
| **Vendor/** | Third-party C libraries the host app links directly (XADMaster, UniversalDetector). |
| **flattened submodule** | A core directory that used to be a git submodule but has been committed as plain tracked files. Do not try to `git submodule init` these — they are flat on purpose. |

## Features

| Term | Meaning |
|---|---|
| **Play With…** | The library context-menu submenu that lets the user pick which core to launch a given ROM with. Only an autosave from the selected core is offered for resuming; an autosave from another core is skipped so it cannot override the selection. Normal launches can still resume with the autosave's core. |
| **RetroAchievements (RA)** | Third-party achievement system. Phase 1 covers the cores listed in the v1.0.7 release notes. The pref pane and HUD live in the host app; the rcheevos C library lives in the helper. |
| **hardcore mode** | A RetroAchievements concept (no save states or rewind) — *not currently supported* in this repo. Do not claim it in release notes or documentation. |
| **rewind** | The host-side save-state ring buffer that lets the player step backward. Implemented in the helper, controlled from the host. |

## What this file is not

- It is not a module map or architecture overview — read the directory structure for that.
- It is not a list of supported cores — `AGENTS.md` has the current matrix.
- It is not a glossary of generic emulation terms — only the ones used distinctively in this codebase.

When you add a new feature or rename something significant, update this file in the same PR. Drift here is more harmful than no entry at all.
