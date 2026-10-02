#!/usr/bin/env python3
"""install_twrp.py - install this TWRP on any Pixel 8 (shiba) firmware.

TWRP lives in vendor_boot. Instead of flashing an image built for one firmware,
this grafts TWRP's recovery fragment onto the phone's OWN vendor_boot (the same
operation as TWRP's "Reflash TWRP after OTA", here done on the PC with
vbgraft.py), keeps a backup of the original, and flashes the result.

The phone's vendor_boot comes from:
  - the phone itself, if Android is rooted (KernelSU / Magisk: su), or
  - the factory image for the phone's exact build (--factory ZIP, or found in
    ~/Downloads as shiba-<build>-factory-*.zip).
(Stock fastbootd can't `fetch` partitions: that's compiled into debuggable
builds only.)

  python3 install_twrp.py [--frag recovery.cpio.lz4] [--factory ZIP] [--dry-run]

Needs: adb + fastboot (Android platform-tools), Python 3 with `lz4`
(pip install lz4), the phone in Android with USB debugging on, bootloader
unlocked. Afterwards, in TWRP: Advanced > KEEP TWRP > Install to both slots.
"""
import argparse
import glob
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "vbgraft"))

DEVICE = "shiba"
PARTITION_SIZE = 64 * 1024 * 1024      # vendor_boot_a/_b on shiba; re-read in fastboot
MAX_FRAGMENT = 46_000_000              # largest recovery fragment proven to boot (+~1 MB);
                                       # a 55.4 MB one dropped to fastboot (see build.sh)
WINDOWS = os.name == "nt"
# vbgraft.py: next to this script (release) or in vbgraft/ (device tree)
VBGRAFT = next((p for p in (os.path.join(HERE, "vbgraft.py"), os.path.join(HERE, "vbgraft", "vbgraft.py"))
                if os.path.isfile(p)), None)


def say(msg=""):
    print(msg, flush=True)


def fail(msg):
    say("\nERROR: " + msg)
    say("Nothing was flashed.")
    sys.exit(1)


# ---- tools ------------------------------------------------------------------
def find_tool(name, override=None):
    if override:
        return override
    exe = name + (".exe" if WINDOWS else "")
    found = shutil.which(exe)
    if found:
        return found
    candidates = [os.path.join(HERE, "platform-tools", exe)]
    for env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(env):
            candidates.append(os.path.join(os.environ[env], "platform-tools", exe))
    candidates += [os.path.expanduser("~/platform-tools/" + exe), "C:\\platform-tools\\" + exe]
    for c in candidates:
        if os.path.isfile(c):
            return c
    fail("%s not found - install Android platform-tools and add them to PATH" % name)


