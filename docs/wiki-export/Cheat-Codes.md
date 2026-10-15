# Cheat Codes

OpenEmu has a built-in Cheat Code and Cheat Search manager. You can enter codes while a game is running — no cartridge swapping, no external hardware needed.

OpenEmu also bundles a small database of verified cheats for some popular games. When you load one of those games, the built-in cheats appear automatically in the cheats menu — no typing required.

OpenEmu can also look up cheats for many popular games from online **cheat code databases** and let you import them with a single click — no typing, no hunting for the right format. This is done through the **Browse Online Cheats** window (see below).

Huge shoutout to @leocck for all their hard work on these features

---

## How to Add and Use Cheat Codes

1. Launch a game in OpenEmu.
2. Move the mouse over the game window to reveal the HUD bar.
3. Expand the **Cheats** context from the Options menu on the HUD.
4. The menu lists any built-in cheats for the current game (if available). Toggle one on by clicking it — it takes effect immediately.
5. To enter your own cheat, click **Add Cheat…**
6. In the dialog:
   - **Title** — a label so you can identify it later (e.g. "Infinite Lives")
   - **Code** — the cheat code in the format your system supports (see the table below)
   - Check **Enable now** to activate the cheat as soon as you click Add
7. Click **Add Cheat**.

Your codes persist between sessions and are saved per-game (matched by ROM hash). Closing the game, quitting OpenEmu, and reopening will keep your codes and their enabled state.

> **Tip:** to toggle a code off later, expand the Cheats menu again, then expand the cheat. The check mark on the **Enabled** option indicates whether it's currently active.

---

## Supported Formats by System

The code format you enter has to match what the system's emulator core understands. Codes copied from the wrong format will be silently ignored — the cheat will appear in the menu but have no in-game effect.

| System | Supported formats | Example |
|--------|-------------------|---------|
| **Nintendo 64** | GameShark v1/v2 only — exactly **12 hex characters** per code (8-char address + 4-char value) | `8033B21D 0064` |
| **NES / Famicom Disk System** | Game Genie (6 or 8 chars), raw hex `XXXX:YY`, compare `XXXX?CC:YY`, Pro Action Rocky | `SXIOPO`, `0064:08` |
| **SNES** | Game Genie, Pro Action Replay | `DD62-6DDD`, `7E0DBE:63` |
| **Game Boy / Game Boy Color** | Game Genie (with hyphens), GameShark (no hyphens) | `01FF6FC1` (GS), `09A-B6F-FFB` (GG) |
| **Game Boy Advance** | GameShark / Action Replay (handled by mGBA) | varies — see Game Boy Advance code databases |
| **Genesis / Mega Drive / Master System / Game Gear / Sega CD / SG-1000** | Game Genie, Action Replay | `RYGA-A6X4` |
| **Nintendo DS** | Action Replay | varies — see DS code databases |
| **ColecoVision** | Raw hex patches (`ADDRESS:VALUE`) | `73B8:03` |
| **Atari 2600** | Raw hex patches (`ADDRESS:VALUE`) | `80:FF` |
| **PlayStation** | GameShark (12 hex chars: type byte + address + value) | `80097BA0 270F` |
| **Saturn** | Action Replay (`TAAAAAAA VVVV`, 12 hex chars), raw hex (`ADDRESS:VALUE`) | `1060785C 270F` |
| **Atari Lynx / Neo Geo Pocket / PC Engine / PC Engine CD / PC-FX / Virtual Boy / WonderSwan** | Raw hex patches (`ADDRESS:VALUE`) | `0080:FF` |
| **Arcade** | Raw hex patches (`ADDRESS:VALUE`) | `C80B:63` |

Multi-line cheats can be joined with `+` for any system. For example: `code1+code2+code3`.

If a code type isn't listed for your system, it isn't supported by the current core. Raw memory addresses (some online cheat databases publish those instead of formatted codes) are not supported except where listed above.

### N64 cheats: a note on code formats

The most common pitfall is N64 codes. Modern cheat archives often publish **GameShark Pro v3** or **Action Replay** codes for N64, which are **16 hex characters** (8 address + 8 value). These look very similar to the 12-character codes that work in OpenEmu, but they're a different format that the bundled core (Mupen64Plus) doesn't understand.

If your N64 code is 16 characters per line (e.g. `031A5344 00004320`), it won't work in OpenEmu. Look for a 12-character version (e.g. `8033B21D 0064`) instead.

---

## Browse Online Cheats

