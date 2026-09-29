#!/system/bin/bash
# twrp_encryption.sh - disable/re-enable /data encryption on Pixel 8 (shiba)
# using DFE-NEO v2 (LeeGarChat), bundled with a locked-down NEO.config:
#   DFE_METHOD=neov2 (never `legacy`), WHERE_TO_INJECT=super (never the
#   inactive vendor_boot/boot), WIPE_DATA_AFTER_INSTALL=false (its rm-based
#   wipe is unsafe with metadata encryption), all extras off.
#
# How DFE neov2 works here: builds a small ext4 image `neo_inject_<slot>` in
# super holding /vendor/etc/init/hw with the /data encryption flags removed
# from fstab.zuma, and adds one first_stage_mount line to the fstab in this
# slot's vendor_boot platform ramdisk (via magiskboot_28, which keeps our TWRP
# `recovery` fragment and the bootconfig intact).
#
#   status      what's active on this slot (read-only)
#   dryrun      every check `disable` makes, no writes
#   disable     checks -> backup vendor_boot -> DFE -> verify (rollback on any
#               failure). Does NOT format: exits 0 only when DFE is applied and
#               verified; the GUI then runs TWRP's own Format Data.
#   postformat  after the format: store the vendor_boot backup in the new
#               Internal Storage (TWRP/dfe_backups/)
#   enable      remove DFE's fstab line from this slot's vendor_boot
#               (magiskboot_28, verified) and delete neo_inject_<slot>.
#               The GUI then formats /data so Android re-encrypts it.
# Log: /tmp/twrp_encryption.log

set -o pipefail
PAYLOAD=/system/etc/twrp_dfe/dfe-neo-shiba.zip
WORK=/tmp/twrp_dfe
LOG=/tmp/twrp_encryption.log
SLOT="$(getprop ro.boot.slot_suffix)"
case "$SLOT" in _a) SLOTNUM=0 ;; _b) SLOTNUM=1 ;; *) echo "unknown slot '$SLOT'"; exit 1 ;; esac
VB="/dev/block/by-name/vendor_boot$SLOT"
SUPER=/dev/block/by-name/super
BIN="$WORK/META-INF/tools/binary/arm64-v8a"
MB="$BIN/magiskboot_28"
LPT="$BIN/lptools_new"
LPARGS="--super $SUPER --slot $SLOTNUM --suffix $SLOT"
MIN_FREE=$((32 * 1024 * 1024))
BACKUP_DIR="$WORK/backup"
STORE_DIR=/data/media/0/TWRP/dfe_backups

say()  { echo "$*"; echo "$(date +%T) $*" >> "$LOG"; }
ok()   { say "  ok    $*"; }
bad()  { say "  FAIL  $*"; FAILED=1; }
die()  { say "!! $*"; exit 1; }

prepare() {     # extract the tools we use from the payload
    [ -s "$PAYLOAD" ] || die "payload missing: $PAYLOAD"
    rm -rf "$WORK/vbx" "$WORK/ram"
    mkdir -p "$WORK" "$BACKUP_DIR"
    unzip -o -q "$PAYLOAD" NEO.config \
        "META-INF/tools/binary/arm64-v8a/magiskboot_28" \
        "META-INF/tools/binary/arm64-v8a/lptools_new" -d "$WORK" \
        || die "cannot extract tools from payload"
    chmod 755 "$MB" "$LPT"
}

unpack_vb() {   # $1 = image -> $WORK/vbx (fragments) + $WORK/ram (platform ramdisk files)
    rm -rf "$WORK/vbx" "$WORK/ram"; mkdir -p "$WORK/vbx" "$WORK/ram"
    ( cd "$WORK/vbx" && "$MB" unpack -h "$1" ) >> "$LOG" 2>&1 || return 1
    [ -s "$WORK/vbx/vendor_ramdisk/ramdisk.cpio" ] || return 1
    ( cd "$WORK/ram" && "$MB" cpio "$WORK/vbx/vendor_ramdisk/ramdisk.cpio" extract ) >> "$LOG" 2>&1 || return 1
}

