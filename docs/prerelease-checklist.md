# Pre-release checklist

What is in the next pre-release, how each part was tested, what is not proven, and what the maintainer still has to do. Written on 2026-11-12 when the four lines of work were brought into `main`. Nothing here has been signed, notarized, tagged, uploaded, or published.

## What is in it

| Feature | PR | In the app for testers |
|---|---|---|
| Nintendo 3DS on a native Azahar core | [#850](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/pull/850) (carries Kinestrata's system plugin from #831) | Yes, as a core update (`Azahar.oecoreplugin`) |
| Big-picture mode | [#795](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/pull/795) | **No.** Debug builds only. Release builds are unchanged. |
| Artwork that is never lost (durable store, one Artwork tab, choose and import art, cover-art providers, cloud backup) | [#818](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/pull/818) | Yes |
| PlayStation 2 on a native ARMSX2 core | [#788](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/pull/788) | Yes, as a core (`PCSX2.oecoreplugin`), experimental |

Left alone on purpose: #836 and #827.

## What was tested, and how

Everything below was run on the merged tree, not assumed. Each merge into `main` was a merge commit (never a squash), so contributor commits keep their authors. After each merge `main` was byte-identical to the branch that had been built and tested.

### Nintendo 3DS (#850)
- Engine rebuilt from the pinned commit; core built `--release`, installed, `verify-core-installed.sh Azahar --release` OK. App built. `./Scripts/unit-tests.sh`: 78 passed. All CI checks green.
- Real debug app: Super Mario 3D Land boots, both screens draw, a click on the bottom screen advanced the game (touch).
- Earlier long session (before the merge, same code): five games boot (Super Mario 3D Land, New Super Mario Bros. 2, Ocarina of Time 3D, Majora's Mask 3D, A Link Between Worlds), sound, buttons, touch, save states, in-game saves surviving a relaunch, 5 screen layouts, 1x to 4x resolution, about 15 minutes of play, flat memory. Pictures: `docs/3ds-evidence/README.md`.
- **Not proven:** stereo 3D, camera, a strict 30-minute run, keyboard delivery (needs you at the keyboard), encrypted dumps. The other four games and the layouts were not re-checked on the merged tree.

### Big-picture mode (#795, debug builds only)
- Main merged in with no conflicts; built; 107 unit tests passed; CI green.
- Real debug app: Window > Big Picture (Spike) opens, the Home and Library tabs show the real library with artwork.
- **Not proven:** controller navigation, launching and resuming a game from inside big picture, in this round.

### Artwork (#818)
- Main merged in with no conflicts; built; 214 unit tests passed; CI green (the Game Boy headless job stalled once on a runner and passed on re-run; it also passed locally).
- Real debug app: the right-click menu has Choose Artwork… and Import Artwork from Folder…; Choose Artwork… loaded real SteamGridDB pictures; closed without changing anything.
- The session that built the cover-art provider work reported checking, on the real library: Choose Artwork with SteamGridDB and ScreenScraper pictures, and a folder import that said "No matching artwork found" with Apply off and no change. That was not repeated here.
- **Needs hands-on test:** iCloud backup between two Macs; anything that needs your own ScreenScraper or SteamGridDB sign-in.

### PlayStation 2 (#788)
- Landed as one PR into `main` (its base branch `feat/ps2-core` held only the plan doc and merges from main, all already inside it). The only conflict was `.github/workflows/build-check.yml`: both the PCSX2 and Azahar build jobs were kept.
- Engine built from the pin (`./Scripts/build-armsx2-core.sh`), core installed and verified; app built; 214 unit tests passed.
- `./Scripts/playtest.sh --game "Dragon Quest VIII" --seconds 60` on the real library: boots, 640x448 Metal picture that changes, 57 fps average, one hitch of about 3.5 s (already noted in the PCSX2 README), 0 crash reports, game closed cleanly.
- CI on #788 never finished green: GitHub could not find macOS runners ("job was not acquired by Runner") and some core builds ran 40 to 90 minutes before failing. The app build, unit tests, Game Boy headless check and the PCSX2 core build passed. It was merged on the strength of the local build and playtest above. Re-run the core builds on `main` before you rely on CI.
- **Not proven:** keyboard and controller input in this round, other games, long sessions, rumble, saving to a memory card, disc swap. Experimental.

## Known gaps and things to watch
- Debug-signing: the keyboard in a debug build dies if macOS sees an ad-hoc signature. Builds here were signed with the "OpenEmu Debug" certificate. Release builds are signed by you, so this does not apply to the release.
- The PCSX2 core's `SUFeedURL` points to `Appcasts/pcsx2.xml`; the Azahar core's to `Appcasts/azahar.xml`. `azahar.xml` has no item yet. Until each has an item, Sparkle has nothing to offer.
- The cores are GPL (Azahar GPL-2.0-or-later, ARMSX2 GPL-3.0). Keep each core's license notice with the release.
- Do not commit or share BIOS files or game images. PS2 needs the user's own BIOS in OpenEmu's BIOS folder.

## What you still have to do

I did not run any of these, and did not run `package-core.sh`, `release.sh`, or `notarize.sh` at all.

1. **Package each new core** (needs your Developer ID certificate and, optionally, `sentry-cli`):
   ```bash
   cd /Users/nicholasblackmon/Documents/GitHub/OpenEmu-Silicon
   ./Scripts/core.sh Azahar --release        # runs build-azahar-core.sh (fetches the pinned engine, long first build)
   ./Scripts/build-armsx2-core.sh            # PS2: core.sh has no PCSX2 script hook, so use this one directly
   ./Scripts/package-core.sh Azahar 0.1.0.0
   ./Scripts/package-core.sh PCSX2 0.1.0.0
   ```
   `package-core.sh` refuses to continue unless the plugin's `CFBundleVersion` equals the version you pass. Both cores are currently `0.1.0.0` (set by `CURRENT_PROJECT_VERSION` in their Xcode projects), so that is the version to pass unless you bump it first. It signs with `Developer ID Application: Nick Blackmon`, writes `/tmp/<Core>.oecoreplugin.zip`, and prints the byte count for the appcast.
2. **Upload the zips** to the cores release (the existing pre-release is `cores-v1.6.0`; pick or create the tag you want):
   ```bash
   gh release upload <cores-tag> /tmp/Azahar.oecoreplugin.zip /tmp/PCSX2.oecoreplugin.zip --repo OpenEmu-Silicon/OpenEmu-Silicon
   ```
3. **Add the first appcast item for each core** (EdDSA-signs the zip with the host app's existing Sparkle key):
   ```bash
   python3 Scripts/update_core_appcast.py Appcasts/azahar.xml Azahar 0.1.0.0 \
     https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases/download/<cores-tag>/Azahar.oecoreplugin.zip <bytes> --sign-zip /tmp/Azahar.oecoreplugin.zip
   python3 Scripts/update_core_appcast.py Appcasts/pcsx2.xml PCSX2 0.1.0.0 \
     https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/releases/download/<cores-tag>/PCSX2.oecoreplugin.zip <bytes> --sign-zip /tmp/PCSX2.oecoreplugin.zip
   ```
   Commit both appcasts to `main` (they are what installed cores read from the `main` branch).
4. **Bump the app version.** `OpenEmu/OpenEmu-Info.plist` is at `CFBundleVersion` 23 and `CFBundleShortVersionString` 1.4.0 (`MARKETING_VERSION` 1.4.0 in the project). `release.sh` stops unless `CFBundleVersion` equals the highest `sparkle:version` in `appcast.xml` plus one, so set it to 24 (and the short version to your new number) before running it.
5. **Notarize and release the app.** `./Scripts/release.sh <X.Y.Z> [notes.md]` archives, calls `notarize.sh` (re-sign, notarize, DMG, staple), signs the DMG with Sparkle, prepends the item to `appcast.xml`, commits and pushes it, tags the commit, and makes a **draft** GitHub release. You need `notarytool` credentials stored under the name `OpenEmu`, a real (not placeholder) `ScreenScraperDevCredentials.swift` and `CheatWorksSecrets.swift`, and `sentry-cli` authenticated. You publish the draft yourself. To notarize an existing archive on its own: `./Scripts/notarize.sh [path/to.xcarchive]`.
6. **Hands-on checks only you can do:** keyboard in a 3DS and a PS2 game on a release-signed build, a controller, the two-Mac iCloud artwork backup, stereo 3D and camera (3DS).

## Sharing it with testers (the FBNeo-style test DMG)

The earlier FBNeo pre-release was an all-in-one DMG (app, cores, an Install script, a readme) attached to a GitHub pre-release. The same route is set up for this one. It is separate from the normal release above: it does not touch Sparkle or the appcasts.

1. **Use the pre-release branch.** `prerelease/preview-2026-11` is `main` plus one change: the Big Picture menu item is compiled into release builds (on `main` it is debug-only). Keep that change out of `main`. Check it out in a clean worktree, and make sure `OpenEmu/ScreenScraperDevCredentials.swift` and `OpenEmu/CheatWorksSecrets.swift` are your real files (the script stops if they are placeholders).
2. **Build the DMG:** `./Scripts/prerelease/build-preview-dmg.sh`. It asks for the app version (suggests 1.4.1), builds Azahar, PCSX2 and FBNeo (list in `Scripts/prerelease/dmg-assets/preview-cores.txt`), builds the Release app, signs with your Developer ID if it is in the keychain, notarizes if the `OpenEmu` notarytool profile exists, and writes `Scripts/prerelease/build/OpenEmu-Silicon-Preview-<version>-RC-<date>-<sha>.dmg` plus a `.sha256`. It edits two tracked files while it runs (`preview-cores.txt`, `readme.html`); `git checkout` them afterwards. This script has not been run end to end, only syntax-checked, because it signs and notarizes.
3. **Create the GitHub pre-release** tagged `preview-<date>-<sha>`, marked pre-release, and attach the DMG and `.sha256`. Paste `docs/prerelease-tester-notes.md` as the description, filling in the build name, commit, DMG link and SHA-256 near the top.
4. Before you post, install the DMG on a Mac and run Big Picture, one 3DS game and one PS2 game from it (the release-signed keyboard check is still open).
