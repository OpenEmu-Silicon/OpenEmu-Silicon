# SwiftUI library window spike

Question: can the library window be built in SwiftUI next to the AppKit one? This is a spike, not a feature. It is off
unless you pass `-OESwiftUILibrary YES`, and nothing in it is meant to merge as is.

## What is in the branch

- `OpenEmu/NewUI/OESwiftLibraryController.swift`: a hosting controller that takes the place of `LibraryController` in
  `MainWindowController` when the flag is on. Starting a game calls `MainWindowController.startGame`, the same path the
  AppKit library uses, so the emulation stack is untouched.
- `OESwiftLibraryStore.swift`: one batched Core Data fetch for the selected scope (all games or one system), sorted and
  filtered in the store. Counts come from fetch counts, not `system.games.count`. About 18 ms to fetch 5,000 games.
- `OESwiftLibraryView.swift`: sidebar of systems, search, sort, grid or list in a `LazyVGrid` / `LazyVStack`. Colors and
  sizes come from `BP` (Big Picture), art from `OEBigPictureArt.poster(for:)`.
- `OELibraryBench.swift`: `-OELibraryBench YES` scrolls the biggest scroll view in the library window on a display link and
  writes frame times and memory, then quits. It works on the AppKit grid too, so the two are measured the same way.

- `OESwiftCell.swift` and small edits to `GameCollectionViewItem` / `GameCollectionDataSource`: the **middle route**.
  With `-OESwiftUICells YES` the existing AppKit grid keeps its NSCollectionView (selection, drag and drop, menus, Quick
  Look, type to select) and each cell draws its picture, title, rating and overlays in SwiftUI. Selection ring and
  overlays are drawn by SwiftUI; the data source still loads the images.

Not ported from AltUI: its store (loads every game into memory), its box-image cache, home screen, game detail page,
hero fetcher, SteamGridDB client (already on this base) and RetroAchievements store. See the gaps below.

## Base branch

The spike was written on `feat/artwork-originals-archive`, which had `OEArtworkStore`, `OEBigPictureArt` and the
NSCollectionView grid before they reached `main`. That branch has since merged, so this branch is rebased on `main`.

## Numbers

5,000 synthetic games, Debug build, 60 Hz display, 965 x 575 window, macOS 26. Two runs each, run-to-run noise is
about one dropped frame. Raw output is in the two `swiftui-library-spike-bench-*.txt` files next to this one.

| | AppKit grid (NSCollectionView) | SwiftUI (LazyVGrid) | Middle route (AppKit grid, SwiftUI cells) |
|---|---|---|---|
| Launch to grid filled | 0.5 to 0.7 s | 0.5 to 1.7 s | 0.6 to 1.8 s |
| Scroll 2,000 pt/s | 58.9 to 59.8 fps | 59.6 to 59.7 fps | 58.3 to 58.6 fps (cold), 59.5 (warm) |
| Scroll 8,000 pt/s | 59.5 to 59.9 fps | 59.6 to 59.8 fps | 59.6 fps |
| Dropped frames over 5 s | 0 to 5 | 0 to 5 | 7 to 8 cold, 1 warm |
| Process CPU while scrolling | 39 to 44 % | 14 to 41 % | 35 to 40 % |
| Memory (footprint) | 61 to 63 MB | 58 to 75 MB | 66 to 67 MB |

Read this as: at 5,000 games a lazy SwiftUI grid scrolls as smoothly as the AppKit one, and loading is not the
problem if the store does one batched fetch.

The middle route drops a few more frames on the first pass over cold cells (about 2.5 % against 0 to 1.7 %), then settles.
A screenshot confirms the cells draw: covers, titles, a rating star, rounded corners. It is not pixel matched to the old
cells, and the selection ring, hover, and overlays were not exercised by hand.

What the numbers do not cover:
- The benchmark games have 24 shared covers and no provider artwork. In an earlier run, with artwork lookups on, the
  SwiftUI window grew to 650+ MB as it scrolled. That is `OEBigPictureArt` caching decoded posters (its cache limit is
  256 MB), not SwiftUI itself, but it is the real cost of showing posters. Measure again on a real library with art.
