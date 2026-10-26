Run the local verification checks on the current branch.

Run this yourself when you believe a fix or change is done. Do not run it again before committing or shipping if you built after your last edit; CI is the build gate for a PR. You do not need permission to build, install, launch, or read logs. Do not ask the user to launch the app, check the console, or look at crash reports; do it and report what you found.

## Which mode

| Change touched | Command |
|---|---|
| Main app code (`OpenEmu/`, `OpenEmuKit/`, `OpenEmu-SDK/`, `OpenEmu-Shaders/`) | `./Scripts/verify.sh --launch` |
| Code covered by `OpenEmu/OpenEmuTests/` | `./Scripts/verify.sh --launch --test` |
| A core plugin (`Dolphin/`, `Flycast/`, `mGBA/`, etc.) | `./Scripts/verify.sh --core <CoreName>` (add `--release` for Release-only bugs) |
| Both | run both, app first |
| Scripts, CI, docs only | skip |

## What it does

App: build, static analyzer, plist lint, codesign verify. With `--launch`: also a 5 second smoke launch, a scan of the unified log for faults, and a check for new crash reports.

Core: builds the core scheme, lints plists, installs with `Scripts/install-core.sh`, verifies codesign on the installed plugin, and runs `Scripts/verify-core-installed.sh` to confirm the installed plugin's hash matches the build. Run that preflight on its own, in under a second, before reporting any in-game core result.

## Reading the output

- Every check prints `PASS` or `FAIL` on its own line, and the exit code is the failure count.
- Read all of it. Do not pipe through `tail`. Flag new warnings even on a pass.
- Fix failures before shipping.
- If `verify.sh` itself breaks for a reason unrelated to the change (script bug, missing scheme, stuck process), fall back to a plain `xcodebuild build`, say so in the report, and keep going.

## When to involve a person

Only when the behavior can't be checked from a build, logs, or a crash scan: controllers and hardware, gameplay feel, audio sync, rendering, achievements triggering. Hand over one short numbered list of exactly what to try.
