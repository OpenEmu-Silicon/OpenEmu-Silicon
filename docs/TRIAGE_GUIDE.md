# Triage Guide — OpenEmu-Silicon

Maintainer-facing reference for issue and PR triage, contributor identification, and escalation patterns. Not public-facing, but can be.

---

## Triage Philosophy

The goal of triage is not to close issues — it's to make the project legible to contributors. A well-triaged backlog tells someone new exactly where to start, what's in scope, and what actually needs help.

Three principles:

1. **Every issue deserves a response, not just a close.** A one-line "thanks, labeled and in the backlog" is enough to make a reporter feel heard and far more likely to contribute again.
2. **The label is the invitation.** `good first issue` only works if the issue has enough context to act on without asking questions.
3. **Triage is not commitment.** Labeling something `enhancement` doesn't mean you're building it. That transparency is itself valuable.

---

## Label System

### Status Labels

| Label | Meaning |
|-------|---------|
| `needs-info` | Missing OS version, chip, game title, core, or other required context |
| `confirmed` | Reproduced by maintainer or trusted tester |
| `in-progress` | Actively being worked on |
| `needs-testing` | Fix implemented; needs verification before closing |
| `blocked` | Waiting on upstream (a core repo, rcheevos, Apple) |
| `known-issue` | Tracked, not yet fixable — see issue for status |

### Type Labels

| Label | Meaning |
|-------|---------|
| `bug` | Confirmed regression or incorrect behavior |
| `enhancement` | New feature or improvement request |
| `documentation` | Wiki, README, or inline comment work |
| `chore` | Cleanup, tooling, non-functional changes |
| `shaders` | Metal shaders / rendering pipeline |
| `cloud-sync` | Cloud Sync backup folder (iCloud Drive, Google Drive for desktop) |
| `arm64` | Apple Silicon–specific behavior (not present on Intel OpenEmu) |

### Core Scope Labels

| Label | Cores |
|-------|-------|
| `core: NES` | Nestopia, FCEU |
| `core: SNES` | BSNES, SNES9x |
| `core: Sega` | GenesisPlus, CrabEmu (Genesis, SMS, Game Gear, SG-1000, Sega CD) |
| `core: N64` | Mupen64Plus |
| `core: Atari` | Stella (2600), ProSystem (7800), Atari800 (5200/8-bit) |
| `core: PS2` | PCSX2 |
| `core: C64` | VirtualC64 / VICE |
| `core: other` | mGBA (GBA/GB/GBC), Gambatte (GB/GBC), Mednafen (PSX/PCE/Lynx/NGP), Flycast (Dreamcast), Dolphin (GC/Wii), PPSSPP (PSP), long-tail cores |
| `core: arcade` | Arcade cores |

### Priority / Workflow Labels

| Label | Meaning |
|-------|---------|
| `good first issue` | Well-scoped, relevant file identified, approachable without deep codebase knowledge |
| `help wanted` | Maintainer wants a contributor but can't prioritize it now |
| `critical` | App-level blocker — needs a patch release |
| `checklist` | Tracking checklist for a release or major effort |
| `ready-for-agent` | Fully specified, ready for an AFK agent to implement |
| `retro-achievements` | RetroAchievements integration work |

### Resolution Labels

| Label | Meaning |
|-------|---------|
| `wontfix` | Out of scope, upstream issue, or by design |
| `by-design` | This is the expected behavior |
| `duplicate` | Link to the canonical issue in the close comment |
| `upstream` | Filed in the appropriate core or dependency repo; link included |
| `invalid` | Not a valid bug report or feature request |

---

## Issue Triage Workflow

### Step 1: First response (target: within 48 hours)

Even if you can't investigate yet, acknowledge the issue. Boilerplate is fine:

> "Thanks for the report. I've labeled this and will take a closer look. If you can provide [any missing info], that will help."

Apply at minimum one type label and one scope label. If it's clearly `needs-info`, say so explicitly.

### Step 2: Reproduce or escalate (target: within 1 week for `critical`, 2 weeks otherwise)

- **Can reproduce:** Add `confirmed`, remove `needs-info`, add scope label, add `help wanted` if you want a contributor to take it.
- **Cannot reproduce:** Add `needs-info`, ask for: macOS version, M-chip generation, game title and region, app version or commit, whether RA is enabled.
- **Clearly upstream:** Add `upstream`, link to the relevant core repo issue, close with an explanation. Closing upstream issues promptly keeps the backlog accurate.

### Step 3: Tag for contributors

For any `confirmed` bug or `enhancement` you're not addressing immediately:

- If approachable without deep knowledge → add `good first issue` **and** edit the issue body to include:
  - The relevant file and function name
  - Your preferred approach or known constraints
  - Estimated complexity (small / medium / large)
- If it needs specific expertise → add `help wanted` and tag anyone who has touched that area in a previous PR.

