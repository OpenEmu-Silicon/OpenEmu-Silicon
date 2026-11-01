# ADR-0008: Replace the library grid with NSCollectionView, not SwiftUI

## Status

Accepted. Partly reverses the library direction in #789.

## Context

The library grid, and the save-state and screenshot views, are drawn by `OEGridView`, a subclass of `IKImageBrowserView`. That class has been deprecated since macOS 10.14. `OEGridView` also overrides and calls private ImageKit methods (`_rectOfGroupHeader:`, `gridGroupFromDictionary:`, `startSelectionProcess:`, the private renderer and layout manager) through seven private headers in `OpenEmu/`. If Apple renames any of them, the override silently stops working. The grid produces about 23 of the app's build warnings.

#789 proposed moving the desktop library to SwiftUI, shared with big-picture mode, and closed the NSCollectionView migration issues (#689–#697) as superseded. A review against the macOS 27 SDK found:

- `LazyVGrid` has no selection model: no rubber-band, Shift/Cmd multi-select or type-select. There is no SwiftUI grid equivalent of inline rename, and dragging several items out needs macOS 26. The library depends on all of these.
- `NSHostingConfiguration` does not exist on macOS, so "NSCollectionView with SwiftUI cells" means hosting an `NSHostingView` in each item by hand.
- `NSCollectionView` and `NSTableView` are not deprecated, and Apple still invests in AppKit.
- An NSCollectionView migration is already half built: `ImageCollectionViewController`, `CollectionView`, and new save-state and screenshot views behind debug toggles, plus an uncompiled `GameCollectionViewController` port.
- No credible benchmark shows SwiftUI grids matching `NSCollectionView` with thousands of image items on macOS.
- Big-picture mode's SwiftUI views are built for a scaled TV canvas and avoid SwiftUI scroll views, so they are not a template for the desktop library.

The goal is to remove the deprecated grid. A SwiftUI desktop library is not a goal in itself.

## Decision

- The games grid, save states and screenshots move to `NSCollectionView`, finishing the existing `ImageCollectionViewController` path.
- The list view stays `NSTableView` (`GameTableView`).
- The parity checklist from #689–#697 is the definition of done. Those issues are reopened.
- Once parity is reached, `OEGridView`, its cells, `OEGameCollectionViewController`, `OECollectionViewController`, `OEMediaViewController` and the private `IKImageBrowser*` headers are deleted.
- The visual refresh (larger posters, a metadata line, list columns) comes after the cutover, drawn in AppKit cells.
- Big-picture mode stays SwiftUI. It shares Swift code with the desktop library (data access, artwork and metadata service, design tokens), not views.
- The Settings window stays as it is.
- The deployment target stays macOS 12. Nothing in this decision needs a newer SDK floor.

## Consequences

**Easier:** selection, drag and drop, rename and type-select come from AppKit instead of being rebuilt. Much of the code already exists. Private API use and about 23 warnings go away. No users are dropped.

**Harder:** two UI frameworks remain in the app. The visual refresh is more code in AppKit than it would be in SwiftUI.

**Risks accepted:** there are no automated tests of the grid today, so the cutover relies on new UI tests plus a manual pass. The shared artwork service needs real work before the desktop grid can use it (see the plan).
