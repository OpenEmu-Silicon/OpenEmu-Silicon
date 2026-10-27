#!/usr/bin/env python3
"""Read-only look at the OpenEmu game library, and a translator from game actions to your saved keys.

  library.py list                     # every game: system, name, file path
  library.py find <text>              # games whose name contains <text>; prints the first match as tab-separated
                                      #   system id, name, file path
  library.py keys <system id> <action>[,<action>...]
                                      # the keyboard key each action is bound to for that system

Actions: up down left right start select ok cancel x y l r z (plus any exact button name such as N64ButtonB).
"ok" is the A button, "cancel" is the B button. A game action is turned into the key you have saved in
~/Library/Application Support/OpenEmu/Bindings/Default.oebindings, so it follows whatever you set in Preferences.
Nothing here writes to your library or your bindings.
"""
import os, plistlib, sqlite3, sys, urllib.parse

SUPPORT = os.path.expanduser("~/Library/Application Support/OpenEmu")
LIBRARY = os.path.join(SUPPORT, "Game Library")
BINDINGS = os.path.join(SUPPORT, "Bindings", "Default.oebindings")

def games():
    db = sqlite3.connect("file:%s?mode=ro" % os.path.join(LIBRARY, "Library.storedata"), uri=True)
    rows = db.execute("select g.ZNAME, s.ZSYSTEMIDENTIFIER, r.ZLOCATION from ZGAME g "
                      "join ZROM r on r.ZGAME = g.Z_PK join ZSYSTEM s on g.ZSYSTEM = s.Z_PK order by s.ZSYSTEMIDENTIFIER, g.ZNAME")
    for name, system, location in rows:
        location = urllib.parse.unquote(location or "")
        path = location if location.startswith("/") else os.path.join(LIBRARY, "roms", location)
        yield system, name, path

# HID keyboard usage -> the name UI tests type
def key_name(usage):
    if 4 <= usage <= 29: return chr(ord("a") + usage - 4)
    if 30 <= usage <= 38: return str(usage - 29)
    if usage == 39: return "0"
    return {40: "return", 41: "escape", 44: "space", 79: "right", 80: "left", 81: "down", 82: "up",
            225: "lshift", 229: "rshift", 224: "lctrl", 226: "lalt", 227: "lcmd"}.get(usage, "key%d" % usage)

# action -> button name endings to look for, best match first
ACTIONS = {
    "up": ["ButtonUp", "AnalogUp", "ButtonDPadUp", "ButtonUp1"], "down": ["ButtonDown", "AnalogDown", "ButtonDPadDown"],
    "left": ["ButtonLeft", "AnalogLeft", "ButtonDPadLeft"], "right": ["ButtonRight", "AnalogRight", "ButtonDPadRight"],
    "start": ["ButtonStart", "ButtonReset", "ButtonPause"], "select": ["ButtonSelect", "ButtonMode"],
    "ok": ["ButtonA", "ButtonFire1", "ButtonFire", "ButtonCross", "ButtonB1"], "cancel": ["ButtonB", "ButtonCircle", "ButtonB2"],
    "x": ["ButtonX", "ButtonSquare"], "y": ["ButtonY", "ButtonTriangle"], "l": ["ButtonL", "ButtonL1"],
    "r": ["ButtonR", "ButtonR1"], "z": ["ButtonZ"],
}

def keys(system, actions):
    bindings = plistlib.load(open(BINDINGS, "rb")).get(system, {})
    players = bindings.get("keyboardPlayerBindings") or [{}]
    player = players[0]
    by_suffix = {}
    for button, event in player.items():
        by_suffix[button] = key_name(event.get("OEHIDEventKeycode", 0))
    out = []
    for action in actions:
        found = None
        if action in ACTIONS:
            for suffix in ACTIONS[action]:
                found = next((k for b, k in by_suffix.items() if b.endswith(suffix)), None)
                if found: break
        else:
            found = by_suffix.get(action) or next((k for b, k in by_suffix.items() if b.endswith(action)), None)
        if not found:
            sys.exit("no key bound for action '%s' on %s (bound buttons: %s)" % (action, system, ", ".join(sorted(by_suffix))))
        out.append(found)
    return out

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "list":
        for system, name, path in games(): print("%s\t%s\t%s" % (system, name, path))
    elif cmd == "find" and len(sys.argv) > 2:
        wanted = sys.argv[2].lower()
        match = next(((s, n, p) for s, n, p in games() if wanted in n.lower()), None)
        if not match: sys.exit("no game in the library matches '%s'" % sys.argv[2])
        print("%s\t%s\t%s" % match)
    elif cmd == "keys" and len(sys.argv) > 3:
        print(",".join(keys(sys.argv[2], sys.argv[3].split(","))))
    else:
        sys.exit(__doc__)
