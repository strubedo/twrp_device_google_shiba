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
# portrait.xml is read from TWRP's source every time (the build copies it
# byte-for-byte), so baking it can never undo later menu changes.
SRC_PORTRAIT = os.path.join(HERE, "..", "..", "..", "..", "bootable", "recovery",
                            "gui", "theme", "common", "portrait.xml")

# --- Stage 2b: main-menu tile icons -----------------------------------------
# button label (string id) -> icon image drawn by mkimages.py. Button.cpp puts
# the icon above the centred label when both fit.
TILE_ICONS = {
    "install_btn": "tile_install_dark", "wipe_btn": "tile_wipe",
    "backup_btn": "tile_backup", "restore_btn": "tile_restore",
    "mount_btn": "tile_mount", "settings_btn": "tile_settings",
    "advanced_btn": "tile_advanced", "reboot_btn": "tile_reboot",
}

# --- Stage 2c: PIN page -------------------------------------------------------
# pin_keypad replaces the numeric keyboard's drawn keys (keyboard.cpp blits a
# layout image and skips DrawKey - taps/backspace/enter still work, labels are
# in the image). Stretched like any non-retainaspect image.
PIN_IMAGES = {"pin_keypad": False, "pin_lock": True}     # name: retainaspect
FRAME_IMAGES = {"navbar_bg": False, "chip_slot": True, "chip_decrypted": True,
                "chip_locked": True, "chip_plain": True,
                "chip_ksu": True, "chip_magisk": True, "chip_noroot": True,
                "main_button_accent": False}             # Install = primary (blue) tile
NEW_IMAGES = set(TILE_ICONS.values()) | set(PIN_IMAGES) | set(FRAME_IMAGES) | {"tile_install"}
# primary tile style: blue image, black label (button parts resolve node-first,
# then style - pages.cpp FindNode - so only the Install button uses it)
ACCENT_STYLE = '''
		<style name="main_button_accent">
			<highlight color="%highlight_color%"/>
			<font resource="font_l" color="#000000"/>
			<image resource="main_button_accent"/>
		</style>
'''
MUTED = "#A1A1A1"

# --- Stage 3: lists (engine support: scrolllist.cpp <itemcard>, listbox.cpp header="1")
# Every list style gets rounded row cards; the separator becomes the gap.
LIST_STYLES = ["fileselector", "listbox", "advanced_listbox", "options_listbox",
               "partitionlist", "partitionlist_storage"]
CARD = ('<itemcard color="#121212" selectedcolor="#242424" radius="28" padx="24" headercolor="#A1A1A1"/>'
        '\n\t\t\t<separator color="%background_color%" height="14"/>')
# Advanced (and Reboot) lists: grouped sections - rows share one card, split by
# thin dividers; only a group's ends are rounded (listbox.cpp); small headers.
CARD_GROUPED = ('<itemcard color="#121212" selectedcolor="#242424" radius="28" padx="24" '
                'headercolor="#A1A1A1" headerfont="font_s"/>'
                '\n\t\t\t<separator color="%background_color%" height="2"/>')
# Advanced page: (existing item name, new name or None, header before it or None, subtitle or None)
ADV_ITEMS = [
    ('Root: Show status', 'Show status', "ROOT", None),
    ('Root: Install KernelSU', 'Install KernelSU', None, None),
    ('Root: Install Magisk', 'Install Magisk', None, None),
    ('Root: Remove root', 'Remove root', None, None),
    ('TWRP: Install to other slot', 'Install to other slot', "KEEP TWRP", "After an update"),
    ('TWRP: Install to both slots', 'Install to both slots', None, None),
    ('Encryption: Status', 'Status', "ENCRYPTION", None),
    ('Encryption: Dry run (no changes)', 'Dry run (no changes)', None, None),
    ('Encryption: Disable (formats data)', 'Disable encryption', None, "Formats data \u00b7 type yes to confirm"),
    ('Encryption: Re-enable (formats data)', 'Re-enable encryption', None, "Formats data \u00b7 type yes to confirm"),
    ('{@reload_theme_btn=Reload Theme}', None, "TOOLS", None),
]
# stock items that sat above ROOT - moved into TOOLS (mockup has no GENERAL)
ADV_MOVE_TO_TOOLS = ['Enable USB debugging',
                     '{@change_twrp_folder_btn=Change TWRP folder}', '{@decrypt_users=Decrypt Users}']
