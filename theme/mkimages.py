#!/usr/bin/env python3
"""Graphite stage 2: draw TWRP's theme images in the Graphite style.

Every image keeps the stock canvas size AND visible area (measured from
base/images), so no layout moves - only how things look.

TWRP renders this 1080x1920 theme at 1.0x width, 1.25x height (1080x2400
screen), stretching every image vertically. Shapes here are drawn 1.25x
shorter (VS) so corners, circles and icons come out true on screen.

  ~/.venvs/twrp-theme/bin/python mkimages.py   -> graphite/images/*.png
"""
import os

import cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "graphite", "images")
VS = 1.25                       # vertical stretch applied by TWRP at runtime

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


# Mockup icon paths (24x24 viewBox)
P_BACK = '<path d="M15 18l-6-6 6-6"/>'
P_HOME = '<path d="M4 11l8-7 8 7v9H4z"/>'
P_CONSOLE = '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M7 10l3 2-3 2M12 15h5"/>'
P_CHECK = '<path d="M5 12l5 5 9-10"/>'
P_ARROW = '<path d="M5 12h14M13 6l6 6-6 6"/>'
P_FOLDER = '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'
P_FILE = '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/>'

IMAGES = {
    # buttons: charcoal rounded tiles in the stock visible box
    "main_button":                        (504, 288,  rrect(36, 32, 468, 256, 44, SURFACE)),
    "main_button_half_height":            (504, 192,  rrect(36, 32, 468, 160, 36, SURFACE)),
    "main_button_half_height_full_width": (1008, 192, rrect(36, 32, 972, 160, 36, SURFACE)),
    # bottom navigation bar
    "back":    (265, 128, icon(265, 128, 132.5, 64, 56, P_BACK, ICON)),
    "home":    (265, 128, icon(265, 128, 132.5, 64, 56, P_HOME, ICON)),
    "console": (265, 128, icon(265, 128, 132.5, 64, 56, P_CONSOLE, ICON)),
    # toggles (stock visible box 0,21 - 54,75)
    "checkbox_true":  (72, 96, rrect(2, 27, 52, 69, 12, ACCENT) + icon(72, 96, 27, 48, 40, P_CHECK, INK, 3.0)),
    "checkbox_false": (72, 96, f'<rect x="4" y="28.6" width="46" height="{38.8:.1f}" rx="10" ry="8" '
                               f'fill="none" stroke="{OUTLINE}" stroke-width="4"/>'),
    "radio_true":     (72, 96, f'<ellipse cx="27" cy="48" rx="25" ry="20" fill="none" stroke="{ACCENT}" stroke-width="4"/>'
                               f'<ellipse cx="27" cy="48" rx="13" ry="10.4" fill="{ACCENT}"/>'),
    "radio_false":    (72, 96, f'<ellipse cx="27" cy="48" rx="25" ry="20" fill="none" stroke="{OUTLINE}" stroke-width="4"/>'),
    # swipe-to-confirm (stock visible 0,32 - W,160)
    "slider":       (936, 192, rrect(0, 32, 936, 160, 64, TRACK)),
    "slider_used":  (936, 192, rrect(0, 32, 936, 160, 64, "#0B3A4E")),
    "slider_touch": (288, 192, rrect(8, 40, 280, 152, 56, ACCENT) + icon(288, 192, 144, 96, 64, P_ARROW, INK, 2.5)),
    # progress bars: slim pill track + fill
    "progress_empty": (1008, 64, rrect(0, 20, 1008, 44, 12, TRACK)),
    "progress_fill":  (1008, 64, rrect(0, 20, 1008, 44, 12, ACCENT)),
    # file browser
    "folder": (72, 96, icon(72, 96, 27, 48, 52, P_FOLDER, ACCENT, 2.0)),
    "file":   (72, 96, icon(72, 96, 27, 48, 52, P_FILE, ICON, 2.0)),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, (w, h, body) in IMAGES.items():
        path = os.path.join(OUT, f"{name}.png")
        cairosvg.svg2png(bytestring=svg(w, h, body).encode(), write_to=path,
                         output_width=w, output_height=h)
    print(f"  wrote {len(IMAGES)} images to {os.path.relpath(OUT, HERE)}/")


if __name__ == "__main__":
    main()
