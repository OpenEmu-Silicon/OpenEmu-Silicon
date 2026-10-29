# FinalBurn Neo (FBNeo) Core for OpenEmu-Silicon

A second **Arcade** core alongside MAME, added mainly because FBNeo is
RetroAchievements-approved (MAME is not). It is a thin Objective-C++ `OEGameCore`
wrapper (`FBNeoGameCore.mm`) over a headless build of FBNeo, loaded as
`org.openemu.FBNeo` for `openemu.system.arcade`.

MAME remains the **default** arcade core; pick FBNeo per-game via **Play With…**,
or make it the default in **Preferences → Cores**.

Non-commercial: FBNeo must never be sold, and it inherits the MAME license. The
full license ships verbatim in [`LICENSE`](LICENSE).

## Features

- Video (with software rotation so vertical games — 1942, Raiden — show upright)
- Input (`OEArcadeSystemResponderClient`)
- Save states (quick/auto; also enables the per-game "last used core" memory)
- RetroAchievements (`RC_CONSOLE_ARCADE`)
- Cheat codes + Cheat Search, and Browse Online Cheats via the **Libretro** FBNeo
  database (Pugsy's is MAME-only)

## Source dependency

The FBNeo source is not committed here (too large). It is pulled from the
`OpenEmu-Silicon/fbneo` fork at the revision pinned in `deps-fbneo-revision.txt`:

```sh
./Scripts/prepare-fbneo-core.sh
```

This checks out the pinned revision into `FBNeo/deps/fbneo` (gitignored). The
headless frontend lives in the fork under `src/burner/headless/`.

## Build

```sh
./Scripts/build-fbneo-core.sh      # builds fbneo_headless.dylib, then FBNeo.oecoreplugin
```

Product: `FBNeo/build/XcodeDerived/Build/Products/Release/FBNeo.oecoreplugin`

## Local testing

```sh
./Scripts/install-core.sh FBNeo --release
./Scripts/verify-core-installed.sh FBNeo --release
```

`install-core.sh`'s three-way hash check (`OK — installed bundle matches source`)
is authoritative; `verify-core-installed.sh` without `--release` false-fails after
a Release build because it looks for a Debug build.

## ROM sets — important

**FBNeo uses its own versioned ROM sets, which are NOT interchangeable with
MAME's.** This fork's MAME core expects MAME 0.250 sets; FBNeo expects sets
matching the pinned FBNeo revision. A given game's `.zip` is often valid for one
core but not the other (different CRCs, different member files, different parent/
clone splits). When a game fails to load under FBNeo:

- Confirm the set is an **FBNeo-compatible** set (FBNeo's own DAT), not a MAME set.
- FBNeo is strict about ROM contents; a renamed or MAME-only zip will report
  "not a recognized FinalBurn Neo set".
- Games are identified by **short name** = the zip's filename without extension
  (e.g. `mslug.zip` → `mslug`, `sf2.zip` → `sf2`). Keep the canonical short name.

## Support folders

The core keeps FBNeo's runtime files under
`~/Library/Application Support/OpenEmu/FBNeo/`, the same way the MAME core does:

| Folder | Holds |
|--------|-------|
| `nvram/` | EEPROM saves (`.nv`), battery-backed RAM (`.fs`, e.g. Mortal Kombat's settings), per-game DIP switch/input config (`.ini`), hiscore saves (`.hi`), hard-disk diffs. Created automatically. |
| `samples/` | Optional sample packs (e.g. `invaders.zip` with WAV files) for games whose sounds FBNeo plays from recordings. Not shipped; without a pack those games are silent. |
| `hiscore/`, `blend/`, `hdd/` | FBNeo's optional `hiscore.dat`, blend files and hard-disk images. |

## RetroAchievements — filename requirement

Arcade RA hashing is based on the **ROM filename** (the zip's base name, no
extension), **not** the file contents. So for achievements to resolve:

- The zip **must** be named with FBNeo's canonical short name (e.g. `mslug.zip`,
  `sf2ce.zip`). A renamed zip hashes to something the RA server doesn't know and
  shows no achievement set.
- This is the same key used for cheats: Libretro FBNeo `.cht` files are also
  looked up by romset short name.

So the one rule that satisfies loading, achievements, and cheats at once: **keep
each game's zip named with its canonical FBNeo short name.**

## Playtest checklist (for a new build)

1. A horizontal sprite game (e.g. `rallyx`) — renders, audio, input.
2. A vertical game (e.g. `1942`) — upright, not sheared.
3. A CPS2 / Neo Geo title (e.g. `sf2ce`, `mslug`) — loads and plays.
4. Save state → reload; Reset → game restarts without freezing.
5. RetroAchievements: a supported title unlocks against the RA server.
6. Cheat Search finds a value and the applied cheat sticks; Browse Online Cheats
   shows Libretro entries (not Pugsy's).
