# Contributing to OpenEmu-Silicon

OpenEmu-Silicon is a community-maintained Apple Silicon fork of [OpenEmu](https://github.com/OpenEmu/OpenEmu). It's kept alive by a small group of contributors and testers. Contributions of all kinds are welcome — code, documentation, testing, triage, and compatibility reporting.

---

## Ways to Contribute

You don't need to write code to make a meaningful contribution.

| Role | What it involves | How to start |
|------|-----------------|--------------|
| **Issue Triager** | Applying labels, asking for repro steps, closing duplicates, flagging `good first issue` candidates | Engage with a few issues, then ask the maintainer for triage permissions |
| **Compatibility Tester** | Testing games on the latest build, documenting results in the wiki | Open a Discussion and introduce yourself |
| **RetroAchievements Liaison** | Testing RA integration per-core, filing upstream RA tickets, maintaining the compatibility table | See [docs/retro-achievements/retroachievements-community-guide.md](../docs/retro-achievements/retroachievements-community-guide.md) |
| **Wiki / Docs Maintainer** | Keeping installation guides, core pages, and build instructions accurate | Open a PR or comment on a docs issue |
| **Code Contributor** | Bug fixes, feature work, core updates | Read on |

Not sure where to start? Open a Discussion in the Q&A category and say what you're interested in.

---

## Setting Up Your Dev Environment

### Requirements

- macOS 11.0 (Big Sur) or later — macOS 14 (Sonoma) or later recommended
- Xcode with the latest stable toolchain, including the Metal toolchain
- Apple Silicon Mac (M1 or later) — this fork does not target Intel
- No additional Homebrew dependencies required for the main app

### Steps

```bash
# 1. Fork and clone with submodules (cores live in submodules — this will take a few minutes)
git clone --recursive https://github.com/YOUR_USERNAME/OpenEmu-Silicon.git
cd OpenEmu-Silicon

# 2. Copy credential stubs (required — real credentials are never committed)
cp OpenEmu/ScreenScraperDevCredentials.template.swift OpenEmu/ScreenScraperDevCredentials.swift
cp OpenEmu/OEGoogleDriveSecrets.template.swift OpenEmu/OEGoogleDriveSecrets.swift
cp OpenEmu/CheatWorksSecrets.template.swift OpenEmu/CheatWorksSecrets.swift

# 3. Open the workspace (not the .xcodeproj)
open OpenEmu-metal.xcworkspace
```

Select the **OpenEmu** scheme and build for **My Mac**, or verify from the command line:

```bash
xcodebuild build \
  -workspace OpenEmu-metal.xcworkspace \
  -scheme OpenEmu \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Or use the project's verify script, which also runs a codesign check:

```bash
./Scripts/verify.sh
```

### Common Setup Issues

**Submodules not initialized:** If cores are missing from the workspace, run `git submodule update --init --recursive`. This can take 5–10 minutes the first time.

**Missing credential files:** If the build fails with "no such file" errors for Swift credential files, re-run the `cp` commands above. Template files are in the repo; real ones are not and are never committed.

**Wrong architecture:** Make sure the build destination is `arm64`. If Xcode defaults to Rosetta or an Intel simulator, change it in the scheme settings.

**Missing Metal toolchain:** Some command-line builds may fail with misleading errors from subprojects or external dependencies if the Metal toolchain is not installed. Make sure the Metal toolchain is included in your Xcode installation.

### Worktree builds

If you're working in a git worktree, use `./Scripts/build-for-worktree.sh` and `./Scripts/verify.sh --worktree`. Plain `xcodebuild` will break permission persistence between builds. See [docs/worktree-workflow.md](../docs/worktree-workflow.md) for the full workflow.

---

## Submitting a Pull Request

1. **Open an issue first** for anything beyond a trivial fix. This prevents duplicate work and lets us agree on approach before you invest time writing code.
2. **Branch from `main`**. Name your branch descriptively: `fix/snes-audio-regression` or `feat/retroachievements-badge`.
3. **Keep PRs focused.** One logical change per PR. If your fix touches three systems, open three PRs.
4. **Fill out the PR template completely.** It asks what changed, how you tested it, and whether AI tools were used.
5. **Expect a 1–2 week review window.** This project is maintained by one person. A polite ping after two weeks is welcome.
6. **Coordinate before touching `OpenEmu-SDK/OpenEmuBase/OEGameCore.h/.m`.** That file is the base class for every core and the highest-conflict file in the repo. Rebase on `main` immediately before pushing a change to it.

### PR Checklist

- [ ] Builds cleanly on Apple Silicon with no new warnings (`./Scripts/verify.sh`)
- [ ] Tested the affected core or system with at least one game
- [ ] Submodules pinned correctly if cores were updated
- [ ] AI tool use disclosed in PR description if applicable
- [ ] No build logs, binaries, or credentials committed

---

## AI-Assisted Contributions

AI tools (Claude, Cursor, Copilot) are used in the development of this project. Contributions using AI assistance are welcome. However, AI-generated code introduces specific risks — subtle regressions, incorrect memory handling, and plausible-looking but wrong emulation behavior that passes a surface review.

**The policy:**

1. **Disclose AI use in your PR description.** "Drafted with Claude Code" or "used Cursor for scaffolding" is sufficient — not a penalty.
2. **You must be able to explain every line on request.** If a reviewer asks "why does this work?" and you don't know, the PR will be closed. You are responsible for the code you submit.
3. **AI-only PRs with no issue link will be closed.** Open or comment on an issue first to agree the fix is worth pursuing and discuss approach.
4. **Low-effort AI PRs — vague description, no testing, no issue link — will be closed without review.** This is a capacity constraint, not a judgment.

---

## Good First Issues

Issues tagged [`good first issue`](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues?q=is%3Aopen+label%3A%22good+first+issue%22) are chosen because:

- The scope is well-defined
- The relevant file or function is identified in the issue body
- An approach or known constraints are described
- No deep codebase knowledge required

Comment on an issue before you start work to avoid duplicates.

---

## Working on RetroAchievements Integration

RA core integration is tracked in [issue #258](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/258). The implementation pattern and known pitfalls are documented in [docs/retro-achievements/retroachievements-implementation-guide.md](../docs/retro-achievements/retroachievements-implementation-guide.md). Read that before wiring up a new core.

For testing RA as a user or tester rather than as a developer, see [docs/retro-achievements/retroachievements-community-guide.md](../docs/retro-achievements/retroachievements-community-guide.md).

---

## Non-Code Roles

### Issue Triage

Triagers can apply and remove labels, close duplicates, mark issues `needs-info`, and flag `good first issue` candidates. They cannot merge PRs or push to main.

Engage with a few issues first — ask clarifying questions, look for duplicates — then ask the maintainer for triage permissions.

### Compatibility Testing

The compatibility list lives in the [project wiki](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki). To contribute:
1. Test a game on the latest release build
2. Note: core name, macOS version, M-chip generation, and what you observed
3. Submit a PR against the wiki or open a Discussion with your findings

### RetroAchievements Testing

See [docs/retro-achievements/retroachievements-community-guide.md](../docs/retro-achievements/retroachievements-community-guide.md) for how to test achievement behavior per-core and how to file upstream RA tickets.

---

## Recognition

Every contributor — code or otherwise — is named in release notes and Progress Reports. If you've contributed and weren't credited, open an issue and we'll fix it.

---

## Code of Conduct

This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Be constructive, be patient, be kind to people doing this work for free.

---

*Questions? Open a [Discussion](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/discussions).*
