Ship the current work. Pick the lane, then do the minimum it needs.

## 1. Pick the lane

**Straight to `main`** (no branch, no PR) for the maintainer's own:
- docs, README, `AGENTS.md`, scripts, appcasts, release bookkeeping, chores
- tiny code fixes: one file, under about 30 lines, not touching a core, input handling, or threading

Do not use this lane for `.github/workflows/`, for another contributor's work, or for anything you are unsure about.

**Pull request** for everything else. CI is the build gate that matters here. Group related work into one branch and one PR per theme, with every issue listed as `Fixes #N`.

## 2. Check before shipping

- Code changed: run `/verify` now if you have not since the last edit.
- Bug fix: it needs proof, not just a build. Follow "Proving a fix" in `AGENTS.md` (a check that failed before and passes now) and put the before and after output in the PR. `./Scripts/prove.sh` runs the whole set. If part of it cannot be automated, say which part in the PR.
- Read `git diff` once. Never commit secrets or build output.
- Run the adversarial reviewer (`.claude/agents/adversarial-reviewer.md`) only when the diff touches a core, input handling, or threading, or is over about 50 lines of code. Show `git diff main...HEAD | wc -l` first. Skip it for docs, scripts, and small fixes. Fix `block` findings or rebut them with evidence; `note` findings go in the PR body.

## 3. Commit

Format `<type>: <description>` (`fix:`, `feat:`, `chore:`, `docs:`, `refactor:`). Add `Fixes #N` in the body when it resolves an issue.

## 4a. Straight to `main`

```bash
git switch main && git pull --ff-only
# apply or cherry-pick the change, commit
git push origin main
```

If CI runs on pushes to `main`, watch it go green and tell the user if it does not. If not, say the change was not built by CI.

## 4b. Pull request

Read `.github/PULL_REQUEST_TEMPLATE.md` first and keep its test block verbatim. Fill the placeholders only. Push and open the PR in the same step, then replace `NUMBER` with the real PR number:

```bash
PR_URL=$(gh pr create --repo OpenEmu-Silicon/OpenEmu-Silicon --base main --title "<type>: description" --body-file <body>)
PR_NUM=${PR_URL##*/}
gh pr edit "$PR_NUM" --repo OpenEmu-Silicon/OpenEmu-Silicon --body "$(gh pr view "$PR_NUM" --repo OpenEmu-Silicon/OpenEmu-Silicon --json body -q .body | sed "s/NUMBER/$PR_NUM/g")"
```

Put `Fixes #N` in the PR body, since GitHub only auto-closes from there. Never merge unless the user asks for it in that same message.

## 5. Close the loop

- A PR with `Fixes #N` closes the issue when it merges. For a direct push to `main`, close it: `gh issue close N --repo OpenEmu-Silicon/OpenEmu-Silicon --comment "Resolved in <sha>."`
- If an external reporter filed the issue (not `nickybmon`), leave a short, warm, plain-English comment: what was wrong, what changed, and that it ships in the next release.
- Report the lane used, the PR URL or commit, and what was or was not verified.
