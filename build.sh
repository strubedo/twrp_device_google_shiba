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

# Output colors (script-colors palette: bright/neon); off when not a terminal,
# NO_COLOR, or TERM=dumb. RD, not R: R is the recovery root path below.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
    if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* ]]; then
        # 24-bit: neon green #39FF14, yellow #FFFF33, orange #FF9F1C, red #FF3131
        C=$'\e[1;38;2;57;255;20m'; G=$'\e[38;2;57;255;20m'; Y=$'\e[1;38;2;255;255;51m'
        W=$'\e[38;2;255;159;28m'; RD=$'\e[1;38;2;255;49;49m'
    else
        C=$'\e[1;92m'; G=$'\e[92m'; Y=$'\e[1;93m'; W=$'\e[93m'; RD=$'\e[1;91m'
    fi
    B=$'\e[1m'; N=$'\e[0m'
else
    B= C= G= Y= W= RD= N=
fi
step() { printf '\n%s== %s%s\n' "$C" "$*" "$N"; }        # step
ok()   { printf '   %s\u2713 %s%s\n' "$G" "$*" "$N"; }     # success
user() { printf '%s>> %s%s\n' "$Y" "$*" "$N"; }            # YOU do this
warn() { printf '   %s! %s%s\n' "$W" "$*" "$N"; }          # notice
fail() { printf '%sFAIL: %s%s\n' "$RD" "$*" "$N" >&2; }    # error line (caller exits)

DEVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$DEVICE_DIR/../../.." && pwd)"
cd "$TOP"

export ALLOW_MISSING_DEPENDENCIES=true
# Neutral build identity: Android records the builder's user and host name in
# ro.build.user / ro.build.host (prop.default) - not something to publish.
export BUILD_USERNAME=shiba-twrp
export BUILD_HOSTNAME=build

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
step "TWRP device version: ${B}$SHIBA_VERSION${N}${C} (tag ${SHIBA_TAG:-none})"

# No `set -u`: envsetup.sh's functions (lunch, m) reference unset variables.
# shellcheck disable=SC1091
source build/envsetup.sh >/dev/null
lunch twrp_shiba-ap2a-eng >/dev/null

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
# vbgraft_static: the flashable zip's graft tool (make_release.sh packages it)
m vbgraft_static -j10 2>&1 | tail -1

step "Wiping stale recovery staging root (relink never refreshes it)"
rm -rf out/target/product/shiba/recovery

BUILD_LOG="$HOME/twrp-build.log"
step "Building vendorbootimage (full log: $BUILD_LOG)"
# Live progress on one line ("[ 63% 1712/2716 1m40s remaining]"), updated in
# place; the full output still goes to the log. m's status comes from
# PIPESTATUS (the awk display always succeeds); -e is off around the pipeline
# so a failed build reaches the error report below instead of exiting here.
set +e
m adbd vendorbootimage vbgraft -j10 2>&1 | tee "$BUILD_LOG" | awk '
    match($0, /\[ *[0-9]+% [0-9]+\/[0-9]+[^]]*\]/) {
        printf "\r   %s\033[K", substr($0, RSTART, RLENGTH); fflush(); shown = 1 }
    END { if (shown) print "" }'
BUILD_RC=${PIPESTATUS[0]}
set -e
if [[ $BUILD_RC -ne 0 ]]; then
    fail "BUILD FAILED - first error:"
    grep -m1 -A30 'FAILED:' "$BUILD_LOG" || tail -40 "$BUILD_LOG"
    fail "full log: $BUILD_LOG"
    exit 1
fi
tail -3 "$BUILD_LOG"

