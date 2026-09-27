#!/system/bin/sh
# twrp_install_slot.sh - install the running TWRP into a slot's vendor_boot.
#
#   twrp_install_slot.sh other|both|a|b
#
# Typical use: after an OTA (sideloaded or taken in Android) the updated slot
# gets a stock vendor_boot, which removes TWRP. From TWRP on the old slot:
# "Install TWRP to other slot", then install root, then reboot.
#
# How: our recovery fragment is taken from the vendor_boot of the slot we're
# running (that's the TWRP you're using right now). The target slot's own
# vendor_boot supplies everything else - header, cmdline, DTB, bootconfig and
# first stage - so it keeps matching the Android build installed in it.
# vbgraft (same tool as repack.sh on the PC) builds and self-verifies the
# image. Then: backup -> write -> read back -> compare; any mismatch restores
# the backup. A slot that would not change is left alone.
#
# Log: /tmp/twrp_install_slot.log

LOG=/tmp/twrp_install_slot.log
W=/tmp/twrp_install_slot
VBGRAFT=/system/bin/vbgraft

say() { echo "$*"; echo "$(date +%T) $*" >> "$LOG"; }
die() { say "ERROR: $*"; exit 1; }

# head_of SRC BYTES OUT: first BYTES of SRC (file or partition). vendor_boot
# images are whole 2048-byte pages, so read in pages - avoids relying on
# `cmp -n`, which toybox's cmp may not have.
head_of() {
    [ $(( $2 % 2048 )) -eq 0 ] || die "image size $2 is not page aligned"
    dd if="$1" of="$3" bs=2048 count=$(( $2 / 2048 )) 2>>"$LOG"
}

CUR="$(getprop ro.boot.slot_suffix)"
case "$CUR" in _a) OTHER=_b ;; _b) OTHER=_a ;; *) die "unknown active slot '$CUR'" ;; esac
case "$1" in
    other) TARGETS="$OTHER" ;;
    both)  TARGETS="$OTHER $CUR" ;;
    a)     TARGETS=_a ;;
    b)     TARGETS=_b ;;
    *)     die "usage: $0 other|both|a|b" ;;
esac

[ -x "$VBGRAFT" ] || die "vbgraft missing"
rm -rf "$W"; mkdir -p "$W" || die "cannot create $W"
say "== Install TWRP to vendor_boot${TARGETS} (running slot $CUR)"

# Our recovery fragment comes from the slot we booted TWRP from.
DONOR_DEV="/dev/block/by-name/vendor_boot$CUR"
dd if="$DONOR_DEV" of="$W/donor.img" bs=1M 2>>"$LOG" || die "cannot read $DONOR_DEV"
"$VBGRAFT" --info "$W/donor.img" 2>>"$LOG" | grep -q "type=2 (recovery) name='recovery'" \
    || die "vendor_boot$CUR has no TWRP recovery fragment - boot TWRP from the slot you want to copy it from"

# Backups go to Internal Storage when it's decrypted, so they survive reboot.
BK=""
if [ -d /data/media/0 ] && mkdir -p /data/media/0/TWRP/vendor_boot_backups 2>/dev/null \
   && touch /data/media/0/TWRP/vendor_boot_backups/.w 2>/dev/null; then
    rm -f /data/media/0/TWRP/vendor_boot_backups/.w
    BK=/data/media/0/TWRP/vendor_boot_backups
fi

for S in $TARGETS; do
    DEV="/dev/block/by-name/vendor_boot$S"
    [ -b "$DEV" ] || die "no $DEV"
    PSIZE="$(blockdev --getsize64 "$DEV")"
    say "-- vendor_boot$S (${PSIZE} bytes)"

    dd if="$DEV" of="$W/orig$S.img" bs=1M 2>>"$LOG" || die "cannot read $DEV"
    if [ -n "$BK" ]; then
        B="$BK/vendor_boot${S}-$(date +%Y%m%d-%H%M%S).img"
        cp "$W/orig$S.img" "$B" && say "   backup: ${B#/data/media/0/}" || die "backup to $B failed"
    else
        say "   backup: /tmp only (Internal Storage not decrypted)"
    fi

    "$VBGRAFT" --src "$W/orig$S.img" --recovery-from "$W/donor.img" --out "$W/new$S.img" --max-size "$PSIZE" \
        >>"$LOG" 2>&1 || die "vbgraft failed for vendor_boot$S (see $LOG) - nothing written"
    NSIZE="$(stat -c %s "$W/new$S.img")"

    # Skip if the slot already holds exactly this image.
    head_of "$W/orig$S.img" "$NSIZE" "$W/orighead$S.img"
    if cmp "$W/new$S.img" "$W/orighead$S.img" >/dev/null 2>&1; then
        say "   already has this TWRP - left unchanged"
        continue
    fi

    say "   writing ${NSIZE} bytes..."
    blockdev --setrw "$DEV" 2>/dev/null
    dd if="$W/new$S.img" of="$DEV" bs=1M conv=fsync 2>>"$LOG" || die "write failed on $DEV"
    sync
    head_of "$DEV" "$NSIZE" "$W/readback$S.img"
    if cmp "$W/new$S.img" "$W/readback$S.img" >>"$LOG" 2>&1; then
        say "   verified: vendor_boot$S matches (byte compare)"
    else
        say "   VERIFY FAILED - restoring original vendor_boot$S"
        dd if="$W/orig$S.img" of="$DEV" bs=1M conv=fsync 2>>"$LOG"; sync
        head_of "$DEV" "$(stat -c %s "$W/orig$S.img")" "$W/restored$S.img"
        cmp "$W/orig$S.img" "$W/restored$S.img" >/dev/null 2>&1 \
            && die "vendor_boot$S restored to its original contents" \
            || die "vendor_boot$S restore could NOT be verified - reflash it from the PC before booting that slot"
    fi
done
say "== Done: TWRP installed to vendor_boot${TARGETS}"
exit 0
