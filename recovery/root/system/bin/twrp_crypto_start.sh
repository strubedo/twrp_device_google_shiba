#!/system/bin/sh
# twrp_crypto_start.sh - bring up the TEE key services for /data decryption.
#
# Called by TWRP's TWPartitionManager::Decrypt_Data() (patched) right BEFORE the
# metadata unlock. That runs from Setup_Fstab_Partitions(), early in startup:
# before twrp.cpp applies TW_OVERRIDE_SYSTEM_PROPS and runs runatboot.sh. So
# this script sets the security patch props itself.
#
# Two chains, same order (storage proxy -> KeyMint -> keystore2 -> Gatekeeper
# -> Weaver):
#   vendor   - the installed slot's own vendor binaries (proven on A14/A15; they
#              always match the firmware). Needs vendor<slot> to mount and its
#              binaries to run in recovery.
#   fallback - nothing from /vendor: AOSP's Trusty KeyMint + Gatekeeper built
#              from source, LeeGarChat's recovery-tensor-daemon for Weaver (Titan
#              M2 directly), our AOSP storageproxyd. Used when vendor<slot> won't
#              mount (damaged super, released slot) or its KeyMint won't start,
#              or when /metadata/twrp/crypto_force_fallback exists (testing).
#              Weaver alone also falls back if citadeld/Weaver fail.
#
# SAFETY: KeyMint versions keys by OS version and security patch levels. With a
# newer OS version or SPL than the installed system it asks to upgrade every key
# and returns blobs stamped with those values. In TWRP those upgraded blobs only
# ever live in RAM (vold writes them to /tmp; keystore2's database is
# /tmp/misc/keystore), never on /data - but to avoid upgrades entirely KeyMint
# gets the INSTALLED values: read from the slot's system/vendor, saved to
# /metadata/twrp/crypto_osinfo every time that works, and reused from there when
# they can't be read (fallback). Only if nothing was ever saved does KeyMint run
# with the build's own (future) values, and that is logged.
#
# Log: /tmp/twrp_crypto.log

LOG=/tmp/twrp_crypto.log
log() { echo "$(date +%T) $*" >> "$LOG"; }

OSINFO_REL=twrp/crypto_osinfo
FORCE_REL=twrp/crypto_force_fallback

# wait up to $2 tenths of a second for service $1 to be running
wait_running() {
    i=0
    while [ "$(getprop init.svc.$1)" != running ] && [ $i -lt "$2" ]; do
        sleep 0.1; i=$((i + 1))
    done
    [ "$(getprop init.svc.$1)" = running ]
}

# wait up to $2 tenths of a second for binder service $1 to be registered
wait_service() {
    i=0
    until service check "$1" 2>/dev/null | grep -q ": found"; do
        [ $i -ge "$2" ] && return 1
        sleep 0.1; i=$((i + 1))
    done
    return 0
}

SLOT="$(getprop ro.boot.slot_suffix)"
MNT=/tmp/cryptomnt
log "crypto start: slot=$SLOT"

# /metadata (saved OS info, test flag): TWRP mounts it only AFTER this script
# runs, so if it isn't mounted yet, mount it briefly at a private spot and
# unmount it again before any service starts (TWRP's own mount comes later).
META=""; META_TMP=""
if mountpoint -q /metadata; then
    META=/metadata
else
    mkdir -p /tmp/metamnt
    if mount -t f2fs /dev/block/by-name/metadata /tmp/metamnt 2>>"$LOG"; then
        META=/tmp/metamnt; META_TMP=1
    else
        log "WARNING: /metadata not available - no saved OS info, no test flag"
    fi
fi
meta_done() {
    [ -n "$META_TMP" ] && umount /tmp/metamnt 2>>"$LOG" && META_TMP=""
}
OSINFO="$META/$OSINFO_REL"
FORCE_FALLBACK=""
[ -n "$META" ] && [ -e "$META/$FORCE_REL" ] && FORCE_FALLBACK=1

if [ -n "$(pidof keystore2)" ] && { [ "$(getprop init.svc.twrp.keymint)" = running ] \
        || [ "$(getprop init.svc.twrp.fb.keymint)" = running ]; }; then
    log "services already running - nothing to do"
    meta_done
    setprop twrp.crypto.keystore ready
    exit 0
fi

# --- 1. the installed system's real OS version + SPLs ------------------------
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

info_source=installed
if [ -n "$real_sys" ] && [ -n "$real_ven" ] && [ -n "$real_rel" ] && [ -n "$real_roc" ]; then
    # remember them for the fallback (when this slot's system/vendor can't be read)
    new="rel=$real_rel
