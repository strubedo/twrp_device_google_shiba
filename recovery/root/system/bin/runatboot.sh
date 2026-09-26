#!/system/bin/sh
# runatboot.sh - TWRP device hook (twrp.cpp runs it right AFTER applying
# TW_OVERRIDE_SYSTEM_PROPS and BEFORE the decrypt page).
#
# Starts the Trusty storage proxy and TEE KeyMint for /data decryption.
#
# SAFETY: KeyMint versions keys by security patch level (SPL). If recovery
# reported a newer SPL than the installed system (our build default is
# 2099-12-31), KeyMint would ask for a key upgrade and vold could rewrite the
# /data keys stamped with that future SPL - Android would then reject them as a
# downgrade and /data could never be unlocked again. So KeyMint is started ONLY
# when the live SPL props exactly match the installed system and vendor
# build.prop values. On any doubt we skip decryption instead.
#
# Log: /tmp/twrp_crypto.log

LOG=/tmp/twrp_crypto.log
log() { echo "$(date +%T) $*" >> "$LOG"; }

SLOT="$(getprop ro.boot.slot_suffix)"
MNT=/tmp/cryptomnt
log "runatboot: slot=$SLOT"

# --- 1. read the installed system's real SPLs (read-only mounts) -----------
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
live_sys="$(getprop ro.build.version.security_patch)"
live_ven="$(getprop ro.vendor.build.security_patch)"
log "SPL system: installed=$real_sys live=$live_sys"
log "SPL vendor: installed=$real_ven live=$live_ven"

if [ -z "$real_sys" ] || [ -z "$real_ven" ] \
   || [ "$real_sys" != "$live_sys" ] || [ "$real_ven" != "$live_ven" ]; then
    log "REFUSING to start KeyMint: SPL mismatch or unreadable - decryption disabled"
    exit 0
fi
log "SPL match - OK to start KeyMint"

# --- 2. real vendor at /vendor (KeyMint binary + its libs), kept mounted ------
if ! mountpoint -q /vendor; then
    mount -t ext4 -o ro "/dev/block/mapper/vendor$SLOT" /vendor 2>>"$LOG" \
        || { log "cannot mount vendor$SLOT at /vendor"; exit 0; }
fi

# --- 3. Trusty secure storage in RAM (mirrors init.zuma.rc's /data/vendor/ss)
mkdir -p /tmp/ss/persist
ln -sf /dev/block/platform/13200000.ufs/by-name/trusty_persist /tmp/ss/persist/0

start twrp.storageproxyd
for i in 1 2 3 4 5; do
    [ -n "$(pidof storageproxyd)" ] && break
    sleep 1
done
[ -n "$(pidof storageproxyd)" ] || { log "storageproxyd did not start"; exit 0; }
log "storageproxyd running (pid $(pidof storageproxyd))"

# --- 4. KeyMint -------------------------------------------------------------
start twrp.keymint
log "keymint start requested"
exit 0
