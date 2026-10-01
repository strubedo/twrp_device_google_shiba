#!/usr/bin/env python3
"""twrp_remote.py - view and control TWRP on the Pixel 8 (shiba) from this PC.

The phone side is /system/bin/twrp_remote (device/google/shiba/twrp_remote),
reached through `adb forward` - USB only, nothing on the network.

  python3 twrp_remote.py [--scale 0.4]

Mouse = finger: click to tap, drag to swipe; scroll wheel swipes lists.
Side buttons: Power, Vol +, Vol -, Screenshot (saved to ~/).
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

from PIL import Image, ImageTk

PORT = 27183
KEY_VOLUMEDOWN, KEY_VOLUMEUP, KEY_POWER = 114, 115, 116
BG, SURFACE, TEXT, MUTED, ACCENT = "#000000", "#121212", "#EDEDED", "#A1A1A1", "#0090CA"


class Remote:
    def __init__(self, scale):
        subprocess.run(["adb", "forward", f"tcp:{PORT}", "localabstract:twrp_remote"],
                       check=True, capture_output=True)
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        self.sock.settimeout(None)
        self.send_lock = threading.Lock()
        self.frames = queue.Queue(maxsize=1)
        self.scale = scale
        self.src = (1080, 2400)        # panel size; updated from each frame
        self.last = None               # last frame (half resolution) for screenshots
        self.frame_count = 0

        self.root = tk.Tk()
        self.root.title("TWRP remote \u00b7 Pixel 8")
        self.root.configure(bg=BG)
        self.root.resizable(False, False)
        self.canvas = tk.Canvas(self.root, width=int(1080 * scale), height=int(2400 * scale),
                                bg=BG, highlightthickness=0, cursor="hand2")
        self.canvas.pack(side="left")
        self.item = self.canvas.create_image(0, 0, anchor="nw")

        bar = tk.Frame(self.root, bg=SURFACE)
        bar.pack(side="right", fill="y")
        for label, cmd in (("Power", lambda: self.press(KEY_POWER)),
                           ("Vol +", lambda: self.press(KEY_VOLUMEUP)),
                           ("Vol \u2212", lambda: self.press(KEY_VOLUMEDOWN)),
                           ("Screenshot", self.screenshot)):
            tk.Button(bar, text=label, command=cmd, width=11, relief="flat", bd=0,
                      bg="#1A1A1A", fg=TEXT, activebackground=ACCENT, activeforeground=BG,
                      padx=6, pady=8).pack(padx=10, pady=(10, 0))
        self.status = tk.Label(bar, text="connecting\u2026", bg=SURFACE, fg=MUTED, justify="left")
        self.status.pack(side="bottom", padx=10, pady=10)

        self.canvas.bind("<ButtonPress-1>", lambda e: self.touch("D", e))
        self.canvas.bind("<B1-Motion>", lambda e: self.touch("M", e))
        self.canvas.bind("<ButtonRelease-1>", lambda e: self.touch("U", e))
        self.canvas.bind("<Button-4>", lambda e: self.wheel(e, +1))   # X11 wheel up
        self.canvas.bind("<Button-5>", lambda e: self.wheel(e, -1))   # X11 wheel down
        self.canvas.bind("<MouseWheel>", lambda e: self.wheel(e, 1 if e.delta > 0 else -1))

        threading.Thread(target=self.reader, daemon=True).start()
        self.root.after(15, self.pump)

    # -------------------------------------------------------------- phone -> PC
    def recv_exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("phone closed the connection")
            buf += chunk
        return bytes(buf)

    def reader(self):
        try:
            while True:
                magic, sw, sh, w, h, ln = struct.unpack("<4sHHHHI", self.recv_exact(16))
                if magic != b"TWRF":
                    raise ValueError(f"bad frame header {magic!r}")
                img = Image.frombytes("RGB", (w, h), zlib.decompress(self.recv_exact(ln)))
                try:
                    self.frames.get_nowait()        # keep only the newest frame
                except queue.Empty:
                    pass
                self.frames.put((img, sw, sh))
        except Exception as ex:                     # shown in the status line
            self.frames.put(ex)

    def pump(self):
        try:
            item = self.frames.get_nowait()
        except queue.Empty:
            item = None
        if isinstance(item, Exception):
            self.status.config(text=f"disconnected:\n{item}")
            return
        if item:
            img, sw, sh = item
            self.src, self.last = (sw, sh), img
            self.frame_count += 1
            size = (int(sw * self.scale), int(sh * self.scale))
            self.photo = ImageTk.PhotoImage(img.resize(size, Image.BILINEAR))
            self.canvas.itemconfig(self.item, image=self.photo)
            self.status.config(text=f"{sw}\u00d7{sh}\nframes: {self.frame_count}")
        self.root.after(15, self.pump)

    # -------------------------------------------------------------- PC -> phone
    def send(self, op, a=0, b=0):
        with self.send_lock:
            self.sock.sendall(struct.pack("<BBHHH", ord(op), 0, a, b, 0))

    def panel_xy(self, e):
        x = min(max(int(e.x / self.scale), 0), self.src[0] - 1)
        y = min(max(int(e.y / self.scale), 0), self.src[1] - 1)
        return x, y

    def touch(self, op, e):
        self.send(op, *self.panel_xy(e))

    def press(self, code, hold_ms=80):
        self.send("K", code, 1)
        self.root.after(hold_ms, lambda: self.send("K", code, 0))

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
    Remote(ap.parse_args().scale).root.mainloop()


if __name__ == "__main__":
    main()