step "Gates"
R=out/target/product/shiba/recovery/root
FRAG=out/target/product/shiba/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4
gate() { if eval "$2"; then ok "$1"; else fail "gate: $1"; exit 1; fi; }
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
echo "   recovery fragment: ${B}$(stat -c %s $FRAG)${N} bytes (limit 46000000)"
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
gate "encryption: script, lptool, vbgraft --fstab-set, shims, pages, no DFE-NEO" "test -x $R/system/bin/twrp_encryption.sh && test -x $R/system/bin/lptool && /bin/grep -a -q -- '--fstab-set' $R/system/bin/vbgraft && ls $R/system/etc/twrp_root/encryption-{status,dryrun,disable,postformat,enable}.zip >/dev/null 2>&1 && grep -q 'page name=\"shiba_dfe_step2\"' $R/twres/portrait.xml && ! test -e $R/system/etc/twrp_dfe"
gate "auto-reflash after OTA -> vendor_boot script" "/bin/grep -a -q 'twrp_install_slot.sh other' $R/system/bin/recovery"
gate "device version $SHIBA_VERSION in recovery"   "/bin/grep -a -q -F '$SHIBA_VERSION' $R/system/bin/recovery"
gate "touch fallback: hook, script, 5.15 + 6.1 sets" "/bin/grep -a -q 'twrp_touch_fallback.sh' $R/system/bin/recovery && test -f $R/system/bin/twrp_touch_fallback.sh && ls $R/system/etc/touch_fallback/5.15.*/goodix_brl_touch.ko >/dev/null 2>&1 && ls $R/system/etc/touch_fallback/6.1.*/goodix_brl_touch.ko >/dev/null 2>&1"
gate "fallback decryption: AOSP KeyMint + Gatekeeper, Weaver daemon" "test -f $R/system/bin/android.hardware.security.keymint-service.rust.trusty && test -f $R/system/bin/android.hardware.gatekeeper-service.trusty && test -f $R/system/bin/recovery-tensor-daemon && grep -q 'service twrp.fb.weaver' $R/init.recovery.zuma.rc"
gate "neutral build identity (no user/host name)" "grep -q -x 'ro.build.user=shiba-twrp' $R/prop.default && grep -q -x 'ro.build.host=build' $R/prop.default && ! grep -r -q -F '$(id -un)' $R/prop.default && ! grep -r -q -F '$(hostname)' $R/prop.default"
gate "KernelSU install checks KMI support first"  "grep -q 'boot-info supported-kmis' $R/system/bin/twrp_root.sh"
gate "Graphite fonts not overridden by languages" "! grep -q 'Graphite' $R/twres/ui.xml || grep -q 'name=\"font_l\" type=\"fontoverride\" filename=\"SpaceGrotesk-SemiBold.ttf\"' $R/twres/languages/en.xml"
gate "theme images match mkimages.py (not stale)" "python3 $DEVICE_DIR/theme/check_images.py"
gate "Enable USB debugging: menu item + zip"     "grep -q 'twrp_tools/enable-adb.zip' $R/twres/portrait.xml && unzip -tq $R/system/etc/twrp_tools/enable-adb.zip >/dev/null"
gate "Collect logs: script + menu item + zip"     "test -x $R/system/bin/twrp_collect_logs.sh && grep -q 'twrp_root/collect-logs.zip' $R/twres/portrait.xml && unzip -tq $R/system/etc/twrp_root/collect-logs.zip >/dev/null"
gate "twrp_remote daemon + service"               "test -x $R/system/bin/twrp_remote && grep -q 'start twrp.remote' $R/init.recovery.zuma.rc"
gate "OTG module for kernel 6.1 (Android 15-17)"   "/bin/grep -a -q 'vermagic=6\.1\.' $R/lib/modules/6.1/otg_host_ready.ko"
gate "modules.dep lists OTG for 5.15 and 6.1"      "grep -qx 'otg_host_ready.ko:' $R/lib/modules/5.15/modules.dep && grep -qx 'otg_host_ready.ko:' $R/lib/modules/6.1/modules.dep"
gate "libc++ compat shim for A15+ Titan HALs"      "/bin/grep -a -q _ZNSt3__122__libcpp_verbose_abortEPKcz $R/system/lib64/libshiba_cxx_compat.so && /bin/grep -a -q _ZNSt3__113__hash_memoryEPKvm $R/system/lib64/libshiba_cxx_compat.so && /bin/grep -a -q _ZN7android7BBinder21setTransactionCodeMapEPKNS_19TransactionCodeDataE $R/system/lib64/libshiba_cxx_compat.so && test \$(grep -c 'LD_PRELOAD=/system/lib64/libshiba_cxx_compat.so exec' $R/init.recovery.zuma.rc) -eq 2"
gate "our kernel modules carry no build paths"     "! /bin/grep -a -l '/home/' $R/lib/modules/5.15/otg_host_ready.ko $R/lib/modules/6.1/otg_host_ready.ko"
gate "boot HAL built from source (no AR fuse blow)" "/bin/grep -a -q 'anti-rollback fuse blow skipped' $R/system/bin/hw/android.hardware.boot-service.default_recovery-pixel && test -f $R/system/etc/vintf/manifest/android.hardware.boot-service.default_recovery-pixel.xml && test -f $R/system/etc/init/android.hardware.boot-service.default_recovery-pixel.rc"
gate "root after OTA (picker + script)"            "grep -q 'page name=\"shiba_ota_root\"' $R/twres/portrait.xml && grep -q 'page name=\"shiba_ota_kernel\"' $R/twres/portrait.xml && grep -q 'ACTION other' $R/system/bin/twrp_root.sh && grep -q 'flash-kernel)' $R/system/bin/twrp_root.sh && /bin/grep -a -q 'Root after OTA: %s on the updated slot' $R/system/bin/recovery"
gate "A17 OTA: VABC opt-in, no 5-minute confirm"   "/bin/grep -a -q 'twrp.ota.vabc' $R/system/bin/recovery && ! /bin/grep -a -q 'install the same zip again' $R/system/bin/recovery"
gate "A17 OTA: update_engine VABC in recovery"     "/bin/grep -a -q 'VABC in recovery (TWRP opt-in)' $R/system/bin/update_engine_sideload && /bin/grep -a -q '(VABC in recovery)' $R/system/bin/update_engine_sideload"

