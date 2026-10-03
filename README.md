# TWRP for Google Pixel 8 (shiba) — unofficial

> **DRAFT** — not yet released. Sections marked *TBD* are being finalized.

A from-scratch build of **TWRP 3.7.1** (twrp-14.1) for the **Google Pixel 8**
("shiba", Tensor G3), with full **FBE decryption**, **TWRP that survives OTA
updates**, built-in **root** and **encryption** tools, and a PC **remote
control** for the recovery screen.

**Status:** tested on Android 14 and Android 15, including updating from 14 to 15
with TWRP. Android 16 and 17 support is prepared and checked offline (see
`COMPAT_A14-A17.md`); real-device testing is next.

| Android | Firmware tested | Kernel | Status |
|---|---|---|---|
| 14 | AP2A.240605.024, AP2A.240905.003 | 5.15 | ✅ tested, incl. OTA updates from TWRP |
| 15 | BP1A.250405.007.B1 (April 2025) | 6.1 | ✅ tested: OTA 14 → 15 from TWRP (TWRP + root kept), TWRP before and after the first boot, decryption with Android 15's own security services |
| 16 | CP1A.260505.005 | 6.1 | 🔧 prepared (image fits; decryption services' library needs checked and covered), testing next |
| 17 | CP3A.260905.009 | 6.1 | 🔧 prepared (image fits; decryption services' library needs checked and covered), testing next; new lock-screen format unverified |

## Features

**Decryption & storage**
- Full **file-based encryption** support: unlocks `/data` with your **PIN**
  (Titan M2 / Weaver / Gatekeeper / KeyMint), no key upgrades, Android untouched.
- Fixes TWRP changes to `/data` being silently rolled back after an update
  (f2fs checkpoint commit).
- **MTP**, **USB OTG** (flash drives, keyboards) with auto-mount.

**Updates**
- **Install OTA zips from TWRP** with two options:
  - *Reflash TWRP after flashing an OTA* — TWRP is grafted into the updated
    slot's `vendor_boot` and verified byte for byte.
  - *Reinstall root after flashing an OTA* — the same root tool (KernelSU or
    Magisk) is put on the updated slot, checked against **its** kernel.
- **KEEP TWRP** menu: install TWRP to the other slot or both slots.
- Working **slot switching** (Pixel's AIDL boot HAL, built from source; never
  touches the anti-rollback fuses).

**Root** (Advanced → ROOT)
- Install **KernelSU** (official v3.3.0, LKM mode) or **Magisk** (30.7), or
  remove root. Every change is state-checked, backed up, verified after writing,
  and rolled back on any mismatch. KernelSU refuses unsupported kernels (KMI check).
- **KernelSU app installed for you**: put the official `KernelSU_*.apk` in
  `Download/`; if the app isn't installed yet, Install KernelSU sets it up to
  install itself at the next boot (one-shot module, removes itself).

**Encryption** (Advanced → ENCRYPTION) — *experimental*
- Disable or re-enable `/data` encryption. Our own implementation: a small
  overlay (in `super`) shadows `/vendor/etc/init/hw` at first-stage boot, with the
  `/data` encryption flags removed from the fstab; everything is checked, backed
  up, verified after writing and rolled back on failure. **Disabling formats
  `/data`.** A *Dry run* builds and verifies everything without writing.
  Verified on a real phone up to the writes; a full disable-and-boot test on a
  wiped phone is still pending.
- OTA guard: if encryption is disabled, an OTA can't keep it disabled — TWRP keeps
  the phone on the current slot instead of booting an unbootable one.

**Tools** (Advanced → TOOLS)
- **Enable USB debugging** in Android (root module; the PC is authorized via the
  normal "Allow" prompt, or the remote's *Authorize PC*).
- **Collect logs**: one archive with everything needed to diagnose a problem
  (TWRP and crypto logs, kernel log, modules, partitions, update state,
  versions), saved to Download/ (or a USB drive, if /data is locked). The serial
  number and IMEI are removed first. **When reporting a problem, attach this.**
  TWRP Remote has a *Collect logs* button that saves it straight to the PC.

**Look**
- **Graphite** theme: dark, Material-style, with live status chips
  (slot, data state, root).

## TWRP Remote (PC)

`twrp_remote/` — view and control TWRP from your PC over USB (adb): live screen,
touch, keyboard typing, reboot menu, screenshots. Switches to **scrcpy**
automatically when the phone is in Android. Linux and Windows.

```
# Linux: installs what's missing (adb, Python Tk/venv; scrcpy optional - apt, dnf,
# pacman or zypper), its own Python environment, and the menu entry
./twrp_remote/install_linux.sh            # --uninstall to remove
# Windows: build_windows.bat builds "TWRP Remote.exe" (needs Python 3), then
# install_windows.bat installs it, gets adb (and optionally scrcpy) from their
# official sources and adds a Start menu shortcut (not yet tested on Windows)
```

Screenshots are saved to **Pictures/TWRP Remote**; the **Screenshots** button opens that folder.

## ⚠️ Before you start

- **Unlocked bootloader required** (wipes your phone the first time).
- **Anti-rollback:** firmware from **May 2025 onward** permanently raises the
  phone's anti-rollback level. Never flash older firmware than you have.
- **Back up** your data. Disabling encryption formats `/data`.
- Going from Android 14 to 15+ is one-way for your data (downgrading needs a wipe).
- **After an update's first boot, the old slot is gone.** Pixels use virtual A/B:
  once Android finishes merging the update in the background, the previous
  slot's system is released. Test TWRP on the updated slot (Reboot → Recovery)
  **before** booting Android if you want a way back.
- On Android 15+, TWRP's install drops the `vendor_boot` part used only by the
  developer option **"Boot with 16 KB page size"** (it doesn't fit next to
  TWRP). That option needs the stock `vendor_boot`; normal booting is unaffected.
- This is unofficial and comes with **no warranty**.

## Installation

> Tested on a real Pixel 8 (2026-10-02): first install onto a slot with Google's
> stock vendor_boot, both the root and the factory-image path; plus simulated
> phones for every refusal case.

TWRP lives in `vendor_boot`. The release doesn't ship an image built for one
firmware: **`install_twrp.py` grafts TWRP onto your phone's own `vendor_boot`**
(the same operation as *Reflash TWRP after OTA*), keeps a backup of the
original, and flashes it - so it works on **any firmware build**.

Requirements: unlocked bootloader; Android platform-tools (`adb`, `fastboot`);
Python 3 with `lz4` (`pip install lz4`); the phone in Android with USB debugging on.

Your `vendor_boot` is read **from the phone** if it's rooted (KernelSU or Magisk:
allow the Shell app root when asked). Otherwise download the **factory image for
your exact build** (Settings → About phone → Build number) from
<https://developers.google.com/android/images#shiba> into `Downloads/` - the
installer finds it and refuses one for a different build.

```
python3 install_twrp.py --dry-run     # check everything, build + verify the image, flash nothing
python3 install_twrp.py               # install
```

Before flashing it re-checks in fastboot: product `shiba`, bootloader unlocked,
same slot as Android, image fits the partition. Then in TWRP: enter your PIN,
**Advanced → KEEP TWRP → Install to both slots**.

To remove TWRP: flash the backup it printed (`fastboot flash vendor_boot_X <backup>`),
or your firmware's stock `vendor_boot`.

(Why not `fastboot fetch`? Stock fastbootd only allows it on debuggable builds.)

## Building

Requires a TWRP **twrp-14.1** minimal manifest checkout (~90 GB), Linux, 16 GB+ RAM.

```
repo init --depth=1 -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp.git -b twrp-14.1
repo sync
git clone <this repo> device/google/shiba
# apply patches/*.patch to bootable/recovery, frameworks/native, system/core, system/vold
cd device/google/shiba && ./build.sh            # ./build.sh --flash to flash a connected phone
```

`build.sh` runs 35+ safety gates and refuses to produce an image if any fails.
It needs the stock `vendor_boot.img` of your firmware in `~/shiba-stock/factory/`.

## Version history

Newest first. Every version is a git tag in this repository; its commit message
has the technical details.

**v9.35** (2026-10-02) - **Universal installer**: `install_twrp.py` installs TWRP on
any firmware build by grafting it onto your phone's own `vendor_boot` (read from a
rooted phone, or from the factory image for your exact build), with a backup and
full re-checks before flashing. Release packaging with checksums.

**v9.34** (2026-10-02) - App installers for both root tools: after Install KernelSU
or Install Magisk, the matching app installs itself at the next boot (official APK
from Download/, or Magisk's stub).

**v9.33** (2026-10-02) - KernelSU app installer (first version). Build check that
keeps TWRP within the size the bootloader can load.

**v9.32** (2026-10-02) - Touch drivers come from the phone's own firmware, so the
touchscreen works on every Android version without bundled drivers.

**v9.31** (2026-10-01) - Boot control built from Google's open source (no prebuilt
binary); it can never touch the anti-rollback fuses from recovery.

**v9.30** (2026-10-01) - TWRP stays awake while the PC remote is connected.

**v9.29** (2026-10-01) - Fix: switching slots (Reboot > Slot A/B) now really changes
the boot slot. Settings are saved immediately, so they survive any reboot.

**v9.28** (2026-10-01) - *Reinstall root after flashing an OTA*: one install updates
the phone, keeps TWRP and puts root back.

**v9.27** (2026-10-01) - OTA updates from TWRP verified end to end; flashing targets
the current slot.

**v9.26** (2026-10-01) - OTA guard for disabled encryption: TWRP keeps the phone on
the working slot instead of booting one that can't start.

**v9.25** (2026-10-01) - Root status chip on the main screen (KernelSU / Magisk /
Not rooted). PC remote: *Authorize PC* for USB debugging.

**v9.24** (2026-10-01) - PC remote for Linux and Windows; switches to scrcpy when
the phone is in Android.

**v9.23** (2026-10-01) - PC remote: type on the phone from the PC keyboard.

**v9.22** (2026-10-01) - **TWRP Remote**: view and control TWRP from the PC over USB.

**v9.21** (2026-09-29) - Advanced > TOOLS: Enable USB debugging in Android.

**v9.20** (2026-09-29) - Fix: changes made to /data in TWRP were rolled back at
the next boot (f2fs checkpoint); they now persist.

**v9.19** (2026-09-29) - Graphite theme: redesigned Advanced page with grouped sections.

**v9.18** (2026-09-29) - Graphite theme complete: new main screen with live status chips.

**v9.16** (2026-09-29) - Graphite theme: new splash screen, header and status line.

**v9.15** (2026-09-29) - Graphite theme: redesigned PIN screen.

**v9.14** (2026-09-29) - Graphite theme: main-menu icons.

**v9.13** (2026-09-29) - Graphite theme: all theme images drawn from vector sources.

**v9.12** (2026-09-29) - **Graphite theme** (first stage): dark palette, new fonts.

**v9.11** (2026-09-29) - Preparation for Android 16 firmware (newer vendor HALs).

**v9.10** (2026-09-29) - Install KernelSU checks that the kernel is supported first.

**v9.9** (2026-09-29) - **Encryption menu**: disable or re-enable /data encryption
(DFE-NEO). Version number shown from the release tag.

**v9.8** (2026-09-29) - MTP: browse the phone's storage from a PC while in TWRP.

**v9.7** (2026-09-27) - USB OTG drives mount automatically.

**v9.6** (2026-09-27) - **USB OTG** in recovery (flash drives, keyboards).

**v9.5** (2026-09-27) - **Keep TWRP after OTA** complete: install TWRP to the other
or both slots; reflash automatically after an update.

**v9.4** (2026-09-27) - Keep TWRP after OTA: the image tool behind it (vbgraft).

**v9.3** (2026-09-27) - Faster startup.

**v9.1** (2026-09-27) - Decryption no longer changes any keys on the phone.

**v9** (2026-09-27) - **Full decryption**: /data unlocks with your PIN (Titan M2).

**v6** (2026-09-26) - Root menu (KernelSU / Magisk / remove) with on-screen
output. TWRP boots, without decryption.

## License

Apache License 2.0 (`LICENSE`), except the parts listed in
`THIRD_PARTY_NOTICES.md` (TWRP changes GPL-3.0, OTG kernel module GPL-2.0,
bundled KernelSU/Magisk/BusyBox, fonts under OFL-1.1).

## Credits

TeamWin (TWRP) · LeeGarChat (the OrangeFox Pixel tree whose decryption research
made this possible, and DFE-NEO, whose approach inspired our encryption tool) ·
topjohnwu (Magisk) · tiann and
contributors (KernelSU) · Google/AOSP · IBM (Plex) · Florian Karsten (Space Grotesk).
