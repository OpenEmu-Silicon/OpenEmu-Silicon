# Plan: rework the Wiimote orientation feature

Status: **plan only, nothing built yet.** Waiting on the maintainer's go.

## Where this came from

PR #885 landed Wiimote "Upright / Sideways" orientation and Dolphin 1x to 6x
resolution. It came from closed PR #870 by Kinestrata (the source files carry
Derek Hugger's copyright header; those headers stay on every file they are on).
The Controls screen works, but it is fragile. This plan keeps the feature and
changes how it is built.

## What is wrong today (read from the code)

1. **The Controls pane is changed from the outside.** `OEWiiOrientationUI.m`
   (806 lines) listens to every window update, then searches every window's
   views on every update, matching views by the end of their class name
   (`ControlsButtonSetupView`, `ControllerImageView`) and two rows made of
   spaces. It also reaches into private image-view properties. Any change to
   the Controls pane can silently break it.
2. **In-game orientation is a fake button press.** `OEWiiOrientationGameplay.m`
   sends `OEWimoteChangeExtension` and relies on a quirk in
   `DolHost::processSpecialKeys` (it adds 1 to the number first, so the wrong
   name arrives as "toggle sideways"). A toggle needs the app to guess the
   current state per player, and the choice travels through a new
   `org.openemu.WiiOrientation` preferences file polled every 0.2 s.
3. **Resolution creates a new Metal command queue on every change**
   (`DolphinGameCore.mm`, `applyResolutionScale:` and the startup clear). Not
   tested on an 8 GB Mac.

## Findings that change the brief

- **Display modes are saved per core, not per game.** `OEGameDocument.swift`
  stores them under `OEGameCoreDisplayModeKeyFormat` + the core id. For Dolphin
  that means one setting for GameCube and Wii. That is fine for orientation: a
  player picks how they hold the remote, and the Controls pane is global too.
  It means "per game" is not on offer without new work; this plan does not add it.
- **There is no extension point in the Controls pane today.** The Wii plugin
  only gets its extra rows by overriding `controlPageList`, then hunting for the
  rows afterwards. The pane's parser (`ControlsButtonSetupView.swift`,
  `parseControlList`) only understands headings (strings) and key buttons
  (dictionaries). So a small hook is needed (see PR B1).
- `DolHost::setWiimoteSideways` picks Dolphin's setting by position
  (`numeric_settings[3]`). That is fragile; the core-owned version should look
  it up by name.

## Proposed pull requests

### PR A: Dolphin resolution only

- Keep the 1x to 6x "Resolution" display-mode group as it is.
- Make one Metal command queue per game core and reuse it (no new queue per
  change).
- Test at 1x and 6x on the real-library GameCube game if there is one, with
  `./Scripts/playtest.sh --game "<name>"` and the display-modes menu. Report
  frame rate and memory on the MacBook Neo (8 GB). If 6x is not safe there, say
  so and decide then (for example, warn in the menu name, or cap it).
- Take the resolution pieces out of the orientation files so the two PRs do not
  overlap.

### PR B1: one small hook for "a choice in the Controls pane"

- A system plugin's `Info.plist` can declare a pane option: a title, a few
  choices, and the defaults key it is saved in. `ControlsButtonSetupView`
  draws it as a normal row (a segmented control) in the right place. No view
  searching, no placeholder rows, no notifications.
- An option can also name a controller picture per choice, so the pane swaps
  the picture (a plain image swap, at most a short cross-fade).
- Written generically so Atari Lynx rotation (#637) can use the same thing.
- Unit test for the plist parsing.

### PR B2: Wii orientation, owned by the Dolphin core

- Add an "Orientation" group (Upright / Sideways) to Dolphin's existing
  `displayModes`. The core sets Dolphin's sideways setting directly at start and
  on `changeDisplayWithMode:`. No toggle, no responder subclass, no extra
  preferences file, no timer.
- The Controls pane option from B1 writes the same saved value the in-game
  menu uses, so there is one source of truth. A change made in the Controls
  pane while a game is running applies at the next game start; the in-game menu
  applies at once.
- Delete `OEWiiOrientationUI.m`, `OEWiiOrientationGameplay.m/.h`, the
  `+load` observer and the `org.openemu.WiiOrientation` domain. Keep the
  trimmed artwork and the original author's headers where files survive.
- Unit test for the orientation mapping (saved value to Dolphin setting).
- A headless Dolphin check (`./Scripts/headless/run.sh Dolphin ...`, using
  `--display-mode-at`) that proves the orientation reaches the game.
- Screenshots of the Controls pane in both orientations, driven with computer
  use per `docs/computer-use-testing.md`. No saves written into the real library.

## Order and risk

A first (independent, small). B1 next (no Wii change yet). B2 last. Each is
reviewable on its own. If you would rather have B1 and B2 as one PR, say so; I
would still keep them as two commits.

Risk to watch: saved settings from people already on the #885 build
(`OEWiiOrientationSidewaysPreview`, `org.openemu.WiiOrientation`). B2 will read
the old value once and move it to the new key, so nobody's choice is lost.

## What is not proven yet

In-game orientation and Dolphin 1x to 6x were not tested by the review. Real
Wiimote hardware is not part of the plan; the headless check proves the setting
reaches Dolphin, not how it feels with a physical remote.

## AI disclosure

This plan was drafted with an AI coding assistant (Claude Code) and reviewed by
the maintainer.
