#!/usr/bin/env python3
"""Apply the keyboard scheme to every system's player-1 keyboard bindings.

Scheme:  Enter = Start,  W A S D = directions,  K = OK (the A button),  J = cancel (the B button),
         H = Y,  L = X   (the row H J K L reads Y B A X, like a SNES pad).
Systems that have both a D-pad and an analog stick (like N64) get the stick on W A S D and keep the arrow keys
on the D-pad. Select, shoulder buttons and everything else keep the key they already have, unless it collides
with a key the scheme now uses, in which case that button moves to the first free spare key.
Controller bindings are never touched.

  apply-key-scheme.py --dry-run     # show what would change, write nothing
  apply-key-scheme.py               # back up the bindings file, then apply

Close OpenEmu first: it reads the file at launch and writes it when you change a binding.
The backup goes to ~/Library/Application Support/OpenEmu/Bindings-backup/.
"""
import copy, datetime, os, plistlib, shutil, subprocess, sys

SUPPORT = os.path.expanduser("~/Library/Application Support/OpenEmu")
FILE = os.path.join(SUPPORT, "Bindings", "Default.oebindings")
BACKUPS = os.path.join(SUPPORT, "Bindings-backup")

KEY = {"a": 4, "d": 7, "h": 11, "j": 13, "k": 14, "l": 15, "s": 22, "w": 26, "return": 40}
NAMES = {v: k for k, v in KEY.items()}
# Spare keys for buttons that lose their key to the scheme: u i o p y t r e q, then z x c v b n m, then digits 1-0.
SPARE = [24, 12, 18, 19, 28, 23, 21, 8, 20, 29, 27, 6, 25, 5, 17, 16, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39]

def key_label(usage):
    if 4 <= usage <= 29: return chr(ord("a") + usage - 4)
    if 30 <= usage <= 38: return str(usage - 29)
    if usage == 39: return "0"
    return {40: "return", 41: "esc", 44: "space", 79: "right", 80: "left", 81: "down", 82: "up", 225: "lshift", 229: "rshift"}.get(usage, "key%d" % usage)

def wanted(buttons):
    """Which key each button should get, by button name."""
    want = {}
    def find(*suffixes):
        for suffix in suffixes:
            for b in buttons:
                if b.endswith(suffix): return b
        return None
    has_analog = any("Analog" in b for b in buttons)
    pairs = [("Up", "w"), ("Down", "s"), ("Left", "a"), ("Right", "d")]
    for direction, key in pairs:
        if has_analog:
            b = find("Analog" + direction)
        else:
            b = find("Button" + direction, "Button" + direction + "1")
        if b: want[b] = KEY[key]
    for suffixes, key in ((("ButtonStart",), "return"),
                          (("ButtonA", "ButtonFire1", "ButtonFire", "ButtonCross", "Button1", "ButtonAction"), "k"),
                          (("ButtonB", "ButtonCircle", "ButtonFire2", "Button2"), "j"),
                          (("ButtonY", "ButtonTriangle"), "h"),
                          (("ButtonX", "ButtonSquare"), "l")):
        b = find(*suffixes)
        if b: want[b] = KEY[key]
    return want

def apply(data):
    report = []
    for system, config in sorted(data.items()):
        players = config.get("keyboardPlayerBindings") if isinstance(config, dict) else None
        if not players: continue
        player = players[0]
        want = wanted(list(player))
        if not want: continue
        taken = {ev["OEHIDEventKeycode"]: b for b, ev in player.items() if b not in want}
        used = set(want.values())
        moved = []
        for key, button in list(taken.items()):
            if key in used:                      # collides with the scheme: move this button to a spare key
                spare = next(k for k in SPARE if k not in used and k not in taken and k not in {e["OEHIDEventKeycode"] for e in player.values()})
                player[button]["OEHIDEventKeycode"] = spare
                used.add(spare)
                moved.append((button, key_label(key), key_label(spare)))
        changes = []
        for button, key in want.items():
            old = player[button]["OEHIDEventKeycode"]
            if old != key:
                player[button]["OEHIDEventKeycode"] = key
                changes.append((button, key_label(old), key_label(key)))
        if changes or moved: report.append((system, changes, moved))
    return report

if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    if not dry and subprocess.run(["pgrep", "-x", "OpenEmu"], capture_output=True).stdout.strip():
        sys.exit("OpenEmu is running. Quit it first, then run this again.")
    original = plistlib.load(open(FILE, "rb"))
    data = copy.deepcopy(original)
    report = apply(data)
    for system, changes, moved in report:
        print(system)
        for b, old, new in changes: print("   %-28s %s -> %s" % (b.replace("OE", "", 1), old, new))
        for b, old, new in moved: print("   %-28s %s -> %s   (moved: key now used by the scheme)" % (b.replace("OE", "", 1), old, new))
    if dry:
        print("\n(dry run: nothing written)"); sys.exit(0)
    os.makedirs(BACKUPS, exist_ok=True)
    backup = os.path.join(BACKUPS, "Default.oebindings.%s" % datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(FILE, backup)
    fmt = plistlib.FMT_BINARY if open(FILE, "rb").read(6) == b"bplist" else plistlib.FMT_XML
    with open(FILE, "wb") as f: plistlib.dump(data, f, fmt=fmt)
    print("\nbacked up to %s\nwrote %s" % (backup, FILE))
