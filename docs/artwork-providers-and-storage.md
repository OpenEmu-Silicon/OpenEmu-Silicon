# Artwork providers, storage, and backup: phased plan

Status: planning. Phase 0 is half done (see below).

## Goal

Let people choose where their game artwork comes from, keep it where they want, pick art for each game, never lose any of it, and back it up with the cloud backup folder.

## Rules that hold in every phase

1. **Nothing is lost.** The app never overwrites or deletes artwork. A replaced file moves to a `History` folder. "Remove" sends a file to the Trash after a confirmation.
2. **A person's own choices win.** A picked or imported image is pinned. Automatic fetching, a provider change, or a refetch never touches a pinned slot.
3. **A person's own folder is read-only to the app.** We copy from it. We never write, move, rename, or delete anything in it.
4. **Store files as they arrived.** No decode and re-save of provider downloads. Smaller copies for drawing go in a cache that can be rebuilt.
5. **Moving the artwork folder copies first, checks, then switches.** The old folder stays.
6. **Fill, don't replace.** Fetching fills empty slots. Replacing is a deliberate action.

## Slots

Library cover, poster (2:3), hero (wide), icon, logo. Each slot has its own shape. Images are sorted by aspect ratio when they come in, and a mismatch is flagged.

## Layout

```
<artwork root>/<System>/<slot>/<Game>.<ext>        the active image
<artwork root>/<System>/<slot>/History/…           anything that was replaced
<artwork root>/index.json                          what is active, where it came from, pinned or not
```

The index can be rebuilt from the files. The folder layout follows ES-DE's `downloaded_media`, so an existing ES-DE folder can be used as "my folder".

## Phases

Each phase is its own PR. Each ends with checks that must pass before the next starts.

### Phase 0: measure the real downloads

- Done: the raw bytes of every provider download are saved to `Application Support/OpenEmu/Artwork Originals/<provider>/` and never replaced (commit 2a801eb3a, with tests).
- Done: refetched 17 library games through Big Picture with the art caches set aside (and restored afterward), and measured the SteamGridDB originals. ScreenScraper and libretro did not download in that run (SteamGridDB filled every slot), so their originals are not measured yet.
- Results, SteamGridDB, 17 games:

  | Slot | Formats | Median | Average | Largest | Lossless repack saves | Lossy WebP 80 saves |
  |---|---|---|---|---|---|---|
  | Hero | 14 PNG, 3 JPEG | 703 KB | 916 KB | 2.1 MB | 25% | 91% |
  | Poster | 17 PNG | 487 KB | 625 KB | 1.3 MB | 21% | 87% |
  | Logo | 17 PNG | 394 KB | 526 KB | 2.8 MB | 31% | 80% |
  | Icon | 11 ICO, 5 PNG | 173 KB | 262 KB | 0.9 MB | 2% | 74% |

- What this means:
  - SteamGridDB mostly sends PNG, so the originals are bigger than the app's current cache (which re-saves heroes and posters as JPEG). About 2.3 MB per game, or about 2.3 GB per 1,000 games, with all four slots stored as received.
  - Lossless repacking saves 20 to 30%, but it needs a WebP writer that Apple's image library does not have, so the real gain would be smaller.
  - Icons come as Windows `.ico` files that hold several sizes. They need a reader before they can be drawn from the store.
- Decision: keep the rule to store originals. Move the opt-in "save space" mode (lossy, originals kept in `History`) up to Phase 2, since it is the only thing that changes the size. Back up pinned art only by default.
- libretro-thumbnails, 5 posters from a 60 second run: all PNG, 94 KB to 834 KB, average about 450 KB, at most 512 pixels on the long side. Posters only, so about 0.5 MB per game. Small enough that lossless storage is fine.
- ScreenScraper: not measured. In this worktree the app is built with placeholder developer credentials (`harness_ensure_stubs`), so every lookup came back `badCredentials`. It needs a build with the real developer credentials. Fan art is a ScreenScraper media type and has the same requirement.
- Decision unchanged: ScreenScraper is the only unknown, and it does not change the plan. The store keeps whatever arrives.

### Phase 1: the durable store

- Needs PR 795 (Big Picture) merged first, or this work branched from it.
- Add the artwork store, index, history folder, and the never-overwrite rules.
- First copy every cover already in the library into the store. Check what `OEDBImage.prepareForDeletion` does and make sure a replaced cover is kept first.
- Big Picture reads from the store. The `Caches` folder becomes a display-size cache only. The four older `HeroArt`, `GridArt`, `IconArt`, `LogoArt` folders are read once and kept, not deleted.
- Check: unit tests on a temporary folder show that switching providers back and forth, importing the same folder twice, a lost index, and a missing folder leave every file unchanged.

### Phase 2: settings

- Preferred provider and an ordered fallback list, driving both library covers and Big Picture.
- Artwork location picker (copy, check, switch).
- Warn when the location is on a network share or in iCloud placeholders.
- Check: changing provider and location loses nothing; the old art is still reachable.

### Phase 3: choose art for a game

- "Choose Artwork…" in the game's menu and info panel, a tab per slot.
- SteamGridDB shows a thumbnail grid (score, size, author) with filters. Other providers show their single result.
- Choosing pins the slot. "Reset to automatic" unpins and keeps the file.
- Check: pick, switch provider, switch back; the pick is still there.

### Phase 4: use my own folder

- Scan on demand first. Read the ES-DE layout and `Game.png`, `Game-poster.png`, `Game-hero.png`, `Game-icon.png`.
- Extend the existing folder matcher and its review sheet.
- Aspect ratio checks with a warning.
- Check: the folder's files are byte-for-byte unchanged afterward.

### Phase 5: cloud backup

- `{backup}/Artwork/…` plus a manifest, in the existing backup manager.
- Default is pinned art and history only; an option backs up everything.
- Add-only. A restore never replaces a different local file; both are kept.
- Skip the copy when the artwork folder is already inside the backup folder.
- Check: conflicting versions on two Macs keep both; deleting locally deletes nothing in the backup.

### Phase 6: polish

- Bulk fetch with a small worker pool, pause and resume, and a clean stop on a provider quota error.
- Cleanup tool that moves unused provider art to a dated folder.
- Save-space option if Phase 0 says it is worth it.

## Open questions

- Should "my folder" be watched for changes, or only scanned when asked? Start with scan on request.
- Are pinned picks the only thing backed up by default? Proposed: yes.

## What the other apps taught us

- ES-DE: one file per game per media type; fill-only unless overwrite is on; cleanup moves files to a dated folder. Do not copy: its overwrite deletes the old file first, and it shrinks images in place.
- Batocera: skip what exists; worker threads pull from a shared queue.
- Steam ROM Manager: remembers the chosen image by its provider ID, with a versioned cache file. GPL-3, so ideas only.
