# Third-party components and licenses

This device tree is licensed under the **Apache License 2.0** (`LICENSE`), except
for the parts listed below, which keep their own licenses. Binaries are the
unmodified upstream release files unless noted.

## Bundled binaries

| Component | Version | Files | License | Source |
|---|---|---|---|---|
| **KernelSU** (`ksud`) | v3.3.0 | `recovery/root/system/bin/ksud` = official release asset `ksud-aarch64-linux-android`, SHA-256 `8614de6cdc2233c71fd0d1c64381ea10fbe6658651bae9b5a8dab4fe08e6344b` | GPL-3.0 | https://github.com/tiann/KernelSU/tree/v3.3.0 |
| **Magisk** | 30.7 | everything in `recovery/root/system/etc/twrp_root/magisk/` except `busybox` (binaries `magisk`, `magiskboot`, `magiskinit`, `init-ld`, `stub.apk`, and Magisk's installer scripts) from the official Magisk APK | GPL-3.0 | https://github.com/topjohnwu/Magisk/tree/v30.7 |
| **BusyBox** (Magisk's build) | 1.36.1.1 | `recovery/root/system/etc/twrp_root/magisk/busybox` from the same Magisk APK | GPL-2.0 | https://busybox.net (as built by the Magisk project) |
| **DFE-NEO v2** by LeeGarChat | 2.5.x (`module.prop` versionCode 25) | `recovery/root/system/etc/twrp_dfe/dfe-neo-shiba.zip` - the author's zip; only `NEO.config` replaced by this project's locked preset (verified with `diff -r`) | *no license published* - **permission requested from the author (pending)** | https://github.com/leegarchat/dfe-neo-v2 |

## Source code from other projects

| Component | Where | License | Source |
|---|---|---|---|
| Pixel AIDL boot control HAL | `bootctrl/` (Google's copyright headers kept; one local change, see `bootctrl/Android.bp`) | Apache-2.0 | device/google/gs-common, tag android-14.0.0_r75 |
| TWRP changes | `patches/bootable_recovery.patch` (applies to TWRP's `bootable/recovery`, branch twrp-14.1) | GPL-3.0, as TWRP | https://github.com/TeamWin/android_bootable_recovery |
| AOSP changes | `patches/frameworks_native.patch`, `patches/system_core.patch`, `patches/system_vold.patch` | Apache-2.0, as AOSP | https://android.googlesource.com |
| Parts of `patches/system_vold.patch` (Android 15+ Weaver/synthetic-password handling) | adapted from LeeGarChat's OrangeFox Pixel tree | *no license published* - **permission requested from the author (pending)** | https://github.com/leegarchat |
| `otg_host_ready` kernel module | `otg_host_ready/` and the built `.ko` files in `recovery/root/lib/modules/` | GPL-2.0 (Linux kernel module) | this project |

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
- **LeeGarChat** - DFE-NEO, and the OrangeFox Pixel device tree whose decryption
  research (KeyMint/Weaver/vold on Tensor, Android 15+ formats) made this possible.
- **topjohnwu** - Magisk. **tiann** and contributors - KernelSU.
- **Google / AOSP** - Android, the Pixel boot control HAL, GKI kernel sources.
- **IBM** - IBM Plex. **Florian Karsten** - Space Grotesk.
