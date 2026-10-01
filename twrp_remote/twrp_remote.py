#!/usr/bin/env python3
"""twrp_remote.py - view and control TWRP on the Pixel 8 (shiba) from this PC.

The phone side is /system/bin/twrp_remote (device/google/shiba/twrp_remote),
reached through `adb forward` - USB only, nothing on the network.

  python3 twrp_remote.py [--scale 0.4]

Mouse = finger: click to tap, drag to swipe; scroll wheel swipes lists.
Keyboard: while the window has focus, typing goes to TWRP (virtual keyboard).
Side buttons: Power, Screenshot (saved to ~/), and a Reboot menu like TWRP's.
Needs adb, Pillow and Tk (sudo apt install python3-tk python3-pil.imagetk).
"""
import argparse
import os
import queue
import socket
import struct
import subprocess
import threading
import time
import tkinter as tk
import zlib
from tkinter import messagebox

from PIL import Image, ImageTk

PORT = 27183
KEY_POWER = 116
# TWRP's hardwarekeyboard.cpp only turns main-block keys into characters, so
# numpad keys are sent as their main-block equivalents (by Tk keysym, which
# also follows Num Lock). Tuples are pressed in order: Shift first for * and +.
KEYPAD = {
    "KP_0": (11,), "KP_1": (2,), "KP_2": (3,), "KP_3": (4,), "KP_4": (5,),
    "KP_5": (6,), "KP_6": (7,), "KP_7": (8,), "KP_8": (9,), "KP_9": (10,),
    "KP_Decimal": (52,), "KP_Enter": (28,), "KP_Subtract": (12,), "KP_Divide": (53,),
    "KP_Multiply": (42, 9), "KP_Add": (42, 13),          # Shift+8, Shift+=
    "KP_Home": (102,), "KP_Up": (103,), "KP_Prior": (104,), "KP_Left": (105,),
    "KP_Right": (106,), "KP_End": (107,), "KP_Down": (108,), "KP_Next": (109,),
    "KP_Insert": (110,), "KP_Delete": (111,),
}
BG, SURFACE, TEXT, MUTED, ACCENT = "#000000", "#121212", "#EDEDED", "#A1A1A1", "#0090CA"


class Remote:
    def __init__(self, scale, debug_keys=False):
        self.debug_keys = debug_keys
        self.sock = None               # owned by the link thread; None while down
        self.send_lock = threading.Lock()
        self.frames = queue.Queue(maxsize=1)
        self.link_status = "connecting\u2026"
        self.scale = scale
        self.src = (1080, 2400)        # panel size; updated from each frame
        self.last = None               # last frame (half resolution) for screenshots
        self.frame_count = 0

        self.root = tk.Tk(className="TWRPRemote")   # WM_CLASS = StartupWMClass in the .desktop file
        self.root.title("TWRP remote \u00b7 Pixel 8")
        self.root.configure(bg=BG)
        self.root.resizable(False, False)
        self.set_icon()
        self.canvas = tk.Canvas(self.root, width=int(1080 * scale), height=int(2400 * scale),
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
                           ("Screenshot", self.screenshot)):
            button(label, cmd)
        # Reboot menu like TWRP's (sync + adb reboot, see reboot())
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
        # typing -> the phone's virtual keyboard. X11/XWayland keycodes are
        # Linux key codes + 8, so no keysym table is needed.
        self.pressed = {}                  # physical keycode -> codes sent on press
        self.root.bind("<KeyPress>", lambda e: self.board(e, 1))
        self.root.bind("<KeyRelease>", lambda e: self.board(e, 0))
        self.root.bind("<FocusOut>", lambda e: self.release_keys())

        threading.Thread(target=self.link, daemon=True).start()
        self.root.after(15, self.pump)

    def set_icon(self):
        # window icon: the Graphite splash wordmark ("TWRP.") on black
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "theme", "graphite", "images", "splashlogo.png")
        if not os.path.exists(path):
            return
        mark = Image.open(path).convert("RGBA")
        mark = mark.crop(mark.getbbox())
        mark.thumbnail((112, 112))
        icon = Image.new("RGBA", (128, 128), (0, 0, 0, 255))
        icon.paste(mark, ((128 - mark.width) // 2, (128 - mark.height) // 2), mark)
        self.icon = ImageTk.PhotoImage(icon)
        self.root.iconphoto(True, self.icon)

    # -------------------------------------------------------------- phone -> PC
    def link(self):
        """Connect, read frames, and on any drop (reboot, unplug) retry every
        second - adb removes forwards when the device goes away, so redo it."""
        while True:
            try:
                subprocess.run(["adb", "forward", f"tcp:{PORT}", "localabstract:twrp_remote"],
                               check=True, capture_output=True, timeout=5)
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
            self.link_status = "waiting for TWRP\u2026"
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
            size = (int(sw * self.scale), int(sh * self.scale))
            self.photo = ImageTk.PhotoImage(img.resize(size, Image.BILINEAR))
            self.canvas.itemconfig(self.item, image=self.photo)
        if self.link_status:
            self.status.config(text=self.link_status)
        else:
            self.status.config(text=f"{self.src[0]}\u00d7{self.src[1]}\nframes: {self.frame_count}")
        self.root.after(15, self.pump)

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

    def board(self, e, down):
        if down:
            codes = KEYPAD.get(e.keysym)
            if codes is None:
                code = e.keycode - 8
                if not 0 < code < 256:
                    return
                codes = (code,)
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
            cmd = [["adb", "shell", "sync"], ["adb", "shell", "reboot", "-p"]]
        elif target == "system":
            cmd = [["adb", "shell", "sync"], ["adb", "reboot"]]
        else:
            cmd = [["adb", "shell", "sync"], ["adb", "reboot", target]]
        def run():
            for c in cmd:
                subprocess.run(c, capture_output=True)
        threading.Thread(target=run, daemon=True).start()
        self.status.config(text=f"{verb}\u2026")

    def screenshot(self):
        if self.last is None:
            return
        path = os.path.expanduser(time.strftime("~/twrp_remote_%Y%m%d-%H%M%S.png"))
        self.last.save(path)
        self.status.config(text=f"saved\n{os.path.basename(path)}")


def main():
    ap = argparse.ArgumentParser(description="View and control TWRP on the Pixel 8 over adb.")
    ap.add_argument("--scale", type=float, default=0.4,
                    help="window size relative to the 1080x2400 panel (default 0.4)")
    ap.add_argument("--debug-keys", action="store_true",
                    help="print each key's keysym/keycode and the codes sent")
    args = ap.parse_args()
    Remote(args.scale, args.debug_keys).root.mainloop()


if __name__ == "__main__":
    main()
