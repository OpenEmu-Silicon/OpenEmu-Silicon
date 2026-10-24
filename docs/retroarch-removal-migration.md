# RetroArch core support removal — migration behavior

Reference for what happens on a user's machine when they upgrade into the release
that removed RetroArch core support (1.4.0), and what to tell someone who reports
a problem related to it.

Background on why the feature was removed is in the pull request; this file covers
only the upgrade behavior and its edge cases.

## What happens on first launch after upgrading

`AppDelegate.removeOrphanedRetroArchPlugins()` runs once per launch, before any
plugin enumeration:

1. Walks `~/Library/Application Support/OpenEmu/Cores/` and deletes every bundle
   that either is named `*-RetroArch.oecoreplugin` **or** whose `Info.plist` names
   `OEGameCoreClass = OELibretroCoreTranslator` or carries an `OELibretroCorePath`
   key. Two signals, because early builds did not all use the filename convention,
   and the plist is what actually predicts a bundle that can no longer load.
2. Clears any `defaultCore.<systemID>` preference whose value points at a bundle it
   just removed, ends in `-RetroArch`, or begins with the legacy `retroarch.` form.
   The system then falls back to its native core.
3. Records what it did in `~/Library/Logs/OpenEmu/core-inventory.txt` under
   `--- Orphaned RetroArch plugin cleanup ---`, and logs one line per removal.

It is not gated on a "already migrated" flag. After the first run it is a single
directory listing that matches nothing, which also means a restored backup or a
downgrade/upgrade round trip gets cleaned up too.

**Ordering matters.** The call lives in `AppDelegate.init`, immediately before
`OECorePlugin.registerClass()`. That call enumerates the Cores folder and caches
the result for the rest of the launch, so a stub deleted after it would stay in the
in-memory plugin list — removed cores would still appear under "Play With…" and
would try to load a principal class the app no longer contains. Do not move this
call later in the launch sequence.

The plan is to keep this migration for a few releases, then delete it.

## Save states — the one thing that does not migrate

A save state is a snapshot of an emulator's internal memory, so it is only valid in
the core that wrote it. There is no way to convert one between cores. Save states
written by a RetroArch core therefore cannot be restored after the upgrade.

What a user actually sees when they pick one, tracing `loadState(state:)`
(`OEGameDocument.swift:2709` onward):

The stored `coreIdentifier` no longer matches the resolved core, so OpenEmu shows
**"This save state was created with a different core. Do you want to switch to that
core now?"** with *Change Core* and *Cancel*.

| Choice | Behavior |
|---|---|
| **Cancel** | `startEmulation()` — the game runs on the native core from the beginning. The state is not restored. |
| **Change Core** | `OECorePlugin.corePlugin(bundleIdentifier:)` returns nil, so `CoreUpdater.installCore(for: state,…)` runs, finds no downloadable core for a `-RetroArch` identifier, and reports `noDownloadableCoreForIdentifierError`. A dead end — the core can never be reinstalled. |
| Commodore 64 | Same alert; both paths end without a playable core, since C64 has none at all. |

Neither path crashes — the lookup is a failable optional, not a force unwrap. But
note the alert is misleading here: *Change Core* offers something that cannot
succeed, because the core it names no longer exists in any form. If users report
this as a bug, that is the explanation. Users who previously ticked the alert's
"do not ask again" suppression box (`OEAutoSwitchCoreAlertSuppressionKey`) go
straight down the *Change Core* path and see only the error.

Two things worth stating plainly to anyone who reports this:

- **Battery saves are not affected.** In-game saves (the ones the game itself
  writes to its cartridge or memory card) are core-independent and survive. Only
  save states are lost.
- **Auto save states are not loaded automatically, and are easy to miss.** A game's
  right-click → "Play Save State" menu is built from `OEDBRom.normalSaveStates`,
  which filters out every state whose name begins with `OESpecialState_`. Auto save
  states are therefore *never* listed there — a game whose only state is the auto
  save shows "No Save States available", and always has, independent of this change.
  They are visible in the **Save States** section of the library sidebar (controlled
  by the `showsAutoSaves` preference, on by default). So reaching an affected auto
  state takes deliberate action; launching a game normally never hits it.

Affected states can be identified by reading the `Core Identifier` key:

```bash
find ~/Library/Application\ Support/OpenEmu/Save\ States \
  -name Info.plist -path '*.oesavestate*' -exec grep -l -i retroarch {} \;
```

They can be deleted from the **Save States** section of the library sidebar (not
from the game's right-click menu, which hides auto saves). Nothing deletes them
automatically — the cleanup only touches core plugin bundles and preferences, never
user data. `AppDelegate.removeIncompatibleSaveStates()` does prune states for
deprecated cores, but its list is explicit and contains no RetroArch identifiers,
so it leaves these alone.

To exercise this path, open the Save States section of the library and pick an
affected state there.

## Features that share the name and were NOT removed

These come up because all three read as "Libretro" to a user. A report that one of
them broke is not a migration problem:

- **Libretro cheat database** — `LibretroCheatProvider.swift`, shipped in #715.
- **Libretro box art / thumbnails** — `LibretroThumbnailsClient.swift`.
- **`OERetroAchievementsBridge`** — a different "bridge" entirely; RetroAchievements.
