Start a work session. Quick sync, no ceremony.

1. Make sure the working tree is clean, or note what is uncommitted and on which branch.
2. `git cleanup` (fetch, prune, sync `main`, delete local branches whose remote is gone). Drop stashes whose branch no longer exists.
3. If a task was given, pick a branch name (`fix/...`, `feat/...`, `chore/...`) and create it, unless the work is going straight to `main` (see `/ship`).
4. Only list open issues if asked, or if no task was given: `gh issue list --repo OpenEmu-Silicon/OpenEmu-Silicon --state open`.
5. Report the branch and anything that needs attention. Keep it to a few lines.
