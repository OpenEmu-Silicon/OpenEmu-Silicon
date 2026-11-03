# Archipelago connections

[Archipelago](https://archipelago.gg) is a multiworld randomizer: items from many games are shuffled together, and an Archipelago client on your Mac sends and receives them while you play. The client needs to read the game's memory to see what you picked up, and write to it to hand you items from other players.

OpenEmu can let those clients connect to a running game. It is off unless you turn it on.

## What works

| System | Core | Games (built into Archipelago 0.6.8) |
|---|---|---|
| Game Boy / Game Boy Color | Gambatte | Pokémon Red and Blue, Super Mario Land 2 |
| Game Boy Advance | mGBA | Pokémon Emerald, Castlevania: Circle of the Moon, Mario & Luigi: Superstar Saga, Yu-Gi-Oh! 2006 |

Third-party games ("APWorlds") that use Archipelago's **BizHawk Client** on these systems work too, for example Pokémon Crystal.

Not yet: other systems and cores, SNES games (they use a different Archipelago tool, SNI), GameCube games, and the older games that ship their own BizHawk-only scripts (Ocarina of Time, Zelda 1, Mega Man Battle Network 3, Adventure).

## Setting it up

1. Run Archipelago from source on your Mac (see Archipelago's [macOS guide](https://github.com/ArchipelagoMW/Archipelago/blob/main/worlds/generic/docs/mac_en.md)).
2. In OpenEmu, open Preferences → Debug and turn on **Allow Archipelago connections**. (The Debug pane appears after you enter the Konami code in Preferences.) The setting takes effect from the next game you start.
3. Patch your ROM the usual way for that game, add the patched ROM to OpenEmu, and start it.
4. In the Archipelago Launcher, open **BizHawk Client** and connect to the server. The client finds OpenEmu by itself; there is no script to load.

You can play more than one game at once. Each game uses its own port (43055, then 43056, and so on), and each needs its own BizHawk Client.

OpenEmu refuses Archipelago connections while RetroAchievements hardcore mode is in force, because writing game memory from outside counts as cheating there.

## How it works

Archipelago's clients send lists of requests: read these bytes, write those bytes, and "only carry on if these bytes still match". OpenEmu runs each whole list between two frames of the game, so the game never moves on halfway through. If a check fails, nothing after it in the list happens. That is what lets a client safely do things like "add 5 to the rupee count" without the game changing the count in between.

There are three layers, so OpenEmu is not tied to one Archipelago client:

1. **Cores** list their memory areas and read and write them (`liveMemoryAreaNames`, `readLiveMemoryArea:…`, `writeLiveMemoryArea:…` on `OEGameCore`). A core knows nothing about Archipelago.
2. **The list runner** (`LiveMemoryChain` in OpenEmuBase) runs reads, writes and checks in order and applies the "stop after a failed check" rule. It runs inside `-performLiveMemoryTransaction:`, which by default uses `-performBlock:` to run between frames.
3. **Adapters** speak one client's protocol. Today that is BizHawk Client (`BizHawkClientCodec` in OpenEmuBase, `BizHawkClientListener` in OpenEmuKit). Archipelago is working on a newer client, PolyEmu, that uses the same read, write and check model, so it will be another adapter on the same two layers.

The listener only accepts connections from this Mac (127.0.0.1). Nothing reads OpenEmu's memory from another process, so the app keeps the Hardened Runtime and notarization.

## Adding a core

1. Implement the live memory methods from `OEGameCore.h` in the core. Use the area names Archipelago clients expect for that system (for example `RAM`, `WRAM` and `PRG ROM` for NES). Reads past the end of an area return zeros; writes past the end are ignored.
2. If the core runs the emulated CPU on its own thread (Mupen64Plus, Dolphin, Flycast, PPSSPP), also override `-performLiveMemoryTransaction:` so the block runs on that thread at a frame boundary. Otherwise the default is correct.
3. Add the system's BizHawk id to `BizHawkClientCodec` if it differs from the platform name.
4. Build and install with `./Scripts/core.sh <Core>`, start a game with the preference on, and run `python3 Scripts/archipelago-smoke.py`.

## Updating a core

Live memory belongs in the core's OpenEmu wrapper (the `OEGameCore` subclass), not in the emulator's own source, so a new upstream version does not replace it. Keep it that way for new cores: use what the emulator already exposes.

- **mGBA:** nothing in mGBA's own source changed. All of it is in `src/platform/openemu/mGBAGameCore.m`.
- **Gambatte:** the one exception, because its memory is private. About 60 lines were added to `libgambatte` to reach it, in the blocks marked `//> OpenEmu` in `gambatte.h`, `gambatte.cpp`, `cpu.h`, `memory.h` and `mem/cartridge.h`. Carry those blocks over when updating libgambatte, along with the blocks already there for save states and RetroAchievements.

After any core update, run `Scripts/archipelago-smoke.py` against a game on that core. If the emulator moved or renamed something, the wrapper stops compiling or a check fails.

## Checking it

`Scripts/archipelago-smoke.py` connects the way BizHawk Client does and checks:

- the handshake, system, hash and memory sizes;
- reading the ROM header, both directly and through the System Bus;
- that RAM writes land through the RAM area and through the System Bus;
- that a ROM write lands without changing the ROM's size;
- that a passing check lets its writes land, and a failed check blocks them;
- that a second client is refused.

Every change it makes to game memory is undone in the same list, so the game never sees it.

The adapter and list runner have unit tests in `OpenEmu-SDK/OpenEmuBaseTests` (`LiveMemoryChainTests`, `BizHawkClientCodecTests`).
