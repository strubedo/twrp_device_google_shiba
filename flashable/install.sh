# install.sh - install TWRP for Pixel 8 (shiba) onto this phone's own vendor_boot.
# Sourced by update-binary (TWRP, Magisk app) and customize.sh (KernelSU app).
# Needs: ZIPFILE, and a ui_print function. POSIX sh only (busybox ash, mksh, toybox).
#
# Per slot: read vendor_boot -> back it up -> graft our recovery fragment with
# vbgraft (keeps the phone's own header, cmdline, dtb, bootconfig and platform
# ramdisk; verifies its output) -> write -> read back and compare -> on any
# mismatch, write the original back and verify that.

SHIBA_TMP="${SHIBA_TMP:-/dev/tmp/shiba_twrp}"
BLK="${SHIBA_BLK:-/dev/block/by-name}"      # overridable for tests only
META="${SHIBA_META:-/metadata}"
MEDIA="${SHIBA_MEDIA:-/data/media/0}"
FRAG_LIMIT=46000000            # the bootloader won't load a bigger recovery fragment
PART_SIZE=67108864             # vendor_boot partition size

die() { ui_print "! $*"; ui_print "! Nothing more was changed."; rm -rf "$SHIBA_TMP"; exit 1; }

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

ui_print "*********************************************"
ui_print " TWRP for Google Pixel 8 (shiba) - installer"
ui_print "*********************************************"

# --- the phone ---------------------------------------------------------------
dev="$(getprop ro.product.device)"
[ "$dev" = shiba ] || [ "$(getprop ro.build.product)" = shiba ] \
    || die "this is for the Pixel 8 (shiba), not '$dev'"
CUR="$(getprop ro.boot.slot_suffix)"
case "$CUR" in _a) OTHER=_b ;; _b) OTHER=_a ;; *) die "unknown slot '$CUR'" ;; esac

# --- the zip's own files, checked ----------------------------------------------
rm -rf "$SHIBA_TMP"; mkdir -p "$SHIBA_TMP" || die "cannot create $SHIBA_TMP"
unzip -o -q "$ZIPFILE" recovery.cpio.lz4 tools/vbgraft SHA256SUMS VERSION -d "$SHIBA_TMP" \
    || die "cannot unpack the zip"
cd "$SHIBA_TMP" || die "cannot enter $SHIBA_TMP"
sha256sum -c SHA256SUMS >/dev/null 2>&1 || die "the zip's files fail their checksums (damaged download?)"
chmod 755 tools/vbgraft
VBG="$SHIBA_TMP/tools/vbgraft"
"$VBG" --info "$BLK/vendor_boot$CUR" >/dev/null 2>&1 || die "the bundled vbgraft does not run here"
fsize="$(stat -c %s recovery.cpio.lz4)"
[ "$fsize" -le "$FRAG_LIMIT" ] || die "recovery fragment too big for the bootloader ($fsize > $FRAG_LIMIT)"
ui_print "- $(cat VERSION) for slot $CUR (running)"

# --- which slots ---------------------------------------------------------------
SLOTS="$CUR"
if [ -e "$META/ota/snapshot-boot" ] || [ -s "$META/ota/state" ] \
   || [ -n "$(ls -A "$META/ota/snapshots" 2>/dev/null)" ]; then
    ui_print "- an update is in progress: only slot $CUR is changed"
    ui_print "  (TWRP reflashes the new slot itself when it installs the update)"
else
    SLOTS="$CUR $OTHER"
fi

# backups: Internal Storage if it's there (Android, or TWRP with /data decrypted)
BK=""
if [ -d "$MEDIA" ] && mkdir -p "$MEDIA/TWRP/vendor_boot_backups" 2>/dev/null; then
    BK="$MEDIA/TWRP/vendor_boot_backups"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
for s in $SLOTS; do
    part="$BLK/vendor_boot$s"
    ui_print "- slot $s"
    dd if="$part" of="orig$s.img" bs=1048576 2>/dev/null || die "cannot read $part"
    if ! "$VBG" --info "orig$s.img" >/dev/null 2>&1; then
        [ "$s" = "$CUR" ] && die "vendor_boot$s is not a vendor_boot v4 image"
        ui_print "  skipped: vendor_boot$s is not a valid image (empty slot?)"
        continue
    fi
    if [ -n "$BK" ]; then
        cp "orig$s.img" "$BK/vendor_boot$s-$stamp.img" && sha256sum "$BK/vendor_boot$s-$stamp.img" > "$BK/vendor_boot$s-$stamp.img.sha256" \
            && ui_print "  backup: Internal Storage/TWRP/vendor_boot_backups/vendor_boot$s-$stamp.img" \
            || die "backup to Internal Storage failed"
    else
        ui_print "  backup: only in memory (Internal Storage not available)"
    fi
    "$VBG" --src "orig$s.img" --recovery-frag recovery.cpio.lz4 --out "new$s.img" --max-size "$PART_SIZE" >/dev/null 2>"err$s.txt" \
        || die "graft failed for slot $s: $(tail -1 "err$s.txt")"
    want="$(sha_of "new$s.img")"; n="$(stat -c %s "new$s.img")"
    dd if="new$s.img" of="$part" bs=1048576 conv=fsync 2>/dev/null
    dd if="$part" of="check$s.img" bs=1048576 count=$(( n / 1048576 + 1 )) 2>/dev/null
    if [ "$(head -c "$n" "check$s.img" | sha256sum | cut -d' ' -f1)" = "$want" ]; then
        ui_print "  TWRP installed and verified (read back identically)"
    else
        ui_print "! slot $s: read-back mismatch - restoring the original"
        dd if="orig$s.img" of="$part" bs=1048576 conv=fsync 2>/dev/null
        on="$(stat -c %s "orig$s.img")"
        dd if="$part" of="rb$s.img" bs=1048576 count=$(( on / 1048576 + 1 )) 2>/dev/null
        if [ "$(head -c "$on" "rb$s.img" | sha256sum | cut -d' ' -f1)" = "$(sha_of "orig$s.img")" ]; then
            die "slot $s restored and verified"
        else
            die "RESTORE OF SLOT $s FAILED - do not reboot; flash a backup with fastboot"
        fi
    fi
done

cd / && rm -rf "$SHIBA_TMP"
ui_print "- Done. Reboot to recovery to start TWRP."
ui_print "  To undo: fastboot flash vendor_boot_<slot> <backup>.img"
