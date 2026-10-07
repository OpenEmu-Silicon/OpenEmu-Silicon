# AGENTS.md — OpenEmu-Silicon

Instructions for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in this repository.

---

## Read First

Before doing any work, read this file fully. It is the authoritative source for how this project is structured and how changes should be made.

---

## About This Project

OpenEmu-Silicon is a community-maintained fork of OpenEmu, rebuilt to run natively on Apple Silicon (arm64) without Rosetta. It descends from:

- [OpenEmu/OpenEmu](https://github.com/OpenEmu/OpenEmu) — the original project
- [bazley82/OpenEmuARM64](https://github.com/bazley82/OpenEmuARM64) — the foundational ARM64 port

The goal is to honor the original OpenEmu spirit — a beautifully designed, first-class native macOS game emulation frontend — while making it work reliably on M-series Macs with modern macOS and Swift.

**The maintainer is not a professional developer.** If you are writing explanations, commit messages, or comments, please use plain language. Avoid jargon where a plain word works just as well.

---

## Ground Rules

1. **Never commit directly to `main`.** All work goes through feature branches → PRs → `main`.
2. **Branch from `main`, open PRs against `main`.** There is no staging branch.
3. **Build before committing.** Run an `xcodebuild` check on any Swift/ObjC changes before staging a commit.
4. **Don't rewrite files wholesale.** This is a large, complex Xcode project. Make surgical changes. Rewriting `.pbxproj` or large ObjC files without understanding them will break the build.
5. **Respect the flattened architecture.** Submodule directories (`Nestopia/`, `BSNES/`, etc.) are regular directories — do not attempt to re-initialize them as git submodules.
6. **Do not commit build artifacts.** No `.o` files, derived data, `.app` bundles, build logs, or compiled executables.

---

## Language and Tooling

- **Swift 6.3.2** — strict concurrency is enforced. Use `@MainActor`, `Sendable`, and structured concurrency correctly.
- **Objective-C** — many core files are ObjC. Bridge headers are in place. Don't break them.
- **Xcode 26.5** — use `xcodebuild` for CLI builds. The primary workspace is `OpenEmu-metal.xcworkspace`.
- **No package manager** — no SPM, no CocoaPods, no Carthage. Dependencies are vendored or flattened submodules.

---

## Build Command

The canonical verification floor is `Scripts/verify.sh`. It builds, runs the static analyzer, validates Info.plist and entitlements, and checks codesign — a stricter floor than a bare `xcodebuild build`.

```bash
./Scripts/verify.sh                 # build + analyze + plist + codesign
./Scripts/verify.sh --launch        # above + 5s smoke launch with crash check
./Scripts/verify.sh --test          # above + run OpenEmuTests unit target
```

A bare build check is acceptable for quick iteration:

```bash
xcodebuild \
  -workspace OpenEmu-metal.xcworkspace \
  -scheme OpenEmu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build 2>&1 | tail -30
```

**A clean `verify.sh` run is the definition of "passing."** Run it before every push touching source files. The pre-push git hook in `.githooks/pre-push` enforces this mechanically — install it once per clone with `./Scripts/install-hooks.sh`.

### Setup and Credentials Pre-Requisites

Before compiling for the first time, you must generate the local gitignored secrets/credentials files from their templates:
```bash
cp OpenEmu/ScreenScraperDevCredentials.template.swift OpenEmu/ScreenScraperDevCredentials.swift
cp OpenEmu/OEGoogleDriveSecrets.template.swift OpenEmu/OEGoogleDriveSecrets.swift
cp OpenEmu/CheatWorksSecrets.template.swift OpenEmu/CheatWorksSecrets.swift
```

---

## File Organization

| What you're touching | Where it lives |
|----------------------|---------------|
| Main app logic | `OpenEmu/*.swift` and `OpenEmu/*.m` |
| Shared protocols/types | `OpenEmu-SDK/` |
| UI components | `OpenEmuKit/` |
| Metal shaders | `OpenEmu-Shaders/` |
| Emulator cores | `[CoreName]/` (top-level dirs) |
| Build and utility scripts | `Scripts/` |
| Xcode project | `OpenEmu/OpenEmu.xcodeproj/` |

---

## Supported Cores (as of 2026)

| System | Core(s) |
|--------|---------|
| 3DO | 4DO |
| Arcade | MAME |
| Atari 2600 | Stella |
| Atari 5200 | Atari800 |
| Atari 7800 | ProSystem |
| Atari 8-bit | Atari800 |
| Atari Jaguar | VirtualJaguar |
| Atari Lynx | Mednafen |
| ColecoVision | JollyCV (default), CrabEmu, blueMSX |
| Commodore 64 | (no core ships in this fork — native VICE port tracked in [#546](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/546)) |
| Famicom Disk System | Nestopia |
| Game Boy / GBC | Gambatte |
| Game Boy Advance | mGBA |
| Game Gear | Genesis Plus GX (GenesisPlus) |
| GameCube | Dolphin |
| Intellivision | Bliss |
| MSX | blueMSX |
| Neo Geo Pocket | Mednafen |
| Nintendo (NES) | Nestopia (default), FCEU |
| Nintendo 64 | Mupen64Plus |
| Nintendo DS | DeSmuME |
| Odyssey² / Videopac+ | O2EM |
| PC Engine | Mednafen |
| PC Engine CD | Mednafen |
| PC-FX | Mednafen |
| Pokémon Mini | PokeMini |
| Sega 32X | Picodrive |
| Sega CD / Mega CD | Genesis Plus GX (GenesisPlus) |
| Sega Dreamcast | Flycast |
| Sega Genesis / Mega Drive | Genesis Plus GX (GenesisPlus) |
| Sega Master System | Genesis Plus GX (GenesisPlus) |
| Sega Saturn | Mednafen |
| Sony PlayStation | Mednafen |
| Sony PSP | PPSSPP |
| Super Nintendo (SNES) | SNES9x (default), BSNES |
| Supervision | Potator (Potator-Core) |
| Vectrex | VecXGL |
| Virtual Boy | Mednafen |
| Wii | Dolphin |
| WonderSwan | Mednafen |

### Default core selection

For systems with multiple cores, OpenEmu uses the value at
`defaultCore.openemu.system.<sysid>` in `UserDefaults`. The host app seeds a default in `OpenEmu/AppDelegate.swift` for two systems today:

- `openemu.system.nes` → `org.openemu.Nestopia`
- `openemu.system.snes` → `org.openemu.SNES9x`

For any other multi-core system (e.g. ColecoVision — JollyCV / CrabEmu / blueMSX), no default is seeded and the user picks from Preferences → Cores. Adding a default seed is a one-line change in `AppDelegate.swift` if a default is wanted; until that is done, behavior is whatever the picker chooses to surface first.

---

## Branch and PR Rules

These rules exist because AI-assisted sessions have previously created orphaned branches, duplicate issues, and commits without PRs. Follow them exactly.

**Branches:**

| Rule | Why |
|------|-----|
| Always branch from `main` | Prevents tangled history |
| One branch = one concern | Keeps PRs focused and reviewable |
| Never reuse a merged branch | New commits on a merged branch have no PR — invisible |
| Branch name must match content | If scope changes, start a new branch |
| Delete local branch after merge | `git branch -d` immediately after syncing main |

**PRs:**

- **Target branch:** `main` on `OpenEmu-Silicon/OpenEmu-Silicon`
- **Push and open a PR in the same step — never push without immediately opening a PR**
- **PR title format:** `fix: description` / `feat: description` / `chore: description`
- **Use the PR template** — `.github/PULL_REQUEST_TEMPLATE.md` auto-populates. Fill every section.
- Each PR addresses one issue or one logical change — no bundled unrelated fixes
- Reference the issue with `Fixes #N` in the commit body (auto-closes on merge) or `Related to #N` (soft link)
- For core-specific fixes, note which systems are affected

**Every PR description must include a "How to test locally" section** with exact copy-paste commands.

**If the PR only touches main app code** (`OpenEmu/`, `OpenEmuKit/`, `OpenEmu-SDK/`):

```
## How to test locally

# 1. Check out this PR
gh pr checkout <N> --repo OpenEmu-Silicon/OpenEmu-Silicon

# 2. Build
xcodebuild \
  -workspace OpenEmu-metal.xcworkspace \
  -scheme OpenEmu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build 2>&1 | tail -20

# 3. Launch
open ~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-*/Build/Products/Debug/OpenEmu.app
```

**If the PR touches a core plugin** (anything inside `Dolphin/`, `Flycast/`, etc.):

```
## How to test locally

# 1. Check out this PR
gh pr checkout <N> --repo OpenEmu-Silicon/OpenEmu-Silicon

# 2. Build the core scheme (the main OpenEmu scheme does not build core plugins)
xcodebuild \
  -workspace OpenEmu-metal.xcworkspace \
  -scheme <CoreName> \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build 2>&1 | tail -20

# 3. Install the core (quits OpenEmu automatically, then copies binary + Info.plist)
./Scripts/install-core.sh <CoreName>

# 4. Launch
open ~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-*/Build/Products/Debug/OpenEmu.app
```

**Never use `cp -Rf` to install a core plugin.** macOS merges bundle directories rather than replacing them — old files silently stay in place. Always use `./Scripts/install-core.sh` or `cp -f` on individual files. Always quit OpenEmu before installing — the helper process holds the binary open while running.

Replace `<N>` with the actual PR number and `<CoreName>` with the scheme name (e.g. `Dolphin`, `Flycast`). Add any PR-specific setup steps below — which ROM or system to test, any BIOS files required, any permissions to revoke first, or specific behaviors to verify from the QA spec.

---

## Issue Tracker

The issue tracker at `OpenEmu-Silicon/OpenEmu-Silicon` is the primary place for bug reports, feature requests, core integration work, and release checklists.

**Issue templates** — always use the appropriate template:

| Template | Use when |
|----------|----------|
| `bug_report` | Runtime crash, wrong behavior |
| `feature_request` | New core, new capability |
| `core_integration` | Core fails to build, missing from workspace, needs ARM64 porting |
| `checklist` | Release milestone tracking — one open checklist per milestone max |

**Issue hygiene rules (non-negotiable):**

1. **Search before opening.** Run `gh issue list --repo OpenEmu-Silicon/OpenEmu-Silicon --state open` first. If the problem is already tracked, comment — don't open a duplicate.
2. **No type prefixes in titles.** Never write `note:`, `fix:`, `feat:`, `bug:` in the issue title. Labels carry the type. The title describes the problem.
   - Good: `PokeMini — OpenEmuBase header missing in standalone build`
   - Bad: `note: PokeMini — needs workspace integration`
3. **One issue per concern.** Same root cause + same fix = one issue covering both.
4. **Close resolved issues immediately.** The moment a fix is committed, run: `gh issue close #N --repo OpenEmu-Silicon/OpenEmu-Silicon --comment "Resolved in <sha>."` Do not leave issues open for a later cleanup pass.
5. **Close superseded issues immediately.** If you open a more comprehensive issue that replaces an older one, close the old one in the same session.
6. **Only one checklist per milestone.** If one is already open, update it.

---

## What NOT to Do

- Do not modify `project.pbxproj` manually unless you know exactly what you're changing — it's a large generated file and merge conflicts are painful
- Do not add new dependencies without discussion — the project intentionally has no package manager
- Do not remove or rename existing core directories — they are referenced by the Xcode project
- Do not commit the `build_*.log` files that exist at root — they are legacy artifacts
- Do not change `MACOSX_DEPLOYMENT_TARGET` below `11.0` — this is the ARM64 baseline
- Do not commit secrets (like `OEGoogleDriveSecrets.swift` or `ScreenScraperDevCredentials.swift`) — they are gitignored for a reason; they hold real OAuth credentials or API keys
- Do not add debug `+load` / `+initialize` methods that write to `/tmp` or hardcode local paths
- Do not commit large binaries (`.zip`, `.tar.gz`, compiled executables) — these belong in GitHub Releases
- Do not commit directly to `main` under any circumstances
- Do not declare a core test result without running `./Scripts/verify-core-installed.sh <CoreName>` since the last build — testing against a stale installed plugin is the single most expensive failure mode in this repo

---

## Core update channel

Every shipped core plugin embeds a `SUFeedURL` in its `Info.plist`. Sparkle reads it from the **installed** plugin bundle, so it controls updates for users who already have the core.

The canonical pattern, used by all cores nickybmon ships, is:

```
https://raw.githubusercontent.com/OpenEmu-Silicon/OpenEmu-Silicon/main/Appcasts/<core>.xml
```

`<core>` is the lowercased core name (e.g. `dolphin`, `mednafen`, `bluemsx`). The matching file must exist under `Appcasts/` in this repo — that is the file Sparkle fetches.

Rules:

- Never re-introduce `OpenEmu-Update`, `raw.github.com/OpenEmu`, or `appcast.openemu.org` URLs into a core `Info.plist`. That update channel is upstream-owned and dormant; updates published here will not reach users.
- When adding a new core, add its appcast file to `Appcasts/<core>.xml` *and* set the `Info.plist` `SUFeedURL` to the canonical URL above in the same commit.
- `Scripts/check-core-feed-urls.sh` enforces both rules and is wired into `Scripts/verify.sh --core` as a precondition.
- Core appcast entries should be EdDSA-signed when newly published. `Scripts/update_core_appcast.py --sign-zip <path-to-zip>` runs Sparkle's `sign_update` against the local zip and embeds `sparkle:edSignature` on the new `<enclosure>`. The host app's existing Sparkle keypair is reused — do not generate a new one.

---

## License Rules

The main app is **BSD 2-Clause**. Emulator cores are mostly **GPL v2**. Key rules:

1. **Preserve all copyright headers** — never strip or modify the license block at the top of any file
2. **Add a header to new files** you create in `OpenEmu/`, `OpenEmu-SDK/`, or `OpenEmuKit/`:
   ```
   // Copyright (c) 2026, OpenEmu Team
   //
   // Redistribution and use in source and binary forms, with or without
   // modification, are permitted provided that the following conditions are met:
   // ...
   ```
3. **picodrive is non-commercial** — never charge for a build that includes it
4. **No CLA** — your contributions are covered by the license of the files you touch

---

## Testing PRs Locally Before Merging

> **Core plugin work has a process gate.**
>
> OpenEmu loads cores from `~/Library/Application Support/OpenEmu/Cores/`, **not** from the build directory. Building a core does *not* affect what OpenEmu loads. Before claiming any test result on a core change:
>
> 1. Build the core scheme (or run `./Scripts/verify.sh --core <CoreName>` which does this for you, with `--release` if testing a Release-only behavior).
> 2. Run `./Scripts/install-core.sh <CoreName>` (use `--release` for Release builds). This is automatic when you use `verify.sh --core`.
> 3. Run `./Scripts/verify-core-installed.sh <CoreName>` and confirm `OK`. If it prints `FAIL`, the installed plugin doesn't match the build and your test result is invalid.
>
> The most common silent failure is testing against a stale installed plugin from a previous session. The preflight script catches this in under a second; run it before reporting any "still broken" or "now working" result.
>
> Cursor users: a project-level hook at `.cursor/hooks/post-edit-core.sh` automatically reminds the agent of these steps after every edit to a core source file, and surfaces the live preflight status. Do not work around the hook — if it tells you the install is stale, fix it before claiming a result.

Before merging any PR, check it out locally, build, and verify the behaviors described in the PR's test plan.

**When reviewing a PR, always provide:**
1. The exact `gh pr checkout` command for that PR number
2. Any PR-specific setup (e.g. BIOS files needed, permissions to revoke first)
3. The specific behaviors to verify from the PR's test plan

### Check out a PR branch

```bash
# gh looks up the branch name automatically
gh pr checkout <PR_NUMBER> --repo OpenEmu-Silicon/OpenEmu-Silicon

# Example
gh pr checkout 54 --repo OpenEmu-Silicon/OpenEmu-Silicon
```

### Build

For main app changes:

```bash
xcodebuild \
  -workspace OpenEmu-metal.xcworkspace \
  -scheme OpenEmu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build 2>&1 | tail -30
```

For core plugin changes, use the core's own scheme (e.g. `Dolphin`, `Flycast`):

```bash
xcodebuild \
  -workspace OpenEmu-metal.xcworkspace \
  -scheme Dolphin \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build 2>&1 | tail -30
```

The main `OpenEmu` scheme does not build core plugins. Building the wrong scheme means you're testing old code.

### Install a core plugin after building

Use the install script — it quits OpenEmu first and copies files correctly:

```bash
./Scripts/install-core.sh Dolphin
```

**Never use `cp -Rf` to install a core plugin.** macOS merges bundle directories rather than replacing them, so old files silently stay in place. Always use the script or `cp -f` on individual files. Always quit OpenEmu before installing — the helper process holds the binary open while running and `cp` will silently fail to replace it.

### Launch the built app

```bash
open ~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-*/Build/Products/Debug/OpenEmu.app
```

Or launch from Spotlight — after a Debug build the app is registered and findable by name.

### Test multiple PRs in isolation (worktrees)

```bash
# Create an isolated copy of the repo on a PR branch
git worktree add ../openemu-pr54 fix/flycast-input-crash

# Build and run from that directory
cd ../openemu-pr54
xcodebuild -workspace OpenEmu-metal.xcworkspace -scheme OpenEmu \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build

# Clean up when done
git worktree remove ../openemu-pr54
```

### Return to main

```bash
git checkout main
```

---

## Quick Reference

```bash
# Open in Xcode
open OpenEmu-metal.xcworkspace

# --- Start of every new piece of work ---
git checkout main
git fetch origin && git merge origin/main

# Create a feature branch
git checkout -b fix/your-description

# Build check before committing
xcodebuild -workspace OpenEmu-metal.xcworkspace -scheme OpenEmu \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  build 2>&1 | tail -10

# Stage and commit
git add -p
git commit -m "fix: description"

# Push and open a PR — always in the same step, never one without the other
git push -u origin fix/your-description
gh pr create --repo OpenEmu-Silicon/OpenEmu-Silicon --base main --title "fix: your-description" --body "..."
```
