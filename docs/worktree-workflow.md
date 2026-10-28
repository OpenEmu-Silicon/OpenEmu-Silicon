# Worktree workflow

Working on multiple PRs in parallel via `git worktree` is supported, but macOS makes it more friction-prone than the typical "one checkout" workflow. This doc explains the gotchas and the workflow that makes them tractable.

## The fundamental problem

macOS binds privacy permissions (Input Monitoring, Accessibility, Screen Recording, Camera, etc.) to a *specific app path + code signature*. Xcode's default DerivedData uses a random hash per checkout — so:

- Main repo build → `~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-aaaaa/.../OpenEmu.app`
- Worktree A build → `~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-bbbbb/.../OpenEmu.app`
- Worktree B build → `~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-ccccc/.../OpenEmu.app`

Each is a different path, so macOS treats each as a different app. Permissions you grant to one don't apply to another. Every fresh worktree = re-grant all permissions = 5 minutes of clicking through System Settings before you can actually test.

## The fix: stable per-branch build paths

Use `Scripts/build-for-worktree.sh` instead of plain `xcodebuild`. It builds to a stable path keyed by the current branch:

```
~/Builds/openemu/<branch-name>/Build/Products/Debug/OpenEmu.app
```

Same branch → same path → permissions persist across rebuilds.

```bash
# Inside any worktree (or in main):
./Scripts/build-for-worktree.sh

# Builds to ~/Builds/openemu/<branch>/Build/Products/Debug/OpenEmu.app
# Auto-resolves a stable Apple Development signing identity if available.
```

The script also auto-resolves a stable Apple Development signing identity if you have one in your keychain. Without that, builds fall back to ad-hoc signing (`-`), which still works but means TCC permissions are tied to the path alone — they'll persist for that path but not transfer to a release build of the same code.

## First-time setup per branch

The first time you build a branch with `build-for-worktree.sh`:

1. Run the script. Note the printed app path.
2. Launch the app. macOS will prompt for any permissions the app needs.
3. Grant Input Monitoring (and anything else you need) for that path in **System Settings → Privacy & Security**.
4. Subsequent builds of the same branch land at the same path and inherit the granted permissions.

## Cores are shared across all worktrees + the installed app

This is the second worktree gotcha. OpenEmu loads cores from `~/Library/Application Support/OpenEmu/Cores/` regardless of which build is launching them. There is only one installed copy of each core at any time.

Practical implications:

- If you're testing a core fix in worktree A, but worktree B's last `Scripts/install-core.sh <Name>` left a different version of the same core installed, **you're testing the wrong code.**
- Switching between worktrees that touch the same core requires a re-install each time you want to test.
- The "installed cores" state isn't checkpointed by git — there's no equivalent of `git stash` for the cores directory.

The only way to keep cores straight: every time you switch which worktree you're testing, run `Scripts/install-core.sh <CoreName>` from that worktree before launching. `core.sh <Name>` does this automatically.

## `main`'s state isn't in worktrees

This is fundamental git worktree behavior, not a bug. Each worktree is checked out at a specific branch. New commits to `main` don't appear in worktrees on other branches unless you explicitly merge or rebase.

To get the latest `main` into a worktree's branch:

```bash
# From inside the worktree
git fetch origin
git merge origin/main          # safe: adds a merge commit
# or
git rebase origin/main         # rewrites history; only do this on branches no one else uses
```

If you've already pushed the branch and the merge commit is fine, the merge approach is simpler. The rebase approach gives a cleaner history but requires force-pushing afterward.

## `core.sh` from a worktree

`core.sh` notices when it runs inside a linked worktree and uses the stable `~/Builds/openemu/<branch>/` path instead of DerivedData:

```bash
./Scripts/core.sh <CoreName>
```

This builds to the stable path, installs the core, and runs the MD5 preflight (`verify-core-installed.sh`) to confirm the installed plugin matches the build. A plain `xcodebuild` puts the build in DerivedData instead, where a later install can pick up a stale artifact from a previous session.

