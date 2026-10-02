# TWRP for Google Pixel 8 (shiba) — unofficial

> **DRAFT** — not yet released. Sections marked *TBD* are being finalized.

A from-scratch build of **TWRP 3.7.1** (twrp-14.1) for the **Google Pixel 8**
("shiba", Tensor G3), with full **FBE decryption**, **TWRP that survives OTA
updates**, built-in **root** and **encryption** tools, and a PC **remote
control** for the recovery screen.

**Status:** tested daily on Android 14. Android 15–17 support is prepared and
checked offline (see `COMPAT_A14-A17.md`), not yet tested on a real phone.

| Android | Firmware tested | Kernel | Status |
|---|---|---|---|
| 14 | AP2A.240605.024, AP2A.240905.003 | 5.15 | ✅ tested, incl. OTA updates from TWRP |
| 15 | BP1A.250405.007.B1 (April 2025) | 6.1 | 🔧 prepared, real-device test pending |
| 16 | CP1A.260505.005 | 6.1 | 🔧 prepared, untested |
| 17 | CP3A.260905.009 | 6.1 | 🔧 prepared, untested (new lock-screen format unverified) |

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

**Encryption** (Advanced → ENCRYPTION)
- Disable or re-enable `/data` encryption using **DFE-NEO** (by LeeGarChat) with
  a fixed, safe configuration. **Disabling formats `/data`.**
- OTA guard: if encryption is disabled, an OTA can't keep it disabled — TWRP keeps
  the phone on the current slot instead of booting an unbootable one.

**Tools** (Advanced → TOOLS)
- **Enable USB debugging** in Android (root module; the PC is authorized via the
  normal "Allow" prompt, or the remote's *Authorize PC*).

**Look**
- **Graphite** theme: dark, Material-style, with live status chips
  (slot, data state, root).

## TWRP Remote (PC)

`twrp_remote/` — view and control TWRP from your PC over USB (adb): live screen,
touch, keyboard typing, reboot menu, screenshots. Switches to **scrcpy**
automatically when the phone is in Android. Linux and Windows.

```
# Linux
sudo apt install adb python3-tk python3-pil python3-pil.imagetk   # (scrcpy optional)
./twrp_remote/install_linux.sh          # adds "TWRP Remote" to your app menu
# Windows: build_windows.bat builds "TWRP Remote.exe" (needs Python 3)
```

## ⚠️ Before you start

- **Unlocked bootloader required** (wipes your phone the first time).
- **Anti-rollback:** firmware from **May 2025 onward** permanently raises the
  phone's anti-rollback level. Never flash older firmware than you have.
- **Back up** your data. Disabling encryption formats `/data`.
- Going from Android 14 to 15+ is one-way for your data (downgrading needs a wipe).
- This is unofficial and comes with **no warranty**.

## Installation

> The installer is tested against simulated phones (fake adb/fastboot, real
> vendor_boot layouts); its first real-phone run is pending.

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

## License

Apache License 2.0 (`LICENSE`), except the parts listed in
`THIRD_PARTY_NOTICES.md` (TWRP changes GPL-3.0, OTG kernel module GPL-2.0,
bundled KernelSU/Magisk/BusyBox, fonts under OFL-1.1).

## Credits

TeamWin (TWRP) · LeeGarChat (DFE-NEO and the OrangeFox Pixel tree whose
decryption research made this possible) · topjohnwu (Magisk) · tiann and
contributors (KernelSU) · Google/AOSP · IBM (Plex) · Florian Karsten (Space Grotesk).
