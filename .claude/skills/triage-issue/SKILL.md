---
name: triage-issue
description: Triage a GitHub bug report or feature request on behalf of the repo owner. Checks for duplicates, checks the report for missing information, drafts a request for details, and applies labels. Usage: /triage-issue <N>
---

# Triage Issue

Triage issue `<N>` on behalf of the repo owner.

## Setup

Find the repo with `gh repo view --json nameWithOwner -q .nameWithOwner` (or use the repo the user names). Use it as `<owner>/<repo>` below. Check `CONTRIBUTING.md` and the issue templates in `.github/ISSUE_TEMPLATE/` for the information this project expects in a report.

Show the user every comment, close, and label change before you post it. Wait for approval.

## Steps

### 1. Read the issue

```bash
gh issue view <N> --repo <owner>/<repo>
```

Read the full body. Note the type (bug, feature request, other) and what is present or missing.

### 2. Check for duplicates

```bash
gh issue list --repo <owner>/<repo> --state open --search "<key terms>"
```

If it duplicates an existing issue, draft a comment that thanks the reporter, links the original (#X), and invites new details there. Then close the issue as a duplicate. Stop after that.

### 3. Check completeness

**Bug reports:**
- [ ] OS and version
- [ ] Hardware, if relevant
- [ ] App or project version, or commit hash
- [ ] What is affected (feature, game, page, component) or "everything"
- [ ] Steps to reproduce
- [ ] Expected behavior and actual behavior
- [ ] Crash log or error output (required for a crash or error message)
- [ ] Screenshot or recording (required for visual bugs)

**Feature requests:**
- [ ] Clear description of the wanted behavior
- [ ] The problem it solves
- [ ] Prior art or references

### 4. Decide the outcome

**A. Enough information.** Go to step 5.

**B. Missing information.** Draft a comment that asks only for what is missing. Do not ask for everything when one or two items are missing. Always ask for a crash log when a crash has none. Always ask for a screenshot when a visual bug has none.

```
Thanks for the report!

To help us investigate, could you share a bit more:

- **<missing item>**: <where to find it or how to get it>
- **<missing item>**: <where to find it or how to get it>

Thanks again for taking the time to report this!
```

Post with: `gh issue comment <N> --repo <owner>/<repo> --body-file <file>`

### 5. Labels

List what exists with `gh label list --repo <owner>/<repo>`. Use only labels that exist. Add what is missing, for example a type label (bug, enhancement) and a needs-info label if you asked for details:

```bash
gh issue edit <N> --repo <owner>/<repo> --add-label "<label>"
```

### 6. Report back

Summarize:
- Outcome: sufficient, needs more info, or duplicate
- Comment posted (show the text)
- Labels applied
- Next step: ready to investigate, or waiting on the reporter