first_stage_fstab() {   # prints the platform-ramdisk fstab first-stage init will actually use
    # Same precedence as fs_mgr's GetFstabPath(): androidboot.fstab_suffix,
    # then .hardware, then .hardware.platform (-> fstab.zuma on shiba; the
    # -fips variant is only used when the bootloader sets fstab_suffix).
    local key val f
    for key in fstab_suffix hardware hardware.platform; do
        val="$(grep -E "^androidboot\.${key//./\\.} = " /proc/bootconfig 2>/dev/null | head -1 | sed 's/.*= "\(.*\)"/\1/')"
        [ -n "$val" ] || continue
        f="$WORK/ram/first_stage_ramdisk/system/etc/fstab.$val"
        [ -f "$f" ] || f="$(find "$WORK/ram" -name "fstab.$val" 2>/dev/null | head -1)"
        [ -n "$f" ] && [ -f "$f" ] || continue
        grep -w "/system" "$f" | grep -q first_stage_mount && { echo "$f"; return 0; }
    done
    return 1
}

neo_in_super() { "$LPT" $LPARGS --get-info 2>/dev/null | grep -q "neo_inject$SLOT"; }

check_all() {   # every precondition for `disable`; sets FAILED
    FAILED=0
    say "== checks (slot $SLOT)"
    local cfg="$WORK/NEO.config" k
    for k in DFE_METHOD=neov2 WHERE_TO_INJECT=super WIPE_DATA_AFTER_INSTALL=false \
             REMOVE_LOCKSCREEN_INFO=false DISABLE_VERITY_VBMETA_PATCH=false \
             HIDE_NOT_ENCRYPTED=false INSTALL_MAGISK= FORCE_START=true FSTAB_EXTENSION=zuma; do
        grep -qx "$k" "$cfg" && ok "config $k" || bad "config $k not set in payload NEO.config"
    done
    dd if="$VB" of="$WORK/vb.img" bs=1M 2>/dev/null || bad "cannot read $VB"
    if unpack_vb "$WORK/vb.img"; then
        ok "vendor_boot$SLOT parsed (magiskboot_28)"
        [ -s "$WORK/vbx/vendor_ramdisk/recovery.cpio" ] \
            && ok "TWRP recovery fragment present (kept on repack)" \
            || bad "no 'recovery' fragment - unexpected vendor_boot layout"
        [ -s "$WORK/vbx/bootconfig" ] && ok "bootconfig present (kept on repack)" || bad "no bootconfig"
        local fst; fst="$(first_stage_fstab)"
        if [ -n "$fst" ]; then
            ok "first-stage fstab: ${fst#$WORK/ram/}"
            grep -q neo_inject "$fst" && bad "DFE already applied on this slot (use Status / Re-enable)"
        else
            bad "no first-stage fstab in the platform ramdisk"
        fi
    else
        bad "magiskboot_28 could not unpack vendor_boot$SLOT"
    fi
    local free
    free="$("$LPT" $LPARGS --free 2>/dev/null | grep 'Free space' | awk '{print $3}')"
    if [ -n "$free" ] && [ "$free" -ge "$MIN_FREE" ] 2>/dev/null; then
        ok "super free space $((free / 1048576)) MB (need >= $((MIN_FREE / 1048576)) MB)"
    else
        bad "super free space '${free:-unknown}' below $((MIN_FREE / 1048576)) MB"
    fi
    neo_in_super && bad "neo_inject$SLOT already exists in super"
    [ -d /vendor/etc/init/hw ] && ok "/vendor mounted (DFE copies /vendor/etc/init/hw)" \
        || bad "/vendor not mounted - decrypt/boot TWRP normally first"
    return $FAILED
}

do_status() {
    prepare
    say "== encryption status (slot $SLOT)"
    dd if="$VB" of="$WORK/vb.img" bs=1M 2>/dev/null
    if unpack_vb "$WORK/vb.img" && fst="$(first_stage_fstab)" && grep -q neo_inject "$fst"; then
        say "  DFE fstab line:   present in vendor_boot$SLOT"
    else
        say "  DFE fstab line:   not present"
    fi
    neo_in_super && say "  neo_inject$SLOT:   present in super" || say "  neo_inject$SLOT:   not present"
    case "$(getprop ro.crypto.state)" in
        encrypted) say "  /data:            encrypted" ;;
        *)         say "  /data:            not encrypted (or not yet checked)" ;;
    esac
    ls "$STORE_DIR"/vendor_boot*.img >/dev/null 2>&1 \
        && say "  backups:          $(ls "$STORE_DIR"/vendor_boot*.img | wc -l) in TWRP/dfe_backups" \
        || say "  backups:          none"
}

restore_vb() {  # roll vendor_boot back to the backup taken this run
    say "!! rolling back vendor_boot$SLOT from backup"
    dd if="$1" of="$VB" bs=1M conv=fsync 2>/dev/null
    dd if="$VB" of="$WORK/rb.img" bs=1M count=$(( $(stat -c%s "$1") / 1048576 + 1 )) 2>/dev/null
    if [ "$(head -c "$(stat -c%s "$1")" "$WORK/rb.img" | sha256sum | cut -d' ' -f1)" = \
         "$(sha256sum "$1" | cut -d' ' -f1)" ]; then
        say "   vendor_boot$SLOT restored and verified"
    else
        say "!! RESTORE VERIFY FAILED - do not reboot; restore $1 manually"
    fi
    neo_in_super && "$LPT" $LPARGS --remove "neo_inject$SLOT" >> "$LOG" 2>&1 \
        && say "   removed neo_inject$SLOT from super"
}

