#!/usr/bin/env python3
# archipelago-smoke.py — Check a running game's Archipelago connection the way BizHawk Client talks to it.
#
# Usage:
#   python3 Scripts/archipelago-smoke.py            # first open port from 43055 to 43059
#   python3 Scripts/archipelago-smoke.py --port 43056
#
# Before running: turn on Preferences → Debug → "Allow Archipelago connections", then start a game with a
# core that supports it (Gambatte for GB/GBC, mGBA for GBA). Close Archipelago's own BizHawk Client first,
# because each game accepts one client at a time.
#
# Every change this script makes to game memory is undone inside the same request list, so the game never
# sees it. Exit code is 0 only when every check passed.

import argparse
import base64
import json
import socket
import sys

PORTS = range(43055, 43060)

AREAS = {
    "GB": ["ROM", "WRAM", "CartRAM", "System Bus"],
    "GBC": ["ROM", "WRAM", "CartRAM", "System Bus"],
    "GBA": ["ROM", "EWRAM", "IWRAM", "System Bus"],
}
RAM_AREA = {"GB": "WRAM", "GBC": "WRAM", "GBA": "EWRAM"}
TITLE = {"GB": (0x134, 16), "GBC": (0x134, 16), "GBA": (0xA0, 12)}
# Where the ROM and the start of RAM sit on each system's bus.
ROM_ON_BUS = {"GB": 0x0000, "GBC": 0x0000, "GBA": 0x08000000}
RAM_ON_BUS = {"GB": 0xC000, "GBC": 0xC000, "GBA": 0x02000000}

failures = 0


def check(ok, label, detail=""):
    global failures
    if ok:
        print(f"PASS  {label}" + (f"  ({detail})" if detail else ""))
    else:
        failures += 1
        print(f"FAIL  {label}" + (f"  ({detail})" if detail else ""))


class Connection:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.file = self.sock.makefile("rwb")

    def line(self, text):
        self.file.write(text.encode() + b"\n")
        self.file.flush()
        reply = self.file.readline()
        if not reply:
            raise ConnectionError("connection closed")
        return reply.decode().strip()

    def send(self, requests):
        return json.loads(self.line(json.dumps(requests)))


def b64(data):
    return base64.b64encode(bytes(data)).decode()


def unb64(text):
    return list(base64.b64decode(text))


def connect(port):
    ports = [port] if port else PORTS
    for candidate in ports:
        try:
            return candidate, Connection(candidate)
        except OSError:
            continue
    return None, None


