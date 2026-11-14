# OpenEmu-Silicon pre-release: tester notes

Thank you for helping test. This is an early build, not a normal release. The app keeps its normal update feed, but this build has the same version number as the current release, so the updater will only offer something once a newer release is published. It bundles four big pieces of new work that need real people playing real games, plus one older option we would like more eyes on.

> **Fill in before posting:** the download link and SHA-256 for the DMG (`<DMG LINK>`, `<SHA-256>`), and the build name and commit (`<BUILD NAME>`, `<COMMIT>`). Delete this box.

**Build:** `<BUILD NAME>` from commit `<COMMIT>` (app version 1.4.1 release candidate).
**Needs:** a Mac with Apple Silicon.

## What we most want tested

| Area | What it is | How much we trust it |
|---|---|---|
| **Big Picture mode** | A fullscreen, controller-friendly way to browse your library and start games | New. Controller behaviour is the least tested part. |
| **Nintendo 3DS** | A new native 3DS core (Azahar) | Plays five games in our testing. Experimental. |
| **PlayStation 2** | A new native PS2 core (ARMSX2/PCSX2) | Plays one game well in our testing. Experimental. |
| **Artwork providers** | A new Artwork tab, "Choose Artwork…", folder import, and artwork that is never thrown away | New and large. Please try it on a copy of a real library. |
| **FinalBurn Neo (FBNeo)** | An Arcade core option, already shipped, still short on testing | Works in our testing; more games wanted. |

## Before you install (please read)

1. **Back up your library.** Copy `~/Library/Application Support/OpenEmu` somewhere safe. The new artwork storage changes how pictures are kept, and going back to an older OpenEmu later may not show artwork you changed in this build.
2. **Installing replaces `/Applications/OpenEmu.app`** with this build. Your games and saves are left alone (they live in the folder you just backed up).
3. **You bring your own game files.** We do not provide, and cannot help you find, game images, 3DS keys, or a PlayStation 2 BIOS.

## Install

1. Open the DMG and double-click **Install**. It copies the app to `/Applications` and the new cores to `~/Library/Application Support/OpenEmu/Cores/`.
2. Open OpenEmu from `/Applications`.
3. To go back: quit OpenEmu, delete `/Applications/OpenEmu.app`, install the latest normal release from the Releases page, then (if you want) delete `Azahar.oecoreplugin` and `PCSX2.oecoreplugin` from the Cores folder and restore your library backup.

## What to try

### Big Picture mode
Open it from **Window → Big Picture (Spike)** or press **Control-Command-B**.
- Move around Home, Library, Save States, Search and a game's page with a controller, keyboard, or mouse.
- Start a game from it. With a controller, the **Home/Guide button** (or holding **Start + Select**) pauses the game and opens a small menu: Resume Game or Quit Game.
- Leave Big Picture with Back, the sidebar's Exit item, or Home on the library.
- Things we especially want to know: does your controller work, does the Home button open the pause menu (and not the macOS Games overlay), does Resume really resume, does the layout look right on your screen (TV, external display, MacBook).

### Nintendo 3DS
- Add a 3DS game (`.3ds`, `.cci`, `.cxi`, or `.3dsx`) the normal way. Decrypted dumps need nothing else. Encrypted dumps need your own keys, which we have not tested.
- Open the game's options (gear) menu → **Display Modes** to change the screen layout (five layouts) and resolution (1x to 4x). The window follows the layout.
- Try: touch (click the bottom screen), buttons, sound, save states, saving in the game and relaunching.
- We tested Super Mario 3D Land, New Super Mario Bros. 2, Ocarina of Time 3D, Majora's Mask 3D and A Link Between Worlds. Other games may not work. **Not done yet:** stereo 3D, the camera, a long (30 minute+) run. Please tell us how long you played before anything went wrong.

