#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 strubedo
"""twrp_remote.py - view and control TWRP on the Pixel 8 (shiba) from a PC.
Runs on Linux and Windows.

The phone side is /system/bin/twrp_remote (device/google/shiba/twrp_remote),
reached through `adb forward` - USB only, nothing on the network. When the
phone is in Android instead, scrcpy is started for it (unless --no-scrcpy).

  python3 twrp_remote.py [--scale 0.4] [--adb PATH] [--no-scrcpy] [--debug-keys]

Mouse = finger: click to tap, drag to swipe; scroll wheel swipes lists.
Keyboard: while the window has focus, typing goes to TWRP (virtual keyboard).
Side buttons: Power, Screenshot (saved to Pictures/TWRP Remote), Screenshots
(opens that folder), and a Reboot menu.

Needs adb (Android platform-tools) and Pillow; Tk comes with Python on Windows
(Linux: sudo apt install python3-tk python3-pil.imagetk). Optional: scrcpy.
"""
import argparse
import os
import queue
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import tkinter as tk
import zlib
from tkinter import messagebox

from PIL import Image, ImageEnhance, ImageTk

WINDOWS = sys.platform == "win32"
PORT = 27183
KEY_POWER = 116
BG, SURFACE, TEXT, MUTED, ACCENT = "#000000", "#121212", "#EDEDED", "#A1A1A1", "#0090CA"

# ------------------------------------------------------------------ key maps
# The phone gets Linux key codes. TWRP's hardwarekeyboard.cpp only turns
# main-block keys into characters, so numpad keys are sent as main-block keys.
# Tuples are pressed in order (Shift first for * and +).

# Linux/X11 (also XWayland): keycode - 8 is the Linux code; the numpad goes by
# keysym, which follows Num Lock.
X11_KEYPAD = {
    "KP_0": (11,), "KP_1": (2,), "KP_2": (3,), "KP_3": (4,), "KP_4": (5,),
    "KP_5": (6,), "KP_6": (7,), "KP_7": (8,), "KP_8": (9,), "KP_9": (10,),
    "KP_Decimal": (52,), "KP_Enter": (28,), "KP_Subtract": (12,), "KP_Divide": (53,),
    "KP_Multiply": (42, 9), "KP_Add": (42, 13),          # Shift+8, Shift+=
    "KP_Home": (102,), "KP_Up": (103,), "KP_Prior": (104,), "KP_Left": (105,),
    "KP_Right": (106,), "KP_End": (107,), "KP_Down": (108,), "KP_Next": (109,),
    "KP_Insert": (110,), "KP_Delete": (111,),
}

# Windows: Tk keycodes are virtual-key codes (US layout punctuation).
_LETTERS = {"Q": 16, "W": 17, "E": 18, "R": 19, "T": 20, "Y": 21, "U": 22, "I": 23,
            "O": 24, "P": 25, "A": 30, "S": 31, "D": 32, "F": 33, "G": 34, "H": 35,
            "J": 36, "K": 37, "L": 38, "Z": 44, "X": 45, "C": 46, "V": 47, "B": 48,
            "N": 49, "M": 50}