roc=$real_roc
sys=$real_sys
ven=$real_ven"
    if [ -n "$META" ] && [ "$(cat "$OSINFO" 2>/dev/null)" != "$new" ]; then
        mkdir -p "$META/twrp" && echo "$new" > "$OSINFO.tmp" && mv "$OSINFO.tmp" "$OSINFO" \
            && log "saved OS version/SPL to /metadata/$OSINFO_REL" || log "WARNING: could not save /metadata/$OSINFO_REL"
    fi
    # root-only, like the rest of /metadata (recovery's umask leaves them world-writable)
    [ -n "$META" ] && [ -d "$META/twrp" ] && chmod 700 "$META/twrp" && chmod 600 "$META/twrp"/* 2>/dev/null
elif [ -n "$META" ] && [ -s "$OSINFO" ]; then
    info_source="saved (/metadata/$OSINFO_REL)"
    real_rel="$(sed -n 's/^rel=//p' "$OSINFO")"; real_roc="$(sed -n 's/^roc=//p' "$OSINFO")"
    real_sys="$(sed -n 's/^sys=//p' "$OSINFO")"; real_ven="$(sed -n 's/^ven=//p' "$OSINFO")"
    log "installed values unreadable - using saved: os=$real_rel ($real_roc) SPL system=$real_sys vendor=$real_ven"
else
    info_source="build defaults"
    real_rel="$(getprop ro.build.version.release)"; real_roc="$(getprop ro.build.version.release_or_codename)"
    real_sys="$(getprop ro.build.version.security_patch)"; real_ven="$(getprop ro.vendor.build.security_patch)"
    log "WARNING: installed values unreadable and none saved - KeyMint runs with the build's own (future)"
    log "  values: os=$real_rel SPL $real_sys. Key upgrades stay in RAM (vold /tmp, keystore2 /tmp)."
fi
meta_done

# --- 2. set the live props, then verify --------------------------------------
/system/bin/resetprop ro.build.version.release "$real_rel" 2>>"$LOG"
/system/bin/resetprop ro.build.version.release_or_codename "$real_roc" 2>>"$LOG"
/system/bin/resetprop ro.build.version.security_patch "$real_sys" 2>>"$LOG"
/system/bin/resetprop ro.vendor.build.security_patch "$real_ven" 2>>"$LOG"
if [ "$(getprop ro.build.version.release)" != "$real_rel" ] \
   || [ "$(getprop ro.build.version.release_or_codename)" != "$real_roc" ] \
   || [ "$(getprop ro.build.version.security_patch)" != "$real_sys" ] \
   || [ "$(getprop ro.vendor.build.security_patch)" != "$real_ven" ]; then
    log "REFUSING to start KeyMint: live OS version/SPL != intended ($info_source) - decryption disabled"
    exit 0
fi
log "OS version + SPL set from $info_source"

# --- 3. storage proxy (built from source: same for both chains) --------------
start_storage() {
    mkdir -p /tmp/ss/persist
    ln -sf /dev/block/platform/13200000.ufs/by-name/trusty_persist /tmp/ss/persist/0
    start twrp.storageproxyd
    wait_running twrp.storageproxyd 50 || { log "storageproxyd did not start"; return 1; }
    log "storageproxyd running (pid $(pidof storageproxyd))"
}

start_keystore() {
    mkdir -p /tmp/misc/keystore
    start keystore2
    wait_running keystore2 50 || { log "keystore2 did not start"; return 1; }
    sleep 0.5   # let it register IKeystoreService
    log "keystore2 running (pid $(pidof keystore2)) - ready for metadata unlock"
    # Tell TWRP the decryption services are up. Every path that refuses or
    # fails returns before this, and TWRP then skips decryption instead of
    # waiting forever for keystore2 (vold blocks on it).
    setprop twrp.crypto.keystore ready
}

# Weaver via LeeGarChat's daemon (Titan M2 directly through /dev/gsc0)
start_fb_weaver() {
    start twrp.fb.weaver
    if wait_service android.hardware.weaver.IWeaver/default 100; then
        log "fallback weaver running, IWeaver registered"
    else
        log "fallback weaver: IWeaver NOT registered after 10 s (see /tmp/twrp_weaver.log)"
    fi
}

# --- the vendor chain ---------------------------------------------------------
vendor_chain() {
    # Our ramdisk's /vendor/etc/vintf (the HALs these chains register, in a
    # schema our libvintf reads) is hidden once the real vendor is mounted on
    # top - save it first. Only needed when the real one is too new (below).
    if ! mountpoint -q /vendor && [ -d /vendor/etc/vintf ] && [ ! -d /tmp/twrp_vintf ]; then
        cp -a /vendor/etc/vintf /tmp/twrp_vintf
    fi
    if ! mountpoint -q /vendor || [ ! -x /vendor/bin/hw/android.hardware.security.keymint-service.rust.trusty ]; then
        mountpoint -q /vendor && umount /vendor 2>/dev/null
        mount -t ext4 -o ro "/dev/block/mapper/vendor$SLOT" /vendor 2>>"$LOG" \
            || { log "cannot mount vendor$SLOT at /vendor"; return 1; }
    fi
    # VINTF schema: servicemanager only lets HALs register if it can parse the
    # vendor's VINTF manifests. Our libvintf (Android 14 base) reads schema up
    # to 8.0; Android 16's vendor uses 9.0 -> serve our own manifest instead.
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

    start_storage || return 1
    start twrp.keymint
    if ! wait_running twrp.keymint 50; then
        log "vendor keymint did not start"
        return 1
    fi
    sleep 0.5   # let it register IKeyMintDevice/ISharedSecret with servicemanager
    if [ "$(getprop init.svc.twrp.keymint)" != running ]; then
        log "vendor keymint exited right after starting"
        return 1
    fi
    log "vendor keymint running (pid $(pidof android.hardware.security.keymint-service.rust.trusty))"
    start_keystore || return 2      # 2: KeyMint is up - don't switch chains now

    # PIN unlock services. Non-fatal: the metadata unlock doesn't need them;
    # without them only the PIN (CE) unlock is unavailable.
    start twrp.gatekeeper
    wait_running twrp.gatekeeper 30 && log "gatekeeper running" || log "gatekeeper did not start"

    if [ -e /dev/gsc0 ]; then
        # Recovery has ONE flat linker namespace, so a vendor process gets a
        # single libbinder and a single binder connection. Here citadeld's
        # client lib claims vndbinder first, so IWeaver would be registered
        # with vndservicemanager where TWRP never looks. In recovery only,
        # point /dev/vndbinder at the main binder (gone at reboot).
        stop vndservicemanager
        rm -f /dev/vndbinder && ln -s /dev/binderfs/binder /dev/vndbinder
        log "vndbinder -> binder (single-namespace recovery)"
        start twrp.citadeld
        if wait_service android.hardware.citadel.ICitadeld 100; then
            log "citadeld running, ICitadeld registered"
            start twrp.weaver
            if wait_service android.hardware.weaver.IWeaver/default 100; then
                log "weaver running, IWeaver registered"
                return 0
            fi
            log "vendor weaver: IWeaver NOT registered after 10 s"
            stop twrp.weaver
        else
            log "ICitadeld not registered after 10 s (citadeld: $(getprop init.svc.twrp.citadeld))"
        fi
        stop twrp.citadeld
        log "-> Weaver fallback (recovery-tensor-daemon)"
        start_fb_weaver
    else
        log "/dev/gsc0 missing - no Titan, no Weaver"
    fi
    return 0
}

# --- the fallback chain: nothing from /vendor ---------------------------------
fallback_chain() {
    # The ramdisk's own /vendor (our VINTF manifest) must be visible
    for s in twrp.weaver twrp.citadeld twrp.gatekeeper twrp.keymint twrp.storageproxyd; do
        [ "$(getprop init.svc.$s)" = running ] && stop "$s"
    done
    grep -q " /vendor/etc/vintf " /proc/mounts && umount /vendor/etc/vintf 2>/dev/null
    mountpoint -q /vendor && { umount /vendor 2>>"$LOG" || log "WARNING: could not unmount /vendor"; }
    [ -d /vendor/etc/vintf ] && log "using recovery's own VINTF manifest" \
        || log "WARNING: no /vendor/etc/vintf in the ramdisk - HAL registration may be refused"

    [ "$(getprop init.svc.twrp.storageproxyd)" = running ] || start_storage || return 1
    start twrp.fb.keymint
    wait_running twrp.fb.keymint 50 || { log "fallback keymint did not start"; return 1; }
    sleep 0.5
    [ "$(getprop init.svc.twrp.fb.keymint)" = running ] || { log "fallback keymint exited right after starting"; return 1; }
    log "fallback keymint running (AOSP, pid $(pidof android.hardware.security.keymint-service.rust.trusty))"
    start_keystore || return 1

    start twrp.fb.gatekeeper
    wait_running twrp.fb.gatekeeper 30 && log "fallback gatekeeper running (AOSP)" \
        || log "fallback gatekeeper did not start"
    if [ -e /dev/gsc0 ]; then start_fb_weaver; else log "/dev/gsc0 missing - no Titan, no Weaver"; fi
    return 0
}

# --- choose ---------------------------------------------------------------------
if [ -n "$FORCE_FALLBACK" ]; then
    log "/metadata/$FORCE_REL exists - using the fallback chain (test)"
    fallback_chain || log "fallback chain failed - decryption unavailable"
    exit 0
fi
vendor_chain; rc=$?
if [ $rc = 1 ]; then
    log "vendor chain unavailable -> fallback chain (nothing from /vendor)"
    fallback_chain || log "fallback chain failed - decryption unavailable"
fi
exit 0
