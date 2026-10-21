"""devices.py - the phones in twrp_devices.conf, for the theme build.

mkimages.py draws, and mktheme.py places, one slot chip ("Pixel 8 · Slot a")
and one splash line ("PIXEL 8 · SHIBA") per row; TWRP shows the one matching
tw_device (data.cpp, from androidboot.hardware). Text widths are the IBM Plex
Sans 33 advances in twrp_root.sh (KW_WIDTHS, characters ! .. ~), the table the
kernel chip uses too.
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SYSTEM = os.path.join(HERE, "..", "recovery", "root", "system")
CONF = os.path.join(SYSTEM, "etc", "twrp_devices.conf")
ROOT_SH = os.path.join(SYSTEM, "bin", "twrp_root.sh")

# The Pixel 8 chip (270, measured for "Pixel 8 · Slot a") is the reference:
# other models change it by their name's width difference, so the Pixel 8's
# main page stays pixel-identical. A phone without a row gets this chip too.
SLOT_CHIP_MODEL = "Pixel 8"
SLOT_CHIP_WIDTH = 270


def fail(msg):
    raise SystemExit(f"devices.py: {msg}")


def rows():
    """[(codename, model)] in file order."""
    out = []
    with open(CONF, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split("|")
            if len(fields) != 3 or not re.fullmatch(r"[a-z0-9_]+", fields[0]) or not fields[1].isascii():
                fail(f"bad row in twrp_devices.conf: {line!r}")
            out.append((fields[0], fields[1]))
    if not out:
        fail("no rows in twrp_devices.conf")
    return out


def _advances():
    with open(ROOT_SH, encoding="utf-8") as f:
        m = re.search(r'^KW_WIDTHS="([0-9 ]+)"', f.read(), re.M)
    widths = [int(x) for x in m.group(1).split()] if m else []
    if len(widths) != 126 - 33 + 1:
        fail("KW_WIDTHS in twrp_root.sh: expected 94 widths (! .. ~)")
    return {chr(33 + i): w for i, w in enumerate(widths)}


ADVANCES = _advances()


def text_width(s):
    """Width of ASCII text in IBM Plex Sans 33 (space 8, as twrp_root.sh)."""
    if not s.isascii():
        fail(f"text_width: ASCII only: {s!r}")
    return sum(8 if c == " " else ADVANCES[c] for c in s)


def slot_chip_width(model):
    return SLOT_CHIP_WIDTH + text_width(model) - text_width(SLOT_CHIP_MODEL)
