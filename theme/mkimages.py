#!/usr/bin/env python3
"""Graphite stage 2: draw TWRP's theme images in the Graphite style.

Every image keeps the stock canvas size AND visible area (measured from
base/images), so no layout moves - only how things look.

TWRP renders this 1080x1920 theme at 1.0x width, 1.25x height (1080x2400
screen). Images WITHOUT retainaspect in ui.xml (buttons, slider, progress) are
stretched vertically, so their shapes are drawn 1.25x shorter to come out true.
Images WITH retainaspect="1" (icons, toggles) are scaled uniformly - drawn as-is.

  ~/.venvs/twrp-theme/bin/python mkimages.py   -> graphite/images/*.png
"""
import os

import cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "graphite", "images")
STRETCH = 1.25                  # vertical stretch TWRP applies to non-retainaspect images
VS = STRETCH                    # set per image by main(): STRETCH or 1.0

ACCENT = "#0090CA"              # TWRP blue
SURFACE = "#121212"             # tiles / buttons
TRACK = "#1A1A1A"               # slider + progress track
ICON = "#CFCFCF"                # nav icons
OUTLINE = "#6E6E6E"             # unchecked controls (visible on black)
INK = "#000000"                 # marks drawn on the accent


def svg(w, h, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}">{body}</svg>')


def rrect(x0, y0, x1, y1, r, fill):
    """Rounded rect whose corners look circular after the vertical stretch."""
    return (f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" '
            f'rx="{r}" ry="{r / VS:.2f}" fill="{fill}"/>')


def icon(w, h, cx, cy, size, paths, stroke, sw=2.0):
    """24x24 line icon (mockup paths) centred at cx,cy, `size` px wide on screen."""
    sx, sy = size / 24.0, size / 24.0 / VS
    tx, ty = cx - size / 2, cy - size / VS / 2
    return (f'<g transform="translate({tx:.2f},{ty:.2f}) scale({sx:.4f},{sy:.4f})" '
            f'fill="none" stroke="{stroke}" stroke-width="{sw}" '
            f'stroke-linecap="round" stroke-linejoin="round">{paths}</g>')


def ellipse(cx, cy, r, stroke=None, fill="none", sw=4):
    """Circle that looks round on screen (uses the current VS)."""
    s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    return f'<ellipse cx="{cx}" cy="{cy}" rx="{r}" ry="{r / VS:.2f}" fill="{fill}"{s}/>'


def outline_box(x0, y0, x1, y1, r, stroke, sw=4):
    h = (y1 - y0) / VS
    y = y0 + ((y1 - y0) - h) / 2
    return (f'<rect x="{x0}" y="{y:.2f}" width="{x1 - x0}" height="{h:.2f}" rx="{r}" '
            f'ry="{r / VS:.2f}" fill="none" stroke="{stroke}" stroke-width="{sw}"/>')


# Mockup icon paths (24x24 viewBox)
P_BACK = '<path d="M15 18l-6-6 6-6"/>'
P_HOME = '<path d="M4 11l8-7 8 7v9H4z"/>'
P_CONSOLE = '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M7 10l3 2-3 2M12 15h5"/>'
P_CHECK = '<path d="M5 12l5 5 9-10"/>'
P_ARROW = '<path d="M5 12h14M13 6l6 6-6 6"/>'
P_FOLDER = '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'
P_FILE = '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/>'
# main-menu tiles (Home mockup)
P_INSTALL = '<path d="M12 3v12m0 0l-5-5m5 5l5-5M4 21h16"/>'
P_WIPE = '<path d="M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14"/>'
P_BACKUP = '<path d="M3 5h18v5H3zM5 10v10h14V10M10 14h4"/>'
P_RESTORE = '<path d="M4 12a8 8 0 1 0 2.5-5.8M4 4v5h5"/>'
P_MOUNT = '<rect x="3" y="6" width="18" height="12" rx="3"/><path d="M7 14h.01M11 14h6"/>'
P_SETTINGS = '<path d="M4 7h9M18 7h2M4 17h4M12 17h8"/><circle cx="15.5" cy="7" r="2.5"/><circle cx="9.5" cy="17" r="2.5"/>'
P_ADVANCED = '<path d="M4 17l6-6-6-6M12 19h8"/>'
P_REBOOT = '<path d="M12 3v9M6.3 6.3a8 8 0 1 0 11.4 0"/>'
WARN = "#F2A25C"
TILE = 96                       # tile icon canvas (retainaspect, declared by mktheme)
P_BKSP = '<path d="M21 5H9l-6 7 6 7h12z"/><path d="M16 10l-4 4M12 10l4 4"/>'
P_LOCK = '<rect x="4" y="10" width="16" height="11" rx="3"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>'
TEXT = "#EDEDED"


