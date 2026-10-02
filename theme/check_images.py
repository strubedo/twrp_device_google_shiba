#!/usr/bin/env python3
"""check_images.py - are theme/graphite/images/*.png up to date with mkimages.py?

The build bakes the PNGs as they are; it doesn't run mkimages.py (that needs
cairosvg, from ~/.venvs/twrp-theme). If mkimages.py changes an image's size and
nobody re-runs it, the theme ships stale images (2026-10-02: chip text moved,
chip backgrounds didn't). Compares every declared "name": (w, h, ...) in
mkimages.py with the PNG's real size (IHDR). Stdlib only. Exit 1 on mismatch.
"""
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "mkimages.py"), encoding="utf-8").read()
# sizes are numbers or module-level integer constants (the tiles use TILE)
consts = {m.group(1): int(m.group(2)) for m in re.finditer(r'^([A-Z_][A-Z0-9_]*)\s*=\s*(\d+)\b', src, re.M)}
val = lambda t: int(t) if t.isdigit() else consts.get(t)
declared = {}
for m in re.finditer(r'^\s*"(\w+)":\s*\(\s*(\w+),\s*(\w+),', src, re.M):
    w, h = val(m.group(2)), val(m.group(3))
    if w is None or h is None:
        print("  check_images: can't resolve the size of %s (%s, %s)" % (m.group(1), m.group(2), m.group(3)))
        sys.exit(1)
    declared[m.group(1)] = (w, h)
bad = []
for name, (w, h) in sorted(declared.items()):
    p = os.path.join(HERE, "graphite", "images", name + ".png")
    try:
        with open(p, "rb") as f:
            head = f.read(24)
    except OSError:
        bad.append("%s: missing" % name)
        continue
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        bad.append("%s: not a PNG" % name)
        continue
    pw, ph = struct.unpack(">II", head[16:24])
    if (pw, ph) != (w, h):
        bad.append("%s: %dx%d, mkimages.py says %dx%d" % (name, pw, ph, w, h))
for b in bad:
    print("  stale image " + b)
if bad:
    print("  -> run: ~/.venvs/twrp-theme/bin/python theme/mkimages.py")
sys.exit(1 if bad else 0)
