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
- ScreenScraper, measured 2026-11-01 on the same 17 library games with the real developer credentials (a one-off debug report that downloaded each picture, counted it and stored nothing; the code was removed afterward):

  | Slot | Formats | Median | Average | Largest | Usual size |
  |---|---|---|---|---|---|
  | Cover (box 2D) | 17 PNG | 564 KB | 697 KB | 1.6 MB | 497 x 680 |
  | Hero (fan art / screenshot) | 17 JPEG | 269 KB | 279 KB | 579 KB | 1920 x 1080 |
  | Logo (wheel) | 17 PNG | 48 KB | 75 KB | 189 KB | 600 x 300 |
  | Icon (cartridge, 3D box, mix; up to 4 offered per game) | 65 PNG | 491 KB | 499 KB | 997 KB | 745 x 745 |

  Every game had a picture in every slot. Storing the first picture of each slot is about 1.55 MB per game, against about 2.3 MB for SteamGridDB, and ScreenScraper's hero is already JPEG. Nothing here changes the plan.
- Decision unchanged: the measurements did not change the plan. The store keeps whatever arrives.

### Phase 1: the durable store

Progress: done: the store (`OEArtworkStore`, with tests); a replaced or deleted library cover is copied in first; the covers already in the library are copied in once at launch; provider downloads are saved in it under the game's name; Big Picture falls back to it when a provider has nothing. Icons: macOS reads `.ico` files itself, and the store picks the largest size in the file. Hardening after an adversarial review: a failed replace puts the old picture back, the index is saved on quit, names are capped by bytes, titles that differ only in case no longer share a picture, and an unreadable index is never written over. Still to do: reading from the store first (that belongs with the provider-choice work in Phase 2, because it decides what a change of provider replaces). The `Artwork Originals` files from the Phase 0 run are not imported; that folder is new in this branch, so only the test run made them.

- Needs PR 795 (Big Picture) merged first, or this work branched from it.
- Add the artwork store, index, history folder, and the never-overwrite rules.
- First copy every cover already in the library into the store. Check what `OEDBImage.prepareForDeletion` does and make sure a replaced cover is kept first.
- Big Picture reads from the store. The `Caches` folder becomes a display-size cache only. The four older `HeroArt`, `GridArt`, `IconArt`, `LogoArt` folders are read once and kept, not deleted.
- Check: unit tests on a temporary folder show that switching providers back and forth, importing the same folder twice, a lost index, and a missing folder leave every file unchanged.

### Phase 2: settings

Progress: done: Preferences → Artwork has an "Artwork folder" section (choose, show in Finder, use default) that copies everything, checks every copy byte for byte, then switches, leaves the old folder alone, refuses a folder that holds different files of the same name, and warns for network drives and iCloud folders. Hardened after a second adversarial review: the app keeps working during the copy and a last short pause carries over what changed (a picture saved at that moment goes to the new folder), the two indexes are merged (an existing one is kept as `index.replaced-<time>.json`), a file that clashes is kept beside the incoming one so moving back to an old folder works, overlap is checked through symlinks and case, and linked files and folders are copied as their contents; and a "use the other sources when this one has nothing" option that makes a chosen source the first of the automatic chain. Not done: library covers still come from the importer, not this setting; reading from the store first with replace-on-provider-change; save-space mode.

- Preferred provider and an ordered fallback list, driving both library covers and Big Picture.
- Artwork location picker (copy, check, switch).
- Warn when the location is on a network share or in iCloud placeholders.
- Check: changing provider and location loses nothing; the old art is still reachable.

Progress, second part: done and checked. (1) Replace on provider change: when a source is chosen on its own, its pictures replace an automatic picture that came from another provider (the old one moves to `History`); a pinned or own picture is never replaced, and with Automatic the first picture keeps the slot. (2) Store first: Big Picture reads the artwork folder before asking a provider, and uses a picture there when it is pinned, is the person's own, or came from the provider in use, so clearing the small copies or switching back does not download again. A library cover from another provider never counts. (3) Library covers: with a source chosen on its own, "Download Cover Art" asks that provider (then the others, if the fallback is on) for a portrait picture and falls back to OpenVGDB when it has none. Automatic and "Library covers only" keep the OpenVGDB lookup, and nothing is fetched until a person asks. Tests: 8 new, including switching providers back and forth losing nothing and a failed replace leaving the picture, the index and the folder as they were. In the real app (libretro chosen for one run by a launch argument), Download Cover Art on Katamari Damacy put the libretro box art in as the cover and added only two files to the artwork folder. Save-space mode is not built: the Phase 0 numbers say only lossy storage would shrink anything, and it needs its own writer and a way back to the original, so it moves to Phase 6.

