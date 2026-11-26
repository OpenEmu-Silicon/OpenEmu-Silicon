# ADR-0009: AppKit shell, SwiftUI for visuals, macOS 14 minimum

## Status

Accepted. Amends ADR-0008: it keeps the NSCollectionView grid, but changes who draws the cells and raises the deployment target.

## Context

#887 asked whether the library window should be AppKit or SwiftUI, and #882 needs an answer before the design refresh can start. The spike (#888, `docs/swiftui-library-spike.md`) measured three versions of the library grid on a 5,000-game library: the AppKit grid, a SwiftUI `LazyVGrid`, and the AppKit grid with SwiftUI cells. All three scrolled at about 59 to 60 fps in a Debug build, so speed does not decide it.

What decides it is behavior. A full SwiftUI library has to rebuild selection, keyboard handling, context menus, drag and drop import, collections and Quick Look. The spike estimated 30 to 45 days for parity, and outside reports agree that SwiftUI on macOS is still weaker on those exact things. Public write-ups of large Mac grids mostly end up with an AppKit collection view and SwiftUI cells.

The deployment target was macOS 12. Several SwiftUI features the design work wants (`@Observable`, `scrollPosition`, better grid and focus behavior) need macOS 13 or 14. Every Apple silicon Mac can run macOS 14.

## Decision

- The app shell, window, toolbar, menus and the library grid stay AppKit. The games grid stays an `NSCollectionView` (ADR-0008), so selection, drag and drop, rename, type-select and Quick Look keep working as they do today.
- New and restyled visuals are SwiftUI. Grid cells draw in SwiftUI, hosted by hand in each item with one `NSHostingView` per cell that is reused (update `rootView`, never add or remove subviews while scrolling). New screens such as the game page are SwiftUI views hosted in the window.
- ADR-0008's "visual refresh drawn in AppKit cells" no longer applies. Cells are SwiftUI.
- The minimum macOS is 14.0 (Sonoma). The app, OpenEmuKit and OpenEmu-SDK projects are raised to 14.0. Cores are separate bundles and keep their own targets for now.
- The main app follows system design: system colors, system type, SF Symbols, the user's accent color. Character (retro frames, CRT looks, console tints) is added on top of that base. Tokens live in `OEDesign.swift` and the rules are in `docs/design-system.md`. Big Picture keeps its TV theme (`BP`) and shares data and art code, not views.
- Full SwiftUI library windows are not pursued. Revisit only if SwiftUI gets a real selection model for grids and the parity cost drops.

## Consequences

**Easier:** the visual refresh is mostly SwiftUI, which is faster to iterate on. Risky behavior (selection, drag and drop, menus) is not rebuilt. The work can ship in small steps behind one flag, and rolls back to AppKit drawing without a data change. `@Observable` and the newer SwiftUI APIs are usable.

**Harder:** two UI frameworks stay in the app, and each cell hosts a SwiftUI view, which costs a little on a cold first scroll (about 2.5% dropped frames in the spike). Cell trees must stay small. Users on macOS 12 and 13 stop getting updates after the last release that supports them.

**Release steps this needs:**
- The next release's appcast item sets `sparkle:minimumSystemVersion` to 14.0 and the notes say macOS 14 is required. Do not change the existing items: they describe releases that still run on macOS 12.
- The existing appcast item says 12.0 and older items say 11.0. These were already out of step with the app, which needs 12.0 or later.
- Say it in the release notes and on the download page.

**Still to verify:** a Release build, a 120 Hz display, a real library with artwork, and keyboard and mouse behavior in the SwiftUI-cell grid. These are tracked in #887.
