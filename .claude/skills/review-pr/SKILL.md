---
name: review-pr
description: Review a contributor's pull request thoroughly, walk the user through it in plain language, and after approval post the inline comments and submit the review as "request changes" with a short note tagging the author. Use when asked to review a PR, draft review comments, or follow up on a PR that has had review rounds already. Usage: /review-pr <PR_NUMBER>
---

# Review PR

Review a contributor's pull request. First give the user a plain-language briefing and the drafted inline comments to read. Only after the user approves, post the inline comments and submit the review as **request changes** with a short, basic note tagging the author.

## Setup

Find the repo with `gh repo view --json nameWithOwner -q .nameWithOwner` (or use the repo the user names). Use it as `<owner>/<repo>` below.

## What this does

1. Fetches the PR diff and reads all changed files in full.
2. Sorts issues into three severity levels:
   - **Critical / bugs**: broken or incorrect behavior.
   - **Concerns**: design choices, edge cases, or patterns to address before merge.
   - **Minor**: small suggestions, style, non-blocking improvements.
3. Drafts inline comments in a warm, direct tone. Acknowledge the intent of the work, then be clear and specific about the issue.
4. Shows the user the briefing (see below) and the drafted inline comments. Waits for approval.
5. On approval, posts the inline comments and submits the review as **request changes** in one call, with the short author note as the review body.
6. The user adds any longer summary comment themselves, in GitHub.

## The briefing (shown in chat before anything is posted)

Write it for someone who has not read the diff and does not want jargon. Short sentences, everyday words. If a technical term is unavoidable, explain it in a few words.

- **What this PR does**: two or three sentences on what changes for a user of the product.
- **Blockers**: things that must change before merge. Say what goes wrong and who it affects. Write "none" if there are none.
- **Risks**: things that probably work but could bite later, or were not tested (for example, no real-hardware test).
- **Worth fixing, not blocking**: smaller notes and suggestions.
- **What's good**: anything well executed or a real improvement, said specifically. Skip this section only if there is truly nothing.
- **Not verified**: what you did not build, run, or test, so the user knows how much weight the review carries.

Then list the drafted inline comments, each with file, line, severity, and the exact text that would be posted.

## Tone for inline comments

- Lead with what the contributor was trying to do or what works.
- Then state the concern directly. Do not soften the technical facts.
- For bugs, name what will go wrong and suggest the fix.
- For concerns, explain the risk and offer a concrete alternative.
- For minor items, keep them brief and mark them non-blocking.
- Write like a thoughtful collaborator, not a checklist.

## Process

1. `gh pr view <PR_NUMBER> --repo <owner>/<repo>` for metadata, author login, and the head SHA.
2. `gh pr diff <PR_NUMBER> --repo <owner>/<repo>` for the full diff.
3. Fetch the PR's version of each changed file through the GitHub API to get exact line numbers.
4. Read each file fully for context, not just the changed lines.
5. Check for an existing pending review from you on this PR. If one exists, tell the user before continuing.
6. Show the briefing and the drafted inline comments. Wait for approval. Apply any edits the user asks for and show the changed comments again if the change is more than a wording tweak.
7. Post the inline comments and submit in one call, with `event` set to `REQUEST_CHANGES` and a `commit_id` of the head SHA you reviewed:
   `gh api repos/<owner>/<repo>/pulls/<PR_NUMBER>/reviews --method POST --input <json_file>`
   The review body is only this, with the author's login filled in:
   `@<author> thanks for the PR. I've reviewed it and left inline comments. It's ready for you to make changes whenever you get a chance.`
   Do not add a longer summary. The user writes that themselves if they want one.
8. Confirm the posted comment count matches the draft and that the review state is `CHANGES_REQUESTED`. Give the user the link to the review.

If the review has no blockers or concerns (only minor notes or praise), tell the user and ask whether to submit as `COMMENT` or `APPROVE` instead of request changes. Never approve unless the user says so.

## What NOT to do

- Do not post or submit anything before the user approves the drafts.
- Do not write a long summary in the review body. Keep it to the short author note.
- Do not use technical jargon in the briefing.
- Do not blur severity levels. Be clear what is a bug and what is a suggestion.
- Do not claim you tested something you only read.

## After one or two unresolved review rounds

If a PR has been through one or two comment cycles and still has issues, recommend fixup-and-squash-merge instead of another comment round. Ask the user before doing any of it.

1. Check `maintainer_can_modify`: `gh api repos/<owner>/<repo>/pulls/<N> --jq '.maintainer_can_modify'`
2. Add the contributor's fork as a local remote and check out their branch.
3. Push fixup commits to their branch that resolve the issues.
4. Squash merge, preferably through the GitHub web UI. It injects the correct `Co-authored-by` trailers from the PR history, so the contributor gets credit. The CLI needs the email supplied by hand:
   `gh pr merge <N> --repo <owner>/<repo> --squash --subject "..." --body "Co-authored-by: <name> <<id>+<username>@users.noreply.github.com>"`
5. Comment on the closed PR. Explain each change briefly and thank the contributor, so they see what good looks like without feeling blocked or lectured.

Only merge when the user asks for the merge in that same request.
