# Progress Report Template — OpenEmu-Silicon

Reusable template for two related but distinct content types:

1. **Monthly Progress Report** — published as a GitHub Discussions Announcement; the primary community-facing document
2. **Release Notes** — short companion published with each GitHub Release; links to the Discussion for the full story

The philosophy in both cases: name people, be specific, make the work legible. The Dolphin Emulator Progress Reports are the gold standard — they've run for 10+ years and are explicitly credited with attracting contributors and building community.

Use `/progress-report` in a Claude Code session to draft a filled-in version from the repo's git history and PR list.

---

## Part 1: Monthly Progress Report

### When to Publish

- **Cadence:** Monthly is ideal. Bimonthly is sustainable. Less frequent than that dilutes the recognition effect.
- **Where:** GitHub Discussions → Announcements category. Pin the current report; unpin the previous one.
- **Cross-post:** After publishing on GitHub Discussions, share a link (not the full text) in community spaces — the Mac gaming subreddit, the RetroAchievements forum thread for OpenEmu-Silicon, etc.

---

### Template

**Title:** `OpenEmu-Silicon Progress Report — [MONTH YEAR]`

---

> Hello everyone — here's what's been happening with OpenEmu-Silicon over the past [month / two months].

> Open with 1–2 sentences of genuine context — what was the big theme of this period? A major bug fix, a new core, progress on RA integration, a lot of under-the-hood cleanup? Keep it conversational.

---

#### Highlights

> 3–5 bullet points, each covering one significant change. For each: what changed, why it matters to users, and who did it. If the improvement has a story (what caused the bug, what made the fix non-obvious), tell it briefly.

- **[CHANGE TITLE]** — [what changed and why it matters]. Thanks to @[HANDLE] for this one. ([#PR])

- **[CHANGE TITLE]** — [what changed]. ([#PR])

- **[CHANGE TITLE]** — [what changed]. This was a long-standing issue — [1–2 sentence backstory if interesting]. ([#PR])

---

#### Core Updates

> List any core submodule bumps this period, with the version change and a brief note on what changed upstream. RA-relevant updates should be called out explicitly.

| Core | Previous | New | Notable Changes |
|------|----------|-----|-----------------|
| [CORE] | [OLD] | [NEW] | [BRIEF NOTE] |

---

#### RetroAchievements

> Include this section whenever there is RA-relevant news — a new core gaining support, a known issue resolved, a behavior change. Skip the section entirely (don't leave it empty) in months where there's nothing RA-specific.

- [RA_UPDATE] — e.g., "Gambatte now passes the full RA GB/GBC test suite. Thanks to @[HANDLE] for detailed repro steps."

---

#### Bug Fixes

> Fixes not already covered in Highlights. Include issue number and fix author. For community contributions, add a brief note on what made the fix meaningful.

- Fixed [BUG] affecting [CORE/SYSTEM]. ([#ISSUE], [#PR]) — @[HANDLE]
- Fixed [BUG]. ([#ISSUE])

---

#### Contributors This Period

> This section is the most important part for community building. Name everyone — code and non-code alike. A first-time contributor named in a Progress Report is far more likely to contribute again than one who isn't.

**Code contributions:**
- @[HANDLE] — [what they contributed]

**Testing and QA:**
- @[HANDLE] — [what they tested, e.g., "GBA RA regression testing across 12 achievement sets"]

**Documentation and triage:**
- @[HANDLE] — [what they did, e.g., "triaged 8 incoming issues", "updated the NDS installation guide"]

**Bug reports that led to fixes:**
> For high-quality bug reports that directly enabled a fix — especially with detailed repro steps or testing across multiple builds — name the reporter here. One of the strongest retention mechanics for engaged testers.

- @[HANDLE] — filed the detailed repro for [issue description] ([#ISSUE])

> If I've missed anyone, please reply and I'll update the post.

---

#### What's Next

> 3–5 bullet points on planned work. Be honest about uncertainty — "I'm hoping to" is better than commitments you can't keep. This section signals to potential contributors where they can jump in.

- [PLANNED_WORK] — [brief context / what's blocking it]
- **Help wanted:** [SPECIFIC_THING] — if you're interested, comment below or pick up [#ISSUE].

---

#### How to Get Involved

New to the project? Here's where to start:
- [`good first issue`](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues?q=is%3Aopen+label%3A%22good+first+issue%22) — well-scoped bugs and improvements with pointers to the relevant code
- [`help wanted`](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues?q=is%3Aopen+label%3A%22help+wanted%22) — things the maintainer wants help with but can't prioritize right now
- [CONTRIBUTING.md](../.github/CONTRIBUTING.md) — how to set up a build, submit a PR, and the AI contribution policy
- [RetroAchievements Community Guide](retro-achievements/retroachievements-community-guide.md) — if you're an RA user or achievement set developer

Questions? Open a [Discussion](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/discussions).

---

*Thanks for using and supporting OpenEmu-Silicon. — @nickybmon*

---

---

## Part 2: Release Notes Format

Release notes are tied to a specific version; Progress Reports cover a time period. When a release coincides with a Progress Report, the release notes are short and link to the Discussion for the full story.

### When to Use

Every GitHub Release, including small patch releases. Consistent release notes train users to check them and contributors to expect their work to be acknowledged.

---

### Template

**Release title:** `v[VERSION] — [OPTIONAL ONE-LINE SUMMARY]`

> e.g., `v1.4.2 — GBA RetroAchievements fix + SNES audio regression`

---

[ONE PARAGRAPH SUMMARY — what's in this release, why it matters. If it's a patch release, say so directly.]

---

#### Changes

**Fixes**
- [FIX] ([#PR]) — @[HANDLE]
- [FIX] ([#PR])

**Improvements**
- [IMPROVEMENT] ([#PR]) — @[HANDLE]

**Core Updates**
- [CORE] updated to [VERSION] ([#PR])

---

#### Contributors

Thanks to everyone who contributed to this release: @[HANDLE_1] and @[HANDLE_2] for code; @[HANDLE_3] for testing and bug reports.

> For releases that follow a Progress Report: "Full details in the [Month Year Progress Report](DISCUSSION_LINK)."

---

#### Installation

Download the `.dmg` or `.zip` from the assets below. Requires macOS 12.0 or later on Apple Silicon.

For installation help, see the [Wiki](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/wiki) or open a [Discussion](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/discussions).

---

#### Known Issues

- [KNOWN_ISSUE] — tracked in [#ISSUE]
- None known at this time.

---

---

## Part 3: Pre-Publish Checklist

Use before publishing any Progress Report or release notes:

- [ ] All external PRs merged since the last report are listed with contributor handles
- [ ] First-time contributors are explicitly called out ("first contribution from @[HANDLE]!")
- [ ] Testers who filed repro steps or tested specific builds are named in the testing section
- [ ] Wiki or documentation contributors are named
- [ ] Triage contributors (if any) are named
- [ ] Anyone who filed a bug that directly led to a fix is credited under "bug reports that led to fixes"
- [ ] The `help wanted` section links to at least one open issue where a new contributor could start
- [ ] Release notes link to the Discussion progress report (if one was published for this period)