# Advanced page: the four stock buttons become TOOLS rows (same actions and
# conditions) and the list fills the page, like the mockup.
ADV_BUTTONS = [          # (label string, action page) - mockup order
    ("{@adb_sideload_btn=ADB Sideload}", "sideload"),
    ("{@file_manager_btn=File Manager}", "filemanagerlist"),
    ("{@terminal_btn=Terminal}", "terminalcommand"),
    ("{@copy_log_btn=Copy Log}", "copylog"),
]
ADV_LIST_PLACEMENT = '<placement x="%indent%" y="176" w="%content_width%" h="1600"/>'


def patch_lists(xml):
    for name in LIST_STYLES:
        s = xml.find(f'<style name="{name}">')
        e = xml.find("</style>", s)
        if s < 0 or e < 0:
            fail(f"list style {name} not found in portrait.xml")
        block = re.sub(r'\n\s*<separator [^>]*/>', '', xml[s:e])        # stock divider line out
        if name == "advanced_listbox":                                 # no row icon (mockup)
            if block.count('<icon selected="handle" unselected="handle"/>') != 1:
                fail("advanced_listbox: handle icon line not found")
            block = re.sub(r'\n\s*<icon selected="handle" unselected="handle"/>', '', block)
            # the handle icon set the row height; without it, set it via spacing
            fs = re.compile(r'(<font resource="font_m" spacing=")[^"]*(")')
            if len(fs.findall(block)) != 1:
                fail("advanced_listbox: font spacing not found")
            block = fs.sub(r'\g<1>72\g<2>', block)
        card = CARD_GROUPED if name == "advanced_listbox" else CARD
        block = block.rstrip() + "\n\t\t\t" + card + "\n\t\t"
        xml = xml[:s] + block + xml[e:]
    a = xml.find('<page name="advanced">')
    b = xml.find("</page>", a)
    page = xml[a:b]
    # the four buttons -> TOOLS rows (keep each button's conditions + action)
    tool_rows = ""
    for label, target in ADV_BUTTONS:
        bt = re.compile(r'\n\t*<button style="main_button">((?:\s*<condition[^>]*/>)*)\s*<placement[^>]*/>\s*'
                        r'<text>' + re.escape(label) + r'</text>\s*<action function="page">'
                        + re.escape(target) + r'</action>\s*</button>\n')
        found = bt.findall(page)
        if len(found) != 1:
            fail(f"advanced page: expected one {label} button")
        conds = found[0].strip()
        tool_rows += (f'<listitem name="{label}">' + (conds + "" if conds else "")
                      + f'<action function="page">{target}</action></listitem>')
        page = bt.sub("\n", page)
    lp = re.compile(r'(<listbox style="advanced_listbox">\s*)<placement[^>]*/>')
    if len(lp.findall(page)) != 1:
        fail("advanced page: listbox placement not found")
    page = lp.sub(lambda m: m.group(1) + ADV_LIST_PLACEMENT, page)
    # stock items above ROOT -> end of the TOOLS rows (whole blocks, conditions kept)
    for label in ADV_MOVE_TO_TOOLS:
        blk = re.compile(r'\n\t*<listitem name="' + re.escape(label) + r'">.*?</listitem>', re.S)
        found = blk.findall(page)
        if len(found) != 1:
            fail(f"advanced page: expected one listitem '{label}'")
        tool_rows += found[0].strip()
        page = blk.sub("", page)
    for old, new, header, subtitle in ADV_ITEMS:
        pat = re.compile(r'(\n(\t+))<listitem name="' + re.escape(old) + '">')
        if len(pat.findall(page)) != 1:
            fail(f"advanced page: expected one listitem '{old}'")
        def repl(m, new=new, header=header, old=old, subtitle=subtitle):
            out = m.group(1)
            if header:
                out += f'<listitem name="{header}" header="1"></listitem>' + m.group(1)
            if header == "TOOLS":
                out += tool_rows + m.group(1)
            sub = f' subtitle="{subtitle}"' if subtitle else ""
            return out + f'<listitem name="{new or old}"{sub}>'
        page = pat.sub(repl, page)
    return xml[:a] + page + xml[b:]

