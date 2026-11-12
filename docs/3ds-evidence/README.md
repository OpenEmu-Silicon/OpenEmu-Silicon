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
| `display-modes/app-layout-remembered-after-relaunch.jpg` | App quit and reopened, game launched again: Side by side is applied without choosing it again. |
| `display-modes/app-side-by-side-after-touch.jpg` | Clicking OK on the bottom screen in that layout advanced the game to its next dialog: touch follows the layout. |

Notes from the work:
- The menu did not show at first. A core must declare `OEGameCoreSupportsDisplayModeChange` per system in its `Info.plist` (`OEGameCoreOptions`), even when it implements `displayModes`.
- The game window keeps its shape when the layout changes, so a wide layout is letterboxed. Resizing the window to the new shape is not done yet.
- OpenEmu saves the choice but the core must read it back on load (`displayModeInfo`); the first build forgot it on relaunch.
- The headless harness gained `--display-mode-at FRAME:NAME`.

- Found later: after relaunching with Side by side remembered, the picture was drawn too big and offset. Cause: the black-window recovery (see below) made a new layer context and reset the layer's size to the game's frame size, replacing the size the window had given it. The recovery now keeps the existing size. `display-modes/app-oot-layout-remembered-correct.jpg` is Ocarina of Time 3D after that fix, same relaunch.

## in-game-saves: saving inside a game

Ocarina of Time 3D, driven entirely by touch (the keyboard does not reach the game in this build).

| File | What it shows |
|---|---|
| `in-game-saves/1-oot-name-entry-by-touch.jpg` | File select, empty slot chosen, name keyboard on the bottom screen (side by side layout). |
| `in-game-saves/2-oot-save-completed.jpg` | The game says "Save completed." The files appear under `~/Library/Application Support/OpenEmu/Azahar/sdmc/Nintendo 3DS/.../title/00040000/00033500/data/00000001/`. |
| `in-game-saves/3-oot-save-still-there-after-relaunch.jpg` | App quit and reopened, game started again: slot 1 holds "Link" with hearts. In-game saves persist. |

## compat: which games boot

Headless run of 2400 frames each, picture read back from the GPU at frame 2400, stacked layout, 1x. Speed is not paced (no frame limiter), so seconds are the engine's own speed on an Apple A18 Pro class GPU, not a real-time measure; real-time was checked separately for Ocarina in the app (about 60 fps at the title screen).

| Game | Result | Headless time for 2400 frames |
|---|---|---|
| Super Mario 3D Land | Boots, dialogs, title, touch works, sound | (earlier runs) |
| The Legend of Zelda: A Link Between Worlds | Boots to title screen, picture correct | 35 s |
| The Legend of Zelda: Majora's Mask 3D | Boots to the in-game scene and shows the "Return to HOME Menu" bottom screen; sound | 23 s |
| The Legend of Zelda: Ocarina of Time 3D | Title, file select, creating a save by touch works; sound | 15 s |
| New Super Mario Bros. 2 | Boots to the "Welcome" dialog; top screen is black there | 6 s |

Pictures: `compat/*.png`. Not covered: actual gameplay past menus, long sessions, stereo 3D.
