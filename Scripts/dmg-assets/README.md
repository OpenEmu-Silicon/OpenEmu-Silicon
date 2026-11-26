# DMG Installer Pipeline

Builds the styled `.dmg` users see when they download OpenEmu-Silicon — retro-synthwave background with the real OpenEmu app icon on the left, the system Applications folder on the right, and a glowing arrow between them.

This document captures the load-bearing knowledge we learned the hard way. **Read it before changing anything.**

---

## How to make common changes

| You want to… | Edit… | Notes |
|---|---|---|
| Move icons | `dmgbuild_settings.py` `icon_locations` **and** `background.html` `.pedestal-left/-right` `top`/`left` | The two **must** match. |
| Change icon size in Finder | `dmgbuild_settings.py` `icon_size` **and** `.pedestal` width/height in CSS | |
| Change a colour, the headline, corner marks, drag hint | `background.html` only | |
| Resize the window | `dmgbuild_settings.py` `window_rect` **and** HTML/CSS dimensions in `background.html` | Window total ≈ background height + 40 px slack (see "macOS 26 quirks"). |
| Replace the Applications folder icon | Re-extract from system, see [Re-extracting the folder icon](#re-extracting-the-folder-icon) | |
| Update headline copy | `background.html` `.headline h1` text | Test that it fits at 16 px Press Start 2P width. |

To verify a change locally:

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData/OpenEmu-metal-*/Build/Products/Debug \
       -name 'OpenEmu.app' -maxdepth 2 | head -1)
bash Scripts/make-dmg.sh "$APP" /tmp/test.dmg && open /tmp/test.dmg
```

---

## Architecture

Three source files plus an orchestrator:

```
background.html                                 (decorative source of truth, 960 × 680 logical)
       │
       │  swift Scripts/render-html-background.swift
       ▼
background.png                                  (1920 × 1360 px @ 144 DPI — Finder reads as 960 × 680 logical @2×)
       │
       │  dmgbuild -s dmgbuild_settings.py
       ▼
