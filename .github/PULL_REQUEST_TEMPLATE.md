## What does this PR do?

<!-- One or two sentences describing the change. What problem does it solve, or what does it add? -->

## What did you test?

<!-- How did you verify this works? Which game(s), system(s), or workflow(s) did you test with? -->

## Which cores or systems are affected?

<!-- List the emulation cores or systems this change touches, if any. If it's a general app change, say so. -->

## Did you use AI tools?

<!-- We're fully open to AI-assisted contributions — just be transparent about it. Did you use Claude, Copilot, Cursor, or anything else? If so, briefly describe how. (e.g. "Used Claude to draft the fix, reviewed and tested it myself.") -->

## Linked issues

<!-- Use "Fixes #N" to auto-close an issue on merge, or "Related to #N" to soft-link -->

Fixes #

---

## How to test locally

The PR number below is filled in automatically — just paste the whole block. For Flycast use `-scheme "OpenEmu + Flycast"` with `clean build`; for Mednafen use `-scheme "OpenEmu + Mednafen" -configuration Release`.

```bash
cd <path to your OpenEmu-Silicon clone>
gh pr checkout NUMBER --repo OpenEmu-Silicon/OpenEmu-Silicon
./Scripts/build-for-worktree.sh
./Scripts/launch-debug.sh
```

`build-for-worktree.sh` builds to a stable per-branch folder. `launch-debug.sh` picks the freshest Debug build without using a glob (which opens multiple instances when DerivedData has more than one hash directory).

If this PR touches a core, install it before launching:

```bash
./Scripts/install-core.sh <CoreName>
./Scripts/launch-debug.sh
```

`install-core.sh` quits OpenEmu first, copies files correctly, and re-signs the bundle.

<!-- Add any PR-specific setup here (BIOS files, permissions to revoke, specific ROM to test with). -->

---

## PR checklist

- [ ] Branched from an up-to-date `main` (ran `git fetch origin && git merge origin/main`)
- [ ] Build passes: `./Scripts/build-for-worktree.sh` (or `xcodebuild -workspace OpenEmu-metal.xcworkspace -scheme OpenEmu -configuration Debug -destination 'platform=macOS,arch=arm64' build`)
- [ ] Tested on Apple Silicon (M1 / M2 / M3 / M4 Mac)
- [ ] No build logs, binaries, or credentials committed
- [ ] Copyright headers preserved on all modified files
- [ ] New files (if any) include the BSD 2-Clause license header
