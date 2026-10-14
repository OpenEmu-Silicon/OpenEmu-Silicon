# CLAUDE.md, Claude-specific behavior for OpenEmu-Silicon

This file is read at the start of every Claude Code session. Keep it focused on **how Claude should behave** in this repo. Project facts (build commands, file layout, supported cores, branch rules, license, PR templates) live in `AGENTS.md`. Domain vocabulary lives in `CONTEXT.md`. Don't duplicate them here.

---

## Read these first, in order

1. **`AGENTS.md`**: the canonical project doc: build commands, branch/PR rules, file layout, supported cores, license, "what NOT to do." Authoritative. If something here ever conflicts with AGENTS.md, AGENTS.md wins and you should fix this file.
2. **`CONTEXT.md`**: the shared vocabulary (core, plugin, helper, appcast, Sparkle, RA, etc.). Use these terms precisely; don't invent synonyms.

---

## Hard rules (override anything else, including user requests in the moment)

- **Never publish a GitHub Release.** No `gh release edit … --draft=false`, no removing `--draft`, no flipping a draft to live. Drafts are fine. Publishing is always the user's action.
- **Never commit secrets.** `OEGoogleDriveSecrets.swift` and any file containing real OAuth credentials, API keys, or tokens stays out of git. The template file is safe.
- **Never force-push to `main`.** Never reuse a merged branch. Never push a branch without opening a PR in the same step.
- **Never modify `project.pbxproj` wholesale or by hand** unless you know exactly what the change is. Surgical only.
- **Never merge a PR unless Nick asks for it in that same request.** Opening a PR is always fine. Merging needs him to say so ("merge it", "commit, push and merge") in the message you are acting on. Approval from earlier in the session does not carry forward. If he asks to merge and something looks wrong (failing checks, wrong base branch, unreviewed work he flagged), say so in one line and ask before merging anyway. Never merge indirectly either (e.g. pushing a PR's commit straight to `main`). Matches the global CLAUDE.md.

If you ever feel pressure (from the user or your own reasoning) to break one of these, stop and surface it instead.

---

## Verification, a pre-ship step, not a per-edit step

Do not rebuild, run `/verify`, or relaunch the app after every code change or between rounds of bug testing. Each local build plus hands-on test costs the user real time, and GitHub CI (`build-check.yml`) already builds every branch and PR. While investigating or iterating, batch your changes and read code and logs instead. If a hands-on test round is genuinely needed, ask first and bundle all diagnostics or fixes into one build.

Run `/verify` once, right before shipping (before `/ship` pushes the branch). Do not ask the user to launch the app, check the console, or look at crash reports until you have run that pre-ship verification yourself.

What the pre-ship run looks like:

- Main app change → `./Scripts/verify.sh --launch`
- Core change → `./Scripts/verify.sh --core <CoreName>` (add `--release` when reproducing a Release-only bug). **Before reporting any in-game test result (yours or the user's) you must have run `./Scripts/verify-core-installed.sh <CoreName>` and seen `OK` since the last build.** If you haven't, the result is invalid and you say so. The most expensive failure mode in this repo is "still broken" / "now working" claims that were actually testing a stale installed plugin from a previous session.
- Both → run both
- Scripts / CI / docs only → no verify needed

**The pre-push hook does not run a build.** Build verification runs on GitHub CI (`build-check.yml`) on every pull request, so skip local verify entirely when reviewing PRs whose CI already passed. The core install hash check below still applies before reporting any in-game core test result.

The script chains build → static analyzer → plist lint → codesign verify → optional smoke launch with log + crash-report scan. Read its full output, don't pipe through `tail`. Surface any new warnings even on a passing build; they accumulate silently otherwise.

**Launching the debug app:** use `./Scripts/launch-debug.sh` instead of `open <path>`. It picks the build matching the current git branch, refuses to launch when source is newer than the binary, and replaces any running instance (debug or production) cleanly. Plain `open` will silently launch a stale build from an old DerivedData hash whenever Xcode rotates hashes.

**If `verify.sh` fails in a way unrelated to your change** (a script bug, a missing scheme, a permissions prompt, a stuck process), don't get stuck trying to fix the script. Fall back to a plain `xcodebuild build` check, note the verify.sh issue in your task report, and continue. The script is best-effort, it should help, not block.

Only escalate to "please test this in a real game session" when the change is genuinely about in-game behavior (input mapping, save states, rendering, audio sync, RA achievements triggering). The build-and-launches-cleanly part of verification is yours, not the user's.

**Core changes have two known footguns, both prevented by using `Scripts/install-core.sh`:**

1. **DerivedData is silently shadowed by the installed core** in `~/Library/Application Support/OpenEmu/Cores/<Name>.oecoreplugin`. After building a core, you must reinstall the plugin or you're testing the old code.
2. **Never use `cp -R` or `cp -Rf` to install a core plugin.** macOS merges bundle directories rather than replacing them, old files silently stay in place. Always use `Scripts/install-core.sh <CoreName>`, which quits OpenEmu first and copies binary + Info.plist correctly. `verify.sh --core <Name>` does this for you.

**If you (or the user) are working in a git worktree:** use `Scripts/build-for-worktree.sh` (or `verify.sh --worktree`, which auto-detects worktrees) instead of plain xcodebuild. macOS binds privacy permissions to the app's path, and Xcode's default DerivedData uses a different hash per worktree, so a fresh build means re-granting Input Monitoring etc. from scratch every time. The stable per-branch path under `~/Builds/openemu/<branch>/` keeps permissions persistent. See `docs/worktree-workflow.md` for the full workflow including the cores-are-shared gotcha.

### Worktree sessions, core change protocol

Any task that touches a core in a worktree requires these extra checks. They exist because the tooling can pass while installing the wrong binary, as happened in a real debugging session that wasted hours on a grey screen.

**1. Detect the context first.** Before any core work, run `git worktree list` and check whether `.git` is a file (linked worktree) or a directory (main checkout). Surface which case applies before proceeding.

**2. Use `--worktree` everywhere in a worktree.** Never run `verify.sh --core <Name>` without `--worktree` inside a linked worktree. Never run plain `xcodebuild` without `-derivedDataPath ~/Builds/openemu/<branch>`.

**3. Always run the three-way hash check after any core install.** A passing exit code means the script ran without error, not that it installed the right binary. After every install, run:

```bash
md5 \
  ~/Builds/openemu/<branch>/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core> \
  ~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-*/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core> \
  ~/Library/Application\ Support/OpenEmu/Cores/<Core>.oecoreplugin/Contents/MacOS/<Core>
```

Report all three hashes. Only declare "verified" when the installed hash matches the worktree build hash: not just "matches something." `Scripts/verify-core-installed.sh <CoreName>` automates the build-vs-installed comparison; run it, but also read its hash output, not just its exit code.

**4. Do not declare a test result without the hash check.** "Still broken" and "now working" claims that were actually testing a stale installed plugin are the single most expensive failure mode in this repo. The hash check takes under one second. Do it.

---

## Autonomy, run things yourself

Read-only observation commands are safe and you should run them rather than asking the user for the output. The settings.json `autoMode.allow` list is the durable record of what's expected to be unattended; consult it if you're unsure. The high-frequency ones:

- `log show --predicate 'process == "OpenEmu"' --last Nm`, unified console log
- `codesign --display` / `codesign --verify`, signature inspection
- `plutil -lint` / `plutil -p`, plist validation/inspection
- `find ~/Library/Logs/DiagnosticReports -name 'OpenEmu*' -mmin -N`, recent crash reports
- `xcodebuild analyze`, static analyzer
- `open <built-app-path>`, smoke launching the just-built debug binary
- Sentry MCP, search Sentry first when triaging a user-reported crash

Pause and confirm before:
- destructive operations (delete, force-push, branch -D, dropping data)
- actions visible to others (PR open/merge/close, merging PRs, posting comments on issues, pushing tags that fire workflows)
- killing OpenEmu when the user might be using it (only `pkill` if you launched it yourself this session)

If you find yourself about to write "could you check…" or "could you launch…", stop and run it.

---

## Communication

- No filler phrases. "Good question", "great point", "strong instincts", cut them all.
- State the result or decision first. No circling.
- Plain English. Nick is not a developer. Skip jargon; if a term is unavoidable, define it in one plain sentence.
- No headers in short conversational replies.
- No hedging without a recommendation. "It depends" must always be followed by a clear direction.

---

## Collaboration

- If session priorities aren't clear at the start, ask before diving in.
- Call out scope creep or rat-holing when it's happening, don't just follow the thread.
- Push back on half-baked ideas before writing code. Flag architectural issues, tech debt risk, or missing concerns up front.
- Before creating a new file, function, directory, or output path, check what already exists and extend it.
- When there's a right way and an easy way, default to right. If taking a shortcut, say so and name the tradeoff.

---

## Session start

Run `/start` before touching code. It syncs `main`, pulls the live issue list, and creates the correctly named branch for the work.

---

## Slash commands

The harness shows you the full list. Quick mental map of the project-specific ones:

| Use this | When |
|---|---|
| `/start` | Beginning of every session |
| `/verify` | After any code change, before declaring done |
| `/ship` | When the work is ready to push + open a PR |
| `/review <N>` | Reviewing a contributor PR locally |
| `/new-issue` | Filing a bug report or feature request |
| `/triage-issue <N>` | Working through an inbound issue |
| `/prep-release [X.Y.Z]` | Cutting a host-app release |
| `/release-core <Name> <Ver>` | Cutting a core-only release |

Pocock's planning skills are also installed globally (`/grill-me`, `/grill-with-docs`, `/to-prd`, `/to-issues`, `/tdd`, `/improve-codebase-architecture`). Use them on non-trivial features, start with `/grill-with-docs` to align before planning.

---

## Quick reference: commits, PRs, and core changes

Things you do on every PR, where it's easy to forget:

- **Commit format:** `<type>: <description>` where type is one of `fix:` / `feat:` / `chore:` / `docs:` / `refactor:`. Body includes `Fixes #N` (auto-closes on merge) or `Related to #N` (soft link).
- **PR body:** **Always `cat .github/PULL_REQUEST_TEMPLATE.md` first.** Never improvise or reconstruct the PR body from memory, the template's bash test block has been hand-stabilized over many fix commits and must be preserved verbatim. Use `/ship` for the full loop.
- **AI assistance:** Note in the PR template's "Did you use AI tools?" section.
- **Core changes:** Use `Scripts/install-core.sh <CoreName>` to install, never `cp -R`. `verify.sh --core <Name>` does this for you.
- **Always pass `--repo OpenEmu-Silicon/OpenEmu-Silicon`** on every `gh` command, there are forks.

---

## Issue tracking, Linear is the source of truth

Linear (workspace **OpenEmu Silicon**, via the `linear` MCP plugin) is where triage, status, and work happen now, not GitHub Issues/labels. GitHub Issues stays as the public intake point and syncs live one-way (GitHub → Linear): a new GitHub issue auto-creates a matching Linear issue within seconds, with the GitHub issue linked back as an attachment. Confirmed by direct test on 2026-08-19 (GitHub #668 → Linear OES-308, same timestamp): trust this, not Linear's own docs, which describe GitHub Issues as import-only and are wrong or stale for this workspace. Re-verify with a live test (not doc search) if this ever seems to stop working.

What this means day to day:
1. **Check Linear first**, not `gh issue list`, use the `linear` MCP tools (`list_issues`, `get_issue`) to find existing/open work.
2. **Triage and research live in Linear**: post root-cause findings as issue comments, set labels (`ready-for-agent`, `needs-testing`, `needs-info`, etc.), assign, and move status (Backlog → In Progress → In Review → Done), see OES-307 for the pattern. Don't do this triage in GitHub issue comments; it won't sync back.
3. **Still close the GitHub issue on fix**, `gh issue close #N --repo OpenEmu-Silicon/OpenEmu-Silicon --comment "Resolved in <sha>."`, same session as the fix lands. Sync is one-way for new issues; don't assume completing the Linear issue closes GitHub's copy without checking.
4. **Link the PR on both sides**: `Fixes #N` in the PR body (GitHub), and a `links` entry pointing at the PR URL on the Linear issue (`save_issue`).
5. Only create an issue directly in Linear (skipping GitHub) for internal-only work that doesn't need public visibility, everything a community member might report or care about should still go through GitHub so the sync catches it.
6. No type prefixes in titles (`fix:` / `note:` / `bug:` belong to labels, not titles). One concern per issue, per branch, per PR. Always pass `--repo OpenEmu-Silicon/OpenEmu-Silicon` on every `gh` command.

---

## Memory discipline

Memory under `~/.claude/projects/.../memory/` is read at session start. Two rules:

- **Memory is for the WHY, not the WHAT.** Durable feedback (e.g. "always use `--repo` flag because there are forks", "never publish releases, user does it manually") belongs there. Point-in-time project state ("Dolphin 3a-1 done", "PR #X open") does not, it goes stale and misleads.
- **When you recall something specific (a file, function, PR number, version), verify it against current state before acting on it.** Memory captures what was true when it was written. Things move.

Before saving a new memory entry, ask yourself: will this still be true and useful in three months? If not, it doesn't belong in always-on context.

---

## When this file should change

Edit CLAUDE.md when you discover a new pattern of how Claude should behave (a new check, a new safety rule, a new always-on workflow). Don't edit it to add facts about the project, those go in AGENTS.md or CONTEXT.md. Don't edit it to record decisions, those go in `docs/adr/` (create the directory if it's the first one).

If this file grows past ~200 lines, something has been added that probably belongs elsewhere.