OpenEmu-Silicon.dmg                             (UDZO, with .DS_Store written directly via mac_alias)
```

| File | Role |
|---|---|
| `background.html` | The decorative layer only. **No** filename text, **no** window chrome, **no** real-icon placeholders. |
| `applications-folder-icon.png` | The real macOS system Applications folder icon, extracted from `CoreTypes.bundle`. Drawn into the right pedestal. |
| `retro-grid.jpg`, `openemu-logo.png` | Static design assets referenced by `background.html`. |
| `Scripts/render-html-background.swift` | Offscreen `WKWebView` snapshot. Outputs the PNG with the critical 144 DPI tag. |
| `dmgbuild_settings.py` | `dmgbuild` config: window size, icon coordinates, the symlink to `/Applications`. |
| `Scripts/make-dmg.sh` | Thin orchestrator: render → dmgbuild. ~25 lines. |

`Scripts/notarize.sh` calls `make-dmg.sh` after notarization succeeds. CI installs `dmgbuild` via `pip3` in `.github/workflows/release.yml`.

---

## Coordinate system (this is what bit us repeatedly)

Three coordinate spaces that **must agree**. Whenever you change one, change the others.

1. **DMG window — logical points.** Set in `dmgbuild_settings.py` `window_rect` and in `background.html` (CSS `width` / `height` on `html, body, .stage`).

2. **Background PNG — physical pixels.** WebKit on retina takes a 2× snapshot, so a 960 × 680 viewport produces a **1920 × 1360 PNG**. The renderer tags it **144 DPI** so Finder maps those pixels back to 960 × 680 logical. Without this tag Finder treats them as logical pixels and you only see the top-left quarter. Verify with:

   ```bash
   sips -g pixelWidth -g pixelHeight -g dpiWidth -g dpiHeight \
       Scripts/dmg-assets/background.png
   # Expect: 1920, 1360, 144, 144
   ```

3. **Icon positions — logical points.**
   - `dmgbuild_settings.py` `icon_locations`: **centre** of the icon in logical points.
   - `background.html` `.pedestal-*` CSS `top` / `left`: **top-left corner** of the 144 × 144 pedestal in logical points.
   - Conversion: `top-left = centre - 72` for a 144 px pedestal.
   - Example: `icon_locations["OpenEmu.app"] = (240, 340)` ⇔ `.pedestal-left { top: 268px; left: 168px; }`.

The arrow SVG endpoints in `background.html` must also bracket the icon centres with ~20 px clearance from the icon edges.

---

## macOS 26 (Tahoe) regressions we work around

These are the bugs we hit. They explain why the pipeline looks the way it does — don't "simplify" by reverting any of them without testing on macOS 26.

1. **Finder won't persist `backgroundImageAlias` for files in hidden directories.** Every tool that puts the background in `.background/` (`appdmg`, `create-dmg`, our earlier `hdiutil` + AppleScript) silently fails to save the alias bookmark, and the DMG opens with a black window. → We use **`dmgbuild`**, which writes `.DS_Store` directly via `mac_alias` and never asks Finder to set the background.

2. **Finder doesn't render the system Applications folder icon for symlinks `dmgbuild` writes.** The symlink is correct (`Applications -> /Applications`) but Finder shows nothing where the icon should be. → We draw the real `ApplicationsFolderIcon.icns` into the right pedestal in `background.html`. If a future Finder version does render it, the system icon will overlay at the same position pixel-identically.

3. **`show_status_bar = False` and `show_pathbar = False` aren't fully respected** on macOS 26 — Finder shows a small status row anyway. → The window is 40 px taller than the background (720 vs 680) so the design opens fully visible without resizing.

4. **WebKit `WKWebView.takeSnapshot` on macOS 26 silently waits for fonts, but not always reliably for `<img>` decoding.** → The renderer adds a 2.5 s delay after `didFinish` before snapshotting.

---

## Don't

- **Don't put the app filename or "Applications" text in `background.html`.** macOS draws those on top of the background.
- **Don't put the OpenEmu app icon `<img>` or a custom Applications cartridge in `background.html` as primary content.** macOS draws the real icons. The folder icon we draw is a fallback because Finder doesn't render the system icon (point 2 above) — it's not a stylistic replacement.
- **Don't include simulated window chrome** (title bar, status bar, traffic lights, sidebar). macOS draws all of those.
- **Don't tag the PNG as 72 DPI.** WebKit on retina produces a 1920 × 1360 image; without 144 DPI Finder treats it as logical pixels and only the top-left quarter is visible.
- **Don't switch to `appdmg` or `create-dmg`** "for simplicity." Both hit macOS 26 regression #1.
- **Don't render the HTML in a browser and screenshot it.** Browser zoom, scrollbar reservations, and font cache state all drift the output. The Swift `WKWebView` renderer is deterministic.
- **Don't edit `background.png` by hand.** `make-dmg.sh` regenerates it from `background.html` on every run, so any hand edits will be overwritten.

---

## Verification checklist

After `bash Scripts/make-dmg.sh <app> /tmp/test.dmg && open /tmp/test.dmg`:

- [ ] Window opens fully visible — no need to resize
- [ ] Background fills the entire content area; no clipping at any edge
- [ ] OpenEmu icon (red joystick) centred on the magenta pedestal on the left
- [ ] Applications folder icon (blue with "A") centred on the blue pedestal on the right
- [ ] Cyan arrow connects the two pedestals horizontally
- [ ] All four corner marks visible: `SYS // DMG-01`, `PLAYER 1`, `© 2026 OPENEMU`, `READY`
- [ ] OpenEmu logo + `NATIVE APPLE SILICON` badge centred at the top
- [ ] Headline `DRAG OPENEMU INTO APPLICATIONS` centred and not clipped
- [ ] Drag hint at the bottom centre, fully visible
- [ ] `Finder` filename labels for `OpenEmu` and `Applications` appear under their respective icons (drawn by Finder, not the background)
- [ ] Drag-and-drop works: drag OpenEmu to Applications and the app installs

PNG sanity:

```bash
sips -g pixelWidth -g pixelHeight -g dpiWidth -g dpiHeight \
    Scripts/dmg-assets/background.png
# Expect: 1920, 1360, 144, 144
```

`.DS_Store` sanity (mount the DMG first):

```bash
python3 -c "
with open('/Volumes/OpenEmu-Silicon/.DS_Store', 'rb') as f:
    d = f.read()
print('size:', len(d), 'bytes')
print('backgroundImageAlias:', b'backgroundImageAlias' in d)
print('Iloc:', b'Iloc' in d)
"
```

Expect: size > 8 KB, both `True`.

---

## Re-extracting the folder icon

The system Applications folder icon may change between macOS releases. If it starts looking out of date, re-extract it:

```bash
ICON_SRC=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns
sips -s format png "$ICON_SRC" \
     --out Scripts/dmg-assets/applications-folder-icon.png
```

Then commit the updated PNG.

---

## Dependencies

- **Xcode** (for `swift`, used by the renderer)
- **`dmgbuild`** — `pipx install dmgbuild` (or `pip3 install --user dmgbuild`)
- **macOS 14+** (project deployment target)

CI installs `dmgbuild` in `.github/workflows/release.yml`:

```yaml
- name: Install dmgbuild
  run: |
    python3 -m pip install --user --break-system-packages dmgbuild
    echo "$HOME/.local/bin" >> $GITHUB_PATH
```