def pin_keypad():
    """Keyboard image for the PIN page (keyboardnum template, 1080x644).

    Geometry mirrors keyboard.cpp for layout1: rows of 160, a 225 spacer then
    three 212-wide keys; DrawKey insets each key by keymargin (8,8). With an
    image layout the keyboard draws no labels, so digits/icons are drawn here.
    """
    body, fs = [], 64
    keys = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["bksp", "0", "enter"]]
    for r, row in enumerate(keys):
        for c, k in enumerate(row):
            x0, y0 = 225 + c * 212 + 8, r * 160 + 8
            x1, y1 = x0 + 196, y0 + 144
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
            if k == "bksp":
                body.append(icon(1080, 644, cx, cy, 68, P_BKSP, ICON, 2.0))
            elif k == "enter":
                body.append(rrect(x0, y0, x1, y1, 40, ACCENT))
                body.append(icon(1080, 644, cx, cy, 64, P_CHECK, INK, 2.6))
            else:
                body.append(rrect(x0, y0, x1, y1, 40, SURFACE))
                # text squashed by 1/VS so it reads true after TWRP's stretch
                body.append(f'<g transform="translate({cx},{cy}) scale(1,{1 / VS:.4f})">'
                            f'<text x="0" y="{fs * 0.36:.1f}" text-anchor="middle" '
                            f'font-family="Space Grotesk" font-weight="500" font-size="{fs}" '
                            f'fill="{TEXT}">{k}</text></g>')
    return "".join(body)