# Main page header (mockup): big TWRP title + live chips. Chip widths/text x
# come from measured Plex Sans 33 text (see mkimages.py). TWRP clears
# tw_is_encrypted during a successful decrypt, so the data state keys off
# tw_is_fbe (data uses FBE at all; stays set) + tw_is_decrypted.
MAIN_HEADER = '''<text color="%text_color%">
				<font resource="font_xl"/>
				<placement x="36" y="84"/>
				<text>TWRP</text>
			</text>

			<image>
				<image resource="chip_slot"/>
				<placement x="36" y="196"/>
			</image>
			<text color="#CFCFCF">
				<font resource="font_s"/>
				<placement x="64" y="204"/>
				<text>Pixel 8 \u00b7 Slot %tw_active_slot%</text>
			</text>
''' + "".join(f'''
			<image>
				<conditions>{conds}</conditions>
				<image resource="{img}"/>
				<placement x="322" y="196"/>
			</image>
			<text color="#CFCFCF">
				<conditions>{conds}</conditions>
				<font resource="font_s"/>
				<placement x="{tx}" y="204"/>
				<text>{label}</text>
			</text>
''' for img, tx, label, conds in [
    ("chip_plain", 350, "Data unencrypted",
     '<condition var1="tw_is_fbe" var2="0"/>'),
    ("chip_decrypted", 374, "Data decrypted",
     '<condition var1="tw_is_fbe" var2="1"/><condition var1="tw_is_decrypted" var2="1"/>'),
    ("chip_locked", 374, "Data locked",
     '<condition var1="tw_is_fbe" var2="1"/><condition var1="tw_is_decrypted" var2="0"/>'),
])
MAIN_HEADER = MAIN_HEADER.replace("\\u00b7", "\u00b7")

# Root chip (tw_root_state, set by TWRP from twrp_root.sh status) after the
# data chip - whose width depends on its state, so one placement per pair.
_DATA_CHIPS = [   # data chip conditions, x where that chip ends (322 + width)
    ('<condition var1="tw_is_fbe" var2="0"/>', 322 + 320),
    ('<condition var1="tw_is_fbe" var2="1"/><condition var1="tw_is_decrypted" var2="1"/>', 322 + 310),
    ('<condition var1="tw_is_fbe" var2="1"/><condition var1="tw_is_decrypted" var2="0"/>', 322 + 256),
]
_ROOT_CHIPS = [   # image, label, text offset (after dot 52, plain 28), tw_root_state
    ("chip_ksu", "KernelSU", 52, "KERNELSU"),
    ("chip_magisk", "Magisk", 52, "MAGISK"),
    ("chip_noroot", "Not rooted", 28, "STOCK"),
]
for _dc, _end in _DATA_CHIPS:
    for _img, _label, _off, _val in _ROOT_CHIPS:
        _c = _dc + f'<condition var1="tw_root_state" var2="{_val}"/>'
        MAIN_HEADER += f'''
			<image>
				<conditions>{_c}</conditions>
				<image resource="{_img}"/>
				<placement x="{_end + 16}" y="196"/>
			</image>
			<text color="#CFCFCF">
				<conditions>{_c}</conditions>
				<font resource="font_s"/>
				<placement x="{_end + 16 + _off}" y="204"/>
				<text>{_label}</text>
			</text>
'''

