# 3DS core: running record

One folder per piece of work, with pictures taken while testing it, so later ports (and reviewers) can see what was checked and what went wrong on the way. Newest at the bottom.

## saves: save states (PR for item 7, part 1)

Test game: Super Mario 3D Land, headless harness (`Scripts/headless/run.sh Azahar`), picture read back from the GPU.

| File | What it shows |
|---|---|
| `saves/1-saved-at-welcome-dialog.png` | Frame 1200, the "Welcome" dialog. State written here (15.7 MB). |
| `saves/2-after-pressing-A.png` | Frame 1300, after pressing A at 1210: the dialog is gone. |
| `saves/3-after-loading-state.png` | Frame 1302, after loading the state: byte-identical to picture 1. |

Also checked: a brand-new process that boots the game and loads that same state file lands on the same picture (hash `7cca80bc95a37d98`, same as the saved frame), so states survive a relaunch.

Notes from the work:
- Save and load run on the thread that runs frames, after waiting for the game's pending kernel work (same rule Azahar's libretro frontend uses).
- Driving the in-app save button with computer use closed the game window to the background (focus moved to the library window); the headless harness was used for the real check instead.
- In-game saves (SD card and NAND) already persist: they live under `~/Library/Application Support/OpenEmu/Azahar/{sdmc,nand}`. Not yet checked by saving in a game and relaunching.

## display-modes: screen layouts and resolution (item 6)

Display Modes menu in the game's options (gear) menu, with two groups: Screen Layout (Stacked, Top screen only, Bottom screen only, Side by side, Large top screen) and Resolution (1x to 4x). Changes apply while the game runs.

| File | What it shows |
|---|---|
| `display-modes/headless-*.png` | Super Mario 3D Land's welcome dialog in each layout, read back from the GPU: stacked 400x480, side by side 720x240, top only 400x240, bottom only 320x240, stacked at 2x 800x960. |
| `display-modes/app-menu-screen-layout.jpg` | The menu in the real app, with the five layouts. |
| `display-modes/app-side-by-side.jpg` | Side by side chosen in the real app, picture drawn live. |
| `display-modes/app-side-by-side-after-touch.jpg` | Clicking OK on the bottom screen in that layout advanced the game to its next dialog: touch follows the layout. |

Notes from the work:
- The menu did not show at first. A core must declare `OEGameCoreSupportsDisplayModeChange` per system in its `Info.plist` (`OEGameCoreOptions`), even when it implements `displayModes`.
- The game window keeps its shape when the layout changes, so a wide layout is letterboxed. Resizing the window to the new shape is not done yet.
- The headless harness gained `--display-mode-at FRAME:NAME`.