### Phase 3: choose art for a game

- "Choose Artwork…" in the game's menu and info panel, a tab per slot.
- SteamGridDB shows a thumbnail grid (score, size, author) with filters. Other providers show their single result.
- Choosing pins the slot. "Reset to automatic" unpins and keeps the file.
- Check: pick, switch provider, switch back; the pick is still there.

Progress: "Choose Artwork…" is in the game's right-click menu (single game). A tab per slot (Cover, Poster, Hero, Icon, Logo) shows up to 30 SteamGridDB pictures with size, score and author, plus "From File…". "Use This Picture" stores the bytes as they arrived and pins the slot (the old picture moves to History); "Reset to Automatic" unpins and deletes nothing. Cover also sets the library's box art. A pinned pick is copied into Big Picture's display copies (a cache, one small marker per slot) and wins over provider art. Checked in the real app on Space Invaders (Poster: pick, pinned in the index, reset, file kept). The grid cutover has since landed on `main` (the Swift grid is the only grid), and the menu entries for Choose Artwork and Import Artwork from Folder live in `GameCollectionViewController.swift`; the build and unit tests pass after the merge, and the entries still need a live click-through, and the info panel entry is dropped: this app has no info panel. The picker also has SteamGridDB filters (style, size, file type; the choices depend on the slot, logos have no size filter, adult content is always left out) and shows one result each from ScreenScraper (when signed in) and libretro-thumbnails beside SteamGridDB's, stored as the bytes they sent and pinned with that provider as the origin. ScreenScraper's answer for a game is kept for ten minutes so the five tabs cost one lookup. Checked in the real app on Super Mario 64: filters cut 30 pictures to 2 (Blurred) and kept the other sources' pictures; a ScreenScraper picture was picked for Poster, pinned as `provider:screenscraper`, the libretro poster it replaced is byte-identical in History, and Reset left the file and unpinned it.

### Phase 4: use my own folder

- Scan on demand first. Read the ES-DE layout and `Game.png`, `Game-poster.png`, `Game-hero.png`, `Game-icon.png`.
- Extend the existing folder matcher and its review sheet.
- Aspect ratio checks with a warning.
- Check: the folder's files are byte-for-byte unchanged afterward.

