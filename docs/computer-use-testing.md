# Testing the app by driving it (computer use)

This is the first way to check the app window, menus, preferences, library, and anything you can see. An agent that has the computer-use tools opens the real debug app and clicks through it, then reads the screen. It does not go through `check.sh`.

Why this comes first: `check.sh` runs the app through Apple's UI test runner. That runner makes macOS ask for a password every time it turns on UI automation ("XCTest is trying to Enable UI Automation"). The run waits, times out, and fails, and nobody is there to type the password. Driving the app directly has no such prompt, so a run does not stall. It can also judge what it sees ("the grid has no covers"), where a fixed test can only pass or fail.

## What you need

- Computer use turned on in the Claude desktop app: Settings, This computer, Computer use. A session only gets the tools if the setting was on **when the session started**. If the tools (`mcp__computer-use__*`) are not there, start a new session.
- Nothing else. No Accessibility grant for a test runner, no `automationmodetool`.

If an agent does not have these tools (a contributor's agent, CI), use the scripts in "When to use the scripts instead" below.

## How to run a check

1. Quit any OpenEmu that is running (`pgrep -x OpenEmu`). Ask the maintainer once up front; quitting the debug app is fine.
2. Build if the code changed: `./Scripts/build-for-worktree.sh`.
3. Launch with `./Scripts/launch-debug.sh`, never `open <path>`. It picks this branch's build and signs it so permissions survive rebuilds.
4. Ask for access to the debug app. Its bundle identifier is `org.openemu.OpenEmu.debug`.
5. Work in the background with the `app_*` tools (`app_screenshot`, `app_menu`, `app_click`, `app_type`, `app_key`). Use `app_menu` for menu items; it is more reliable than clicking the menu bar.
6. Ask for full-screen control only for a step the background tools cannot do. In practice that is dismissing an open or save panel (a background click does not reach a sheet), and anything that needs the app in front. Release it as soon as that step is done.
7. Look at what you did. Take a screenshot after each meaningful step and say what you saw. Do not report a pass from a click that returned "ok"; a background click can be accepted without having an effect.
8. Quit the debug app when you are finished, and release the app locks.

## Rules for the real library

- Check on the real library and real games. A throwaway library is for a case where you need a known empty or large library; say why.
- **Never write saves into the real library.** Do not quick save, and close games without leaving an auto save changed. If a step cannot avoid writing one, stop and say so.
- Do not type into credential fields or sign in to anything. Settings panes can show saved usernames; leave them alone.

## Things to know

- The window can show as "on another Space" to the tools. Background clicks usually still work; if one is refused, `app_bring_to_current_space` brings it over.
- If two things are open (for example two file panels), close them one at a time and take a screenshot between.
- Only one session should drive the app at a time. Two sessions on one library collide, same as with the scripts.
- The window on screen is the real debug build. Tell the maintainer before a run that the app will open and be driven, and that they should leave it alone while it runs.

## When to use the scripts instead

Keep these. They are the right tool for a few specific jobs, and the only option when no computer-use tools exist:

| Job | Use |
|---|---|
| Unit tests | `./Scripts/unit-tests.sh` |
| A core with no window: loading, picture, sound, button input, save states | `./Scripts/headless/run.sh <Core> --rom <file>` or `./Scripts/headless/gb-checks.sh` |
| Frame rate, audio underruns, error counts over a play session | `./Scripts/playtest.sh --game "<name>"` (numbers a person looking at the screen cannot get) |
| Building and installing a core | `./Scripts/core.sh <Name>` |
| Build, tests, headless checks, and crash scan in one pass, ending `PROVEN` / `NOT PROVEN` | `./Scripts/prove.sh` |
| Repeatable regression run with no agent in the loop (a person at the machine, or another tool) | `./Scripts/check.sh` |

`check.sh` can still fail with "Timed out while enabling automation mode" or "macOS has not granted Accessibility". That is the password prompt described at the top. It is not a bug in the change under test. Do not keep retrying it. Say so in the report and use the computer-use route.

Say plainly what was not covered. Real controllers, Bluetooth, and macOS permission prompts still need a person.
