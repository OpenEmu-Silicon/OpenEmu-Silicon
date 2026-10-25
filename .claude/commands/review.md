Review and test a pull request locally.

Arguments: $PR_NUMBER [$ROM_PATH]

1. Check out the PR branch:
   gh pr checkout $PR_NUMBER --repo OpenEmu-Silicon/OpenEmu-Silicon

2. Run the build check (`Scripts/verify.sh`, add `--test` when the PR adds or
   touches unit tests) and report the result. If a unit test file is new or
   changed, also run it scoped (`-only-testing:OpenEmuTests/<ClassName>`) and
   report per-test pass/fail — don't just read the test code and assume it
   passes.

3. If the PR touches a core, reinstall and re-sign the plugin before testing.

4. Read the PR description and list the specific behaviors to verify. Before
   calling any of them "needs manual verification," actually try to automate
   them with what the project already has, in this order:
   - `Scripts/check.sh` runs the real app through `OpenEmuUITests` (library
     window, preference panes, Cores pane) with no ROM needed — always run
     this; quit OpenEmu first if it's running (`pgrep -x OpenEmu`).
   - `Scripts/check.sh --rom "$ROM_PATH"` additionally loads a game and
     checks it draws, keeps rendering (not frozen), can quick save/load, can
     take a screenshot, and quits cleanly without hanging. Run this whenever
     $ROM_PATH is given, or a ROM is already available locally — it directly
     covers "game loads and runs," "quit doesn't hang," and (via the picture
     actually changing across frames) that the emulation loop isn't stalled.
     If no $ROM_PATH is given, look for one the user already owns:
     `find ~/Library/Application\ Support/OpenEmu/Game\ Library/roms -type f`
     (search all extensions, e.g. .z64/.sfc/.nes/.gba/.zip, not just a
     few) and pass one to `--rom`; it is only read, never modified. Prefer a
     system matching the PR's core when there is one. Never download a ROM
     yourself; if the user's library has none, say so and skip this step.
   - Only mark a claim "needs manual verification" if nothing in
     `Scripts/check.sh` / `OpenEmuSmokeUITests.swift` exercises it (e.g.
     resizing the window onto a display with a different refresh rate, or
     subjective audio-smoothness during real gameplay) — say exactly which
     check.sh test would need to grow to cover it, instead of leaving a gap
     silently.
   - Known failure mode, not a PR bug: `check.sh` can fail with
     "Timed out while enabling automation mode." This means the test
     runner hasn't been granted Accessibility/automation permission for UI
     testing yet. Don't keep retrying it, and don't try to self-grant it
     (modifying security settings isn't something to do without asking) —
     ask the user to grant it once. If a prompt never appears (likely a
     stale denied record from an earlier ad-hoc-signed build), have the
     user run `tccutil reset Accessibility org.openemu.OpenEmuUITests.xctrunner`
     themselves, then rerun. Note: until check.sh's build products are
     re-signed with a stable certificate (the same trick launch-debug.sh
     uses for Input Monitoring), a fresh ad-hoc signature on every rebuild
     may require re-granting again — this is a known gap, not something to
     paper over by skipping the check.
   - Known pre-existing failure, not a PR bug: `testPreferencesPanesAllOpen`
     expects a "Secrets" pane that only renders once a `debug` UserDefaults
     flag is toggled (`PreferencesWindowController.swift`'s `debugModeKey`
     gate, a per-machine standard-domain default, not scoped by the test's
     throwaway library path). It passes on whichever machine happened to
     have that flag set when the test was written, and fails elsewhere —
     this is unrelated to almost any PR; don't attribute it to the PR under
     review unless the PR actually touches `PreferencesWindowController.swift`
     or the debug-pane gating. Check with `defaults read org.openemu.OpenEmu.debug debug`
     (or the non-debug bundle id) if you need to confirm this machine's state.

5. Report:
   - Build result (and scoped unit-test results, if any ran)
   - Plugin reinstalled (yes/no, which core)
   - `check.sh` result (and `check.sh --rom` result, if run)
   - Remaining behaviors from the PR description and whether each passed,
     failed, or truly needs manual verification (with the reason why no
     automated test covers it)