# name: (w, h, body builder). Builders run with VS set for that image.
IMAGES = {
    # buttons: charcoal rounded tiles in the stock visible box
    "main_button":                        (504, 288,  lambda: rrect(36, 32, 468, 256, 44, SURFACE)),
    "main_button_accent":                 (504, 288,  lambda: rrect(36, 32, 468, 256, 44, ACCENT)),
    "main_button_half_height":            (504, 192,  lambda: rrect(36, 32, 468, 160, 36, SURFACE)),
    "main_button_half_height_full_width": (1008, 192, lambda: rrect(36, 32, 972, 160, 36, SURFACE)),
    # bottom navigation bar
    "back":    (265, 128, lambda: icon(265, 128, 132.5, 64, 56, P_BACK, ICON)),
    "home":    (265, 128, lambda: icon(265, 128, 132.5, 64, 56, P_HOME, ICON)),
    "console": (265, 128, lambda: icon(265, 128, 132.5, 64, 56, P_CONSOLE, ICON)),
    # toggles (stock visible box 0,21 - 54,75)
    "checkbox_true":  (72, 96, lambda: rrect(2, 23, 52, 73, 12, ACCENT) + icon(72, 96, 27, 48, 40, P_CHECK, INK, 3.0)),
    "checkbox_false": (72, 96, lambda: outline_box(4, 25, 50, 71, 10, OUTLINE)),
    "radio_true":     (72, 96, lambda: ellipse(27, 48, 25, ACCENT) + ellipse(27, 48, 13, fill=ACCENT)),
    "radio_false":    (72, 96, lambda: ellipse(27, 48, 25, OUTLINE)),
    # swipe-to-confirm (stock visible 0,32 - W,160)
    "slider":       (936, 192, lambda: rrect(0, 32, 936, 160, 64, TRACK)),
    "slider_used":  (936, 192, lambda: rrect(0, 32, 936, 160, 64, "#0B3A4E")),
    "slider_touch": (288, 192, lambda: rrect(8, 40, 280, 152, 56, ACCENT) + icon(288, 192, 144, 96, 64, P_ARROW, INK, 2.5)),
    # progress bars: slim pill track + fill
    "progress_empty": (1008, 64, lambda: rrect(0, 20, 1008, 44, 12, TRACK)),
    "progress_fill":  (1008, 64, lambda: rrect(0, 20, 1008, 44, 12, ACCENT)),
    # file browser
    "folder": (72, 96, lambda: icon(72, 96, 27, 48, 52, P_FOLDER, ACCENT, 2.0)),
    "file":   (72, 96, lambda: icon(72, 96, 27, 48, 52, P_FILE, ICON, 2.0)),
    # NEW: main-menu tile icons (not in stock; mktheme declares them retainaspect)
    "tile_install":  (TILE, TILE, lambda: icon(TILE, TILE, 48, 48, 84, P_INSTALL, ACCENT, 2.0)),
    "tile_install_dark": (TILE, TILE, lambda: icon(TILE, TILE, 48, 48, 84, P_INSTALL, INK, 2.2)),
    "tile_wipe":     (TILE, TILE, lambda: icon(TILE, TILE, 48, 48, 84, P_WIPE, WARN, 2.0)),
    "tile_backup":   (TILE, TILE, lambda: icon(TILE, TILE, 48, 48, 84, P_BACKUP, ACCENT, 2.0)),
    "tile_restore":  (TILE, TILE, lambda: icon(TILE, TILE, 48, 48, 84, P_RESTORE, ACCENT, 2.0)),
    "tile_mount":    (TILE, TILE, lambda: icon(TILE, TILE, 48, 48, 84, P_MOUNT, ACCENT, 2.0)),
    "tile_settings": (TILE, TILE, lambda: icon(TILE, TILE, 48, 48, 84, P_SETTINGS, ACCENT, 2.0)),
    "tile_advanced": (TILE, TILE, lambda: icon(TILE, TILE, 48, 48, 84, P_ADVANCED, ACCENT, 2.0)),
    "tile_reboot":   (TILE, TILE, lambda: icon(TILE, TILE, 48, 48, 84, P_REBOOT, ACCENT, 2.0)),
    # NEW: PIN page (mktheme declares pin_keypad stretched, pin_lock retainaspect)
    "pin_keypad": (1080, 644, pin_keypad),
    "pin_lock":   (176, 176, lambda: rrect(8, 8, 168, 168, 56, TRACK) + icon(176, 176, 88, 88, 84, P_LOCK, ACCENT, 2.0)),
    # NEW: frame - rounded bar behind the back/home/console buttons (navbar 1080x130)
    "navbar_bg":  (1080, 130, lambda: rrect(36, 10, 1044, 120, 48, SURFACE)),
    # NEW: main-page chips (retainaspect; text drawn over them by the theme).
    # Widths = measured IBM Plex Sans 33 text + 28 padding each side (+ 12 dot + 12 gap).
    "chip_slot":      (270, 64, lambda: rrect(0, 0, 270, 64, 32, TRACK)),
    "chip_decrypted": (310, 64, lambda: rrect(0, 0, 310, 64, 32, TRACK) + ellipse(34, 32, 6, fill=ACCENT)),
    "chip_locked":    (256, 64, lambda: rrect(0, 0, 256, 64, 32, TRACK) + ellipse(34, 32, 6, fill=WARN)),
    "chip_plain":     (320, 64, lambda: rrect(0, 0, 320, 64, 32, TRACK)),
    # root chip (tw_root_state): measured Plex Sans 33 KernelSU 138, Magisk 104, Not rooted 159
    "chip_ksu":       (220, 64, lambda: rrect(0, 0, 220, 64, 32, TRACK) + ellipse(34, 32, 6, fill=ACCENT)),
    "chip_magisk":    (186, 64, lambda: rrect(0, 0, 186, 64, 32, TRACK) + ellipse(34, 32, 6, fill=ACCENT)),
    "chip_noroot":    (216, 64, lambda: rrect(0, 0, 216, 64, 32, TRACK)),
    # splash (replaces TeamWin's art; splash.xml declares both retainaspect)
    "splashlogo":    (500, 500, lambda: (
        '<text x="232" y="305" text-anchor="middle" font-family="Space Grotesk" '
        f'font-weight="600" font-size="168" letter-spacing="-4" fill="{TEXT}">TWRP</text>'
        f'<circle cx="452" cy="294" r="17" fill="{ACCENT}"/>')),
    "splashteamwin": (708, 96, lambda: (
        '<text x="354" y="62" text-anchor="middle" font-family="IBM Plex Sans" '
        f'font-weight="500" font-size="40" letter-spacing="8" fill="#A1A1A1">PIXEL 8 · SHIBA</text>')),
}
NEW_IMAGES = [n for n in IMAGES if n.startswith(("tile_", "pin_"))]


def stretched_images():
    """Image files TWRP stretches: declared in base/ui.xml WITHOUT retainaspect."""
    import re
    xml = open(os.path.join(HERE, "base", "ui.xml"), encoding="utf-8").read()
    out = set()
    for m in re.finditer(r'<image name="[^"]+" filename="([^"]+)"([^/]*)/>', xml):
        if 'retainaspect="1"' not in m.group(2):
            out.add(m.group(1))
    return out


def main():
    global VS
    os.makedirs(OUT, exist_ok=True)
    stretched = stretched_images() | {"pin_keypad", "navbar_bg", "main_button_accent"}   # declared without retainaspect by mktheme
    for name, (w, h, build) in IMAGES.items():
        VS = STRETCH if name in stretched else 1.0
        path = os.path.join(OUT, f"{name}.png")
        cairosvg.svg2png(bytestring=svg(w, h, build()).encode(), write_to=path,
                         output_width=w, output_height=h)
    print(f"  wrote {len(IMAGES)} images to {os.path.relpath(OUT, HERE)}/ "
          f"(stretch-compensated: {', '.join(sorted(n for n in IMAGES if n in stretched))})")


if __name__ == "__main__":
    main()
