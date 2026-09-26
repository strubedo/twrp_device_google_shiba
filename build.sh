#!/usr/bin/env bash
# Build TWRP for Pixel 8 (shiba) and repack it into a flashable vendor_boot.
#
#   device/google/shiba/build.sh            build + gates + repack
#   device/google/shiba/build.sh --flash    ...then flash vendor_boot_a and
#                                           reboot to recovery (phone must be
#                                           in TWRP or Android with ADB up)
#
# Encodes every workaround found while bringing this tree up:
#   * task_profiles.json / mke2fs.conf / servicemanager are copied into the
#     recovery ramdisk by TWRP rules that don't depend on them, so they are
#     pre-built first (clean out/ would otherwise fail or ship without them).
#   * TWRP's relink step never refreshes libraries in recovery/root once its
#     timestamp exists, so the staging root is wiped every build.
#   * Gates check the things that silently broke before (pixel format,
#     servicemanager variant, bootstrap linker symlink) before repacking.
set -eo pipefail

DEVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$DEVICE_DIR/../../.." && pwd)"
cd "$TOP"

export ALLOW_MISSING_DEPENDENCIES=true
# No `set -u`: envsetup.sh's functions (lunch, m) reference unset variables.
# shellcheck disable=SC1091
source build/envsetup.sh >/dev/null
lunch twrp_shiba-ap2a-eng >/dev/null

step() { printf '\n== %s\n' "$*"; }

step "Pre-building modules TWRP copies without declaring dependencies"
m servicemanager task_profiles.json mke2fs.conf -j10 2>&1 | tail -1

step "Wiping stale recovery staging root (relink never refreshes it)"
rm -rf out/target/product/shiba/recovery

step "Building vendorbootimage"
m adbd vendorbootimage -j10 2>&1 | tail -3

step "Gates"
R=out/target/product/shiba/recovery/root
FRAG=out/target/product/shiba/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4
gate() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1" >&2; exit 1; fi; }
gate "pixel format RGBA8888 (ABGR + no R/B swap)" \
     "grep -a -q 'setting DRM_FORMAT_RGBA8888' $R/system/lib64/libminuitwrp.so"
gate "system servicemanager present"              "test -x $R/system/bin/servicemanager"
gate "servicemanager is system variant"           "! grep -a -q VintfObjectRecovery $R/system/bin/servicemanager"
# No -q here: with pipefail, grep -q exits on the first match, cpio/lz4 die
# with SIGPIPE, and the pipeline reports failure even though it matched.
gate "bootstrap/linker64 symlink in fragment" \
     "lz4 -dc $FRAG | cpio -tv 2>/dev/null | grep 'bootstrap/linker64 -> ../linker64' >/dev/null"
gate "fastbootd present"                          "test -x $R/system/bin/fastbootd"
gate "bash present"                               "test -x $R/system/bin/bash"
gate "touch modules present"                      "test -f $R/lib/modules/5.15/goodix_brl_touch.ko"
gate "boot control HAL present"                   "test -x $R/system/bin/hw/android.hardware.boot-service.default_recovery-pixel"
gate "libtrusty present"                          "test -f $R/system/lib64/libtrusty.so"
gate "vendor VINTF base manifest present"        "grep -q IBootControl $R/vendor/etc/vintf/manifest.xml"

step "Repacking vendor_boot"
bash "$DEVICE_DIR/repack.sh"

if [[ "${1:-}" == "--flash" ]]; then
    step "Flashing vendor_boot_a and booting recovery"
    adb reboot bootloader
    fastboot flash vendor_boot_a "$HOME/shiba-stock/twrp_vendor_boot.img"
    fastboot reboot recovery
    adb wait-for-recovery
    echo "TWRP is up."
fi
