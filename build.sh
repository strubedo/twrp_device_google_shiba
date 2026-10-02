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

# Version shown in TWRP (TW_DEVICE_VERSION, read by BoardConfig.mk) comes from
# the latest device-tree tag: v9.9-encryption -> shiba-v9.9. A trailing `+`
# marks commits or uncommitted changes since that tag, so a work-in-progress
# build never shows a release number.
SHIBA_TAG="$(git -C "$DEVICE_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
SHIBA_NUM="$(echo "$SHIBA_TAG" | sed -n 's/^v\([0-9][0-9.]*\).*/\1/p')"
export SHIBA_VERSION="shiba-v${SHIBA_NUM:-dev}"
if [ -n "$SHIBA_TAG" ] && { [ "$(git -C "$DEVICE_DIR" rev-list -n1 "$SHIBA_TAG")" != "$(git -C "$DEVICE_DIR" rev-parse HEAD)" ] \
        || [ -n "$(git -C "$DEVICE_DIR" status --porcelain)" ]; }; then
    SHIBA_VERSION="${SHIBA_VERSION}+"
fi
echo "TWRP device version: $SHIBA_VERSION (tag ${SHIBA_TAG:-none})"

# No `set -u`: envsetup.sh's functions (lunch, m) reference unset variables.
# shellcheck disable=SC1091
source build/envsetup.sh >/dev/null
lunch twrp_shiba-ap2a-eng >/dev/null

step() { printf '\n== %s\n' "$*"; }

step "Generating root-menu shim zips"
python3 "$DEVICE_DIR/mkrootzips.py"

# Graphite bakes portrait.xml (tile icons) from TWRP's source - re-bake every
# build so the baked copy always matches the current menus (never stale).
if [ -f "$DEVICE_DIR/recovery/root/twres/ui.xml" ]; then
    step "Re-baking Graphite theme (from current TWRP sources)"
    python3 "$DEVICE_DIR/theme/mktheme.py" --bake
fi

# gui/*.hpp changes (e.g. objects.hpp class layouts) are NOT tracked by the
# build: stale .o files keep old layouts and corrupt memory (list pages
# segfaulted in GUIListBox::NotifyVarChange). If any gui header is newer than
# any compiled gui object, recompile the GUI and its includers from scratch.
GUI_OBJ=out/soong/.intermediates/bootable/recovery/gui/libguitwrp
GUI_HDR="$(ls -t bootable/recovery/gui/*.hpp | head -1)"
if [ -d "$GUI_OBJ" ] && [ -n "$(find "$GUI_OBJ" -name '*.o' ! -newer "$GUI_HDR" | head -1)" ]; then
    step "GUI headers changed ($GUI_HDR) - forcing a clean GUI rebuild"
    rm -rf "$GUI_OBJ"
    find out/soong/.intermediates/bootable/recovery -name 'twrp.o' -o -name 'twrpAdbBuFifo.o' | xargs -r rm -f
