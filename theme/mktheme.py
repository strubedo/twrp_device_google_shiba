#!/usr/bin/env python3
"""Graphite theme for TWRP (Pixel 8 / shiba) - one source, two outputs.

  base/       pristine stock theme as built (snapshot of out/.../twres)
  graphite/   our additions (fonts now; images/layouts in later stages)

  ./mktheme.py          -> dist/graphite-theme.zip   (flash in TWRP to test;
                           TWRP stores it as Internal Storage/TWRP/theme/ui.zip
                           and loads it after decryption)
  ./mktheme.py --bake   -> also writes the changed files into
                           recovery/root/twres/ so the next build has Graphite
                           built in (PIN screen included)
  ./mktheme.py --unbake -> removes those files again (back to stock built-in)

Every change is an exact, counted substitution: if the stock theme ever
changes under us, this stops with an error instead of half-theming.
"""
import os
import re
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(HERE, "base")
GRAPHITE = os.path.join(HERE, "graphite")
DIST = os.path.join(HERE, "dist")
BAKE_DIR = os.path.join(HERE, "..", "recovery", "root", "twres")
BAKE_LIST = os.path.join(HERE, ".baked")

# --- Stage 1: palette + fonts ------------------------------------------------
VARIABLES = {                       # ui.xml <variable name=... value=...>
    "background_color":             ("#1A1A1A",   "#000000"),    # black matte (OLED off)
    "highlight_color":              ("#1A1A1A80", "#24242480"),  # pressed state
    "caps_highlight_color":         ("#22222280", "#24242480"),
    "fileselector_linecolor":       ("#555555",   "#222222"),
    "fileselector_highlight_color": ("#555555",   "#242424"),
    "text_color":                   ("#EEEEEE",   "#EDEDED"),
    "text_button_color":            ("#EEEEEE",   "#EDEDED"),
    "warning":                      ("#F8F8A0",   "#F2A25C"),    # Graphite warm orange
    "error":                        ("#FF0101",   "#FF5A5A"),    # softer red on black
    "text_fail_color":              ("#FF0101",   "#FF5A5A"),
    "text_success_color":           ("#76FF03",   "#7EE787"),
    # accent_color / highlight stay #0090CA - TWRP blue
}

FONTS = {                           # name: (new file, new size) - Plex is wider than Roboto Condensed
    "font_l":             ("SpaceGrotesk-SemiBold.ttf", 50),
    "font_m":             ("IBMPlexSans-Regular.ttf",   38),
    "font_s":             ("IBMPlexSans-Regular.ttf",   33),
    "fixed":              ("IBMPlexMono-Regular.ttf",   28),
    "keylabel":           ("IBMPlexSans-Medium.ttf",    58),
    "keylabel-small":     ("IBMPlexSans-Medium.ttf",    42),
    "keylabel-longpress": ("IBMPlexSans-Regular.ttf",   30),
}

LITERALS = [                        # (regex, replacement, expected count)
    (r'<background color="#111111"/>', '<background color="#000000"/>', 3),        # keyboard board
    (r'(<key-(?:alphanumeric|other) color=")#111111', r'\g<1>#121212', 6),        # keys = charcoal tiles
    (r'textcolor="#5b5b5bff"', 'textcolor="#A1A1A1FF"', 6),                          # secondary key labels: 2.7:1 -> readable
    (r'textcolor="#EEEEEE"', 'textcolor="#EDEDED"', 3),
    (r'<title>[^<]*</title>', '<title>Graphite</title>', 1),
    (r'<description>[^<]*</description>', '<description>Black matte + TWRP blue, Pixel 8 (shiba)</description>', 1),
]


def fail(msg):
    sys.exit(f"mktheme: {msg}")


def build_ui_xml():
    xml = open(os.path.join(BASE, "ui.xml"), encoding="utf-8").read()
    for name, (old, new) in VARIABLES.items():
        pat = f'<variable name="{name}" value="{old}"/>'
        if xml.count(pat) != 1:
            fail(f'expected 1x {pat} in base ui.xml, found {xml.count(pat)}')
        xml = xml.replace(pat, f'<variable name="{name}" value="{new}"/>')
    for name, (fname, size) in FONTS.items():
        pat = re.compile(rf'<font name="{re.escape(name)}" filename="[^"]*" size="\d+"/>')
        if len(pat.findall(xml)) != 1:
            fail(f'expected 1 font "{name}" in base ui.xml')
        if not os.path.exists(os.path.join(GRAPHITE, "fonts", fname)):
            fail(f"missing graphite/fonts/{fname}")
        xml = pat.sub(f'<font name="{name}" filename="{fname}" size="{size}"/>', xml)
    for rx, repl, n in LITERALS:
        found = len(re.findall(rx, xml))
        if found != n:
            fail(f"expected {n}x /{rx}/ in base ui.xml, found {found}")
        xml = re.sub(rx, repl, xml)
    return xml


def changed_files(ui_xml):
    """{relative path in twres: bytes} for everything Graphite adds or changes."""
    out = {"ui.xml": ui_xml.encode("utf-8")}
    for f in sorted(os.listdir(os.path.join(GRAPHITE, "fonts"))):
        out[f"fonts/{f}"] = open(os.path.join(GRAPHITE, "fonts", f), "rb").read()
    return out


def write_zip(changes):
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, "graphite-theme.zip")
    files = {}
    for root, _, names in os.walk(BASE):          # full stock theme ...
        for n in names:
            p = os.path.join(root, n)
            files[os.path.relpath(p, BASE)] = open(p, "rb").read()
    files.update(changes)                          # ... with Graphite on top
    with zipfile.ZipFile(out, "w") as z:
        for rel in sorted(files):
            info = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, files[rel])
    print(f"  wrote {os.path.relpath(out, HERE)} ({os.path.getsize(out) // 1024} KB, {len(files)} files)")


def unbake():
    if os.path.exists(BAKE_LIST):
        for rel in open(BAKE_LIST).read().split():
            p = os.path.join(BAKE_DIR, rel)
            if os.path.exists(p):
                os.remove(p)
        os.remove(BAKE_LIST)
    for d in (os.path.join(BAKE_DIR, "fonts"), BAKE_DIR):   # remove empty dirs we made
        if os.path.isdir(d) and not os.listdir(d):
            os.rmdir(d)


def bake(changes):
    unbake()
    for rel, data in changes.items():
        p = os.path.join(BAKE_DIR, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(data)
    open(BAKE_LIST, "w").write("\n".join(sorted(changes)) + "\n")
    print(f"  baked {len(changes)} files into recovery/root/twres/ (next build has Graphite built in)")


def main():
    if "--unbake" in sys.argv:
        unbake()
        print("  unbaked: next build uses the stock built-in theme")
        return
    changes = changed_files(build_ui_xml())
    write_zip(changes)
    if "--bake" in sys.argv:
        bake(changes)


if __name__ == "__main__":
    main()