# Graphite decrypt_pin page (mockup: lock tile, title, subtitle, dots, note,
# skip, keypad). Functional parts kept from TWRP's page: the masked input on
# tw_crypto_password -> trydecrypt, the failure message, cancel -> canceldecrypt.
PIN_PAGE = '''<page name="decrypt_pin">
			<template name="page"/>

			<image>
				<image resource="pin_lock"/>
				<placement x="%center_x%" y="300" placement="5"/>
			</image>

			<text style="text_l">
				<placement x="%center_x%" y="500" placement="5"/>
				<text>Decrypt data</text>
			</text>

			<text style="text_m">
				<placement x="%center_x%" y="575" placement="5"/>
				<text>Enter the PIN you use to unlock this phone.</text>
			</text>

			<input>
				<placement x="240" y="650" w="600" h="%input_height%"/>
				<text>%tw_crypto_display%</text>
				<data name="tw_crypto_password" mask="\u2022" maskvariable="tw_crypto_display"/>
				<restrict minlen="1" maxlen="254"/>
				<action function="page">trydecrypt</action>
			</input>

			<text style="text_m_fail">
				<condition var1="tw_password_fail" var2="1"/>
				<placement x="%center_x%" y="760" placement="5"/>
				<text>Wrong PIN - try again</text>
			</text>

			<button style="main_button_half_height_full_width">
				<placement x="%indent%" y="900"/>
				<text>Skip - use without decrypting</text>
				<action function="page">canceldecrypt</action>
			</button>

			<text style="text_m">
				<placement x="%center_x%" y="1070" placement="5"/>
				<text>Wrong PINs count toward the lock screen's limit.</text>
			</text>

			<template name="keyboardnum"/>
		'''.replace("\\u2022", "\u2022")

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
    "col1_x_header":                ("184",       "36"),         # no logo: titles at the margin
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


# Language files re-set the fonts AFTER ui.xml loads (<resource type="fontoverride">,
# gui/resources.cpp), so every language that overrides must be rewritten too.
# Space Grotesk is Latin-only: Greek/Cyrillic languages get Plex Sans headings.
NON_LATIN = {"el", "ru", "uk"}


def build_languages():
    out = {}
    ldir = os.path.join(BASE, "languages")
    for f in sorted(os.listdir(ldir)):
        if not f.endswith(".xml"):
            continue
        xml = open(os.path.join(ldir, f), encoding="utf-8").read()
        if "fontoverride" not in xml:
            continue
        heading = FONTS["font_m"][0] if f[:-4] in NON_LATIN else FONTS["font_l"][0]
        want = {"font_l": heading, "font_m": FONTS["font_m"][0],
                "font_s": FONTS["font_s"][0], "fixed": FONTS["fixed"][0]}
        seen = []

        def rewrite(m):     # one <resource .../> element, any attribute order
            el = m.group(0)
            if 'type="fontoverride"' not in el:
                return el
            name = re.search(r'(?<![\w-])name="([^"]+)"', el).group(1)   # not the tail of filename=
            if name not in want:
                fail(f"languages/{f}: unexpected fontoverride '{name}'")
            seen.append(name)
            return re.sub(r'filename="[^"]+"', f'filename="{want[name]}"', el)
        xml = re.sub(r'<resource\b[^>]*/>', rewrite, xml)
        if sorted(seen) != sorted(want):
            fail(f"languages/{f}: expected fontoverrides {sorted(want)}, found {sorted(seen)}")
        out[f"languages/{f}"] = xml.encode("utf-8")
    if "languages/en.xml" not in out:
        fail("languages/en.xml has no fontoverride block - base changed?")
    return out


