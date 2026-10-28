Check the current branch the way CI and a person would, without a redundant build.

Run this yourself when you believe a change is done, and again right before shipping. You do not need permission to build, launch, or read logs. Do not ask the user to launch the app or look at crash reports; do it and report what you found. Quit OpenEmu first (`pgrep -x OpenEmu`).

CI builds every PR, and `check.sh` and `playtest.sh` build the app themselves, so there is no separate build-only step.

## Which mode

Start with `./Scripts/prove.sh`. It runs the checks the diff touches (build, unit tests, headless Game Boy checks, crash scan) and ends with `PROVEN` or `NOT PROVEN`, listing what it could not cover. Add `--ui` to also drive the real app, or `--core <Name> --rom <file>` to run a core headless. Use the single commands below when you only need one piece.

| Change touched | Command |
|---|---|
| Main app code (`OpenEmu/`, `OpenEmuKit/`, `OpenEmu-SDK/`, `OpenEmu-Shaders/`) | `./Scripts/check.sh` (real library; add `--no-build` if nothing changed since the last run) |
| Gameplay, rendering, audio, input | `./Scripts/playtest.sh --game "<name>"` or `./Scripts/check.sh --rom <file>` |
| Code covered by `OpenEmu/OpenEmuTests/` | `./Scripts/unit-tests.sh` |
| A core plugin (`Dolphin/`, `Flycast/`, `mGBA/`, etc.) | `./Scripts/core.sh <CoreName>` (add `--release` for Release-only bugs) |
| Scripts, CI, docs only | skip |

## Reading the output

- Every check prints `PASS` or `FAIL` on its own line. Read all of it; do not pipe through `tail`.
- Fix failures before shipping. Failures that look like app bugs but are harness problems are listed in the UI test harness notes.
- If a script breaks for a reason unrelated to the change, say so in the report and keep going.

## When to involve a person

Only when the behavior can't be checked by the scripts: controllers and hardware, gameplay feel, audio sync, achievements triggering. Hand over one short numbered list of exactly what to try.
