#!/system/bin/sh
# twrp_crypto_start.sh - bring up the TEE key services for /data decryption.
#
# Called by TWRP's TWPartitionManager::Decrypt_Data() (patched) right BEFORE the
# metadata unlock. That runs from Setup_Fstab_Partitions(), early in startup:
# before twrp.cpp applies TW_OVERRIDE_SYSTEM_PROPS and runs runatboot.sh. So
# this script sets the security patch props itself.
#
# SAFETY: KeyMint versions keys by security patch level (SPL). If KeyMint ran
# with a newer SPL than the installed system (our build default is 2099-12-31)
# it would report "key requires upgrade" and vold could rewrite the /data keys
# stamped with that future SPL - Android would then reject them as a downgrade
# and /data could never be unlocked again. So KeyMint is started ONLY when the
# live SPL props exactly match the installed system and vendor build.prop.
# On any doubt we start nothing and decryption is simply skipped.
#
# Order (each step waits for the previous one):
#   1. read installed SPLs   2. set + verify live SPL props (resetprop)
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
    exit 0
fi

# --- 1. read the installed system's real SPLs (read-only mounts) -------------
mkdir -p "$MNT/system" "$MNT/vendor"
real_sys=""; real_ven=""
if mount -t ext4 -o ro "/dev/block/mapper/system$SLOT" "$MNT/system" 2>>"$LOG"; then
    real_sys="$(grep -m1 '^ro.build.version.security_patch=' "$MNT/system/system/build.prop" | cut -d= -f2)"
    umount "$MNT/system"
fi
if mount -t ext4 -o ro "/dev/block/mapper/vendor$SLOT" "$MNT/vendor" 2>>"$LOG"; then
    real_ven="$(grep -m1 '^ro.vendor.build.security_patch=' "$MNT/vendor/build.prop" | cut -d= -f2)"
    umount "$MNT/vendor"
fi
log "installed SPL: system=$real_sys vendor=$real_ven"
if [ -z "$real_sys" ] || [ -z "$real_ven" ]; then
    log "REFUSING to start KeyMint: installed SPL unreadable - decryption disabled"
    exit 0
fi

# --- 2. set the live SPL props to the installed values, then verify ----------
/system/bin/resetprop ro.build.version.security_patch "$real_sys" 2>>"$LOG"
/system/bin/resetprop ro.vendor.build.security_patch "$real_ven" 2>>"$LOG"
live_sys="$(getprop ro.build.version.security_patch)"
live_ven="$(getprop ro.vendor.build.security_patch)"
log "live SPL after resetprop: system=$live_sys vendor=$live_ven"
if [ "$real_sys" != "$live_sys" ] || [ "$real_ven" != "$live_ven" ]; then
    log "REFUSING to start KeyMint: live SPL != installed - decryption disabled"
    exit 0
fi
log "SPL match - OK to start KeyMint"

# --- 3. real vendor at /vendor (KeyMint binary + its libs), kept mounted -----
if ! mountpoint -q /vendor || [ ! -x /vendor/bin/hw/android.hardware.security.keymint-service.rust.trusty ]; then
    mountpoint -q /vendor && umount /vendor 2>/dev/null
    mount -t ext4 -o ro "/dev/block/mapper/vendor$SLOT" /vendor 2>>"$LOG" \
        || { log "cannot mount vendor$SLOT at /vendor"; exit 0; }
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
exit 0
