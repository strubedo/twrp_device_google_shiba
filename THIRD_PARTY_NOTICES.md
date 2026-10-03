# Third-party components and licenses

This device tree is licensed under the **Apache License 2.0** (`LICENSE`), except
for **TWRP Remote** (`twrp_remote/`: the PC app, its installers and the phone-side
server), which is licensed under the **GNU General Public License v3.0 or later**
(`twrp_remote/LICENSE`), and the parts listed below, which keep their own
licenses. Binaries are the unmodified upstream release files unless noted.

## Bundled binaries

| Component | Version | Files | License | Source |
|---|---|---|---|---|
| **KernelSU** (`ksud`) | v3.3.0 | `recovery/root/system/bin/ksud` = official release asset `ksud-aarch64-linux-android`, SHA-256 `8614de6cdc2233c71fd0d1c64381ea10fbe6658651bae9b5a8dab4fe08e6344b` | GPL-3.0 | https://github.com/tiann/KernelSU/tree/v3.3.0 |
| **Magisk** | 30.7 | everything in `recovery/root/system/etc/twrp_root/magisk/` except `busybox` (binaries `magisk`, `magiskboot`, `magiskinit`, `init-ld`, `stub.apk`, and Magisk's installer scripts) from the official Magisk APK | GPL-3.0 | https://github.com/topjohnwu/Magisk/tree/v30.7 |
| **BusyBox** (Magisk's build) | 1.36.1.1 | `recovery/root/system/etc/twrp_root/magisk/busybox` from the same Magisk APK | GPL-2.0 | https://busybox.net (as built by the Magisk project) |

"Disable encryption" (`twrp_encryption.sh`, `lptool/`, `vbgraft --fstab-*`) is this
project's own implementation (Apache-2.0); it bundles no third-party installer.

## Source code from other projects

| Component | Where | License | Source |
|---|---|---|---|
| Pixel AIDL boot control HAL | `bootctrl/` (Google's copyright headers kept; one local change, see `bootctrl/Android.bp`) | Apache-2.0 | device/google/gs-common, tag android-14.0.0_r75 |
| TWRP changes | `patches/bootable_recovery.patch` (applies to TWRP's `bootable/recovery`, branch twrp-14.1) | GPL-3.0, as TWRP | https://github.com/TeamWin/android_bootable_recovery |
| AOSP changes | `patches/frameworks_native.patch`, `patches/system_core.patch`, `patches/system_vold.patch` | Apache-2.0, as AOSP | https://android.googlesource.com |
| Parts of `patches/system_vold.patch` (Android 15+ Weaver/synthetic-password handling) | adapted from LeeGarChat's OrangeFox Pixel tree | no license published; **used with the author's permission** (granted by LeeGarChat on Telegram, 2026-10-02) | https://github.com/leegarchat |
| `recovery-tensor-daemon/` (Trusty storage proxy + Titan M2 Weaver, Rust) | LeeGarChat's OrangeFox Pixel tree (`include/recovery-tensor-daemon`, branch R12_14.1), unmodified | MIT OR Apache-2.0 (`recovery-tensor-daemon/LICENSE-MIT`, `LICENSE-APACHE`) | https://github.com/leegarchat/twrp_device_google_pixels |
| Recovery build support for Rust: `patches/system_tools_aidl.patch`, `hardware_interfaces.patch`, `external_rust_crates_*.patch`, the Rust parts of `frameworks_native.patch` | from LeeGarChat's OrangeFox Pixel tree (`patches/`), plus enabling the Weaver AIDL Rust backend | Apache-2.0, as AOSP | https://github.com/leegarchat/twrp_device_google_pixels |
| `otg_host_ready` kernel module | `otg_host_ready/` and the built `.ko` files in `recovery/root/lib/modules/` | GPL-2.0 (Linux kernel module) | this project; on kernel 6.1 its kprobe lookup and `/proc` switch follow LeeGarChat's `otg_host_shim` (GPL), used with permission |
| USB OTG host switching in `twrp_otg_watch.sh` (OTG ID to host + 5 V through the CHARGER_MODE vote, VBUS-based role changes) | after LeeGarChat's zuma OTG method (`include/recovery-pixel-boot/src/usb/zuma.rs`), reimplemented in shell | used with the author's permission | https://github.com/leegarchat/twrp_device_google_pixels |
| Touchscreen drivers (fallback): `heatmap.ko`, `goog_touch_interface.ko`, `goodix_brl_touch.ko` | `recovery/root/system/etc/touch_fallback/<kernel release>/`, unmodified, extracted from `vendor_dlkm` in Google's Pixel 8 factory images (the build is named in each folder's `FROM_BUILD`) | GPL-2.0 (Linux kernel modules) | Google's Pixel kernel modules source: https://android.googlesource.com/kernel/google-modules/ (touch: `touch/common`, `touch/goodix`) |

## Fonts

| Font | Files | License |
|---|---|---|
| IBM Plex Sans, IBM Plex Mono | `theme/graphite/fonts/`, `recovery/root/twres/fonts/` | SIL Open Font License 1.1 - `licenses/OFL-IBM-Plex.txt` |
| Space Grotesk | `theme/graphite/fonts/`, `recovery/root/twres/fonts/` | SIL Open Font License 1.1 - `licenses/OFL-Space-Grotesk.txt` |
| Roboto Condensed, Droid Sans Mono | `theme/base/fonts/` (TWRP's stock theme, kept as the theme build's base) | Apache-2.0 |

## Not bundled
Touch drivers and all other vendor kernel modules are loaded from the phone's own
firmware (vendor_kernel_boot / vendor_dlkm) at runtime; no Google vendor binaries
are distributed here.

## Credits
- **TeamWin** - TWRP.
- **LeeGarChat** - the OrangeFox Pixel device tree whose decryption research
  (KeyMint/Weaver/vold on Tensor, Android 15+ formats) made this possible, and
  DFE-NEO, whose first-stage overlay approach showed how to disable encryption on
  these phones.
- **topjohnwu** - Magisk. **tiann** and contributors - KernelSU.
- **Google / AOSP** - Android, the Pixel boot control HAL, GKI kernel sources.
- **IBM** - IBM Plex. **Florian Karsten** - Space Grotesk.
