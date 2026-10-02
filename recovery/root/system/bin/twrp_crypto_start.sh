#!/system/bin/sh
# twrp_crypto_start.sh - bring up the TEE key services for /data decryption.
#
# Called by TWRP's TWPartitionManager::Decrypt_Data() (patched) right BEFORE the
# metadata unlock. That runs from Setup_Fstab_Partitions(), early in startup:
# before twrp.cpp applies TW_OVERRIDE_SYSTEM_PROPS and runs runatboot.sh. So
# this script sets the security patch props itself.
#
# SAFETY: KeyMint versions keys by OS version and security patch levels. If
# KeyMint ran with a newer OS version or SPL than the installed system (our
# build defaults are PLATFORM_VERSION 99.87.36 and SPL 2099-12-31) it reports
# "key requires upgrade" for every key and returns blobs stamped with those
# future values. Android would reject such a key as a downgrade, so /data could
# never be unlocked again if one ever reached disk. So KeyMint is started ONLY
# when the live OS version and both SPL props exactly match the installed
# system and vendor build.prop - then KeyMint sees exactly what Android's does
# and no key upgrade is requested at all. On any doubt we start nothing and
# decryption is simply skipped.
#
# Order (each step waits for the previous one):
#   1. read installed OS version + SPLs  2. set + verify live props (resetprop)
#   3. real /vendor mounted  4. Trusty storage proxy
#   5. KeyMint (TEE)         6. keystore2  -> then vold unwraps the metadata key
#
# Log: /tmp/twrp_crypto.log

LOG=/tmp/twrp_crypto.log
log() { echo "$(date +%T) $*" >> "$LOG"; }

# wait up to $2 tenths of a second for service $1 to be running
wait_running() {
    i=0
    while [ "$(getprop init.svc.$1)" != running ] && [ $i -lt "$2" ]; do
        sleep 0.1; i=$((i + 1))
    done
    [ "$(getprop init.svc.$1)" = running ]
}

SLOT="$(getprop ro.boot.slot_suffix)"
MNT=/tmp/cryptomnt
log "crypto start: slot=$SLOT"

if [ -n "$(pidof keystore2)" ] && [ "$(getprop init.svc.twrp.keymint)" = running ]; then
    log "services already running - nothing to do"
    setprop twrp.crypto.keystore ready
    exit 0
fi

# --- 1. read the installed system's real OS version + SPLs (read-only mounts) --
mkdir -p "$MNT/system" "$MNT/vendor"
real_sys=""; real_ven=""; real_rel=""; real_roc=""
if mount -t ext4 -o ro "/dev/block/mapper/system$SLOT" "$MNT/system" 2>>"$LOG"; then
    BP="$MNT/system/system/build.prop"
    real_sys="$(grep -m1 '^ro.build.version.security_patch=' "$BP" | cut -d= -f2)"
    real_rel="$(grep -m1 '^ro.build.version.release=' "$BP" | cut -d= -f2)"
    real_roc="$(grep -m1 '^ro.build.version.release_or_codename=' "$BP" | cut -d= -f2)"
    umount "$MNT/system"
fi
if mount -t ext4 -o ro "/dev/block/mapper/vendor$SLOT" "$MNT/vendor" 2>>"$LOG"; then
    real_ven="$(grep -m1 '^ro.vendor.build.security_patch=' "$MNT/vendor/build.prop" | cut -d= -f2)"
    umount "$MNT/vendor"
fi
log "installed: os=$real_rel ($real_roc) SPL system=$real_sys vendor=$real_ven"
if [ -z "$real_sys" ] || [ -z "$real_ven" ] || [ -z "$real_rel" ] || [ -z "$real_roc" ]; then
    log "REFUSING to start KeyMint: installed OS version/SPL unreadable - decryption disabled"
    exit 0
fi

# --- 2. set the live props to the installed values, then verify --------------
/system/bin/resetprop ro.build.version.release "$real_rel" 2>>"$LOG"
/system/bin/resetprop ro.build.version.release_or_codename "$real_roc" 2>>"$LOG"
/system/bin/resetprop ro.build.version.security_patch "$real_sys" 2>>"$LOG"
/system/bin/resetprop ro.vendor.build.security_patch "$real_ven" 2>>"$LOG"
live_rel="$(getprop ro.build.version.release)"
live_roc="$(getprop ro.build.version.release_or_codename)"
live_sys="$(getprop ro.build.version.security_patch)"
live_ven="$(getprop ro.vendor.build.security_patch)"
log "live after resetprop: os=$live_rel ($live_roc) SPL system=$live_sys vendor=$live_ven"
if [ "$real_rel" != "$live_rel" ] || [ "$real_roc" != "$live_roc" ] \
   || [ "$real_sys" != "$live_sys" ] || [ "$real_ven" != "$live_ven" ]; then
    log "REFUSING to start KeyMint: live OS version/SPL != installed - decryption disabled"
    exit 0
fi
log "OS version + SPL match - OK to start KeyMint"

# --- 3. real vendor at /vendor (KeyMint binary + its libs), kept mounted -----
# Our ramdisk's /vendor/etc/vintf (the HALs this chain registers, in a schema
# our libvintf reads) is hidden once the real vendor is mounted on top - save
# it first. Only needed when the real one is too new (see 3b).
if ! mountpoint -q /vendor && [ -d /vendor/etc/vintf ] && [ ! -d /tmp/twrp_vintf ]; then
    cp -a /vendor/etc/vintf /tmp/twrp_vintf