WIN_VK = {ord(ch): (code,) for ch, code in _LETTERS.items()}
WIN_VK.update({0x30: (11,)})                                       # 0
WIN_VK.update({0x31 + i: (2 + i,) for i in range(9)})              # 1-9
WIN_VK.update({0x60: (11,)})                                       # numpad 0
WIN_VK.update({0x61 + i: (2 + i,) for i in range(9)})              # numpad 1-9
WIN_VK.update({0x70 + i: (59 + i,) for i in range(10)})            # F1-F10
WIN_VK.update({
    0x7A: (87,), 0x7B: (88,),                                      # F11 F12
    0x08: (14,), 0x09: (15,), 0x0D: (28,), 0x10: (42,), 0x11: (29,), 0x12: (56,),
    0x14: (58,), 0x1B: (1,), 0x20: (57,),                          # bksp tab enter shift ctrl alt caps esc space
    0x21: (104,), 0x22: (109,), 0x23: (107,), 0x24: (102,),        # pgup pgdn end home
    0x25: (105,), 0x26: (103,), 0x27: (106,), 0x28: (108,),        # left up right down
    0x2D: (110,), 0x2E: (111,),                                    # insert delete
    0xBA: (39,), 0xBB: (13,), 0xBC: (51,), 0xBD: (12,), 0xBE: (52,), 0xBF: (53,),  # ; = , - . /
    0xC0: (41,), 0xDB: (26,), 0xDC: (43,), 0xDD: (27,), 0xDE: (40,),              # ` [ \ ] '
    0x6A: (42, 9), 0x6B: (42, 13), 0x6D: (12,), 0x6E: (52,), 0x6F: (53,),       # numpad * + - . /
})


# ------------------------------------------------------------------ tools
def here(*parts):
    """A file next to this program (inside the .exe when frozen)."""
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, *parts)


def find_tool(name, explicit=None, env=None):
    """explicit path, then $ENV, then PATH, then the usual places."""
    exe = name + (".exe" if WINDOWS else "")
    candidates = [explicit, os.environ.get(env) if env else None, shutil.which(name)]
    exe_dir = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__))
    candidates += [os.path.join(exe_dir, exe), os.path.join(exe_dir, "platform-tools", exe),
                   os.path.join(exe_dir, "scrcpy", exe)]      # install_windows.bat puts both here
    if WINDOWS:
        local = os.environ.get("LOCALAPPDATA", "")
        home = os.path.expanduser("~")
        candidates += [os.path.join(local, "Android", "Sdk", "platform-tools", exe),
                       os.path.join("C:\\", "platform-tools", exe),
                       os.path.join(home, "platform-tools", exe),
                       os.path.join("C:\\", "scrcpy", exe),
                       os.path.join(home, "scrcpy", exe)]
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    return None


NO_WINDOW = 0x08000000 if WINDOWS else 0        # CREATE_NO_WINDOW: no console flashes


def screenshot_dir():
    """<Pictures>/TWRP Remote - the user's real Pictures folder (XDG on Linux, which
    follows a renamed/localized one; the Pictures known folder's usual place on
    Windows), created on first use."""
    base = ""
    if WINDOWS:
        base = os.path.join(os.environ.get("USERPROFILE") or os.path.expanduser("~"), "Pictures")
    else:
        try:
            base = subprocess.run(["xdg-user-dir", "PICTURES"], capture_output=True,
                                  text=True, timeout=3).stdout.strip()
        except Exception:
            base = ""
        if not base or os.path.realpath(base) == os.path.realpath(os.path.expanduser("~")):
            base = os.path.join(os.path.expanduser("~"), "Pictures")   # xdg-user-dir falls back to ~
    d = os.path.join(base, "TWRP Remote")
    os.makedirs(d, exist_ok=True)
    return d


def downloads_dir():
    """The user's Downloads folder (XDG on Linux; the usual place on Windows)."""
    base = ""
    if WINDOWS:
        base = os.path.join(os.environ.get("USERPROFILE") or os.path.expanduser("~"), "Downloads")
    else:
        try:
            base = subprocess.run(["xdg-user-dir", "DOWNLOAD"], capture_output=True,
                                  text=True, timeout=3).stdout.strip()
        except Exception:
            base = ""
        if not base or os.path.realpath(base) == os.path.realpath(os.path.expanduser("~")):
            base = os.path.join(os.path.expanduser("~"), "Downloads")
    os.makedirs(base, exist_ok=True)
    return base


def open_folder(path):
    if WINDOWS:
        os.startfile(path)                          # noqa - Windows only
    elif sys.platform == "darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


