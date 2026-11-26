# Design system for the main app

Plain macOS first, character on top. This is the base the refresh in #882 builds on. The tokens are in code (`OpenEmu/NewUI/OEDesign.swift`); the code is the source of truth, and any design file follows it.

## Rules

1. **System first.** Use system colors (`.primary`, `.secondary`, `Color.accentColor`), system type and SF Symbols before inventing anything. Selection uses the user's accent color. The app follows light and dark mode.
2. **Quiet chrome, art first.** Window chrome is plain. Color and detail come from cover art, screenshots and save previews.
3. **Character is opt-in and named.** Retro looks (pixel or CRT treatments, console tints, a vintage frame) are separate, named pieces added on top of the plain base, never baked into it. The plain version must always work.
4. **Match platform behavior.** Selection, focus, keyboard, context menus, drag and drop and accessibility work like any Mac app. Cells expose a label and rating to VoiceOver.
5. **One value, one place.** No hard-coded colors, radii or font sizes in views. Add a token to `OEDesign` first.

## Where to look when deciding a pattern

- Apple's Human Interface Guidelines for macOS, and the macOS design resources (free Sketch and Figma kits with the system controls).
- SF Symbols app for icons, so icons share weight and alignment with system text.
- Finder, Photos and Music for grid, list, selection and sidebar behavior. When unsure, do what those do.

## Do we need a UI library in Sketch?

No. The system controls already exist in Apple's own design kits, and the app's tokens live in code. A design file is for drawing new screens and character pieces, not for defining the system. Keep one file (the "OpenEmu v2" file) for mockups and export images to `docs/design/` for review.
