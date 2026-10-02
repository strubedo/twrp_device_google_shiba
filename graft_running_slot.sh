#!/system/bin/sh
# graft_running_slot.sh - run IN TWRP: graft a TWRP recovery fragment onto the
# RUNNING slot's own vendor_boot (what "Install to other slot" does, for the
# current slot). For development when the other slot can't be used (e.g. after
# a Virtual A/B merge released it) and build.sh --flash must not be used (its
# image is built on another firmware's stock vendor_boot).
#   adb push <recovery.cpio.lz4> /tmp/frag.lz4
#   adb push graft_running_slot.sh /tmp/ && adb shell sh /tmp/graft_running_slot.sh
# Backs up the partition to /sdcard/TWRP/vendor_boot_backups first, lets
# vbgraft verify the result, writes it, and byte-compares what was written.
set -e
FRAG=/tmp/frag.lz4
SLOT="$(getprop ro.boot.slot_suffix)"
PART="/dev/block/by-name/vendor_boot${SLOT}"
BK=/sdcard/TWRP/vendor_boot_backups
[ -f "$FRAG" ] || { echo "no $FRAG - adb push the fragment first"; exit 1; }
[ -b "$PART" ] || { echo "no $PART"; exit 1; }
mkdir -p "$BK"
dd if="$PART" of=/tmp/vb_cur.img bs=1M 2>/dev/null
cp /tmp/vb_cur.img "$BK/vendor_boot${SLOT}-$(date +%Y%m%d-%H%M%S).img"
echo "- backup: $BK/vendor_boot${SLOT}-*.img"
vbgraft --src /tmp/vb_cur.img --recovery-frag "$FRAG" --out /tmp/vb_new.img --max-size 67108864 | tail -1
dd if=/tmp/vb_new.img of="$PART" bs=1M conv=fsync 2>/dev/null
n=$(stat -c %s /tmp/vb_new.img)
if head -c "$n" "$PART" | cmp - /tmp/vb_new.img; then
    echo "VERIFIED: vendor_boot${SLOT} written ($n bytes) - adb reboot recovery"
else
    echo "MISMATCH - restoring the backup"
    dd if=/tmp/vb_cur.img of="$PART" bs=1M conv=fsync 2>/dev/null
    exit 1
fi