fi

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
gate "touch modules requested (from firmware vendor_dlkm)" "/bin/grep -a -q 'goodix_brl_touch.ko' $R/system/bin/recovery && ! test -e $R/lib/modules/5.15/goodix_brl_touch.ko"
# The bootloader can't load an oversized vendor ramdisk: a 55.4 MB recovery
# fragment (113 MB unpacked) dropped to fastboot; 45.0 MB (102 MB) boots. Never
# build past the largest size proven to boot (+~1 MB); raise only after proving more.
echo "  info recovery fragment: $(stat -c %s $FRAG) bytes (limit 46000000)"
gate "recovery fragment fits the bootloader (<= 46000000 bytes)" "test \$(stat -c %s $FRAG) -le 46000000"
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
gate "citadeld/weaver launched via sh (SELinux)"  "grep -q 'service twrp.citadeld /system/bin/sh -c .*exec /vendor/bin/hw/citadeld' $R/init.recovery.zuma.rc && grep -q 'service twrp.weaver /system/bin/sh -c .*exec /vendor/bin/hw/android.hardware.weaver-service.citadel' $R/init.recovery.zuma.rc"
gate "keystore2 restarted after copySqliteDb"     "/bin/grep -a -q 'Restarting keystore2 to load' $R/system/bin/recovery"
gate "OS version matched to installed (KeyMint)"  "grep -q 'resetprop ro.build.version.release ' $R/system/bin/twrp_crypto_start.sh"
gate "vold writes upgraded keys only if upgraded" "/bin/grep -a -q 'RAM only, not committed' $R/system/bin/recovery"
gate "no keystore2 hang when crypto is refused"   "test \$(grep -c 'setprop twrp.crypto.keystore ready' $R/system/bin/twrp_crypto_start.sh) -eq 2 && /bin/grep -a -q 'twrp.crypto.keystore' $R/system/bin/recovery"
gate "/data size walk deferred to Backup"        "/bin/grep -a -q 'deferred until needed' $R/system/bin/recovery && grep -q tw_shiba_exact_data_size $R/twres/portrait.xml"
gate "vbgraft (on-device TWRP install) present"   "test -x $R/system/bin/vbgraft && test -x $R/system/bin/twrp_install_slot.sh"
gate "TWRP install menu entries + zips"          "grep -q twrp-install-other.zip $R/twres/portrait.xml && test -f $R/system/etc/twrp_root/twrp-install-other.zip && test -f $R/system/etc/twrp_root/twrp-install-both.zip"
gate "official TWRP app excluded"                "! test -e $R/system/bin/me.twrp.twrpapp.apk"
gate "no 'Install TWRP App' without the app"     "/bin/grep -a -q 'TWRP app not included in this build' $R/system/bin/recovery"
gate "timezone database present"                 "test -s $R/system/usr/share/zoneinfo/tzdata"
gate "bash extras present (bashrc, /sbin/bash)"  "test -s $R/system/etc/bash/bashrc && test -L $R/sbin/bash"
gate "USB OTG: module + load list + storage entry" "test -s $R/lib/modules/5.15/otg_host_ready.ko && grep -q otg_host_ready.ko $R/lib/modules/5.15/modules.dep && grep -q '^/usb-otg' $R/system/etc/twrp.flags"
gate "USB OTG auto-mount watcher"                "test -x $R/system/bin/twrp_otg_watch.sh && grep -q 'start twrp.otgwatch' $R/init.recovery.zuma.rc"
gate "MTP: compiled in + configfs rule + guard"   "/bin/grep -a -q 'Failed to enable MTP' $R/system/bin/recovery && grep -q 'functions/ffs.mtp' $R/init.recovery.zuma.rc && test -x $R/system/bin/twrp_mtp_guard.sh"
gate "encryption (DFE): script, pinned payload, shims, pages" "test -x $R/system/bin/twrp_encryption.sh && unzip -p $R/system/etc/twrp_dfe/dfe-neo-shiba.zip NEO.config | grep -qx 'DFE_METHOD=neov2' && unzip -p $R/system/etc/twrp_dfe/dfe-neo-shiba.zip NEO.config | grep -qx 'WHERE_TO_INJECT=super' && unzip -p $R/system/etc/twrp_dfe/dfe-neo-shiba.zip NEO.config | grep -qx 'WIPE_DATA_AFTER_INSTALL=false' && ls $R/system/etc/twrp_root/encryption-{status,dryrun,disable,postformat,enable}.zip >/dev/null 2>&1 && grep -q 'page name=\"shiba_dfe_step2\"' $R/twres/portrait.xml"
gate "auto-reflash after OTA -> vendor_boot script" "/bin/grep -a -q 'twrp_install_slot.sh other' $R/system/bin/recovery"
gate "device version $SHIBA_VERSION in recovery"   "/bin/grep -a -q -F '$SHIBA_VERSION' $R/system/bin/recovery"
gate "KernelSU install checks KMI support first"  "grep -q 'boot-info supported-kmis' $R/system/bin/twrp_root.sh"
gate "Graphite fonts not overridden by languages" "! grep -q 'Graphite' $R/twres/ui.xml || grep -q 'name=\"font_l\" type=\"fontoverride\" filename=\"SpaceGrotesk-SemiBold.ttf\"' $R/twres/languages/en.xml"
gate "theme images match mkimages.py (not stale)" "python3 $DEVICE_DIR/theme/check_images.py"
gate "Enable USB debugging: menu item + zip"     "grep -q 'twrp_tools/enable-adb.zip' $R/twres/portrait.xml && unzip -tq $R/system/etc/twrp_tools/enable-adb.zip >/dev/null"
gate "twrp_remote daemon + service"               "test -x $R/system/bin/twrp_remote && grep -q 'start twrp.remote' $R/init.recovery.zuma.rc"
gate "OTG module for kernel 6.1 (Android 15-17)"   "/bin/grep -a -q 'vermagic=6\.1\.' $R/lib/modules/6.1/otg_host_ready.ko"
gate "modules.dep lists OTG for 5.15 and 6.1"      "grep -qx 'otg_host_ready.ko:' $R/lib/modules/5.15/modules.dep && grep -qx 'otg_host_ready.ko:' $R/lib/modules/6.1/modules.dep"
gate "libc++ compat shim for A15+ Titan HALs"      "/bin/grep -a -q _ZNSt3__122__libcpp_verbose_abortEPKcz $R/system/lib64/libshiba_cxx_compat.so && /bin/grep -a -q _ZNSt3__113__hash_memoryEPKvm $R/system/lib64/libshiba_cxx_compat.so && /bin/grep -a -q _ZN7android7BBinder21setTransactionCodeMapEPKNS_19TransactionCodeDataE $R/system/lib64/libshiba_cxx_compat.so && test \$(grep -c 'LD_PRELOAD=/system/lib64/libshiba_cxx_compat.so exec' $R/init.recovery.zuma.rc) -eq 2"
gate "our kernel modules carry no build paths"     "! /bin/grep -a -l '/home/' $R/lib/modules/5.15/otg_host_ready.ko $R/lib/modules/6.1/otg_host_ready.ko"
gate "boot HAL built from source (no AR fuse blow)" "/bin/grep -a -q 'anti-rollback fuse blow skipped' $R/system/bin/hw/android.hardware.boot-service.default_recovery-pixel && test -f $R/system/etc/vintf/manifest/android.hardware.boot-service.default_recovery-pixel.xml && test -f $R/system/etc/init/android.hardware.boot-service.default_recovery-pixel.rc"
gate "reinstall root after OTA (tickbox + script)" "grep -q 'tw_auto_reroot' $R/twres/portrait.xml && grep -q 'ACTION other' $R/system/bin/twrp_root.sh && /bin/grep -a -q 'Reinstalling root on the updated slot' $R/system/bin/recovery"