Progress: done and checked. "Import Artwork from Folder…" now reads `Game.png` (cover), `Game-poster|hero|icon|logo|cover.png` (also with `_`), and folders named for a slot or an ES-DE media kind (`covers`, `fanart`, `marquees`, `miximages`), up to three levels deep. History folders, links and non-pictures are skipped. Matching is by exact normalized name; two games with the same name are never guessed between. A wrong shape for a slot shows a warning in the review sheet but can still be applied. Applied pictures are stored as pinned user art, and a cover also becomes the library box art. Checked on a generated sample folder in the real app (one match applied as a pinned hero for Space Invaders; the folder's SHA-1s were identical afterward) and by 8 unit tests. Not done: scanning on its own schedule, and matching by system folder when two games share a name.

### Phase 5: cloud backup

- `{backup}/Artwork/…` plus a manifest, in the existing backup manager.
- Default is pinned art and history only; an option backs up everything.
- Add-only. A restore never replaces a different local file; both are kept.
- Skip the copy when the artwork folder is already inside the backup folder.
- Check: conflicting versions on two Macs keep both; deleting locally deletes nothing in the backup.

Progress: done and checked. `OEArtworkBackup` copies to `{backup}/Artwork/` when the existing backup runs (launch and quit) and has its own scope setting in Cloud Sync: off, pinned picks and history (default), or all artwork. It is add-only: same bytes are skipped, different bytes are kept beside the existing file as `Name (from <Mac>).png`, nothing is deleted, and each Mac writes only its own `index-<id>.json`. A restore adds missing files, keeps both when a file differs, and adopts index entries (with their pins) only for pictures this Mac has no entry for. An artwork folder that overlaps the backup folder is skipped. 13 unit tests, including two Macs changing the same picture and a local delete changing nothing in the backup. In the real app (backup pointed at a throwaway folder by a launch argument) only the pinned hero and the index snapshot were copied, and Restore left the real artwork folder byte-identical. Not done: a progress display for large libraries, and restoring when the other Mac's index names a different file for a slot this Mac already has (the pick is kept as is; the other file is saved beside it).

### Phase 6: polish

- Bulk fetch with a small worker pool, pause and resume, and a clean stop on a provider quota error.
- Cleanup tool that moves unused provider art to a dated folder.
- Save-space option if Phase 0 says it is worth it.

Progress: bulk fetch and cleanup are done and checked; save-space is dropped. Preferences → Artwork has a "Whole library" section: "Fetch Missing Artwork" runs a small worker pool (3 at a time, 1 for ScreenScraper, which has a shared limit) with Pause and Stop. It stops by itself, cleanly, when a provider says its quota is used up or when six games in a row get no answer; the game that hit the quota is not counted, and every finished game keeps its picture, so running it again carries on. A game whose slots are already covered is skipped without asking anyone, and a provider that already answered for a game (found nothing, within a week) is not asked again. "Clean Up Unused Artwork…" lists automatic provider pictures for games no longer in the library, asks first, and moves them into a dated `Cleaned <time>` folder inside the artwork folder; it never deletes, leaves pinned, own, library-cover and History pictures alone, and refuses to run when the library list is empty. 10 new unit tests (pool size, pause and resume, stop, quota stop, no-answer stop, no double fetch, cleanup keeps every byte). In the real app (libretro chosen for one run): the first run fetched 4 posters and found none for 13 games, replacing an unpinned SteamGridDB poster whose bytes went to History; the second run fetched nothing and changed no file; Clean Up reported nothing to clean. Pause and Stop were not clicked live because the keyless source finished in seconds; they are covered by the tests. Save-space mode is not built: it would store a lossy copy, and the rule is that originals are always kept, so the only saving left is a second smaller file per picture, which is not worth a writer and a restore path.

### Closing notes

- Logins in library cover addresses: ScreenScraper's media addresses include the developer's and the user's login in the query string, and the library stored them as a cover's source. The library now stores the address without the login (`ScreenScraperClient.redacted`) and signs it again to download (`signed`), and a launch-time scrub removes the login from covers saved earlier (2 of 17 in the maintainer's library; 0 after). Only the address text changed; no picture was touched.
- Adversarial review follow-ups: the login is only ever added to `screenscraper.fr` and its subdomains over https (a look-alike host or plain http gets nothing; removing a login still works for any scheme). The artwork backup no longer reads every backed-up file on every run (different size means different; same size and the same date to the millisecond means the same; anything else is compared byte by byte), and an index that cannot be read makes that run back up everything instead of silently skipping pinned picks. "Cancel Cover Art Download" now also stops a provider cover that was still on its way. Import warnings about a picture's shape are worked out only for files that matched a game. A confirmed cover is set even if the artwork folder could not keep a copy. Clean Up counts every ROM of a game, not only the default one. ScreenScraper pictures in the picker are kept for ten minutes with the lookup. The debug measuring code was removed. Not changed: the PR is stacked on #795 and large (split it after #795 merges if the maintainer wants), and the Preferences buttons and the backup hook in the folder backup manager have no automated test.
- Still open outside this branch: PR 818 is stacked on #795 (Big Picture) and must be retargeted to `main` once #795 merges.

## Open questions

- Should "my folder" be watched for changes, or only scanned when asked? Start with scan on request.
- Are pinned picks the only thing backed up by default? Proposed: yes.

## What the other apps taught us

- ES-DE: one file per game per media type; fill-only unless overwrite is on; cleanup moves files to a dated folder. Do not copy: its overwrite deletes the old file first, and it shrinks images in place.
- Batocera: skip what exists; worker threads pull from a shared queue.
- Steam ROM Manager: remembers the chosen image by its provider ID, with a versioned cache file. GPL-3, so ideas only.