Browse Online Cheats finds cheats for the game you're playing from built-in **cheat code databases** and lets you import them with one click. Because OpenEmu already knows your system and core, the codes it imports are always in the correct format.

### Opening it

1. Launch a game in OpenEmu.
2. Move the mouse over the game window to reveal the HUD bar.
3. Expand the **Cheats** context from the Options menu on the HUD.
4. Click **Browse Online Cheats…**

The item only appears for systems that have a cheat database available. The window opens alongside the game and lists every cheat found for your loaded ROM (matched by its MD5 hash). Along the top you'll see the **Game**, **MD5**, **System**, **Core**, and **Version** it matched against.

### The cheat list

| Column | What it does |
|----------|-------------|
| **Cheat Name** | What the cheat does. |
| **Provider** | Which database the cheat came from. |
| **Status** | Your personal "does it work" mark. Click to set **Working**, **Not Working**, **I Don't Know**, or leave it unset. |
| **Code** | Click to view the raw code, there's a **Copy** button if you want to share or edit it. |
| **Notes** | Click to add your own notes. The dialog also lets you optionally record whether the cheat worked. |
| **Action** | **Import** adds the cheat to the game's Cheats menu. Already-imported cheats show **Remove** instead. If the same code is already in your list from another source, Import is disabled and shows "Code already used". |

### Filtering

Use the **Name** box and the **Status** filter (**All**, **Working**, **Not Working**, **Not set**) to narrow a long list.

### After importing

Imported cheats appear in the Cheats menu with a small database icon next to them, grouped below your own cheats. An imported cheat:

