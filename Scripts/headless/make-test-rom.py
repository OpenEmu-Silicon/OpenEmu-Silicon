#!/usr/bin/env python3
"""Builds a tiny Game Boy test ROM for the headless harness.

The ROM is written from scratch for this repo, so it can live in the tree without any ROM licensing questions.
What it does, once per frame:
  - scrolls the background sideways (so the picture always changes) and slowly shifts its shades (the picture
    only repeats every 256 frames),
  - turns the background palette into a different value for each of A, B, Select and Start (Start also stays
    latched after release, so a short key tap in a UI test is still visible later),
  - moves the background up or down a few pixels for each direction pad button.
That lets a test prove "the core ran", "a button press reached the core" and "a save state round trips".

Usage: make-test-rom.py <output.gb>
"""
import sys

# Nintendo logo the boot ROM checks for.
LOGO = bytes([
    0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0C, 0x00, 0x0D,
    0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E, 0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99,
    0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E])


def assemble():
    code = bytearray()
    labels = {}
    fixups = []  # (position of the offset byte, label)

    def emit(*b):
        code.extend(b)

    def label(name):
        labels[name] = len(code)

    def rel(opcode, name):
        emit(opcode, 0)
        fixups.append((len(code) - 1, name))

    emit(0xF3)  # di
    # Wait for vblank, then switch the LCD off so video memory can be written.
    label("boot_wait")
    emit(0xF0, 0x44, 0xFE, 144)  # ldh a,(LY); cp 144
    rel(0x38, "boot_wait")  # jr c
    emit(0xAF, 0xE0, 0x40)  # xor a; ldh (LCDC),a
    # Tile 1 = solid colour 3.
    emit(0x21, 0x10, 0x80, 0x06, 16, 0x3E, 0xFF)  # ld hl,8010; ld b,16; ld a,FF
    label("tile_fill")
    emit(0x22, 0x05)  # ld (hl+),a; dec b
    rel(0x20, "tile_fill")  # jr nz
    # Tile map: a checkerboard of tile 0 and 1, so scrolling in either direction is visible.
    emit(0x21, 0x00, 0x98, 0x01, 0x00, 0x04)  # ld hl,9800; ld bc,1024
    label("map_fill")
    # ld a,l; ld e,a; and 20; swap a; rrca; xor e; and 1  -> (column ^ row) & 1, then store and count down
    emit(0x7D, 0x5F, 0xE6, 0x20, 0xCB, 0x37, 0x0F, 0xAB, 0xE6, 0x01, 0x22, 0x0B, 0x78, 0xB1)
    rel(0x20, "map_fill")
    emit(0x3E, 0xE4, 0xE0, 0x47)  # BGP = E4
    emit(0x3E, 0x91, 0xE0, 0x40)  # LCDC = LCD on, BG on, unsigned tile data
    emit(0x16, 0x00, 0x26, 0x00)  # ld d,0 (scroll counter); ld h,0 (Start latch)

    label("frame")
    emit(0xF0, 0x44, 0xFE, 144)  # wait for line 144
    rel(0x20, "frame")  # jr nz
    emit(0x14, 0x7A, 0xE0, 0x43)  # inc d; ld a,d; ldh (SCX),a
    # Buttons (A/B/Select/Start): P1 bit 5 low selects them.
    emit(0x3E, 0x10, 0xE0, 0x00)  # ldh (P1),a with bit5 low -> buttons
    emit(0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00)  # settle
    emit(0x2F, 0xE6, 0x0F, 0x5F)  # cpl; and 0F; ld e,a
    # Start (bit 3) is latched: once pressed it stays on, so a quick key tap is still visible in a later screenshot.
    emit(0xE6, 0x08, 0xB4, 0x67, 0x7B)  # and 08; or h; ld h,a; ld a,e
    emit(0xCB, 0x37, 0xB3, 0xEE, 0xE4)  # swap a; or e; xor E4
    # Also flip the lowest palette bit every 128 frames (bit 7 of the frame counter), so the whole picture only
    # repeats every 256 frames. Without this, scrolling repeats every 16 frames and a save state loaded at the
    # wrong moment can look identical to the right one.
    emit(0x5F, 0x7A, 0x07, 0xE6, 0x01, 0xAB)  # ld e,a; ld a,d; rlca; and 1; xor e
    emit(0x5F, 0x7C, 0x87, 0x87, 0x87, 0xAB, 0xE0, 0x47)  # ld e,a; ld a,h; add a,a x3; xor e; ldh (BGP),a  (latched Start darkens black)
    # Direction pad: select it, then SCY = pressed bits * 8.
    emit(0x3E, 0x20, 0xE0, 0x00)
    emit(0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00)
    emit(0x2F, 0xE6, 0x0F, 0xCB, 0x27, 0xCB, 0x27, 0xCB, 0x27, 0xE0, 0x42)  # cpl; and 0F; sla a x3; ldh (SCY),a
    label("leave_line")
    emit(0xF0, 0x44, 0xFE, 144)
    rel(0x28, "leave_line")  # jr z (wait until we are past line 144)
    rel(0x18, "frame")  # jr

    for pos, name in fixups:
        off = labels[name] - (pos + 1)
        assert -128 <= off <= 127, (name, off)
        code[pos] = off & 0xFF
    return bytes(code)


def build():
    rom = bytearray(0x8000)
    rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])  # nop; jp 0150
    rom[0x104:0x104 + len(LOGO)] = LOGO
    title = b"OETESTROM"
    rom[0x134:0x134 + len(title)] = title
    rom[0x143] = 0x00  # no Game Boy Color features
    rom[0x147] = 0x00  # ROM only
    rom[0x148] = 0x00  # 32 KB
    rom[0x149] = 0x00  # no RAM
    x = 0
    for b in rom[0x134:0x14D]:
        x = (x - b - 1) & 0xFF
    rom[0x14D] = x
    code = assemble()
    rom[0x150:0x150 + len(code)] = code
    return bytes(rom)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "wb") as f:
        f.write(build())
