Draft a monthly Progress Report and companion release notes for OpenEmu-Silicon.

## Usage

Run `/progress-report` at any point to generate a draft. Optionally specify a date range:
- `/progress-report` — drafts for the past 30 days
- `/progress-report 2026-04-01 2026-04-30` — drafts for April 2026

## Steps

### 1. Determine the date range

If the user specified dates, use them. Otherwise, default to the past 30 days:

```bash
SINCE=$(date -v-30d +%Y-%m-%d)
UNTIL=$(date +%Y-%m-%d)
echo "Date range: $SINCE to $UNTIL"
```

### 2. Pull merged PRs with contributors

```bash
gh pr list \
  --repo OpenEmu-Silicon/OpenEmu-Silicon \
  --state merged \
  --search "merged:>$SINCE" \
  --limit 50 \
  --json number,title,author,mergedAt,labels,body \
  | python3 -c "
import json, sys
prs = json.load(sys.stdin)
for pr in sorted(prs, key=lambda x: x['mergedAt']):
    labels = [l['name'] for l in pr['labels']]
    author = pr['author']['login']
    print(f\"#{pr['number']} [{author}] {pr['title']}\")
    print(f\"  Labels: {', '.join(labels) if labels else 'none'}\")
    print()
"
```

### 3. Pull recently closed issues

```bash
gh issue list \
  --repo OpenEmu-Silicon/OpenEmu-Silicon \
  --state closed \
  --limit 30 \
  --json number,title,closedAt,labels \
  | python3 -c "
import json, sys
from datetime import datetime, timezone
issues = json.load(sys.stdin)
since = '$SINCE'
for issue in issues:
    if issue['closedAt'] and issue['closedAt'][:10] >= since:
        labels = [l['name'] for l in issue['labels']]
        print(f\"#{issue['number']} {issue['title']}\")
        print(f\"  Labels: {', '.join(labels) if labels else 'none'}\")
        print()
"
```

### 4. Pull core submodule changes (version bumps)

```bash
git log \
  --since="$SINCE" \
  --oneline \
  --all \
  -- '*.gitmodules' \
  | head -20

# Also check for submodule commits in merged PRs
git log \
  --since="$SINCE" \
  --oneline \
  --merges \
  | grep -i "core\|submodule\|bump\|update" \
  | head -20
```

### 5. Identify first-time contributors

Cross-reference PR authors against the full contributor list to flag first-timers:

```bash
gh api \
  repos/OpenEmu-Silicon/OpenEmu-Silicon/contributors \
  --paginate \
  --jq '.[].login' \
  2>/dev/null | sort > /tmp/all_contributors.txt

# PR authors from step 2 — check which are new
```

### 6. Pull community engagement from issue threads

For every closed issue in the period, scan comment threads for non-@nickybmon activity. Paginate all issue comments to catch everyone:

```bash
for page in 1 2 3 4 5 6; do
  gh api "repos/OpenEmu-Silicon/OpenEmu-Silicon/issues/comments?per_page=100&page=$page&sort=created&direction=desc" \
    --jq '.[] | select(.user.login != "nickybmon") | "Issue \(.issue_url | split("/") | last) [\(.user.login)]: \(.body[:200])"' 2>/dev/null
done
```

For anyone with substantive activity (crash logs, repro steps, multi-comment threads, screen recordings, testing across builds), read their full thread before writing about them. The story of how a bug got fixed is usually more interesting than the fix itself.

```bash
# Pull current help wanted issues for the "What's Next" section
gh issue list \
  --repo OpenEmu-Silicon/OpenEmu-Silicon \
  --state open \
  --label "help wanted" \
  --limit 5 \
  --json number,title \
  --jq '.[] | "#\(.number) \(.title)"'
```

### 7. Draft the Progress Report

**Voice and tone — this is the most important instruction in this skill.**

Nick is not a developer by trade. He's learning as he goes. The Progress Report should read like something he actually wrote — casual, personal, story-first. Not a formatted changelog. Not a technical release notes page with extra sections. Something you'd want to read.

Rules:
- Open like a person talking to their community, not like a product announcement. "Hey everyone! 👋" and one or two sentences on the theme of the month. No lengthy intro about what the project is.
- **Tell the story of bugs, don't just list them.** The PSP saga — 16 comments, multiple failed theories, a crash report that finally cracked it — is more interesting than "Fixed PPSSPP JIT crash." Find the story and tell it briefly.
- **No em dashes (—).** Nick's preference. Rewrite any sentence that would use one. Use a period, a colon, or restructure the sentence.
- **No PR numbers in the body text.** The Progress Report is not a changelog. Save numbers for the release notes.
- **Contributors section uses bullet points, not paragraphs.** One bullet per person. Say what specifically they did and why it mattered. "Thanks to @X for testing" is not enough. "@X went through 16 comments and never got frustrated" is right.
- **"The stuff that was quietly annoying people" uses bullet points.** Fixes that matter but don't need their own section live here as a tight list.
- Skip "What's coming" unless there's something genuinely interesting to say. Don't pad it.
- Skip the "what this is" intro section. Nick's audience knows the project.
- End short and personally. "Thanks for using this. It's been fun." Not corporate, not AI-sounding.
- Emoji are fine where Nick would naturally use them (opener, section headers).

Structure (loose — adjust to what the data actually supports):
- Opening: "Hey everyone! 👋" + one or two sentences on the month's theme
- Major features as named sections with their own stories
- "The stuff that was quietly annoying people" — bullet list of fixes
- "People who made this better 🙇‍♂️" — bullet list, one per contributor
- "Come get involved" — links to good first issue / help wanted
- Short personal sign-off

### 8. Draft the companion Release Notes

The release notes are distinct from the Progress Report — shorter, more structured, and linked to the Discussion for the full story. Don't duplicate the Progress Report's narrative in the release notes.

```
v[VERSION] — [ONE-LINE SUMMARY]

[ONE SHORT PARAGRAPH — what's in this release, why it matters]

## What's New
[BULLET LIST — features only]

## Bug Fixes
[BULLET LIST with PR numbers]

## Core Updates
[brief summary]

## Community
[One sentence naming everyone who contributed bug reports, testing, or review]

## Known Issues
[None / list with issue links]

## Installation
Download the `.dmg` from the assets below. Requires macOS 12.0 or later on Apple Silicon.

Full details in the [Month Year Progress Report](LINK_PLACEHOLDER — fill in after publishing the Discussion).
```

### 9. Output

Present both drafts in sequence:
1. **Progress Report** — the full narrative draft, ready to paste into GitHub Discussions → Announcements
2. **Release Notes** — the short companion, with `LINK_PLACEHOLDER` for the Discussion URL

Remind the user to fill in `LINK_PLACEHOLDER` in the release notes after publishing the Discussion. If the release is already live, offer to update it directly via `gh release edit`.

## Notes

- Always credit the contributor handle (not just the PR number) — recognition is the point.
- Paginate issue comments fully — the default limit misses people.
- If the RA section has nothing to report, fold it into the relevant feature section rather than leaving an empty heading.
- The release notes link to the Discussion — fill in that link after the Discussion is published.
- The Progress Report is NOT a technical document. If it sounds like AI wrote it, rewrite it.