MODULE = "/data/adb/modules/enable_adb"         # installed by TWRP: Advanced > Enable USB debugging


def adb_pubkey_path():
    """This PC's ADB public key, where adb itself keeps it."""
    if os.environ.get("ANDROID_USER_HOME"):
        return os.path.join(os.environ["ANDROID_USER_HOME"], "adbkey.pub")
    base = os.environ.get("ANDROID_SDK_HOME") or os.path.expanduser("~")
    return os.path.join(base, ".android", "adbkey.pub")


def run(cmd, timeout=10):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                          creationflags=NO_WINDOW)


# ------------------------------------------------------------------ app
class Remote:
    def __init__(self, scale=None, adb=None, scrcpy=True, debug_keys=False):
        self.adb = adb
        self.scrcpy_path = find_tool("scrcpy") if scrcpy else None
        self.scrcpy_enabled = scrcpy
        self.scrcpy_proc = None
        self.debug_keys = debug_keys
        self.sock = None               # owned by the link thread; None while down
        self.send_lock = threading.Lock()
        self.frames = queue.Queue(maxsize=1)
        self.link_status = "connecting\u2026"
        self.src = (1080, 2400)        # panel size; updated from each frame
        self.last = None               # last frame (half resolution) for screenshots
        self.frame_count = 0
        self.pressed = {}              # physical keycode -> codes sent on press
        self.dimmed = False            # last frame shown dimmed (not live)
        self.mode = None               # adb state: recovery | device (Android) | ...
        self.note = ("", 0.0)          # short message (e.g. "saved") shown over the status until a time

        self.root = tk.Tk(className="TWRPRemote")   # WM_CLASS = StartupWMClass in the .desktop file
        self.root.title("TWRP remote \u00b7 Pixel 8")
        self.root.configure(bg=BG)
        self.root.resizable(False, False)
        self.set_icon()
        # default size: fit the screen (taskbar and title bar included)
        self.scale = scale or min(0.45, (self.root.winfo_screenheight() - 160) / 2400)
        self.canvas = tk.Canvas(self.root, width=int(1080 * self.scale), height=int(2400 * self.scale),
                                bg=BG, highlightthickness=0, cursor="hand2")
        self.canvas.pack(side="left")
        self.item = self.canvas.create_image(0, 0, anchor="nw")

        bar = tk.Frame(self.root, bg=SURFACE)
        bar.pack(side="right", fill="y")
        def button(label, cmd, top=0):
            tk.Button(bar, text=label, command=cmd, width=11, relief="flat", bd=0, takefocus=0,
                      bg="#1A1A1A", fg=TEXT, activebackground=ACCENT, activeforeground=BG,
                      padx=6, pady=8).pack(padx=10, pady=(top or 10, 0))
        for label, cmd in (("Power", lambda: self.press(KEY_POWER)),
                           ("Screenshot", self.screenshot),
                           ("Screenshots", self.open_screenshots),
                           ("Collect logs", self.collect_logs),
                           ("Authorize PC", self.authorize_pc)):
            button(label, cmd)
        tk.Label(bar, text="REBOOT", bg=SURFACE, fg=MUTED).pack(padx=10, pady=(22, 0), anchor="w")
        for label, target in (("System", "system"), ("Recovery", "recovery"),
                              ("Bootloader", "bootloader"), ("Fastboot", "fastboot"),
                              ("Power off", "poweroff")):
            button(label, lambda l=label, t=target: self.reboot(l, t), top=6)
        self.status = tk.Label(bar, text="connecting\u2026", bg=SURFACE, fg=MUTED, justify="left")
        self.status.pack(side="bottom", padx=10, pady=10)

        self.canvas.bind("<ButtonPress-1>", lambda e: self.touch("D", e))
        self.canvas.bind("<B1-Motion>", lambda e: self.touch("M", e))
        self.canvas.bind("<ButtonRelease-1>", lambda e: self.touch("U", e))
        self.canvas.bind("<Button-4>", lambda e: self.wheel(e, +1))   # X11 wheel up
        self.canvas.bind("<Button-5>", lambda e: self.wheel(e, -1))   # X11 wheel down
        self.canvas.bind("<MouseWheel>", lambda e: self.wheel(e, 1 if e.delta > 0 else -1))
        self.root.bind("<KeyPress>", lambda e: self.board(e, 1))
        self.root.bind("<KeyRelease>", lambda e: self.board(e, 0))
        self.root.bind("<FocusOut>", lambda e: self.release_keys())

        threading.Thread(target=self.link, daemon=True).start()
        self.root.after(15, self.pump)

    def set_icon(self):
        # shipped icon (next to the program / inside the .exe), else the theme
        for path in (here("twrp_remote.png"),
                     here("..", "theme", "graphite", "images", "splashlogo.png")):
            if os.path.exists(path):
                img = Image.open(path).convert("RGBA")
                if img.size != (256, 256):          # theme wordmark: put it on a tile
                    mark = img.crop(img.getbbox())
                    mark.thumbnail((112, 112))
                    img = Image.new("RGBA", (128, 128), (0, 0, 0, 255))
                    img.paste(mark, ((128 - mark.width) // 2, (128 - mark.height) // 2), mark)
                self.icon = ImageTk.PhotoImage(img)
                self.root.iconphoto(True, self.icon)
                return

    # -------------------------------------------------------------- phone -> PC
    def adb_state(self):
        try:
            r = run([self.adb, "get-state"], timeout=5)
            if r.returncode == 0:
                return r.stdout.strip()
            return "unauthorized" if "unauthorized" in r.stderr else None
        except Exception:
            return None

    def android_mode(self):
        """Phone booted to Android: hand over to scrcpy (once per boot)."""
        if not self.scrcpy_enabled:
            self.link_status = "phone is in Android\n(scrcpy disabled)"
        elif not self.scrcpy_path:
            self.link_status = "phone is in Android\ninstall scrcpy to\nview it here"
        else:
            if self.scrcpy_proc is None:
                env = dict(os.environ, ADB=self.adb)          # scrcpy uses the same adb
                self.scrcpy_proc = subprocess.Popen([self.scrcpy_path], env=env,
                                                    creationflags=NO_WINDOW)
            self.link_status = "phone is in Android\nshowing it in scrcpy"

    def link(self):
        """Connect, read frames, and on any drop (reboot, unplug) retry every
        second - adb removes forwards when the device goes away, so redo it."""
        while True:
            state = self.adb_state()
            self.mode = state
            if state == "device":
                self.android_mode()
                time.sleep(2)
                continue
            self.scrcpy_proc = None                           # left Android: next boot may relaunch
            if state == "recovery":
                try:
                    r = run([self.adb, "forward", f"tcp:{PORT}", "localabstract:twrp_remote"], timeout=5)
                    if r.returncode == 0:
                        s = socket.create_connection(("127.0.0.1", PORT), timeout=3)
                        s.settimeout(None)
                        self.sock = s
                        self.reader(s)
                except Exception:
                    pass
                with self.send_lock:
                    if self.sock:
                        try:
                            self.sock.close()
                        except OSError:
                            pass
                    self.sock = None
            self.link_status = {"bootloader": "phone is in the bootloader",
                                "sideload": "phone is in sideload mode",
                                "unauthorized": "phone is in Android\nunlock it and allow\nUSB debugging"
                                }.get(state, "waiting for TWRP\u2026")
            time.sleep(1)

    def recv_exact(self, s, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = s.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("phone closed the connection")
            buf += chunk
        return bytes(buf)

    def reader(self, s):
        while True:
            magic, sw, sh, w, h, ln = struct.unpack("<4sHHHHI", self.recv_exact(s, 16))
            if magic != b"TWRF":
                raise ValueError(f"bad frame header {magic!r}")
            img = Image.frombytes("RGB", (w, h), zlib.decompress(self.recv_exact(s, ln)))
            self.link_status = None                 # live
            try:
                self.frames.get_nowait()            # keep only the newest frame
            except queue.Empty:
                pass
            self.frames.put((img, sw, sh))

    def pump(self):
        try:
            item = self.frames.get_nowait()
        except queue.Empty:
            item = None
        if item:
            img, sw, sh = item
            self.src, self.last = (sw, sh), img
            self.frame_count += 1
            self.show(img)
            self.dimmed = False
        if self.note[0] and time.monotonic() < self.note[1]:
            self.status.config(text=self.note[0])
        elif self.link_status:
            self.status.config(text=self.link_status)
            if self.last is not None and not self.dimmed:   # not live: dim the last frame
                self.show(ImageEnhance.Brightness(self.last).enhance(0.3))
                self.dimmed = True
        else:
            self.status.config(text=f"{self.src[0]}\u00d7{self.src[1]}\nframes: {self.frame_count}")
        self.root.after(15, self.pump)

    def show(self, img):
        size = (int(self.src[0] * self.scale), int(self.src[1] * self.scale))
        self.photo = ImageTk.PhotoImage(img.resize(size, Image.BILINEAR))
        self.canvas.itemconfig(self.item, image=self.photo)

    # -------------------------------------------------------------- PC -> phone
    def send(self, op, a=0, b=0):
        with self.send_lock:
            if not self.sock:
                return                              # down: drop input until reconnected
            try:
                self.sock.sendall(struct.pack("<BBHHH", ord(op), 0, a, b, 0))
            except OSError:
                pass                                # the link thread notices and reconnects

    def panel_xy(self, e):
        x = min(max(int(e.x / self.scale), 0), self.src[0] - 1)
        y = min(max(int(e.y / self.scale), 0), self.src[1] - 1)
        return x, y

    def touch(self, op, e):
        self.send(op, *self.panel_xy(e))

    def press(self, code, hold_ms=80):
        self.send("K", code, 1)
        self.root.after(hold_ms, lambda: self.send("K", code, 0))

    def key_codes(self, e):
        if WINDOWS:
            return WIN_VK.get(e.keycode)
        codes = X11_KEYPAD.get(e.keysym)
        if codes is None and 0 < e.keycode - 8 < 256:
            codes = (e.keycode - 8,)
        return codes

    def board(self, e, down):
        if down:
            codes = self.key_codes(e)
            if codes is None:
                return
            # repeats arrive as more presses: release what's down first
            if e.keycode in self.pressed:
                for code in reversed(self.pressed[e.keycode]):
                    self.send("B", code, 0)
            self.pressed[e.keycode] = codes
        else:
            # release exactly what this physical key pressed: XWayland can
            # report another keysym on release (KP_1 down, KP_End up)
            codes = self.pressed.pop(e.keycode, None)
            if codes is None:
                return
        for code in (codes if down else reversed(codes)):
            self.send("B", code, down)
        if self.debug_keys:
            print(f"{'down' if down else 'up  '} keysym={e.keysym!r} keycode={e.keycode} -> {codes}", flush=True)

    def release_keys(self):
        for codes in self.pressed.values():   # nothing stays stuck when focus leaves
            for code in reversed(codes):
                self.send("B", code, 0)
        self.pressed.clear()

    def wheel(self, e, direction):
        # a short finger swipe: wheel up drags down (content scrolls up)
        x, y = self.panel_xy(e)
        dy = 350 * direction
        def swipe():
            self.send("D", x, y)
            for i in range(1, 8):
                time.sleep(0.012)
                self.send("M", x, min(max(y + dy * i // 7, 0), self.src[1] - 1))
            self.send("U", x, y)
        threading.Thread(target=swipe, daemon=True).start()

    def reboot(self, label, target):
        verb = "Power off" if target == "poweroff" else f"Reboot to {label}"
        if not messagebox.askyesno("TWRP remote", f"{verb} now?", parent=self.root):
            return
        # sync, then init's reboot (which also flushes and unmounts). `twrp reboot`
        # runs as a recovery script instead: it shows TWRP's script page and
        # fails to save settings ("Unable to find partition for path '/.twrps'")
        if target == "poweroff":
            cmds = [[self.adb, "shell", "sync"], [self.adb, "shell", "reboot", "-p"]]
        elif target == "system":
            cmds = [[self.adb, "shell", "sync"], [self.adb, "reboot"]]
        else:
            cmds = [[self.adb, "shell", "sync"], [self.adb, "reboot", target]]
        def go():
            for c in cmds:
                try:
                    run(c, timeout=20)
                except Exception:
                    pass
        threading.Thread(target=go, daemon=True).start()
        self.notify(f"{verb}\u2026")

    def authorize_pc(self):
        """Add this PC's ADB key to the enable_adb module, so Android trusts
        this PC at the next boot without the 'Allow USB debugging?' prompt."""
        if not messagebox.askyesno(
                "TWRP remote",
                "Authorize this PC for USB debugging?\n\nIts ADB key is added to the enable_adb module; "
                "from the next Android boot this PC connects without the 'Allow' prompt.",
                parent=self.root):
            return
        def done(ok, msg):
            self.root.after(0, lambda: (messagebox.showinfo if ok else messagebox.showerror)(
                "TWRP remote", msg, parent=self.root))
        def go():
            try:
                if self.adb_state() != "recovery":
                    return done(False, "Boot the phone into TWRP first.")
                path = adb_pubkey_path()
                try:
                    key = open(path, encoding="utf-8").read().strip()
                except OSError:
                    key = ""
                if not key:
                    return done(False, f"This PC has no ADB key yet ({path}).\nRun 'adb devices' once, then retry.")
                r = run([self.adb, "shell", f"test -d {MODULE} && echo yes"])
                if r.stdout.strip() != "yes":
                    return done(False, "The enable_adb module isn't installed.\n\nIn TWRP: decrypt data, then "
                                       "Advanced > Enable USB debugging (needs KernelSU, Magisk or APatch).")
                old = run([self.adb, "shell", f"cat {MODULE}/adb_keys 2>/dev/null"]).stdout.splitlines()
                old = [k.strip() for k in old if k.strip()]
                if any(k.split()[0] == key.split()[0] for k in old):
                    return done(True, "This PC is already authorized.")
                import tempfile
                with tempfile.NamedTemporaryFile("w", suffix=".pub", delete=False, newline="\n") as f:
                    f.write("\n".join(old + [key]) + "\n")
                    tmp = f.name
                try:
                    r = run([self.adb, "push", tmp, f"{MODULE}/adb_keys"], timeout=20)
                finally:
                    os.unlink(tmp)
                if r.returncode != 0:
                    return done(False, f"Copying the key failed:\n{r.stderr.strip()}")
                # same owner, mode and SELinux label as the TWRP installer sets
                run([self.adb, "shell",
                     f"F={MODULE}/adb_keys; chown 0:0 $F; chmod 0600 $F; "
                     f"C=$(ls -Zd /data/adb/modules | awk '{{print $1}}'); chcon \"$C\" $F; sync"])
                done(True, "This PC is authorized.\n\nFrom the next Android boot it connects "
                           "without the 'Allow USB debugging?' prompt.")
            except Exception as ex:
                done(False, f"Authorizing failed: {ex}")
        threading.Thread(target=go, daemon=True).start()

    def screenshot(self):
        try:
            path = os.path.join(screenshot_dir(), time.strftime("twrp_remote_%Y%m%d-%H%M%S.png"))
        except OSError as ex:
            self.notify(f"can't create the\nscreenshot folder:\n{ex.strerror}")
            return
        if self.mode == "device":
            # Android (scrcpy): ask Android for the screen - full resolution
            def go():
                try:
                    r = subprocess.run([self.adb, "exec-out", "screencap", "-p"], capture_output=True,
                                       timeout=20, creationflags=NO_WINDOW)
                    if r.returncode == 0 and r.stdout.startswith(b"\x89PNG"):
                        with open(path, "wb") as f:
                            f.write(r.stdout)
                        msg = f"saved (Android)\n{os.path.basename(path)}"
                    else:
                        msg = "Android screenshot\nfailed"
                except Exception:
                    msg = "Android screenshot\nfailed"
                self.root.after(0, lambda: self.notify(msg))
            threading.Thread(target=go, daemon=True).start()
            return
        if self.last is None or self.link_status:
            self.notify("no live TWRP screen\nto capture")
            return
        self.last.save(path)
        self.notify(f"saved\n{os.path.basename(path)}")

    def open_screenshots(self):
        try:
            open_folder(screenshot_dir())
        except Exception as ex:
            self.notify(f"can't open the\nscreenshot folder:\n{ex}")

    def collect_logs(self):
        """TWRP: bundle its diagnostic logs (twrp_collect_logs.sh, identifiers
        redacted) and pull the archive into the PC's Downloads folder."""
        if self.mode != "recovery":
            self.notify("Collect logs works\nwhile the phone is\nin TWRP")
            return
        self.notify("collecting logs\u2026", 60)

        def go():
            try:
                r = subprocess.run([self.adb, "shell", "/system/bin/twrp_collect_logs.sh --to /tmp"],
                                   capture_output=True, text=True, timeout=120, creationflags=NO_WINDOW)
                saved = [l for l in r.stdout.splitlines() if l.startswith("SAVED: ")]
                if not saved:
                    raise RuntimeError("no archive (is this TWRP up to date?)")
                remote = saved[-1][len("SAVED: "):].split(" (")[0].strip()
                local = os.path.join(downloads_dir(), os.path.basename(remote))
                p = subprocess.run([self.adb, "pull", remote, local], capture_output=True,
                                   text=True, timeout=60, creationflags=NO_WINDOW)
                if p.returncode != 0 or not os.path.isfile(local):
                    raise RuntimeError("adb pull failed")
                msg = f"logs saved to Downloads\n{os.path.basename(local)}"
            except Exception as ex:
                msg = f"Collect logs failed:\n{ex}"
            self.root.after(0, lambda: self.notify(msg, 8))
        threading.Thread(target=go, daemon=True).start()

    def notify(self, text, seconds=4):
        self.note = (text, time.monotonic() + seconds)


def main():
    ap = argparse.ArgumentParser(description="View and control TWRP on the Pixel 8 over adb.")
    ap.add_argument("--scale", type=float, default=None,
                    help="window size relative to the 1080x2400 panel (default: fit the screen)")
    ap.add_argument("--adb", help="path to adb (default: $ADB, PATH, or the usual install places)")
    ap.add_argument("--no-scrcpy", action="store_true",
                    help="don't start scrcpy when the phone is in Android")
    ap.add_argument("--debug-keys", action="store_true",
                    help="print each key's keysym/keycode and the codes sent")
    args = ap.parse_args()

    if WINDOWS:
        try:                                    # sharp on high-DPI displays (no bitmap scaling)
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass
    adb = find_tool("adb", args.adb, "ADB")
    if not adb:
        root = tk.Tk()
        root.withdraw()
        messagebox.showerror("TWRP remote",
                             "adb was not found.\n\nInstall Android platform-tools and put adb on your "
                             "PATH, or start with --adb C:\\path\\to\\adb.exe")
        return
    Remote(args.scale, adb, not args.no_scrcpy, args.debug_keys).root.mainloop()


if __name__ == "__main__":
    main()