### PlayStation 2
- Put your own PS2 BIOS file (for example `scph39001.bin`) in OpenEmu's BIOS folder (`~/Library/Application Support/OpenEmu/BIOS`).
- Add a PS2 game and play. In our testing Dragon Quest VIII ran at about 57 frames a second with picture and sound, with one pause of about 3 seconds.
- **RetroAchievements now works on PS2** (contributed by Leonardo Kasperavičius), including Hardcore mode. If you have an account, sign in and tell us whether achievements unlock, and whether save, load and reset behave in Hardcore.
- **Expect a black screen at the start:** a fresh PS2 boot can show a black window for roughly 10 seconds before the game's first picture, and the game's own screens can fade to black too. If it stays black for more than about 30 seconds, please report it (with the game name and whether you started fresh or resumed a save state).
- Try: keyboard and controller, saving to a memory card in the game, save states, other games. Heavy 3D games may be slow. **Not tested yet:** D-pad and right stick, rumble, disc swap, long sessions.

### Artwork providers
- Right-click a game → **Choose Artwork…** to pick a picture for cover, poster, hero, icon or logo from SteamGridDB, ScreenScraper or libretro, or from a file. **Reset to Automatic** puts the choice back.
- Right-click → **Import Artwork from Folder…** to use your own folder of pictures (`Game.png`, `Game-poster.png`, or ES-DE style folders). It only reads your folder.
- **Preferences → Artwork** is the one place for your SteamGridDB key, ScreenScraper sign-in, preferred source, and where artwork is stored. Pictures you replace are moved to a `History` folder, not deleted.
- Also there: **Fetch Missing Artwork** for the whole library (with Pause, Resume and Stop), and **Clean Up Unused Artwork…** (asks first, never deletes).
- Please check: do your own pictures stay put, is anything lost, does the library still look right, does the same art show in Big Picture.
- Cloud backup of artwork to your backup folder is in this build. **We have only tested it with one Mac.** If you use two Macs on one iCloud folder, please tell us what happened.

### FinalBurn Neo (Arcade option)
- In **Preferences → Cores**, pick FBNeo for Arcade (MAME stays the default). Try different arcade games and tell us which ones work, look wrong, or crash.

## Known limits
- Big Picture, 3DS and PS2 are experimental. Expect rough edges.
- 3DS: no stereo 3D, camera, or microphone yet.
- PS2: one known pause of about 3 seconds in the game we tested.
- PS2: a long black screen at the start is still being investigated. In our own tests the picture always came up, but we could not yet measure why it takes so long.
- Keyboard input in 3DS and PS2 games has not been confirmed on this release-signed build yet. If keys do nothing in a game, tell us your macOS version.
- Some automatic checks on this release's code did not finish because the build servers were short of Macs. We tested the app and cores by hand instead, but the automatic checks should be re-run before a wide release.

## How to report a problem
Please include as much of this as you can:
- Which area (Big Picture, 3DS, PS2, artwork, FBNeo) and which game or system.
- What you did, what you expected, what happened. A screenshot or short screen recording helps a lot.
- Your Mac model, macOS version, and whether you used a controller (which one) or the keyboard.
- Whether it happens every time.
- If OpenEmu crashed: the newest report from Console → Crash Reports → OpenEmu.

Where to send it: open an issue using the **bug report** form at <https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/new/choose> (mention this pre-release in the title), or talk to us on Discord: <https://discord.gg/HvWfVkMUK>. Please do not attach game files, keys, or BIOS files anywhere.

## Credits and licences
- The 3DS core is built on [Azahar](https://github.com/azahar-emu/azahar) (GPL-2.0-or-later). The PS2 core is built on [ARMSX2](https://github.com/ARMSX2/ARMSX2) (GPL-3.0). The 3DS system plugin was contributed by Kinestrata.
- Big Picture's interface sounds are the Console Mode UI Sounds pack by Brian Kage ([briankage.com](https://briankage.com)), used here under his free non-commercial terms.