step "Shared library check (every ELF's NEEDED libs present in the ramdisk)"
python3 "$DEVICE_DIR/check_libs.py" || { fail "missing libraries above - not repacking"; exit 1; }

step "Repacking vendor_boot"
bash "$DEVICE_DIR/repack.sh"

if [[ "${1:-}" == "--flash" ]]; then
    # The image is our TWRP grafted onto THIS stock vendor_boot (repack.sh base).
    # Never flash it onto a slot running other firmware (e.g. slot A after the
    # A15 OTA: A14's vendor_boot with A15's kernel). The base's build ID comes
    # from its file name: ~/shiba-stock/factory/vendor_boot.img is a link to
    # vendor_boot-<BUILD ID>.img - switching the base = re-pointing the link.
    base_img="$(readlink -f "$HOME/shiba-stock/factory/vendor_boot.img")"
    BASE_BUILD="$(basename "$base_img" | sed -n 's/^vendor_boot-\(.*\)\.img$/\1/p')"
    [[ -n "$BASE_BUILD" ]] || { fail "~/shiba-stock/factory/vendor_boot.img must link to vendor_boot-<BUILD ID>.img (is: ${base_img##*/})"; exit 1; }
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
        fail "the current slot runs '${running:-unknown (no adb)}', but this image is built on the"
        fail "$BASE_BUILD stock vendor_boot - flashing it would mix firmwares."
        [[ -z "$running" ]] && user "Connect the phone (Android with USB debugging, or TWRP) and run this again"
        user "Or: switch to a slot running $BASE_BUILD, flash there, then TWRP > Install to other slot"
        echo "   (grafts onto that slot's own vendor_boot). FORCE_FLASH=1 overrides."
        exit 1
    fi
    adb reboot bootloader
    # flash the slot the phone boots (after an OTA that's no longer always _a)
    slot="$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: *\([ab]\).*/\1/p')"
    [[ "$slot" == a || "$slot" == b ]] || { fail "cannot read the current slot from fastboot"; exit 1; }
    # the check above was for the RUNNING slot; after an OTA the bootloader may point elsewhere
    if [[ "$slot" != "$run_slot" && "${FORCE_FLASH:-}" != 1 ]]; then
        fail "the bootloader's current slot is $slot, but the checked (running) slot was ${run_slot:-?} - not flashing."
        user "Run: fastboot --set-active=${run_slot:-?}  (or FORCE_FLASH=1)"
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
    if [[ "$v" == *"$SHIBA_VERSION"* ]]; then
        step "TWRP is back up"; ok "${B}$v${N}"
    else
        step "TWRP is back up: ${v:-version unknown}"
        warn "phone reports '${v:-nothing}', this build is $SHIBA_VERSION"
    fi
fi