class Phone:
    def __init__(self, adb, fastboot):
        self.adb, self.fastboot = adb, fastboot

    def run(self, tool, args, timeout=60, binary=False):
        try:
            r = subprocess.run([tool] + args, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return 124, b"" if binary else ""
        if binary:
            return r.returncode, r.stdout
        return r.returncode, (r.stdout + r.stderr).decode(errors="replace").strip()

    def adb_state(self):
        rc, out = self.run(self.adb, ["get-state"], timeout=10)
        return out if rc == 0 else ""

    def prop(self, name):
        rc, out = self.run(self.adb, ["shell", "getprop", name], timeout=15)
        return out.strip() if rc == 0 else ""

    def getvar(self, var):
        # fastboot prints "var: value" on stderr
        rc, out = self.run(self.fastboot, ["getvar", var], timeout=20)
        for line in out.splitlines():
            if line.startswith(var + ":"):
                return line.split(":", 1)[1].strip()
        return ""


# ---- getting the phone's own vendor_boot ------------------------------------
def is_vendor_boot(data):
    return len(data) >= 8 and data[:8] == b"VNDRBOOT"


def from_root(phone, slot):
    """Read vendor_boot_<slot> through su. Returns bytes or None."""
    rc, out = phone.run(phone.adb, ["shell", "su", "-c", "id"], timeout=30)
    if rc != 0 or "uid=0" not in out:
        return None
    say("- Root available (%s): reading vendor_boot%s from the phone" % (out.split()[0], slot))
    rc, data = phone.run(phone.adb, ["exec-out", "su", "-c",
                                     "cat /dev/block/by-name/vendor_boot" + slot],
                         timeout=120, binary=True)
    if rc != 0 or not is_vendor_boot(data):
        say("  ! could not read it through su (%d bytes) - trying the factory image instead" % len(data))
        return None
    return data


def find_factory_zip(build_id, explicit):
    if explicit:
        return explicit
    pattern = "%s-%s-factory-*.zip" % (DEVICE, build_id.lower())
    for d in (os.getcwd(), os.path.expanduser("~/Downloads"), HERE):
        hits = sorted(glob.glob(os.path.join(d, pattern)))
        if hits:
            return hits[-1]
    return None


def from_factory(zip_path, build_id):
    """vendor_boot.img from the factory zip for exactly this build."""
    say("- Factory image: %s" % zip_path)
    try:
        outer = zipfile.ZipFile(zip_path)
    except (OSError, zipfile.BadZipFile) as e:
        fail("cannot open %s: %s" % (zip_path, e))
    want = "image-%s-%s.zip" % (DEVICE, build_id.lower())
    inner_names = [n for n in outer.namelist() if os.path.basename(n).startswith("image-%s-" % DEVICE)]
    if not inner_names:
        fail("%s is not a %s factory image (no image-%s-*.zip inside)" % (zip_path, DEVICE, DEVICE))
    inner_name = inner_names[0]
    if os.path.basename(inner_name) != want:
        fail("factory image is for %s, but the phone runs %s - download the factory image for %s"
             % (os.path.basename(inner_name)[len("image-%s-" % DEVICE):-4].upper(), build_id, build_id))
    info = outer.getinfo(inner_name)
    if info.compress_type == zipfile.ZIP_STORED:
        # read straight through the outer zip (seekable when stored)
        inner = zipfile.ZipFile(outer.open(inner_name))
        data = inner.read("vendor_boot.img")
    else:
        say("  (unpacking the inner image zip to a temporary file, %d MB)" % (info.file_size >> 20))
        with tempfile.TemporaryDirectory() as td:
            p = outer.extract(inner_name, td)
            data = zipfile.ZipFile(p).read("vendor_boot.img")
    if not is_vendor_boot(data):
        fail("vendor_boot.img in the factory image is not a vendor_boot image")
    return data


def recovery_fragments(data):
    import vbgraft
    vb = vbgraft.parse(data, "vendor_boot")
    return [f for f in vb.frags if f.type == vbgraft.TYPE_RECOVERY]


# ---- main -------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Install TWRP on a Pixel 8 (shiba), any firmware.")
    ap.add_argument("--frag", default=os.path.join(HERE, "recovery.cpio.lz4"),
                    help="TWRP recovery fragment (default: recovery.cpio.lz4 next to this script)")
    ap.add_argument("--factory", help="factory image zip for the phone's exact build")
    ap.add_argument("--out", default=os.path.join(HERE, "twrp-install"),
                    help="folder for the backup and the grafted image")
    ap.add_argument("--dry-run", action="store_true",
                    help="build and verify the image, print the flash commands, flash nothing")
    ap.add_argument("--adb"), ap.add_argument("--fastboot")
    args = ap.parse_args()

    if not VBGRAFT:
        fail("vbgraft.py not found next to this script")
    try:
        import lz4.block  # noqa: F401
    except ImportError:
        fail("the lz4 Python package is missing: pip install lz4")
    if not os.path.isfile(args.frag):
        fail("TWRP recovery fragment not found: %s" % args.frag)
    frag = open(args.frag, "rb").read()
    if len(frag) < 4 or struct.unpack_from("<I", frag)[0] != 0x184C2102:
        fail("%s is not a TWRP recovery fragment (lz4 legacy)" % args.frag)
    if len(frag) > MAX_FRAGMENT:
        fail("recovery fragment is %d bytes; more than %d won't boot on this phone" % (len(frag), MAX_FRAGMENT))

    phone = Phone(find_tool("adb", args.adb), find_tool("fastboot", args.fastboot))

    # 1. the phone, in Android
    say("== Checking the phone")
    state = phone.adb_state()
    if state != "device":
        fail("no phone in Android with USB debugging (adb state: '%s'). Boot Android, enable "
             "USB debugging, connect, and allow this PC." % (state or "none"))
    device = phone.prop("ro.product.device")
    build_id = phone.prop("ro.build.id")
    slot = phone.prop("ro.boot.slot_suffix")
    say("- %s, build %s, slot %s" % (device, build_id, slot))
    if device != DEVICE:
        fail("this installer is for the Pixel 8 (%s), not '%s'" % (DEVICE, device))
    if slot not in ("_a", "_b") or not build_id:
        fail("could not read the build ID / slot from the phone")

    # 2. its own vendor_boot
    say("== Getting the phone's own vendor_boot")
    data = from_root(phone, slot)
    source = "phone (root)"
    if data is None:
        z = find_factory_zip(build_id, args.factory)
        if not z:
            fail("no root, and no factory image for %s found.\n"
                 "Download it from https://developers.google.com/android/images#shiba\n"
                 "(the %s row) and run again with --factory <zip>, or put it in ~/Downloads."
                 % (build_id, build_id))
        data = from_factory(z, build_id)
        source = "factory image " + os.path.basename(z)
    if len(data) > PARTITION_SIZE:
        fail("vendor_boot is %d bytes, larger than the partition" % len(data))
    recs = recovery_fragments(data)
    if recs:
        say("- note: it already has a recovery fragment (%d bytes) - it will be replaced" % len(recs[0].data))

    # 3. backup + graft
    os.makedirs(args.out, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(args.out, "vendor_boot%s-%s-original-%s.img" % (slot, build_id, stamp))
    with open(backup, "wb") as f:
        f.write(data)
    say("- Backup of the original: %s" % backup)

    say("== Grafting TWRP onto it (vbgraft)")
    grafted = os.path.join(args.out, "vendor_boot%s-%s-twrp-%s.img" % (slot, build_id, stamp))
    r = subprocess.run([sys.executable, VBGRAFT, "--src", backup, "--recovery-frag", args.frag,
                        "--out", grafted, "--max-size", str(PARTITION_SIZE)])
    if r.returncode != 0 or not os.path.isfile(grafted):
        fail("vbgraft refused or failed (see above)")

    flash = ["flash", "vendor_boot" + slot, grafted]
    restore = "fastboot flash vendor_boot%s \"%s\"" % (slot, backup)
    if args.dry_run:
        say("\n== Dry run - nothing flashed. The installer would now run:")
        say("   adb reboot bootloader")
        say("   fastboot " + " ".join('"%s"' % a if " " in a else a for a in flash))
        say("   fastboot reboot recovery")
        say("To undo later: " + restore)
        return 0

    # 4. flash, after re-checking everything in fastboot
    say("== Rebooting to the bootloader")
    phone.run(phone.adb, ["reboot", "bootloader"], timeout=30)
    for _ in range(60):
        rc, out = phone.run(phone.fastboot, ["devices"], timeout=10)
        if out.strip():
            break
        time.sleep(1)
    else:
        fail("the phone didn't show up in fastboot. (Check the USB driver on Windows.)")
    product = phone.getvar("product")
    unlocked = phone.getvar("unlocked")
    cur = phone.getvar("current-slot")
    size = phone.getvar("partition-size:vendor_boot" + slot)
    say("- fastboot: product %s, unlocked %s, current slot %s, vendor_boot%s %s"
        % (product, unlocked, cur, slot, size))
    if product != DEVICE:
        fail("fastboot reports product '%s', not %s" % (product, DEVICE))
    if unlocked != "yes":
        fail("the bootloader is locked - unlock it first (this wipes the phone)")
    if "_" + cur != slot:
        fail("fastboot's current slot (%s) differs from Android's (%s)" % (cur, slot))
    try:
        if size and os.path.getsize(grafted) > int(size, 16):
            fail("the image is larger than vendor_boot%s (%s)" % (slot, size))
    except ValueError:
        pass
    say("== Flashing vendor_boot%s" % slot)
    rc, out = phone.run(phone.fastboot, flash, timeout=180)
    say(out)
    if rc != 0:
        say("\nFlashing failed. Your original is safe in the backup; restore with:\n   " + restore)
        sys.exit(1)
    phone.run(phone.fastboot, ["reboot", "recovery"], timeout=30)
    say("\n== Done. The phone is booting TWRP.")
    say("In TWRP: enter your PIN, then Advanced > KEEP TWRP > Install to both slots.")
    say("To undo (from fastboot): " + restore)
    return 0


if __name__ == "__main__":
    sys.exit(main())