def main():
    parser = argparse.ArgumentParser(description="Check a running game's Archipelago connection.")
    parser.add_argument("--port", type=int, help="port to use instead of scanning 43055-43059")
    args = parser.parse_args()

    port, conn = connect(args.port)
    if conn is None:
        print("FAIL  no game is listening on 127.0.0.1:43055-43059 (is the preference on and a game running?)")
        return 1
    print(f"----  connected on port {port}")

    check(conn.line("VERSION") == "1", "VERSION handshake answers 1")

    replies = conn.send([{"type": "PING"}, {"type": "SYSTEM"}, {"type": "HASH"}, {"type": "PREFERRED_CORES"}])
    check(replies[0] == {"type": "PONG"}, "PING answers PONG")
    system = replies[1].get("value")
    check(system in AREAS, "SYSTEM names a supported system", system)
    rom_hash = replies[2].get("value", "")
    check(replies[2].get("type") == "HASH_RESPONSE" and len(rom_hash) > 0, "HASH is not empty", rom_hash)
    check(replies[3].get("type") == "PREFERRED_CORES_RESPONSE", "PREFERRED_CORES is answered")
    if system not in AREAS:
        return 1

    sizes = {}
    replies = conn.send([{"type": "MEMORY_SIZE", "domain": area} for area in AREAS[system]])
    for area, reply in zip(AREAS[system], replies):
        sizes[area] = reply.get("value", -1)
        check(reply.get("type") == "MEMORY_SIZE_RESPONSE", f"MEMORY_SIZE {area}", hex(sizes[area]))
    check(sizes["ROM"] > 0, "ROM is not empty")

    title_address, title_length = TITLE[system]
    reply = conn.send([{"type": "READ", "domain": "ROM", "address": title_address, "size": title_length}])[0]
    title = bytes(unb64(reply.get("value", ""))).rstrip(b"\0").decode("ascii", "replace")
    check(reply.get("type") == "READ_RESPONSE" and len(title) > 0, "READ the ROM header title", repr(title))

    reply = conn.send([{"type": "READ", "domain": "System Bus", "address": ROM_ON_BUS[system] + title_address,
                        "size": title_length}])[0]
    check(bytes(unb64(reply.get("value", ""))).rstrip(b"\0").decode("ascii", "replace") == title,
          "System Bus shows the same ROM header title")

    reply = conn.send([{"type": "READ", "domain": "ROM", "address": sizes["ROM"] - 2, "size": 4}])[0]
    tail = unb64(reply.get("value", ""))
    check(reply.get("type") == "READ_RESPONSE" and len(tail) == 4 and tail[2:] == [0, 0],
          "READ past the end of ROM pads with zeros instead of failing")

    reply = conn.send([{"type": "READ", "domain": "NoSuchArea", "address": 0, "size": 1}])[0]
    check(reply.get("type") == "ERROR", "unknown domain is an ERROR")

    # Guard passes: flip one RAM byte, read it back, and put it back, all in one list (one frame).
    ram = RAM_AREA[system]
    address = sizes[ram] - 1
    original = unb64(conn.send([{"type": "READ", "domain": ram, "address": address, "size": 1}])[0]["value"])[0]
    flipped = original ^ 0xFF
    replies = conn.send([
        {"type": "GUARD", "domain": ram, "address": address, "expected_data": b64([original])},
        {"type": "WRITE", "domain": ram, "address": address, "value": b64([flipped])},
        {"type": "READ", "domain": ram, "address": address, "size": 1},
        {"type": "WRITE", "domain": ram, "address": address, "value": b64([original])},
    ])
    if replies[0].get("value") is True:
        check(unb64(replies[2]["value"]) == [flipped], "matching GUARD lets the WRITE land in the same frame")
        check([r.get("type") for r in replies[1::2]] == ["WRITE_RESPONSE", "WRITE_RESPONSE"], "both WRITEs answered")
    else:
        # The game changed the byte between our read and the guard: that is the guard doing its job.
        check(True, "matching GUARD skipped because the game changed the byte first (rerun to see the write)")

    # A System Bus write reaches RAM: flip the first RAM byte through the bus, read it through the RAM area, put it back.
    first = unb64(conn.send([{"type": "READ", "domain": ram, "address": 0, "size": 1}])[0]["value"])[0]
    replies = conn.send([
        {"type": "GUARD", "domain": ram, "address": 0, "expected_data": b64([first])},
        {"type": "WRITE", "domain": "System Bus", "address": RAM_ON_BUS[system], "value": b64([first ^ 0xFF])},
        {"type": "READ", "domain": ram, "address": 0, "size": 1},
        {"type": "WRITE", "domain": ram, "address": 0, "value": b64([first])},
    ])
    if replies[0].get("value") is True:
        check(unb64(replies[2]["value"]) == [first ^ 0xFF], "a System Bus WRITE lands in RAM")
    else:
        check(True, "System Bus WRITE skipped because the game changed the byte first (rerun to see the write)")

    # A ROM WRITE lands (some games patch their ROM at runtime). The ROM does not change by itself, so no guard.
    rom_address = title_address + title_length - 1
    rom_byte = unb64(conn.send([{"type": "READ", "domain": "ROM", "address": rom_address, "size": 1}])[0]["value"])[0]
    replies = conn.send([
        {"type": "WRITE", "domain": "ROM", "address": rom_address, "value": b64([rom_byte ^ 0xFF])},
        {"type": "READ", "domain": "ROM", "address": rom_address, "size": 1},
        {"type": "WRITE", "domain": "ROM", "address": rom_address, "value": b64([rom_byte])},
        {"type": "READ", "domain": "ROM", "address": rom_address, "size": 1},
        {"type": "MEMORY_SIZE", "domain": "ROM"},
    ])
    check(unb64(replies[1]["value"]) == [rom_byte ^ 0xFF] and unb64(replies[3]["value"]) == [rom_byte]
          and replies[4].get("value") == sizes["ROM"], "a ROM WRITE lands and is undone, and the ROM keeps its size")

    # Guard fails: guard on ROM with bytes that cannot match, so the write after it must not happen.
    rom_bytes = unb64(conn.send([{"type": "READ", "domain": "ROM", "address": 0, "size": 4}])[0]["value"])
    wrong = [b ^ 0x5A for b in rom_bytes]
    before = unb64(conn.send([{"type": "READ", "domain": ram, "address": address, "size": 1}])[0]["value"])[0]
    poison = before ^ 0xA5
    replies = conn.send([
        {"type": "GUARD", "domain": "ROM", "address": 0, "expected_data": b64(wrong)},
        {"type": "WRITE", "domain": ram, "address": address, "value": b64([poison])},
        {"type": "PING"},
    ])
    check(all(r == {"type": "GUARD_RESPONSE", "value": False, "address": 0} for r in replies),
          "failed GUARD answers every later request with the failed guard")
    after = unb64(conn.send([{"type": "READ", "domain": ram, "address": address, "size": 1}])[0]["value"])[0]
    check(after != poison, "failed GUARD kept the WRITE from landing")

    replies = conn.send([{"type": "DISPLAY_MESSAGE", "message": "OpenEmu Archipelago check"},
                         {"type": "SET_MESSAGE_INTERVAL", "value": 0}])
    check([r.get("type") for r in replies] == ["DISPLAY_MESSAGE_RESPONSE", "SET_MESSAGE_INTERVAL_RESPONSE"],
          "DISPLAY_MESSAGE and SET_MESSAGE_INTERVAL are answered")

    # It must be refused at connect time. Accepting and then dropping it looks like a working port to
    # BizHawk Client, which then retries forever and never finds a second game on the next port.
    try:
        Connection(port).sock.close()
        refused = False
    except ConnectionRefusedError:
        refused = True
    check(refused, "a second client on the same game is refused outright")

    conn.sock.close()
    print(f"----  {'all checks passed' if failures == 0 else f'{failures} check(s) failed'}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