def patch_page_template(xml):
    """Graphite frame (every page): black header without the logo, mockup-style
    status line (time | version | temp + battery, small + muted), rounded nav bar.
    Only the default-position status items are restyled (tw_*_pos_x == 0)."""
    s = xml.find('<template name="page">')
    e = xml.find("</template>", s)
    if s < 0 or e < 0:
        fail("page template not found in base ui.xml")
    t = xml[s:e]
    edits = [
        # header bar: blue -> page background
        (r'<fill color="%accent_color%">(\s*<placement x="0" y="0" w="%screen_width%" h="%header_height%"/>)',
         r'<fill color="%background_color%">\1'),
        # drop the TWRP logo (busy image + home button)
        (r'\s*<image>\s*<condition var1="tw_busy" var2="1"/>\s*<image resource="logo"/>\s*<placement x="0" y="0"/>\s*</image>', ''),
        (r'\s*<button>\s*<condition var1="tw_busy" var2="0"/>\s*<placement x="0" y="0"/>\s*<image resource="logo"/>\s*<action function="key">home</action>\s*</button>', ''),
        # status strip: no tint
        (r'<fill color="#00000030">', '<fill color="#00000000">'),
        # CPU slot -> right: "113°F · 100%"
        (r'<text color="%text_color%">(\s*<condition var1="tw_no_cpu_temp" var2="0"/>\s*<condition var1="tw_cpu_pos_x" var2="0"/>)\s*'
         r'<font resource="font_m"/>\s*<placement x="%indent%" y="%row1_header_y%"/>\s*<text>\{@cpu_temp=[^}]*\}</text>',
         f'<text color="{MUTED}">\\1\n\t\t\t\t<font resource="font_s"/>\n\t\t\t\t'
         '<placement x="%indent_right%" y="%row1_header_y%" placement="1"/>\n\t\t\t\t'
         '<text>%tw_cpu_temp%\u00b0F \u00b7 %tw_battery%</text>'),
        # clock slot -> left
        (r'<text color="%text_color%">(\s*<condition var1="tw_clock_12_pos_x" var2="0"/>\s*<condition var1="tw_clock_24_pos_x" var2="0"/>)\s*'
         r'<font resource="font_m"/>\s*<placement x="%center_x%" y="%row1_header_y%" placement="5"/>',
         f'<text color="{MUTED}">\\1\n\t\t\t\t<font resource="font_s"/>\n\t\t\t\t'
         '<placement x="%indent%" y="%row1_header_y%"/>'),
        # battery slot -> centre: TWRP version (battery is in the right slot now)
        (r'<text color="%text_color%">(\s*<conditions>\s*<condition var1="tw_no_battery_percent" var2="0"/>\s*'
         r'<condition var1="tw_battery" op="&gt;" var2="0"/>\s*<condition var1="tw_battery" op="&lt;" var2="101"/>\s*'
         r'<condition var1="tw_battery_pos_x" var2="0"/>\s*</conditions>)\s*<font resource="font_m"/>\s*'
         r'<placement x="%indent_right%" y="%row1_header_y%" placement="1"/>\s*<text>\{@battery_pct=[^}]*\}</text>',
         f'<text color="{MUTED}">\\1\n\t\t\t\t<font resource="font_s"/>\n\t\t\t\t'
         '<placement x="%center_x%" y="%row1_header_y%" placement="5"/>\n\t\t\t\t<text>%tw_version%</text>'),
        # nav bar: keep the black fill, add the rounded charcoal bar on top
        (r'(<fill color="#000000">\s*<condition var1="tw_busy" var2="0"/>\s*'
         r'<placement x="0" y="%navbar_y%" w="%screen_width%" h="%navbar_height%"/>\s*</fill>)',
         '\\1\n\t\t\t<image>\n\t\t\t\t<condition var1="tw_busy" var2="0"/>\n\t\t\t\t'
         '<image resource="navbar_bg"/>\n\t\t\t\t<placement x="0" y="%navbar_y%"/>\n\t\t\t</image>'),
    ]
    for rx, repl in edits:
        n = len(re.findall(rx, t))
        if n != 1:
            fail(f"page template: expected 1 match for /{rx[:60]}.../, found {n}")
        t = re.sub(rx, repl, t)
    return xml[:s] + t + xml[e:]