## Verification protocol for core changes

OpenEmu loads cores from `~/Library/Application Support/OpenEmu/Cores/`, not the build directory. There are three distinct binaries to track whenever you're doing core work in a worktree:

| What | Path |
|---|---|
| Worktree build | `~/Builds/openemu/<branch>/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core>` |
| DerivedData build | `~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-*/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core>` |
| Installed (what OpenEmu loads) | `~/Library/Application Support/OpenEmu/Cores/<Core>.oecoreplugin/Contents/MacOS/<Core>` |

After any core install, run the three-way MD5 check:

```bash
md5 \
  ~/Builds/openemu/<branch>/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core> \
  ~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-*/Build/Products/Debug/<Core>.oecoreplugin/Contents/MacOS/<Core> \
  ~/Library/Application\ Support/OpenEmu/Cores/<Core>.oecoreplugin/Contents/MacOS/<Core>
```

What each hash tells you:

- **Worktree build hash** — the code you just compiled. This is the source of truth.
- **DerivedData hash** — may be stale from a previous session or a main-checkout build. Should be ignored if it's older than the worktree build.
- **Installed hash** — what OpenEmu will actually run. Must match the worktree build hash or your test result is invalid.

`Scripts/verify-core-installed.sh <CoreName>` automates the build-vs-installed comparison and prints both hashes. Use it, but read the hash output — don't rely on the exit code alone.

### What went wrong (incident log)

During FCEU grey-screen debugging, `install-core.sh` only searched DerivedData. The worktree build landed in `~/Builds/openemu/<branch>/` instead. The script found the stale DerivedData artifact and installed it without error. The preflight check also only looked at DerivedData, so it reported "installed matches latest build" — and both were true about the wrong binary. The bug was caught only by running a manual three-way MD5 comparison. Hours of "still broken" debugging were actually testing code that hadn't been installed.

The fix (PR #321) makes `install-core.sh` search both paths and prefer the most recently modified. The three-way check remains the definitive confirmation — run it after every install.

## Worktree session checklist

Run through this at the start of any session that touches cores in a worktree:

- [ ] Confirm you're in a worktree: `git worktree list` — `.git` will be a file, not a directory
- [ ] Build with: `./Scripts/core.sh <Name>` (or `./Scripts/build-for-worktree.sh` for app-only)
- [ ] Install with: `./Scripts/install-core.sh <Name>` (searches both paths, prefers most recent)
- [ ] Verify with three-way hash — only declare done when installed hash matches worktree build hash
- [ ] If the hashes don't match: quit OpenEmu, re-run `install-core.sh`, re-check

## Cleanup

When you're done with a worktree:

```bash
# Remove the worktree (from the main repo, not the worktree itself)
git worktree remove ../openemu-pr287

# Optionally remove the build artifacts (forfeits granted permissions)
rm -rf ~/Builds/openemu/<branch-name>/
```

If you keep the build dir but delete the worktree, the next `git worktree add` for the same branch will reuse the build dir and the permissions you already granted.

## What this workflow does not solve

- **Cores are still shared.** Solving this would require modifying OpenEmu's core-loading logic to accept a per-build cores path. Out of scope.
- **`OpenEmuHelperApp` permissions are separate from `OpenEmu.app` permissions.** The helper lives inside the .app bundle, so building to a stable path automatically gives the helper a stable path too — should "just work" with this workflow.
- **If your signing identity changes between builds** (sometimes ad-hoc, sometimes Developer ID), permissions may still need re-granting. `build-for-worktree.sh` resolves a consistent Developer ID identity if you have one, which prevents this.

## When NOT to use worktrees

If the work you're doing genuinely requires testing one PR at a time and switching often, worktrees may add more overhead than they save. A single checkout with `git checkout` to switch branches is fine for most workflows. Worktrees are most useful when:

- You're actively comparing two implementations side-by-side
- You need to run two long-running operations (e.g. a build + a test) on different branches simultaneously
- You don't want to disrupt your editor's open files when switching branches
