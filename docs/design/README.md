# Design track: app and library UI refresh

Tracking issue: #882. This folder holds the plan and the agreed decisions for refreshing the main app's look so it matches Big Picture mode. It is docs only for now. Code comes after the scope is agreed.

## Direction

- The existing design system comes first. New ideas are welcome where they fit it.
- Clean, modern frame. Retro belongs in the content (cover art, console icons, screenshots and saves, including an optional CRT look), not in busy chrome.
- Art first, quiet controls, one accent.
- Start small and scope before building.

## Sources

| Source | What it is |
|---|---|
| Design file "OpenEmu v2" (the maintainer's; exports will be added here) | Main window screens and the Big Picture "TV spec" |
| `OpenEmu/BigPictureTheme.swift` | The theme the Big Picture code uses today |
| https://github.com/nickybmon/OpenEmu-AltUI | An earlier SwiftUI library shell (stale since June) |
| #854 | Mockups for the library and Big Picture |
| #868 | Library and Controls polish, including a toolbar crash fix |
| #825 | Richer grid and list (phase 7 of `docs/superpowers/plans/2026-10-31-library-grid-migration.md`) |
| #789 | Controller-navigable library UI |

## Design tokens: where the sources disagree today

One source has to be named canonical before new screens are built.

| Thing | Design file TV spec | `BigPictureTheme.swift` | AltUI tokens |
|---|---|---|---|
| Canvas | 1920 by 1080, safe area 80 and 60 | 1280 by 720 scaled, margin 56 | n/a |
| Gutter | 40 | 22 | 22 |
| Poster radius | 12 | not set | card 4, large 6 |
| Tertiary text | 35% | 40% | 35% |
| Surface | idle button white 15%, selected tab 20% | 7% (strong 14%) | 6% (hover 10%) |
| Focus | scale 1.10 plus shadow, white filled button | accent ring or fill | n/a |

Shared values: background `#0A0A0C`, text `#F5F5F7` (60% secondary), accent `#3B82F6`, success `#22C55E`.

## Open decisions

1. Which source is canonical for the tokens.
2. How to build the new screens: restyle AppKit in place, host SwiftUI inside the AppKit window, or a SwiftUI library window beside the classic one.
3. How much retro and where.
4. Whether the game page becomes the home for per-game controls, shaders and cheats.
5. Where cover overlays, icons and metadata come from, and their licenses.
6. Whether the new design is dark only.
7. The minimum macOS version (the app targets macOS 12 today, which limits SwiftUI).

## Plan

0. Agree the tokens and the decisions above, and record them here.
1. Land bug fixes on their own (the toolbar customization crash fix from #868).
2. One shared theme for Big Picture and the main app.
3. A spike: port the AltUI library shell onto current `main` behind a flag, use Big Picture's art loader and theme, measure it on a large synthetic library (`Scripts/make-synthetic-library.sh`), and list what it would take to match the AppKit library (drag and drop import, context menus, collections, Quick Look, keyboard and controller use).
4. Pilot one screen, then roll out.

## How to take part

Comment on #882. Share mockups as image exports. Please hold large library or design PRs until the scope is agreed; small bug fixes are always welcome.
