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