do_disable() {
    prepare
    check_all || die "checks failed - nothing was changed"
    local bk="$BACKUP_DIR/vendor_boot$SLOT-$(date +%Y%m%d-%H%M%S).img"
    dd if="$VB" of="$bk" bs=1M 2>/dev/null && sha256sum "$bk" > "$bk.sha256" \
        || die "backup failed - nothing was changed"
    say "== backup: $bk"
    say "== running DFE-NEO (neov2 -> super)"
    rm -rf "$WORK/ub"; mkdir -p "$WORK/ub"
    unzip -o -q "$PAYLOAD" META-INF/com/google/android/update-binary -d "$WORK/ub" || die "cannot extract DFE installer"
    # DFE prints `ui_print <text>` to fd $2; give it our stdout and strip the protocol.
    sh "$WORK/ub/META-INF/com/google/android/update-binary" 3 1 "$PAYLOAD" 2>>"$LOG" \
        | sed -n 's/^ui_print //p'
    local rc=${PIPESTATUS[0]}
    say "== DFE exit code $rc; verifying"
    FAILED=0
    dd if="$VB" of="$WORK/vb.img" bs=1M 2>/dev/null
    if unpack_vb "$WORK/vb.img"; then
        [ -s "$WORK/vbx/vendor_ramdisk/recovery.cpio" ] && ok "TWRP recovery fragment intact" || bad "TWRP recovery fragment missing"
        [ -s "$WORK/vbx/bootconfig" ] && ok "bootconfig intact" || bad "bootconfig missing"
        fst="$(first_stage_fstab)" && grep -q neo_inject "$fst" && ok "neo_inject line in ${fst#$WORK/ram/}" || bad "no neo_inject line in first-stage fstab"
    else
        bad "vendor_boot$SLOT no longer parses"
    fi
    neo_in_super && ok "neo_inject$SLOT in super" || bad "neo_inject$SLOT not in super"
    if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then
        restore_vb "$bk"
        die "DFE not applied - rolled back. /data was NOT formatted."
    fi
    say "== DFE applied and verified. TWRP will now format /data."
    say "   (do NOT reboot before the format finishes)"
}

do_postformat() {
    mkdir -p "$STORE_DIR"
    cp -f "$BACKUP_DIR"/vendor_boot*.img* "$STORE_DIR"/ 2>/dev/null \
        && say "== vendor_boot backup saved to Internal Storage/TWRP/dfe_backups" \
        || say "!! no backup to save (was Disable run in this session?)"
    chown -R 1023:1023 /data/media/0/TWRP 2>/dev/null
    say "== done: boot Android and set it up. /data stays unencrypted."
    say "   After every OTA, re-apply before the new slot's first boot."
}

do_enable() {
    prepare
    say "== removing DFE from slot $SLOT"
    dd if="$VB" of="$WORK/vb.img" bs=1M 2>/dev/null || die "cannot read $VB"
    local bk="$BACKUP_DIR/vendor_boot$SLOT-pre-enable-$(date +%Y%m%d-%H%M%S).img"
    cp "$WORK/vb.img" "$bk" && sha256sum "$bk" > "$bk.sha256"
    unpack_vb "$WORK/vb.img" || die "cannot unpack vendor_boot$SLOT - nothing changed"
    fst="$(first_stage_fstab)" || die "no first-stage fstab - nothing changed"
    if grep -q neo_inject "$fst"; then
        sed -i '/neo_inject/d' "$fst"
        local rel="${fst#$WORK/ram/}"
        ( cd "$WORK/vbx" && "$MB" cpio vendor_ramdisk/ramdisk.cpio "add 0644 $rel $fst" \
            && "$MB" repack "$WORK/vb.img" "$WORK/new.img" ) >> "$LOG" 2>&1 || die "repack failed - nothing changed"
        unpack_vb "$WORK/new.img" || die "repacked image doesn't parse - nothing changed"
        [ -s "$WORK/vbx/vendor_ramdisk/recovery.cpio" ] || die "repack lost the TWRP fragment - nothing changed"
        [ -s "$WORK/vbx/bootconfig" ] || die "repack lost bootconfig - nothing changed"
        f2="$(first_stage_fstab)" && ! grep -q neo_inject "$f2" || die "line still present after repack - nothing changed"
        dd if="$WORK/new.img" of="$VB" bs=1M conv=fsync 2>/dev/null || { restore_vb "$bk"; die "write failed - rolled back"; }
        ok "neo_inject line removed from vendor_boot$SLOT (TWRP fragment + bootconfig verified)"
    else
        ok "no DFE fstab line on this slot"
    fi
    if neo_in_super; then
        "$LPT" $LPARGS --remove "neo_inject$SLOT" >> "$LOG" 2>&1 && ok "neo_inject$SLOT removed from super" \
            || say "!! could not remove neo_inject$SLOT (harmless: unused once the fstab line is gone)"
    fi
    say "== DFE removed. TWRP will now format /data so Android re-encrypts it."
}

: > "$LOG.tmp" 2>/dev/null; rm -f "$LOG.tmp"
case "$1" in
    status)     do_status ;;
    dryrun)     prepare; check_all && say "== dry run PASSED - Disable would proceed" \
                         || die "dry run FAILED - Disable would refuse (nothing changed)" ;;
    disable)    do_disable ;;
    postformat) do_postformat ;;
    enable)     do_enable ;;
    *)          echo "usage: $0 status|dryrun|disable|postformat|enable"; exit 1 ;;
esac