def build_splash():
    """Graphite splash: black, 'TWRP.' wordmark centred, PIXEL 8 · SHIBA below,
    'Unofficial build · <version>' at the bottom (images from mkimages.py).
    Splash loads before the language files, so its own font setting sticks."""
    xml = open(os.path.join(BASE, "splash.xml"), encoding="utf-8").read()
    subs = [
        ('<variable name="background_color" value="#222222"/>', '<variable name="background_color" value="#000000"/>'),
        ('<variable name="header_color" value="#555555"/>', '<variable name="header_color" value="#000000"/>'),
        ('<font name="font_l" filename="RobotoCondensed-Regular.ttf" size="52"/>',
         '<font name="font_l" filename="IBMPlexSans-Regular.ttf" size="34"/>'),
        ('<placement x="540" y="456" placement="4"/>', '<placement x="540" y="880" placement="4"/>'),
        ('<placement x="540" y="1540" placement="4"/>', '<placement x="540" y="1080" placement="4"/>'),
        ('<text color="%header_color%">', f'<text color="#6E6E6E">'),
        ('<placement x="540" y="1590" placement="5"/>', '<placement x="540" y="1720" placement="5"/>'),
        ('<text>Recovery Project %tw_version%</text>', '<text>Unofficial build \u00b7 %tw_version%</text>'),
    ]
    for old, new in subs:
        if xml.count(old) != 1:
            fail(f"splash.xml: expected 1x {old}")
        xml = xml.replace(old, new)
    return xml


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
    # extra-large heading for the main page title (not language-overridden)
    fl = f'<font name="font_l" filename="{FONTS["font_l"][0]}" size="{FONTS["font_l"][1]}"/>'
    xml = xml.replace(fl, fl + f'\n\t\t<font name="font_xl" filename="{FONTS["font_l"][0]}" size="96"/>')
    for rx, repl, n in LITERALS:
        found = len(re.findall(rx, xml))
        if found != n:
            fail(f"expected {n}x /{rx}/ in base ui.xml, found {found}")
        xml = re.sub(rx, repl, xml)
    # declare the stage 2b tile icons (not stock images) - keep aspect
    anchor = '<image name="main_button_half_height_full_width" filename="main_button_half_height_full_width"/>'
    if xml.count(anchor) != 1:
        fail("cannot find main_button_half_height_full_width resource in base ui.xml")
    decl = "".join(f'\n\t\t<image name="{i}" filename="{i}" retainaspect="1"/>' for i in TILE_ICONS.values())
    decl += "".join(f'\n\t\t<image name="{i}" filename="{i}"' + (' retainaspect="1"' if keep else "") + "/>"
                    for i, keep in {**PIN_IMAGES, **FRAME_IMAGES}.items())
    xml = xml.replace(anchor, anchor + decl)
    # PIN keypad: give the keyboardnum template's layout the pin_keypad image
    s = xml.find('<template name="keyboardnum">')
    e = xml.find("</template>", s)
    block = xml[s:e]
    if s < 0 or block.count('<keymargin x="8" y="8"/>') != 1 or "<layout1>" not in block:
        fail("keyboardnum template not as expected in base ui.xml")
    block = block.replace('<keymargin x="8" y="8"/>',
                          '<keymargin x="8" y="8"/>\n\t\t\t\t<layout resource1="pin_keypad"/>')
    xml = xml[:s] + block + xml[e:]
    return patch_page_template(xml)


