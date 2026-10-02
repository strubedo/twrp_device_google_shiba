#!/system/bin/sh
# twrp_collect_logs.sh - bundle everything needed to diagnose a problem into one
# archive: TWRP's logs, the crypto startup log, kernel log, modules, mounts,
# partitions, both slots' vendor_boot layouts, the update/snapshot state and
# versions. Identifiers (serial number, IMEI) are redacted before archiving.
#
#   twrp_collect_logs.sh            -> Download/ if /data is decrypted, else the
#                                      USB OTG drive if one is mounted, else /tmp
#   twrp_collect_logs.sh --to DIR   -> DIR (TWRP Remote uses --to /tmp and pulls it)
#
# Advanced > TOOLS > Collect logs runs this (shim zip, see mkrootzips.py).
# The last line is "SAVED: <path>".
set -u
TO=""
[ "${1:-}" = "--to" ] && TO="${2:-}"

SLOT="$(getprop ro.boot.slot_suffix)"
SLOTL="$(echo "${SLOT#_}" | tr a-z A-Z)"
# UTC, marked Z: TWRP's menu runs with the user's time zone but adb shell doesn't,
# so local time gave the same moment two different names
NAME="twrp-logs-$(date -u +%Y%m%d-%H%M%SZ)-slot$SLOTL"
TMP=/tmp/twrp_logs
W="$TMP/$NAME"
rm -rf "$TMP"; mkdir -p "$W"

say() { echo "$*"; }
grab() { [ -r "$1" ] && cp "$1" "$W/$2" && say "  $2"; }          # grab FILE NAME
run()  { n="$1"; shift; "$@" > "$W/$n" 2>&1; say "  $n"; }        # run NAME CMD...

say "Collecting (slot $SLOTL):"
# --- logs ---
grab /tmp/recovery.log             recovery.log
grab /tmp/twrp_crypto.log          twrp_crypto.log
grab /tmp/twrp_install_slot.log    twrp_install_slot.log
grab /data/adb/twrp_app_install.log twrp_app_install.log
run  kernel.log                    dmesg
# --- versions and states ---
run  versions.txt sh -c '
    echo "TWRP:              $(getprop ro.twrp.version)"
    echo "running slot:      $(getprop ro.boot.slot_suffix)"
    echo "installed Android: $(/system/bin/twrp_root.sh android 2>/dev/null)"
    echo "installed build:   $(/system/bin/twrp_root.sh build 2>/dev/null)"
    echo "root (init_boot):  $(/system/bin/twrp_root.sh status 2>/dev/null)"
    echo "bootloader:        $(getprop ro.bootloader)"
    echo "baseband:          $(getprop gsm.version.baseband)"
    echo "kernel:            $(uname -a)"
    echo "decrypted user 0:  $(getprop twrp.user.0.decrypt)"
    echo "crypto services:   $(getprop twrp.crypto.keystore)"'
run  services.txt  sh -c 'getprop | grep -E "init\.svc\.|ro\.boottime\.twrp"'
run  properties.txt getprop
# --- storage, partitions, modules ---
run  mounts.txt     cat /proc/mounts
run  modules.txt    cat /proc/modules
run  partitions.txt ls -l /dev/block/by-name
run  mapper.txt     ls -l /dev/block/mapper
run  vendor_boot.txt sh -c 'for s in a b; do vbgraft --info /dev/block/by-name/vendor_boot_$s 2>&1; echo; done'
run  update_state.txt sh -c 'ls -la /metadata/ota /metadata/ota/snapshots 2>&1; echo; grep "snapshot:" /tmp/recovery.log'
run  vintf.txt sh -c 'mount | grep -i vintf; echo; ls -la /vendor/etc/vintf /vendor/etc/vintf/manifest 2>&1'

# --- redact identifiers (every file) ---
SER1="$(getprop ro.serialno)"; SER2="$(getprop ro.boot.serialno)"
for f in "$W"/*; do
    for s in "$SER1" "$SER2"; do
        [ ${#s} -ge 6 ] && sed -i "s/$s/<serial>/g" "$f"
    done
    # IMEI: a 14-16 digit number near "imei"
    sed -i -E 's/([Ii][Mm][Ee][Ii][^0-9]{0,24})[0-9]{14,16}/\1<imei>/g' "$f"
done
say "Redacted: serial number, IMEI"

# --- archive ---
if [ -n "$TO" ]; then
    DEST="$TO"
elif [ "$(getprop twrp.user.0.decrypt)" = 1 ] && [ -d /data/media/0/Download ]; then
    DEST=/data/media/0/Download
elif grep -q " /usb-otg " /proc/mounts; then
    DEST=/usb-otg
else
    DEST=/tmp
fi
mkdir -p "$DEST"
OUT="$DEST/$NAME.tar.gz"
tar -czf "$OUT" -C "$TMP" "$NAME" || { say "ERROR: could not write $OUT"; exit 1; }
rm -rf "$TMP"
if [ "$DEST" = /data/media/0/Download ]; then
    # visible to Android: owned by the media user, media label
    chown 1023:1023 "$OUT" 2>/dev/null
    chmod 664 "$OUT" 2>/dev/null
    chcon u:object_r:media_rw_data_file:s0 "$OUT" 2>/dev/null
    say "In Android: Files > Download"
elif [ "$DEST" = /tmp ] && [ -z "$TO" ]; then
    say "/data is locked and no USB drive is mounted: the archive is in /tmp."
    say "Get it with TWRP Remote (Collect logs), or: adb pull $OUT"
fi
say "SAVED: $OUT ($(du -k "$OUT" | cut -f1) KB)"