- Only a 60 Hz display was available. A 120 Hz ProMotion screen is a harder test.
- Scrolling was driven by code, not a trackpad. Selection, hover and animation were not exercised.
- Debug build. `LazyVGrid` is usually slower in Debug than Release.
- The AppKit grid's document is 61,000 to 80,000 pt tall and the SwiftUI one 336,000 pt. The cells are different sizes,
  so rows scrolled per second differ.

## What the spike did not verify

- Starting a game from the SwiftUI window. It is wired to `MainWindowController.startGame` but nobody launched a game.
- Any keyboard or mouse behavior, in either SwiftUI variant.
- A real library with real artwork, a 120 Hz display, or a Release build.

## Things found on the way

- `OEArtworkStore` and the Big Picture caches ignore `-databasePath`. They write under
  `~/Library/Application Support/OpenEmu` whatever library is open. Running the spike on a throwaway library with
  artwork lookups on wrote about 1,700 files to the real artwork folders (cleaned up; see the thread). The benchmark now
  skips lookups. This needs fixing before anyone points a second library at the app.
- `SyntheticLibraryGenerator` writes its 24 covers to the real `Game Library/Artwork` folder, not the synthetic one, so
  the synthetic covers did not show until the files were copied across. The script's "never touches your real library"
  is not true for those 24 files.
- The generator marks every 400th game "processing". The library's OpenVGDB sync then looks them up and the app crashes
  with a memory error inside `SQLiteDatabase.executeQuery` about 20 to 50 s after launch. Not related to SwiftUI; it
  also happens in AppKit mode, the 23 s benchmark just exits first. Worked around by setting those rows to ok.
- `OEDBImage.image` already decodes off the main thread and posts `.oeDBImageDidBecomeAvailable`. Each SwiftUI cell
  listens for its own cover's object id rather than the whole grid redrawing (Big Picture bumps one counter that
  redraws every visible card).

## Parity gaps and rough cost

Costs are one person, in days, to reach what the AppKit window does today, including testing. They are estimates from
reading the AppKit code and AltUI, not measured.

| Gap | What it takes | Rough cost |
|---|---|---|
| Multi-select, arrow keys, type to find, Return to play | `LazyVGrid` has no selection model. Hand-built selection and key handling, or an `NSCollectionView` inside SwiftUI | 4 to 6 |
| Context menus (play with core, show in Finder, rename, rating, delete, lock-on games, save states, artwork picker) | About 1,150 lines of AppKit in `GameCollectionViewController` plus its CoreMenu extension to redo as `.contextMenu` | 5 to 8 |
| Drag and drop import | `.onDrop` into the existing import queue, plus drop onto a collection | 2 to 3 |
| Collections and smart collections | Sidebar sections, create, rename, drop games on them, smart collection editor | 8 to 12 |
| Quick Look and Space | A `QLPreviewPanel` responder bridged from SwiftUI | 1 to 2 |
| Cell overlays (missing file, busy, rating, alert) | The AppKit cells draw these; the spike does not | 2 |
| List view with sortable columns | `Table` works on macOS 12; match the columns and sort the store | 3 |
| Title bar and toolbar parity | Toolbar items, search field in the title bar, full-screen behavior, window restoration | 3 to 4 |
| Scroll position and selection restore, accessibility labels | `scrollPosition` is macOS 14; macOS 12 needs `ScrollViewReader` workarounds | 3 to 4 |
| Game detail page and home screen from AltUI | About 2,500 lines (`OEGameDetailView` 1,358, `OEHomeSections` 811, `OEHomeView` 291) to update to the current data and artwork APIs | 10 to 15 |
| Preferences | Separate AppKit window, unaffected. Menu wiring only | 0.5 |

Total for parity with today's library window (everything above except home and detail): about 30 to 45 days.
With home and detail: about 40 to 60.

## Risks

- The deployment target is macOS 12. Several SwiftUI features that make this easier (`scrollPosition`, grid focus,
  `Observable`) need 13 or 14. Either raise the target or write workarounds.
- Two libraries to maintain while the flag exists. Every library change has to land twice.
- The measured result favors "yes, it can match the AppKit grid on speed". The cost is all in behavior parity, not in
  drawing the grid.
