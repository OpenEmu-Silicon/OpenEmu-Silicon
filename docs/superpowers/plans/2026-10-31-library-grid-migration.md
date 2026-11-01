# Library grid migration plan

Decision: [ADR-0008](../../adr/0008-library-grid-on-nscollectionview.md). Replace the deprecated `IKImageBrowserView` grid with `NSCollectionView`, reach parity, delete the old code, then refresh the look.

Each phase is its own PR. Phases 1 and 2 can run in parallel with each other. Phase 3 needs phase 2's test scaffolding.

## Phase 1: Small warning fixes

Independent of the grid work.

- `allowedFileTypes` → `allowedContentTypes`: `AppDelegate.swift`, `OEGameDocument.swift`.
- `kUTTypeImage` → `UTType.image`: `OEDBScreenshot.swift`.
- `kAudioObjectPropertyElementMaster` → `kAudioObjectPropertyElementMain`: `OEAudioDeviceManager.m` (5 uses).
- `kSecUseAuthenticationUIFail` → an `LAContext` with `interactionNotAllowed`: `OECredentialStore.swift`.
- `MainWindowController.swift:279`: this is the project's own deprecation marker, not Apple's. Remove "or User Reports" from the alert (~line 392) and its localizations, then drop the `@available` attribute.
- Redundant cast: `PrefBiosController.swift:101`.

The two warnings in `OEGameCollectionViewController.m` (`setAllowedFileTypes`, `tableView:writeRowsWithIndexes:`) are left alone; that file is deleted in phase 5.

**Done when:** the build shows none of these warnings and `./Scripts/check.sh` passes.

## Phase 2: Test scaffolding and a baseline

Nothing tests the grid today, so build the safety net before changing it.

- Add UI tests for the games grid and list against the current grid: select, multi-select, open the context menu, switch grid/list, rename, and blank slate on an empty collection. Use accessibility identifiers that the new controller will keep.
- Add a script that creates a synthetic library (5,000–10,000 games, generated covers) in a temporary folder and launches with `-databasePath <folder>` and `-OEBigPictureDisableSteamGridDB 1`. It must never touch the real library or its saves. Note that art caches under `~/Library/Application Support/OpenEmu/` are shared, so the script must not write there.
- Record a baseline on the old grid with Instruments: scroll smoothness, memory, time to first paint.

**Done when:** the new UI tests pass on the current grid, and the baseline numbers are written down in the PR.

## Phase 3: Save states and screenshots on NSCollectionView

The new views already exist behind debug toggles (`LibraryController.swift:481–483`, `PrefDebugController.swift:62–63`).

- Compare the new `SaveStateViewController` and `ScreenshotViewController` against `OEMediaViewController`: selection, Quick Look, rename, delete, drag out to Finder, section headers, blank slate, Touch Bar (`OEMediaViewController+TouchBar.swift`).
- Port whatever is missing, then default the toggles to `true`. Keep the toggles for one release as a way back.
- Remove the private `_resizeToFitContentAndClipView` call (`ImageCollectionViewController.swift:145`, `AppKit+ApplePrivate.h:37`) if a public alternative works; otherwise note it as remaining private API.

**Done when:** both views are the default, the UI tests cover them, and `check.sh` passes.

## Phase 4: Games grid on NSCollectionView

Reopen #689–#695 and work through them on `GameCollectionViewController` (560 lines, not compiled yet).

| Issue | Work |
|---|---|
| #689 | Compile the controller, add the grid/list view tag, wire the toolbar toggle and grid-size slider, persist the mode |
| #690 | Selection (click, Shift/Cmd, rubber-band), arrow keys, type-select, Quick Look |
| #691 | Inline rename in both modes; ratings including the #294 double-click guard |
| #692 | Context menu parity: "Play With…" (`OEGameCollectionViewController+CoreMenu.swift`), Sonic & Knuckles lock-on, Import Artwork from Folder, collections, delete |
| #693 | Box-art drop onto a cell; ROM import when dropped elsewhere |
| #694 | Touch Bar play button (only if still wanted; see open questions) |
| #695 | List sort-descriptor persistence with title as the secondary key |

Also: blank slate, group headers if kept, and the `FIXME` at `GameCollectionViewController.swift:178` (starting several selected games only starts the first).

Run the phase 2 UI tests and the synthetic-library benchmark on the new controller. It must match or beat the baseline.

## Phase 5: Cutover and deletion

- #696: switch `LibraryGamesViewController` to `GameCollectionViewController`. Run the full manual matrix (All Games, Recently Played, a system, a collection, a smart collection; grid and list).
- #697: delete `OEGridView`, `OEGridCell`, `OEGridGameCell`, `OEGridMediaItemCell`, `OEGridViewFieldEditor`, `OEGameCollectionViewController` (and its `+CoreMenu`, `+TouchBar`), `OECollectionViewController`, `OEMediaViewController` (and `+TouchBar`), `OECoverGridDataSourceItem.h`, and the private `IKImageBrowser*.h`, `IKImageWrapper.h`, `IKRenderer.h` headers. Remove the debug toggles from phase 3.

**Done when:** no `IKImageBrowser` references or warnings remain, and the UI tests, `check.sh` and the manual matrix pass.

## Phase 6: Shared artwork service

Before the desktop grid uses big-picture's artwork logic (`OEBigPictureArt`), fix what doesn't scale:

- Replace the never-evicted image dictionaries with an `NSCache` that has a cost limit, storing thumbnails sized to the cell, not full-size art.
- Publish changes per game instead of one `tick` that redraws every view.
- Run the OpenVGDB lookups off the main thread.
- Throttle SteamGridDB requests and remember misses so they aren't fetched again on every launch.
- Move colors to light/dark-aware tokens (big-picture's are dark-only hex values).

Big-picture mode then uses the same service. This depends on big-picture's branch landing on `main` first (PR #795).

## Phase 7: Visual refresh

Using the Paper grid and list frames as reference, not a spec:

- Grid: larger posters, title, and a "developer · year · genre" line, with an optional "last played" chip.
- List: Title (with save-state count), Developer, Genre, Last Played, Play Time. `playTime` and `lastPlayed` are already stored on `OEDBRom`.
- Art source per the open question below; local box art must keep working with no SteamGridDB key.

## Not in scope

- Moving the desktop library or the Settings window to SwiftUI.
- Raising the deployment target. If it is raised later, update `sparkle:minimumSystemVersion` in `appcast.xml` and the README at the same time.

## Open questions for the maintainer

1. Default poster art: SteamGridDB when a key is set, or local box art unless the user opts in?
2. Are the Touch Bar play buttons and the grid's group headers still wanted?
3. Does staying mergeable with upstream OpenEmu matter? If so, keep the port close to upstream's `GameCollectionViewController`.
4. Should the refreshed library keep light and dark modes? (Assumed yes.)
