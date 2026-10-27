# AGENTS.md: OpenEmu-Silicon

Shared instructions for AI coding agents (Claude Code, Cursor, Copilot, Codex, and others) and for people working in this repository. Vocabulary lives in [`CONTEXT.md`](CONTEXT.md). Contributor setup lives in [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md).

---

## About This Project

OpenEmu-Silicon is a community-maintained fork of [OpenEmu](https://github.com/OpenEmu/OpenEmu), rebuilt to run natively on Apple Silicon (arm64) without Rosetta. It builds on the foundational ARM64 port at [bazley82/OpenEmuARM64](https://github.com/bazley82/OpenEmuARM64).

The goal is to keep the original OpenEmu spirit (a beautifully designed, native macOS emulation frontend) while making it work reliably on M-series Macs with modern macOS and Swift.

The maintainer is not a professional developer. Write commit messages, PR descriptions, and explanations in plain language. Use a plain word where one works.

---

## Ground Rules

1. **Contributors work on a branch and open a PR against `main`.** There is no staging branch. The maintainer may push small docs, script, and chore changes straight to `main`.
2. **Make surgical changes.** This is a large, complex Xcode project. Do not rewrite `project.pbxproj` or large ObjC files wholesale.
3. **Core directories are regular directories.** `Nestopia/`, `BSNES/`, and the others are flattened. Do not turn them back into git submodules.
4. **Never commit secrets or build output.** No `.o` files, DerivedData, `.app` bundles, logs, binaries, or the real credential files listed below.
5. **Never publish a GitHub Release.** Drafts are fine. Going live is the maintainer's action.
6. **Keep copyright headers** on every file you touch (see License Rules).
7. **No AI attribution in commits, PRs, or issues.** Never add `Co-Authored-By: Claude`, `Claude-Session:`, or "Generated with Claude Code" lines. The maintainer is the sole author. Disclose AI use in the PR text instead.

---

## Language and Tooling

- **Swift 6.3.2** with strict concurrency. Use `@MainActor`, `Sendable`, and structured concurrency correctly.
- **Objective-C**: many core files are ObjC, with bridge headers in place. Do not break them.
- **Xcode 26.5**, built with `xcodebuild`. The primary workspace is `OpenEmu-metal.xcworkspace`.
- **No package manager.** No SPM, CocoaPods, or Carthage. Dependencies are vendored or flattened.

---

## Build and Verify

CI (`build-check.yml`) builds every PR, including every core the PR touches, and the test scripts below build the app themselves. A separate local build-and-analyze pass is not a step any more. Use the script that fits the change:

```bash
./Scripts/check.sh                  # build, then drive the real app (windows, panes, Cores) against your real library
./Scripts/check.sh --no-build       # same, reusing the last build
./Scripts/check.sh --rom <file>     # also load a game: draws, moves, quick save, quit (uses a throwaway library)
./Scripts/playtest.sh --game "<name>"   # play a game from your real library, then report frame rate, audio, errors
./Scripts/doctor.sh                 # a few seconds: signing certificate, credential stubs, running app, test runner signature
./Scripts/prove.sh                  # the checks the diff touches, ends with PROVEN or NOT PROVEN (--all runs every step)
./Scripts/verify.sh --core <Name>   # build, install, and check one core (add --release for Release-only bugs)
./Scripts/verify.sh --test          # run the OpenEmuTests unit target
```

`check.sh` and `playtest.sh` share one build folder (`~/Builds/openemu/harness`, override with `OE_BUILD_DIR`), so the second one reuses the first one's build. Quit OpenEmu before either.

`verify.sh` without `--core` or `--test` (build, analyze, plist, codesign) still works but is redundant with CI and the scripts above.

Read the whole output and note any new warnings even on a passing build.

To launch the debug app, use `./Scripts/launch-debug.sh` instead of `open <path>`. It picks the build that matches your current branch and refuses to launch a stale one.

### Credentials stubs (first build only)

Generate the gitignored local files from their templates:

```bash
cp OpenEmu/ScreenScraperDevCredentials.template.swift OpenEmu/ScreenScraperDevCredentials.swift
cp OpenEmu/CheatWorksSecrets.template.swift OpenEmu/CheatWorksSecrets.swift
```

---

## Working on a core (read this before testing any core change)

OpenEmu loads cores from `~/Library/Application Support/OpenEmu/Cores/`, **not** from the build folder. Building a core does not change what the app runs. The most expensive mistake in this repo is reporting "still broken" or "now working" after testing an old installed copy.

1. Build the core's own scheme. The main `OpenEmu` scheme does not build cores. (`verify.sh --core <Name>` does steps 1 and 2.)
2. Install with `./Scripts/install-core.sh <Name>`. It quits OpenEmu and copies the binary and Info.plist correctly. **Never use `cp -R` or `cp -Rf` on a plugin.** macOS merges bundle folders instead of replacing them, so old files stay.
3. Run `./Scripts/verify-core-installed.sh <Name>` and confirm it prints `OK` before you report any in-game result.

Working in a git worktree? Use `Scripts/build-for-worktree.sh` or `verify.sh --worktree`, and run the three-way hash check. Both are explained in [`docs/worktree-workflow.md`](docs/worktree-workflow.md).

---

## Proving a fix (reproduce first, then fix, then show it passes)

A bug is not fixed because the code compiles or the change looks right. It is fixed when a check that failed before now passes, and the output is in the PR. Do this without waiting for the maintainer, and only come back when you have proof or have hit a limit you can name.

1. **Reproduce first.** Write the smallest check that fails for the reason in the issue, and run it. A failing check you cannot get is a finding in itself: say so.
2. **Fix.** Change the code until that same check passes.
3. **Show it.** Paste the before and after output into the PR description. When the proof is something you can see (a picture that changed, a window that now looks right, an alert that no longer appears), also post screenshots with `./Scripts/pr-evidence.sh --claim "<what this proves>" --from-playtest` (or `--before`/`--after`, or named files). It shows a dry run first; add `--post` once you have looked at every picture. The same goes for a feature: post pictures that show it built the way the agreed spec says.

Pick the cheapest check that can really see the bug:

| The bug lives in | Use |
|------------------|-----|
| A pure function, parser, or data rule | A unit test in the matching `*Tests` target (`./Scripts/verify.sh --test`) |
| A core: loading, picture, sound, button input, save states | `./Scripts/headless/gb-checks.sh` for Game Boy, or `./Scripts/headless/run.sh <Core> --rom <file> ...` for any core. It runs the core with no window, so no one has to play the game |
| The app window, menus, preferences, import, quick save | `./Scripts/check.sh` (UI tests; leave the mouse and keyboard alone while it runs) |
| A crash | The crash report plus `./Scripts/collect-diagnostics.sh`. Write the check that triggers it, then fix |

`./Scripts/prove.sh` chains the build, tests, headless checks, and diagnostics and prints one pass or fail line. A change is proven only when it ends with `PROVEN`.

**One-time setup on a Mac (the maintainer does this once).** Debug builds are signed ad hoc, so the signature changes on every rebuild and macOS forgets what the debug app was allowed to do. That shows up two ways: the keyboard dies (Input Monitoring) and unit tests hang until someone clicks Allow on a "read your Documents folder" prompt. Run `./Scripts/setup-debug-signing.sh` once (it asks for the login password), then click Allow once. `./Scripts/prove.sh` tells you when the certificate is missing. An agent must not run that script, because it changes the keychain.

Known gap: `OpenEmuKitTests` does not compile in the workspace today (`OpenEmuKitPrivate` cannot be resolved), so shader-preset tests are not run anywhere.

State plainly what was not proven. Some things cannot be automated here: real controllers and Bluetooth pairing, and macOS permission prompts (Input Monitoring, Bluetooth). For those, prove everything up to the hardware edge (for example, decode captured reports in a unit test) and list the rest as "needs hands-on test" in the PR. Never write "fixed" for something only a person with the hardware can confirm.

Before you report any in-game result, make sure the thing you ran is the thing you built (see "Working on a core" above, and use `./Scripts/launch-debug.sh` for the app). The headless scripts build their own copy of the core, so they never test a stale install.

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
| Arcade | MAME (default), FBNeo |
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
`defaultCore.openemu.system.<sysid>` in `UserDefaults`. The host app seeds a default in `OpenEmu/AppDelegate.swift` for three systems today:

- `openemu.system.nes` → `org.openemu.Nestopia`
- `openemu.system.snes` → `org.openemu.SNES9x`
- `openemu.system.arcade` → `org.openemu.MAME` (so MAME, the pre-existing core, stays default; the user can switch to FBNeo in Preferences → Cores)

For any other multi-core system (e.g. ColecoVision — JollyCV / CrabEmu / blueMSX), no default is seeded and the user picks from Preferences → Cores. Adding a default seed is a one-line change in `AppDelegate.swift` if a default is wanted; until that is done, behavior is whatever the picker chooses to surface first.

---

---

## Branches and Pull Requests

- Branch from `main` and open the PR against `main` on `OpenEmu-Silicon/OpenEmu-Silicon`.
- Name the branch for its content (`fix/short-description`, `feat/...`, `chore/...`). Do not reuse a merged branch.
- PR title: `fix: description`, `feat: description`, or `chore: description`.
- Fill in `.github/PULL_REQUEST_TEMPLATE.md`, including its "How to test locally" block. Keep that block as written and fill in only the placeholders (PR number, core name).
- Link issues with `Fixes #N` in the PR body (closes on merge) or `Related to #N`.
- Keep a PR to one theme. Several small related fixes in one PR are fine. Unrelated changes are not.
- Always pass `--repo OpenEmu-Silicon/OpenEmu-Silicon` to `gh` commands. Forks exist.

---

## Issues

Use the issue templates (`bug_report`, `feature_request`, `core_integration`, `checklist`).

1. **Search before opening.** `gh issue list --repo OpenEmu-Silicon/OpenEmu-Silicon --state open`. If it is already tracked, comment instead of opening a duplicate.
2. **No type prefixes in titles.** Labels carry the type. Good: `PokeMini: OpenEmuBase header missing in standalone build`. Bad: `note: PokeMini needs workspace integration`.
3. **One issue per concern.** Same root cause and same fix means one issue.
4. **Only one open checklist per milestone.** Update it instead of opening another.

---

## Working with an AI agent on this repo

What has worked well here:

- **Point the agent at this file first**, then at `CONTEXT.md` so it uses the right words.
- **Let the agent build and check its own work** with `check.sh` (and `verify.sh --core` for cores) before it hands anything to you. Ask a person to test only what needs hands, ears, or eyes: controllers, gameplay, audio, rendering.
- **Do core testing through the scripts above.** The stale-plugin mistake is the one agents make most.
- **Ask for plain-language summaries.** The maintainer and most testers are not developers.
- **Say in the PR that AI helped** (the template asks). Nobody minds. Transparency is the point.
- **Review the diff yourself** before you push. Agents are confident when wrong.

---

## What NOT to Do

- Do not edit `project.pbxproj` by hand unless you know exactly what you are changing.
- Do not add dependencies without discussion. The project intentionally has no package manager.
- Do not remove or rename core directories. The Xcode project references them.
- Do not change `MACOSX_DEPLOYMENT_TARGET` below `12.0`.
- Do not commit real credentials (`ScreenScraperDevCredentials.swift`, `CheatWorksSecrets.swift`). Use the templates.
- Do not add debug `+load` / `+initialize` methods that write to `/tmp` or hardcode local paths.
- Do not commit large binaries (`.zip`, `.tar.gz`, executables). Those belong in GitHub Releases.
- Do not report a core test result without running `verify-core-installed.sh` since the last build.

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
3. **picodrive and FBNeo are non-commercial** — never charge for a build that includes either. FBNeo also inherits the MAME license; ship its license verbatim (see [`FBNeo/LICENSE`](FBNeo/LICENSE))
4. **No CLA** — your contributions are covered by the license of the files you touch