fi
if ! mountpoint -q /vendor || [ ! -x /vendor/bin/hw/android.hardware.security.keymint-service.rust.trusty ]; then
    mountpoint -q /vendor && umount /vendor 2>/dev/null
    mount -t ext4 -o ro "/dev/block/mapper/vendor$SLOT" /vendor 2>>"$LOG" \
        || { log "cannot mount vendor$SLOT at /vendor"; exit 0; }
fi

# --- 3b. VINTF schema: servicemanager only lets HALs register if it can parse
# the vendor's VINTF manifests. Our libvintf (Android 14 base) reads schema up
# to 8.0 (system/libvintf constants.h kMetaVersion); Android 16's vendor uses
# 9.0, which it rejects -> EVERY HAL registration refused. Then serve our own
# manifest instead (bind over /vendor/etc/vintf); Android 14 (8.0) keeps its own.
MAX_VINTF=8
vendor_vintf="$(grep -rhoE '<manifest version="[0-9]+' /vendor/etc/vintf/ 2>/dev/null \
    | sed 's/.*"//' | sort -n | tail -1)"
if [ -n "$vendor_vintf" ] && [ "$vendor_vintf" -gt "$MAX_VINTF" ]; then
    if [ -d /tmp/twrp_vintf ] && ! grep -q " /vendor/etc/vintf " /proc/mounts; then
        mount --bind /tmp/twrp_vintf /vendor/etc/vintf \
            && log "vendor VINTF schema $vendor_vintf.x > $MAX_VINTF.0: serving recovery's own manifest" \
            || log "WARNING: could not bind recovery VINTF over /vendor/etc/vintf"
    fi
else
    log "vendor VINTF schema ${vendor_vintf:-?}.x - using vendor manifests"
fi

# --- 4. Trusty secure storage in RAM (mirrors init.zuma.rc's /data/vendor/ss)
mkdir -p /tmp/ss/persist
ln -sf /dev/block/platform/13200000.ufs/by-name/trusty_persist /tmp/ss/persist/0
start twrp.storageproxyd
wait_running twrp.storageproxyd 50 || { log "storageproxyd did not start"; exit 0; }
log "storageproxyd running (pid $(pidof storageproxyd))"

# --- 5. KeyMint ---------------------------------------------------------------
start twrp.keymint
wait_running twrp.keymint 50 || { log "keymint did not start"; exit 0; }
sleep 0.5   # let it register IKeyMintDevice/ISharedSecret with servicemanager
log "keymint running (pid $(pidof android.hardware.security.keymint-service.rust.trusty))"

# --- 6. keystore2 (disabled in its .rc so nothing starts it before KeyMint) ---
mkdir -p /tmp/misc/keystore
start keystore2
wait_running keystore2 50 || { log "keystore2 did not start"; exit 0; }
sleep 0.5   # let it register IKeystoreService
log "keystore2 running (pid $(pidof keystore2)) - ready for metadata unlock"
# Tell TWRP the decryption services are up. Every path that refuses or fails
# exits above without this, and TWRP then skips decryption instead of waiting
# forever for keystore2 (vold blocks on it).
setprop twrp.crypto.keystore ready

# --- 7-9. PIN unlock services (stage 5). Non-fatal: the metadata unlock above
# doesn't need them; without them only the PIN (CE) unlock is unavailable. ---
start twrp.gatekeeper
wait_running twrp.gatekeeper 30 && log "gatekeeper running" || log "gatekeeper did not start"

if [ -e /dev/gsc0 ]; then
    # Recovery has ONE flat linker namespace, so a vendor process gets a single
    # libbinder and a single binder connection. In Android, Weaver has two
    # (vndbinder to reach citadeld, binder to publish IWeaver); here citadeld's
    # client lib claims vndbinder first, so IWeaver ends up registered with
    # vndservicemanager where TWRP never looks. Fix: in recovery only, point
    # /dev/vndbinder at the main binder so citadeld (ICitadeld) and Weaver
    # (IWeaver) both register with servicemanager. vndservicemanager can't share
    # that device and nothing else in recovery uses it, so it's stopped.
    # /dev is tmpfs - this is gone at reboot; Android is unaffected.
    stop vndservicemanager
    rm -f /dev/vndbinder && ln -s /dev/binderfs/binder /dev/vndbinder
    log "vndbinder -> binder (single-namespace recovery)"

    start twrp.citadeld
    # Weaver looks up ICitadeld at startup - wait for the registration, not
    # just the process.
    i=0
    until service check android.hardware.citadel.ICitadeld 2>/dev/null | grep -q ": found"; do
        [ $i -ge 100 ] && break
        sleep 0.1; i=$((i + 1))
    done
    if service check android.hardware.citadel.ICitadeld 2>/dev/null | grep -q ": found"; then
        log "citadeld running, ICitadeld registered (${i}00 ms)"
        start twrp.weaver
        i=0
        until service check android.hardware.weaver.IWeaver/default 2>/dev/null | grep -q ": found"; do
            [ $i -ge 100 ] && break
            sleep 0.1; i=$((i + 1))
        done
        service check android.hardware.weaver.IWeaver/default 2>/dev/null | grep -q ": found" \
            && log "weaver running, IWeaver registered (${i}00 ms)" \
            || log "weaver started but IWeaver NOT registered after 10 s"
    else
        log "ICitadeld not registered after 10 s - no Weaver (citadeld: $(getprop init.svc.twrp.citadeld))"
    fi
else
    log "/dev/gsc0 missing - no Titan, no Weaver"
fi
exit 0