- **Toggles on/off** like any other cheat — expand it and click **Enabled**.
- **Can't be edited** (it comes from a database), but you can **Remove** it.
- Has a **Set Status** submenu (**Working** / **Not Working** / **I don't know**) so you can record whether it worked for you right from the menu.

When you remove an imported cheat, OpenEmu may ask "Did this cheat code work for you?" — your answer helps track which database cheats are reliable, and in the future could be used to consolidate feedback and give you ratings for existing codes.

### Cheat Feedback

Status marks and notes are saved on your machine, per game, so they're still there next time you come back to that game.

They are also shared to CheatWorks.org, an open cheat feedback consolidation platform that helps figuring out if cheat codes work or not. The Browse Online Cheats window will show the global cheat ratings on the left side, if enough users already gave feeback for the codes on screen.

You are still free to test all cheat codes - a cheat code that did not work for another user might still work for you.

---

## Cheat Search

Cheat Search lets you scan a game's memory to find cheat codes yourself — no external databases needed. It works by searching for values in RAM and narrowing the results as values change in-game.

### How to use Cheat Search

1. Launch a game in OpenEmu.
2. Move the mouse over the game window to reveal the HUD bar.
3. Expand the **Cheats** context from the Options menu on the HUD.
4. Click **Cheat Search…**.
3. The Cheat Search window opens alongside the game.

#### Finding a code — step by step

Say you want to find a code for "99 lives" and you currently have 3 lives:

1. **Set the data size** (1 byte for small values like lives, 2 or 4 bytes for larger values like score).
2. **Enter 3** in the value field, select **=** (equals), and click **Search**. This scans all of RAM for the value 3 — you'll probably get many results.
3. Go back to the game and lose a life (now you have 2).
4. Return to Cheat Search, enter **2** in the value field, and click **Search** again. This narrows the results to addresses that were 3 and are now 2.
5. Repeat (gain or lose a life, search for the new value) until only a few addresses remain.
6. Select the address that tracks your lives, click **Add Cheat**, and it's added to your cheats list in the correct format for your system.

#### Search options

| Option | What it does |
|--------|-------------|
| **Compare to: Entered Value** | Compares current memory against a specific number you type in. |
| **Compare to: Previous Value** | Compares current memory against the values from the last search. Useful for finding values that changed (or didn't) between searches. |
| **Compare to: Stored Value** | Compares current memory against a saved snapshot. Useful if you don't know the value but can refer to a specific state (e.g., life bar is full). Click **Store Values** to take a snapshot, then search for changes. |
| **Data type** | Unsigned (≥ 0), Signed (+/−), or Hexadecimal. |
| **Comparison** | `=`, `≠`, `<`, `>`, `≤`, `≥` |

Click **Reset** to clear all results and start a fresh scan.

---

## Supported systems

Cheat Codes / Search are available for the following systems.

| System | Core |
|--------|------|
| Arcade | MAME |
| Atari 2600 | Stella |
| Atari 5200 | Atari800 |
| Atari 7800 | ProSystem |
| Atari Lynx | Mednafen |
| ColecoVision | CrabEmu |
| Famicom Disk System | Nestopia |
| Game Boy | Gambatte |
| Game Boy Advance | mGBA |
| Game Boy Color | Gambatte |
| Game Gear | GenesisPlus |
| Genesis / Mega Drive | GenesisPlus |
| Master System | GenesisPlus |
| MSX | blueMSX |
| Neo Geo Pocket | Mednafen |
| NES / Famicom | FCEU |
| NES / Famicom | Nestopia |
| Nintendo 64 | Mupen64Plus |
| Nintendo DS | DeSmuME |
| Odyssey² | O2EM |
| PC Engine / TurboGrafx-16 | Mednafen |
| PC Engine CD / TurboGrafx-CD | Mednafen |
| PC-FX | Mednafen |
| PlayStation | Mednafen |
| Playstation Portable | PPSSPP |
| Pokemon Mini | PokeMini |
| Sega 32X | picodrive |
| Sega CD | GenesisPlus |
| Sega Saturn | Mednafen |
| SG-1000 | GenesisPlus |
| SNES / Super Famicom | BSNES |
| SNES / Super Famicom | SNES9x |
| Vectrex | VecXGL |
| Virtual Boy | Mednafen |
| Watara Supervision | Potator-Core |
| WonderSwan / WonderSwan Color | Mednafen |

---

## Systems Without Cheat Code/Search Support

The following systems do not have a cheat menu in OpenEmu-Silicon (yet). The **Cheats** context menu will not appear in the Options while playing these games — this is intentional, not a bug

| System |
|--------|
| 3DO |
| Atari 8-bit |
| Atari Jaguar |
| Dreamcast |
| GameCube |
| Intellivision |
| Sega Dreamcast |
| Wii |

---

## Where to Find More Cheat Codes

Besides the **Browse Online Cheats** menu, you have still alternatives to find cheat codes. Different systems have different reliable sources. Here's what works well for OpenEmu:

| System | Recommended source |
|--------|--------------------|
| **Nintendo 64** | [GameGenie.com — N64 GameShark codes](https://gamegenie.com/cheats/gameshark/n64/index.html). Every code on the site is in the 12-character format that works in OpenEmu. |
| **NES, SNES, Genesis, Game Boy, GBA, etc.** | [GameFAQs](https://www.gamefaqs.gamespot.com) — search your game title, then look for the Cheats section. Most older-system codes from GameFAQs work as-is. |
| **All systems (debug modes, dev cheats)** | [TCRF (The Cutting Room Floor)](https://tcrf.net) — debug menus, developer cheats, and unused content |

When using any external source, make sure you're using codes for the correct **region** of your ROM (USA, EUR, JPN) and the **correct format** for your system. A code that works on the USA version of a game won't necessarily work on the European version.

---

## Notes and Limitations

- **Timing matters.** Some codes only take effect at a specific moment — for example, a code that sets your starting lives only works when you start a new game, not mid-session.
- **Codes are stored per-ROM.** Switching cores for a system (e.g. between BSNES and Snes9x for SNES) shouldn't delete your saved codes, but a code written for one core may not work on another if the memory addresses or parser differs.
- **If a code crashes the game**, disable it and reload from a save state or the game's own save system.
- **Save states with cheats active** may behave unexpectedly when loaded with cheats later disabled. Consider taking a clean save state before you start experimenting.
- **No effect, no error.** If a code looks "enabled" in the menu but isn't doing anything in-game, the most likely cause is a format mismatch — the core silently skips codes it can't parse. Double-check that the code matches the format in the table above.
- **Search is limited to 1.000 results.** This is to prevent UI freeze. Refine your search to narrow down the results.
- **RetroAchievements Restriction.** Cheats will be disabled if you play in Hardcore Mode. Achievements will still be triggered if you use cheats if Hardcore Mode is disabled, but they will be marked as "Soft" in RetroAchievements.

---

## Reporting Problems

If a cheat that should work doesn't, or you think a built-in cheat feature is broken, please [open an issue](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon/issues/new/choose) and include:

- The system and game name (with region)
- The exact code you tried
- Whether the cheat shows as enabled in the menu
- Whether you're using a built-in cheat or a code you added yourself
- If applicable, where you found the cheat code
- If you created it via Cheat Search window, describe how