---

## PR Triage Workflow

### On open (within 48 hours)

1. Check that it links to an issue. If not, ask for one (unless it's a trivial fix — typo, docs update).
2. Check the PR description: does it explain what, why, and how it was tested? If not, ask.
3. Check AI disclosure. If AI tools were used and not disclosed, ask before reviewing.
4. Auto-labeler will have fired; verify labels are accurate.

### Reviewing

- **First-time contributors:** Be explicit about what's good and what needs changing. First-time experience determines whether they come back.
- **AI-assisted PRs:** Review with extra attention to correctness, not just style. Ask "does this actually fix the issue, or does it look like it does?"
- **Core updates (submodule bumps):** Check the pinned commit and verify at least one known-working game on the affected core before merging.

### After merging

- Thank the contributor in the merge comment.
- Add their handle to your running list for the next Progress Report.
- Close the related issue with a reference to the merge commit.

### Closing AI-slop PRs gracefully

> "Thanks for the contribution. This PR appears to be AI-generated without an associated issue or evidence of testing on Apple Silicon. Our [CONTRIBUTING.md](CONTRIBUTING.md) outlines the AI policy — we welcome AI-assisted contributions, but the contributor needs to be able to explain and stand behind the code. If you'd like to revisit this with an issue link and testing notes, I'd be happy to take another look."

---

## Identifying and Tapping Contributors

### Where to look

- **Detailed issue reporters** — people who consistently provide good repro steps and follow-up. These are your future triagers.
- **Wiki editors** — people who fix documentation errors. These are your future docs maintainers.
- **People who answer other users' questions** in Discussions. These are your future community leads.
- **People who submit AI-assisted PRs that are actually correct.** They've already cleared the hardest barrier.

### How to ask (specific beats general)

Don't post a generic "we need contributors" message. Be specific:

> "Hey @handle — you've filed three really detailed issues on the mGBA core and your repro steps are excellent. I'd like to offer you triage permissions on GitHub so you can help label and manage incoming issues. Would you be interested?"

For a potential code contributor:

> "Your fix for [issue] was solid. I've got a `good first issue` on the Gambatte core that's right in the same area — [link]. Would you want to take a shot at it?"

The research on this is consistent: **specific, personal asks convert far better than open calls.**

### Core-specific ownership

The model that works best for retention: give people ownership of a specific core rather than the project broadly. When someone demonstrates deep knowledge of a system, ask:

> "Would you want to be the point person for [system] issues? I'd give you triage access and we'd coordinate on PRs that touch that core."

This is how RPCS3 grew its team.

---

## RetroAchievements-Specific Triage

RA issues require different handling. See [retroachievements-community-guide.md](retro-achievements/retroachievements-community-guide.md) for full context. Short version:

- **Achievement not triggering / triggering incorrectly:** Apply `retro-achievements` + the relevant core label. Ask: is this core in the supported list? If not, link to the [RA rollout issue (#258)](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/258). If yes, ask for game title, achievement name, and whether it reproduces with RA disabled.
- **RA vs. emulator bug:** Many RA bugs belong upstream in the RetroAchievements issue tracker or in rcheevos, not here. When the achievement set itself is wrong (wrong memory address, wrong trigger condition), file an RA-side ticket and link it from the issue here.
- **New core RA support requests:** Label `enhancement` + `retro-achievements` + the relevant core label. Check [issue #258](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/258) first — it may already be tracked there. These are `help wanted` candidates since RA integration per-core is largely self-contained once you've read the implementation guide.

---

## Stale Bot Configuration

The stale workflow runs daily and applies a 60-day/14-day lifecycle to issues awaiting reporter response. Key exempt labels (never staled):

```
pinned, security, in-progress, help wanted, good first issue,
confirmed, blocked, critical, retro-achievements, known-issue,
checklist, ready-for-agent
```

PRs are never auto-closed.

---

## Escalation Patterns

### When a bug is clearly upstream

1. Confirm the behavior is in the upstream core repo (test with a standalone build if possible).
2. File or link to the upstream issue.
3. Close with:
   > "This appears to be an upstream issue in [core repo]. I've filed/linked [upstream issue link]. Closing here — we'll address it when the upstream fix is available."
4. Apply `upstream` label before closing.

### When a feature request is out of scope

Close with a clear explanation of why it's out of scope. Don't leave it open indefinitely — an open issue that will never be addressed is misleading to contributors.

### When issue volume spikes (expected around the RA launch)

1. Prioritize `critical` and `confirmed` bugs over everything else.
2. Use `needs-info` aggressively — if a report is missing information, ask once and let the stale bot handle it if there's no response.
3. Post a Discussion announcement letting the community know about the volume and explicitly asking for triage help — this is a recruiting moment.
4. Don't let PR review lag beyond 2 weeks without a response. Even "I've seen this, will review next week" prevents abandonment.