step "Shared library check (every ELF's NEEDED libs present in the ramdisk)"
python3 "$DEVICE_DIR/check_libs.py" || { echo "FAIL: missing libraries above - not repacking"; exit 1; }

step "Repacking vendor_boot"
bash "$DEVICE_DIR/repack.sh"

if [[ "${1:-}" == "--flash" ]]; then
    # The image is our TWRP grafted onto THIS stock vendor_boot (repack.sh base).
    # Never flash it onto a slot running other firmware (e.g. slot A after the
    # A15 OTA: A14's vendor_boot with A15's kernel). Refresh BASE_BUILD with the
    # base image (~/shiba-stock/factory/vendor_boot.img).
    BASE_BUILD="AP2A.240905.003"
    state="$(adb get-state 2>/dev/null)"
    run_slot="$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r_')"
    if [[ "$state" == device ]]; then
        running="$(adb shell getprop ro.build.id | tr -d '\r')"
    elif [[ "$state" == recovery ]]; then
        # TWRP: read the running slot's installed build.prop (read-only mount)
        running="$(adb shell 'm=/tmp/bsh_sys; mkdir -p $m; mount -t ext4 -o ro /dev/block/mapper/system$(getprop ro.boot.slot_suffix) $m 2>/dev/null && grep -m1 "^ro.build.id=" $m/system/build.prop | cut -d= -f2; umount $m 2>/dev/null' | tr -d '\r')"
    else
        running=""
    fi
    if [[ "$running" != "$BASE_BUILD" && "${FORCE_FLASH:-}" != 1 ]]; then
        echo "FAIL: the current slot runs '${running:-unknown (no adb)}', but this image is built on the"
        echo "      $BASE_BUILD stock vendor_boot - flashing it would mix firmwares. Instead: switch to a"
        echo "      slot running $BASE_BUILD, flash there, then TWRP > Install to other slot (grafts onto"
        echo "      that slot's own vendor_boot). FORCE_FLASH=1 overrides."
        exit 1
    fi
    adb reboot bootloader
    # flash the slot the phone boots (after an OTA that's no longer always _a)
    slot="$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: *\([ab]\).*/\1/p')"
    [[ "$slot" == a || "$slot" == b ]] || { echo "FAIL: cannot read the current slot from fastboot"; exit 1; }
    # the check above was for the RUNNING slot; after an OTA the bootloader may point elsewhere
    if [[ "$slot" != "$run_slot" && "${FORCE_FLASH:-}" != 1 ]]; then
        echo "FAIL: the bootloader's current slot is $slot, but the checked (running) slot was ${run_slot:-?}"
        echo "      - not flashing. fastboot --set-active=${run_slot:-?} first, or FORCE_FLASH=1."
        fastboot reboot recovery; exit 1
    fi
    step "Flashing vendor_boot_$slot (current slot) and booting recovery"
    fastboot flash "vendor_boot_$slot" "$HOME/shiba-stock/twrp_vendor_boot.img"
    fastboot reboot recovery
    adb wait-for-recovery
    # ro.twrp.version is set as TWRP starts, a moment after adbd comes up
    v=""; for i in $(seq 30); do
        v="$(adb shell getprop ro.twrp.version 2>/dev/null | tr -d '\r')"
        [[ -n "$v" ]] && break; sleep 1
    done
    step "TWRP is back up: ${v:-version unknown}"
    [[ "$v" == *"$SHIBA_VERSION"* ]] || step "WARNING: phone reports '${v:-nothing}', this build is $SHIBA_VERSION"
fi
