# Contributing to OpenEmu-Silicon

OpenEmu-Silicon is a community-maintained Apple Silicon fork of [OpenEmu](https://github.com/OpenEmu/OpenEmu). It's kept alive by a small group of contributors and testers. Contributions of all kinds are welcome: code, documentation, testing, triage, and compatibility reporting.

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

Not sure where to start? Join the [Discord](https://discord.gg/HvWfVkMUK) and say what you're interested in, or open a Discussion in the Q&A category.

---

## Setting Up Your Dev Environment

### Requirements

- macOS 12.0 (Monterey) or later, macOS 14 (Sonoma) or later recommended
- Xcode with the latest stable toolchain, including the Metal toolchain
- Apple Silicon Mac (M1 or later), this fork does not target Intel
- No additional Homebrew dependencies required for the main app

### Steps

```bash
# 1. Fork and clone with submodules (cores live in submodules, this will take a few minutes)
git clone --recursive https://github.com/YOUR_USERNAME/OpenEmu-Silicon.git
cd OpenEmu-Silicon

# 2. Copy credential stubs (required, real credentials are never committed)
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

## Testing a Pull Request or Fix

You don't have to write code to help. One of the most useful things you can do is build someone else's pull request (PR) on your own Mac, try it, and report what happened. The maintainer often can't reproduce a bug (for example, one that needs a second drive, a specific controller, or a particular game), so a second set of hands is how those fixes get verified.

### Before you start

- **Back up first.** A test build uses the same settings and library as your normal OpenEmu. If the PR touches the library, save states, or settings, copy `~/Library/Application Support/OpenEmu` somewhere safe before you launch it.
- **Installed cores are shared.** The build you make here is just the app. Cores (the emulators) load from `~/Library/Application Support/OpenEmu/Cores/`. Install the latest release from the [README](../README.md#install) once so your cores are in place. If the PR changes a core, see "If the PR changes a core" below.
- **Quit your game first.** `launch-debug.sh` closes any running OpenEmu, including your normal copy, so save your game and quit before you run it.
- **Same requirements as above:** Apple Silicon Mac, Xcode with the Metal toolchain, and the one-time setup in [Setting Up Your Dev Environment](#setting-up-your-dev-environment).

### Steps

Each block below is meant to be pasted into Terminal as is. Only the lines marked `CHANGE THIS` need editing.

**Step 1: One-time setup.** Skip this if you already cloned the repo and set it up for development.

```bash
git clone --recursive https://github.com/OpenEmu-Silicon/OpenEmu-Silicon.git
cd OpenEmu-Silicon
cp OpenEmu/ScreenScraperDevCredentials.template.swift OpenEmu/ScreenScraperDevCredentials.swift
cp OpenEmu/OEGoogleDriveSecrets.template.swift OpenEmu/OEGoogleDriveSecrets.swift
```

**Step 2: Switch to the PR you want to test.** Do this every time. First, in the repo folder, change the PR number on the first line to the one you're testing (it's in the PR's title, like `#123`). If git complains about local changes, stash or discard them first.

```bash
PR=REPLACE_WITH_PR_NUMBER   # CHANGE THIS, for example PR=123
git checkout main && git pull
gh pr checkout $PR --repo OpenEmu-Silicon/OpenEmu-Silicon
```

No GitHub CLI (`gh`)? Use this instead of the `gh pr checkout` line, keeping the `PR=` line from above:

```bash
PR=REPLACE_WITH_PR_NUMBER   # CHANGE THIS, for example PR=123
git checkout main && git pull
git fetch origin pull/$PR/head:pr-$PR && git checkout pr-$PR
```

**Step 3: Build.** The first build takes a while. If it fails, copy the last 30 lines of output into your report.

```bash
./Scripts/verify.sh
```

**Step 4: Launch the build you just made.** This refuses to open an out-of-date build, which prevents the most common mistake: testing an old version by accident.

```bash
./Scripts/launch-debug.sh
```

**When you're done**, switch back to the main branch:

```bash
git checkout main
```

These steps use the repo's helper scripts because they are the simplest and safest path for testers. If you're writing a PR and need a "How to test locally" section for it, follow the format in [`AGENTS.md`](../AGENTS.md) instead.

### If the PR changes a core

Check the PR's "Which cores or systems are affected?" section. If it names a core (for example Flycast or Dolphin), build and install that core too. The main app build does not include it, and OpenEmu keeps using your old installed core until you replace it. Do this after Step 2 and before Step 4. Change the core name on the first line.

```bash
CORE=REPLACE_WITH_CORE_NAME   # CHANGE THIS, for example CORE=Flycast
./Scripts/verify.sh --core $CORE
./Scripts/verify-core-installed.sh $CORE
```

The last command must print `OK`. If it doesn't, your result isn't valid yet. Then run Step 4 to launch.

Never copy a core into place by hand with `cp -R`. macOS merges the folders instead of replacing them, and you end up testing the old code.

### Using an AI assistant to do this for you

If you'd rather not run the commands yourself, you can have an AI coding assistant (Claude Code, Cursor, Codex, or similar) do it from inside the cloned repo. This prompt works well:

```text
I want to test pull request number REPLACE_WITH_PR_NUMBER of OpenEmu-Silicon on my Mac before it is merged.
Read AGENTS.md and .github/CONTRIBUTING.md in this repo first.

Then:
1. Make sure the credential stub files exist (see CONTRIBUTING.md).
2. Check out the PR with gh, build it with ./Scripts/verify.sh, and launch it with
   ./Scripts/launch-debug.sh. If the PR changes a core, build and install that core
   and confirm ./Scripts/verify-core-installed.sh prints OK.
3. Read the PR description and give me a short, numbered list of exact steps to
   try in the app, in plain language.
4. After I tell you what happened, help me write a test report.

Creating the credential stub files and building are fine. Do not push, comment on the
PR, or edit any tracked files in the repo.
```

You still do the actual clicking and playing. The assistant gets the right build running and helps you describe what you saw.

### What to report

Comment on the PR (or the linked issue) with:

- **PR number and commit:** the output of `git rev-parse --short HEAD`
- **Your Mac:** macOS version and chip (for example "macOS 26.1, M2")
- **What you did:** the steps, in order
- **What you expected, and what happened:** "works" and "still broken" are both useful results
- **Evidence:** a screenshot or short screen recording. For crashes, attach the newest file from `~/Library/Logs/DiagnosticReports` that starts with `OpenEmu`
- **Build output:** only if the build or launch failed

Say so if you couldn't fully test something. "I couldn't try this with a second drive" is a useful answer.

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

AI tools (Claude, Cursor, Copilot) are used in the development of this project. Contributions using AI assistance are welcome. However, AI-generated code introduces specific risks: subtle regressions, incorrect memory handling, and plausible-looking but wrong emulation behavior that passes a surface review.

**The policy:**

1. **Disclose AI use in your PR description.** "Drafted with Claude Code" or "used Cursor for scaffolding" is sufficient, not a penalty.
2. **You must be able to explain every line on request.** If a reviewer asks "why does this work?" and you don't know, the PR will be closed. You are responsible for the code you submit.
3. **AI-only PRs with no issue link will be closed.** Open or comment on an issue first to agree the fix is worth pursuing and discuss approach.
4. **Low-effort AI PRs (vague description, no testing, no issue link) will be closed without review.** This is a capacity constraint, not a judgment.

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

Engage with a few issues first (ask clarifying questions, look for duplicates) then ask the maintainer for triage permissions.

### Compatibility Testing

The compatibility list lives in the [project wiki](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki). To contribute:
1. Test a game on the latest release build
2. Note: core name, macOS version, M-chip generation, and what you observed
3. Submit a PR against the wiki or open a Discussion with your findings

### RetroAchievements Testing

See [docs/retro-achievements/retroachievements-community-guide.md](../docs/retro-achievements/retroachievements-community-guide.md) for how to test achievement behavior per-core and how to file upstream RA tickets.

---

## Recognition

Every contributor (code or otherwise) is named in release notes and Progress Reports. If you've contributed and weren't credited, open an issue and we'll fix it.

---

## Code of Conduct

This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Be constructive, be patient, be kind to people doing this work for free.

---

*Questions? Ask in the [Discord](https://discord.gg/HvWfVkMUK) or open a [Discussion](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/discussions).*
