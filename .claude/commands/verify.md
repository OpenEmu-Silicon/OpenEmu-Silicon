Check the current branch the way CI and a person would, without a redundant build.

Run this yourself when you believe a change is done, and again right before shipping. You do not need permission to build, launch, or read logs. Do not ask the user to launch the app or look at crash reports; do it and report what you found. Quit OpenEmu first (`pgrep -x OpenEmu`).

CI builds every PR, and `check.sh` and `playtest.sh` build the app themselves, so there is no separate build-only step.

## Which mode

For anything you can see in the app, drive the real debug app with the computer-use tools first (`docs/computer-use-testing.md`). It has no password prompt and does not stall. Use `check.sh` only where the table below says so, or when you have no computer-use tools.

Start with `./Scripts/prove.sh` for the build, unit tests, headless checks, and crash scan. It runs the checks the diff touches (build, unit tests, headless Game Boy checks, crash scan) and ends with `PROVEN` or `NOT PROVEN`, listing what it could not cover. Add `--ui` to also drive the real app, or `--core <Name> --rom <file>` to run a core headless. Use the single commands below when you only need one piece.

| Change touched | Command |
|---|---|
| Main app code (`OpenEmu/`, `OpenEmuKit/`, `OpenEmu-SDK/`, `OpenEmu-Shaders/`) | Drive the debug app with computer use. No computer-use tools: `./Scripts/check.sh` (real library; add `--no-build` if nothing changed since the last run) |
| Gameplay, rendering, audio, input | Computer use to see it; `./Scripts/playtest.sh --game "<name>"` for frame rate, audio, and error numbers |
| Code covered by `OpenEmu/OpenEmuTests/` | `./Scripts/unit-tests.sh` |
| A core plugin (`Dolphin/`, `Flycast/`, `mGBA/`, etc.) | `./Scripts/core.sh <CoreName>` (add `--release` for Release-only bugs) |
| Scripts, CI, docs only | skip |

## Reading the output

- Every check prints `PASS` or `FAIL` on its own line. Read all of it; do not pipe through `tail`.
- `check.sh` failing with "Timed out while enabling automation mode" or "macOS has not granted Accessibility" is the macOS UI-automation password prompt, not a bug in the change. Do not retry it; use computer use.
- Fix failures before shipping. Failures that look like app bugs but are harness problems are listed in the UI test harness notes.
- If a script breaks for a reason unrelated to the change, say so in the report and keep going.

## When to involve a person

Only when the behavior can't be checked by the scripts: controllers and hardware, gameplay feel, audio sync, achievements triggering. Hand over one short numbered list of exactly what to try.