def build_portrait():
    """TWRP's current portrait.xml with an icon added to each main-menu tile."""
    xml = open(SRC_PORTRAIT, encoding="utf-8").read()
    start = xml.find('<page name="main2">')
    end = xml.find("</page>", start)
    if start < 0 or end < 0:
        fail("main2 page not found in TWRP's portrait.xml")
    page = xml[start:end]
    hdr = re.compile(r'<text style="text_l">\s*<placement x="%col1_x_header%" y="%row3_header_y%"/>\s*'
                     r'<text>\{@twrp_header=[^}]*\}</text>\s*</text>\s*<text style="text_m">(?:\s*<condition[^>]*/>)*\s*'
                     r'<placement x="%col1_x_header%" y="%row4_header_y%"/>\s*<text>%tw_version%</text>\s*</text>')
    if len(hdr.findall(page)) != 1:
        fail("main2 header (title + version) not as expected")
    page = hdr.sub(lambda m: MAIN_HEADER, page)
    for label, icon in TILE_ICONS.items():
        pat = re.compile(r'(\n(\t+)<text>\{@' + label + r'=[^}]*\}</text>)')
        if len(pat.findall(page)) != 1:
            fail(f"expected one {label} button on the main2 page")
        page = pat.sub(lambda m: f'\n{m.group(2)}<icon resource="{icon}" tile="1" padx="72" padtop="60" padbottom="60"/>' + m.group(1), page)
    inst = re.compile(r'<button style="main_button">(\s*<placement[^>]*/>\s*<icon resource="tile_install_dark"[^>]*/>)')
    if len(inst.findall(page)) != 1:
        fail("Install tile not found on main2")
    page = inst.sub(r'<button style="main_button_accent">\1', page)
    xml = xml[:start] + page + xml[end:]
    # the primary-tile style, right after main_button's
    st = re.compile(r'(<style name="main_button">\s*<highlight[^>]*/>\s*<font[^>]*/>\s*<image resource="main_button"/>\s*</style>\n)')
    if len(st.findall(xml)) != 1:
        fail("main_button style not as expected in portrait.xml")
    xml = st.sub(lambda m: m.group(1) + ACCENT_STYLE, xml)
    # PIN page: replace TWRP's decrypt_pin page body with the Graphite layout
    s = xml.find('<page name="decrypt_pin">')
    e = xml.find("</page>", s)
    if s < 0 or xml[s:e].count('<template name="keyboardnum"/>') != 1 \
            or 'name="tw_crypto_password"' not in xml[s:e]:
        fail("decrypt_pin page not as expected in TWRP's portrait.xml")
    return patch_lists(xml[:s] + PIN_PAGE + xml[e:])


def changed_files(ui_xml):
    """{relative path in twres: bytes} for everything Graphite adds or changes."""
    out = {"ui.xml": ui_xml.encode("utf-8"), "portrait.xml": build_portrait().encode("utf-8"),
           "splash.xml": build_splash().encode("utf-8")}
    out.update(build_languages())
    for f in sorted(os.listdir(os.path.join(GRAPHITE, "fonts"))):
        out[f"fonts/{f}"] = open(os.path.join(GRAPHITE, "fonts", f), "rb").read()
    img_dir = os.path.join(GRAPHITE, "images")        # stage 2 (mkimages.py)
    if os.path.isdir(img_dir):
        for f in sorted(os.listdir(img_dir)):
            if f.endswith(".png"):
                new = f[:-4] in NEW_IMAGES
                if not new and not os.path.exists(os.path.join(BASE, "images", f)):
                    fail(f"graphite/images/{f} replaces nothing in base/images")
                out[f"images/{f}"] = open(os.path.join(img_dir, f), "rb").read()
    for i in NEW_IMAGES:
        if f"images/{i}.png" not in out:
            fail(f"missing graphite/images/{i}.png - run mkimages.py")
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
    for d in (os.path.join(BAKE_DIR, "fonts"), os.path.join(BAKE_DIR, "images"),
              os.path.join(BAKE_DIR, "languages"), BAKE_DIR):   # remove empty dirs we made
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
