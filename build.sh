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

step "Generating root-menu shim zips"
python3 "$DEVICE_DIR/mkrootzips.py"

step "Pre-building modules TWRP copies without declaring dependencies"
m servicemanager task_profiles.json mke2fs.conf -j10 2>&1 | tail -1

step "Wiping stale recovery staging root (relink never refreshes it)"
rm -rf out/target/product/shiba/recovery

step "Building vendorbootimage"
BUILD_LOG="$HOME/twrp-build.log"
if ! m adbd vendorbootimage vbgraft -j10 > "$BUILD_LOG" 2>&1; then
    echo "BUILD FAILED - first error:"
    grep -m1 -A30 'FAILED:' "$BUILD_LOG" || tail -40 "$BUILD_LOG"
    echo "full log: $BUILD_LOG"
    exit 1
fi
tail -3 "$BUILD_LOG"

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
gate "root script present"                        "test -x $R/system/bin/twrp_root.sh"
gate "ksud present"                               "test -x $R/system/bin/ksud"
gate "Magisk patcher present"                     "test -f $R/system/etc/twrp_root/magisk/boot_patch.sh -a -f $R/system/etc/twrp_root/magisk/magiskinit"
gate "root menu in theme"                         "grep -q 'twrp_root/install-ksu.zip' $R/twres/portrait.xml"
gate "root shim zips present"                     "test -f $R/system/etc/twrp_root/status.zip -a -f $R/system/etc/twrp_root/install-ksu.zip -a -f $R/system/etc/twrp_root/install-magisk.zip -a -f $R/system/etc/twrp_root/remove.zip"
gate "boot-repack menu items hidden"              "grep -q tw_shiba_never $R/twres/portrait.xml"
gate "CPU temp label in Fahrenheit"               "grep -q 'tw_cpu_temp% &#xB0;F' $R/twres/languages/en.xml"
gate "recovery storageproxyd (no wakelock) present" "test -x $R/system/bin/storageproxyd && ! /bin/grep -a -q acquire_wake_lock $R/system/bin/storageproxyd"
gate "twrp_crypto_start.sh (SPL-gated KeyMint) present" "test -x $R/system/bin/twrp_crypto_start.sh && grep -q REFUSING $R/system/bin/twrp_crypto_start.sh"
gate "resetprop present"                          "test -x $R/system/bin/resetprop"
gate "Decrypt_Data runs twrp_crypto_start.sh"     "/bin/grep -a -q twrp_crypto_start.sh $R/system/bin/recovery"
gate "KeyMint declared in VINTF"                  "grep -q IKeyMintDevice $R/vendor/etc/vintf/manifest.xml"
gate "keystore2 declared in VINTF"                "grep -q IKeystoreService $R/vendor/etc/vintf/manifest.xml"
gate "keystore2 not auto-started (KeyMint first)" "! grep -q 'start keystore2' $R/system/etc/init/keystore2.rc && grep -q disabled $R/system/etc/init/keystore2.rc"
gate "decryption services defined, disabled"     "grep -q 'service twrp.keymint' $R/init.recovery.zuma.rc"
gate "Gatekeeper + Weaver declared in VINTF"     "grep -q IGatekeeper $R/vendor/etc/vintf/manifest.xml && grep -q IWeaver $R/vendor/etc/vintf/manifest.xml"
gate "recovery has AIDL Gatekeeper path"         "/bin/grep -a -q 'android.hardware.gatekeeper.IGatekeeper/default' $R/system/bin/recovery"
gate "no KDF research hook in recovery"          "! /bin/grep -a -q -e fox_fbe_kdf -e fox_kdf.conf $R/system/bin/recovery"
gate "service tool present"                       "test -x $R/system/bin/service"
gate "vndbinder routed to binder for Weaver"      "grep -q 'ln -s /dev/binderfs/binder /dev/vndbinder' $R/system/bin/twrp_crypto_start.sh"
gate "citadeld/weaver launched via sh (SELinux)"  "grep -q 'sh -c \"exec /vendor/bin/hw/citadeld' $R/init.recovery.zuma.rc"
gate "keystore2 restarted after copySqliteDb"     "/bin/grep -a -q 'Restarting keystore2 to load' $R/system/bin/recovery"
gate "OS version matched to installed (KeyMint)"  "grep -q 'resetprop ro.build.version.release ' $R/system/bin/twrp_crypto_start.sh"
gate "vold writes upgraded keys only if upgraded" "/bin/grep -a -q 'RAM only, not committed' $R/system/bin/recovery"
gate "/data size walk deferred to Backup"        "/bin/grep -a -q 'deferred until needed' $R/system/bin/recovery && grep -q tw_shiba_exact_data_size $R/twres/portrait.xml"
gate "vbgraft (on-device TWRP install) present"   "test -x $R/system/bin/vbgraft && test -x $R/system/bin/twrp_install_slot.sh"
gate "TWRP install menu entries + zips"          "grep -q twrp-install-other.zip $R/twres/portrait.xml && test -f $R/system/etc/twrp_root/twrp-install-other.zip && test -f $R/system/etc/twrp_root/twrp-install-both.zip"
gate "official TWRP app excluded"                "! test -e $R/system/bin/me.twrp.twrpapp.apk"
gate "timezone database present"                 "test -s $R/system/usr/share/zoneinfo/tzdata"
gate "bash extras present (bashrc, /sbin/bash)"  "test -s $R/system/etc/bash/bashrc && test -L $R/sbin/bash"
gate "USB OTG: module + load list + storage entry" "test -s $R/lib/modules/5.15/otg_host_ready.ko && grep -q otg_host_ready.ko $R/lib/modules/5.15/modules.dep && grep -q '^/usb-otg' $R/system/etc/twrp.flags"
gate "auto-reflash after OTA -> vendor_boot script" "/bin/grep -a -q 'twrp_install_slot.sh other' $R/system/bin/recovery"

step "Shared library check (every ELF's NEEDED libs present in the ramdisk)"
python3 "$DEVICE_DIR/check_libs.py" || { echo "FAIL: missing libraries above - not repacking"; exit 1; }

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
