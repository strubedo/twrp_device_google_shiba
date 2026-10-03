#!/system/bin/bash
# twrp_encryption.sh - disable/re-enable /data encryption on Pixel 8 (shiba).
# Our own implementation (no third-party installer): the standard Android
# first_stage_mount mechanism mounts a small overlay over /vendor/etc/init/hw.
#
#   * nocrypt_<slot>: a 4 MiB ext4 logical partition in super (lptool) holding
#     a copy of /vendor/etc/init/hw/* plus fstab.<hw> with the /data encryption
#     flags removed (fileencryption=, metadata_encryption=, keydirectory=,
#     inlinecrypt); its init.<hw>.rc reads that fstab for `mount_all --late`.
#     Every file keeps the SELinux label of the file it copies (stat %C).
#   * one line in this slot's first-stage fstab (vendor_boot platform ramdisk,
#     edited with our vbgraft --fstab-set, which verifies that the header,
#     dtb, bootconfig, our TWRP fragment and every other ramdisk file are
#     unchanged):
#       nocrypt /vendor/etc/init/hw ext4 ro,discard slotselect,logical,first_stage_mount
#
#   status      what's active on this slot (read-only)
#   dryrun      every check `disable` makes AND builds + verifies the overlay
#               image in /tmp - no writes to the phone
#   disable     checks -> backup vendor_boot -> partition + image -> fstab line
#               -> verify (rollback on any failure). Does NOT format: exits 0
#               only when everything is applied and verified; the GUI then runs
#               TWRP's own Format Data.
#   postformat  after the format: store the vendor_boot backup in the new
#               Internal Storage (TWRP/encryption_backups/)
#   enable      remove the fstab line from this slot's vendor_boot (verified)
#               and delete the overlay partition. The GUI then formats /data
#               so Android re-encrypts it.
#   dfe-active  read-only: DFE_ACTIVE (exit 0) if this slot boots without
#               encryption, else DFE_INACTIVE (exit 1). Used by the OTA guard
#               (twinstall.cpp): an OTA can't carry this to the new slot.
# DFE-NEO's neo_inject (partition + line) is recognized by status, enable and
# dfe-active, for phones where it was used before.
# Log: /tmp/twrp_encryption.log

set -o pipefail
WORK=/tmp/twrp_nocrypt
LOG=/tmp/twrp_encryption.log
SLOT="$(getprop ro.boot.slot_suffix)"
case "$SLOT" in _a|_b) ;; *) echo "unknown slot '$SLOT'"; exit 1 ;; esac
VB="/dev/block/by-name/vendor_boot$SLOT"
VBG=/system/bin/vbgraft
LPT=/system/bin/lptool
VB_PART_SIZE=67108864
PART=nocrypt                                   # partition: nocrypt_a / nocrypt_b
LINE="$PART /vendor/etc/init/hw ext4 ro,discard slotselect,logical,first_stage_mount"
IMG_SIZE=$((4 * 1024 * 1024))
HW_DIR=/vendor/etc/init/hw
BACKUP_DIR="$WORK/backup"
STORE_DIR=/data/media/0/TWRP/encryption_backups
REMOVE_DATA_FLAGS="fileencryption metadata_encryption keydirectory inlinecrypt"

say()  { echo "$*"; echo "$(date +%T) $*" >> "$LOG"; }
ok()   { say "  ok    $*"; }
bad()  { say "  FAIL  $*"; FAILED=1; }
die()  { say "!! $*"; exit 1; }

prepare() {
    # -f, not -x: TWRP's bash answers -x wrongly (false even for executables
    # on the ramdisk; toybox `test -x` is right)
    [ -f "$VBG" ] || die "vbgraft missing ($VBG)"
    [ -f "$LPT" ] || die "lptool missing ($LPT)"
    rm -rf "$WORK/fs.cur" "$WORK/fs.new"
    mkdir -p "$WORK" "$BACKUP_DIR"
}

hardware() {    # the fstab suffix Android's GetFstabPath() would pick: the first of
    # androidboot.fstab_suffix / .hardware / .hardware.platform for which
    # /vendor/etc/fstab.<value> exists (shiba: hardware=shiba, platform=zuma)
    local key val
    for key in fstab_suffix hardware hardware.platform; do
        val="$(grep -E "^androidboot\.${key//./\\.} = " /proc/bootconfig 2>/dev/null | head -1 | sed 's/.*= "\(.*\)"/\1/')"
        [ -n "$val" ] && [ -f "/vendor/etc/fstab.$val" ] && { echo "$val"; return 0; }
    done
    return 1
}

read_vb() {     # this slot's vendor_boot -> $WORK/vb.img, trimmed to the image's
    # own size (the partition is 64 MB; the rest is leftovers of older contents).
    # Size from the v4 header: header + ramdisk + dtb + ramdisk table +
    # bootconfig, each rounded up to the page size.
    dd if="$VB" of="$WORK/vb.full" bs=1M 2>/dev/null || return 1
    [ "$(head -c 8 "$WORK/vb.full")" = VNDRBOOT ] || return 1
    local u32 pg total part
    u32() { od -An -tu4 -j "$1" -N4 "$WORK/vb.full" | tr -d ' '; }
    pg="$(u32 12)"
    [ "$(u32 8)" = 4 ] && [ -n "$pg" ] && [ "$pg" -gt 0 ] || return 1
    total=0
    for part in 2128 "$(u32 24)" "$(u32 2100)" "$(u32 2112)" "$(u32 2124)"; do
        total=$(( total + (part + pg - 1) / pg * pg ))
    done
    [ "$total" -le "$(stat -c%s "$WORK/vb.full")" ] || return 1
    head -c "$total" "$WORK/vb.full" > "$WORK/vb.img" && rm -f "$WORK/vb.full"
}

fs_name() {     # $1 = vendor_boot image -> prints the first-stage fstab's name (e.g.
    # fstab.zuma) and leaves its content in $WORK/fs.cur. Same precedence as
    # fs_mgr's GetFstabPath(): androidboot.fstab_suffix, .hardware,
    # .hardware.platform - the first one whose fstab exists and mounts /system
    # at first stage.
    local key val
    for key in fstab_suffix hardware hardware.platform; do
        val="$(grep -E "^androidboot\.${key//./\\.} = " /proc/bootconfig 2>/dev/null | head -1 | sed 's/.*= "\(.*\)"/\1/')"
        [ -n "$val" ] || continue
        "$VBG" --src "$1" --fstab-get "fstab.$val" > "$WORK/fs.cur" 2>> "$LOG" || continue
        grep -w "/system" "$WORK/fs.cur" | grep -q first_stage_mount && { echo "fstab.$val"; return 0; }
    done
    rm -f "$WORK/fs.cur"
    return 1
}

vb_has_recovery() { "$VBG" --info "$1" 2>/dev/null | grep -q "type=2 (recovery)"; }
vb_bootconfig() { "$VBG" --info "$1" 2>/dev/null | head -1 | sed -n 's/.* bootconfig=\([0-9]*\) .*/\1/p'; }

has_line() { grep -q -E "^[[:space:]]*(nocrypt|neo_inject)[[:space:]]" "$1"; }   # ours or DFE-NEO's
has_part() { "$LPT" has "$SLOT" "$PART$SLOT" || "$LPT" has "$SLOT" "neo_inject$SLOT"; }

free_bytes() { "$LPT" info "$SLOT" 2>/dev/null | awk '$1 == "free" {print $2}'; }

# --- stale virtual A/B leftovers ------------------------------------------------
# After an update merges, its *-cow partitions can stay in super until the next
# update, leaving no free space. They are stale (safe to remove) only if no
# update is in progress: the snapshot state is NONE (empty file), there are no
# snapshot records and no snapshot-boot marker.
stale_cow_parts() { "$LPT" info "$SLOT" 2>/dev/null | awk '$2 == "cow" {print $1}'; }
no_update_in_progress() {
    [ ! -s /metadata/ota/state ] || return 1
    [ -z "$(ls -A /metadata/ota/snapshots 2>/dev/null)" ] || return 1
    [ ! -e /metadata/ota/snapshot-boot ] || return 1
}
reclaim_stale_cow() {
    local p
    for p in $(stale_cow_parts); do
        "$LPT" remove "$SLOT" "$p" >> "$LOG" 2>&1 && ok "removed stale update space $p" \
            || { bad "could not remove $p"; return 1; }
    done
}

# --- the overlay image ------------------------------------------------------------
label_of() { stat -c %C "$1" 2>/dev/null; }

patch_fstab() {  # $1 = source fstab, $2 = output: /data lines without encryption flags
    awk -v flags="$REMOVE_DATA_FLAGS" '
        BEGIN { n = split(flags, F, " ") }
        function strip(list,   i, j, out, t, k, keep) {
            k = split(list, t, ",")
            out = ""
            for (i = 1; i <= k; i++) {
                keep = 1
                for (j = 1; j <= n; j++)
                    if (t[i] == F[j] || index(t[i], F[j] "=") == 1) keep = 0
                if (keep) out = out (out == "" ? "" : ",") t[i]
            }
            return out
        }
        $0 !~ /^[[:space:]]*#/ && $2 == "/data" { $4 = strip($4); $5 = strip($5) }
        { print }' "$1" > "$2"
}

build_image() {  # -> $WORK/nocrypt.img, verified; sets FAILED on problems
    local hw fstab src root rc n f
    hw="$(hardware)" || { bad "no /vendor/etc/fstab.<fstab_suffix|hardware|platform>"; return 1; }
    fstab="fstab.$hw"
    src="/vendor/etc/$fstab"
    root="$WORK/img_root"
    rm -rf "$root" "$WORK/nocrypt.img" "$WORK/mnt"; mkdir -p "$root"
    [ -n "$hw" ] && [ -f "$src" ] || { bad "no $src (hardware '$hw')"; return 1; }
    cp -a "$HW_DIR"/. "$root"/ || { bad "cannot copy $HW_DIR"; return 1; }
    patch_fstab "$src" "$root/$fstab"
    grep -E "^[^#]*[[:space:]]/data[[:space:]]" "$root/$fstab" | grep -q -E "fileencryption|metadata_encryption|keydirectory|inlinecrypt" \
        && { bad "patched $fstab still has encryption flags"; return 1; }
    [ "$(grep -c -E '^[^#]*[[:space:]]/data[[:space:]]' "$root/$fstab")" = "$(grep -c -E '^[^#]*[[:space:]]/data[[:space:]]' "$src")" ] \
        || { bad "patched $fstab lost /data lines"; return 1; }
    # every line kept - including a last line without a trailing newline (a
    # read-loop patcher silently drops it; awk doesn't, and this proves it)
    [ "$(awk 'END {print NR}' "$root/$fstab")" = "$(awk 'END {print NR}' "$src")" ] \
        || { bad "patched $fstab has a different number of lines"; return 1; }
    ok "$fstab: /data without encryption flags ($(grep -c -E '^[^#]*[[:space:]]/data[[:space:]]' "$src") lines)"
    # mount_all --late (mounts /data, which is latemount) -> our fstab
    rc="$(grep -l -E '^[[:space:]]*mount_all --late[[:space:]]*$' "$root"/*.rc)"
    n="$(echo "$rc" | grep -c .)"
    [ "$n" = 1 ] || { bad "expected one rc file with 'mount_all --late', found $n"; return 1; }
    [ "$(grep -c -E '^[[:space:]]*mount_all --late[[:space:]]*$' "$rc")" = 1 ] || { bad "more than one 'mount_all --late' in $(basename "$rc")"; return 1; }
    sed -i -E "s|^([[:space:]]*)mount_all --late[[:space:]]*\$|\1mount_all /vendor/etc/init/hw/$fstab --late|" "$rc"
    grep -q -E "^[[:space:]]*mount_all /vendor/etc/init/hw/$fstab --late\$" "$rc" || { bad "rc rewrite failed"; return 1; }
    ok "$(basename "$rc"): mount_all --late -> /vendor/etc/init/hw/$fstab"
    mke2fs -q -t ext4 -b 4096 -O ^has_journal -L "$PART" -d "$root" "$WORK/nocrypt.img" $((IMG_SIZE / 4096)) >> "$LOG" 2>&1 \
        || { bad "mke2fs failed"; return 1; }
    # SELinux labels: exactly those of the files being shadowed. mke2fs -d
    # copies contents, modes and owners but not labels, so set them inside the
    # mounted image (writes security.selinux into the ext4 filesystem).
    mkdir -p "$WORK/mnt"
    mount -t ext4 -o rw,loop "$WORK/nocrypt.img" "$WORK/mnt" || { bad "image does not mount (rw)"; return 1; }
    local lbl_ok=1
    chcon "$(label_of "$HW_DIR")" "$WORK/mnt" || lbl_ok=0
    for f in "$HW_DIR"/*; do
        chcon "$(label_of "$f")" "$WORK/mnt/$(basename "$f")" || lbl_ok=0
    done
    chcon "$(label_of "$src")" "$WORK/mnt/$fstab" || lbl_ok=0
    [ -d "$WORK/mnt/lost+found" ] && { chcon "$(label_of "$HW_DIR")" "$WORK/mnt/lost+found" || lbl_ok=0; }
    umount "$WORK/mnt" || { bad "image does not unmount"; return 1; }
    [ "$lbl_ok" = 1 ] || { bad "setting SELinux labels in the image failed"; return 1; }
    # verify: a fresh read-only mount; compare every file, its label, mode and owner
    mount -t ext4 -o ro,loop "$WORK/nocrypt.img" "$WORK/mnt" || { bad "image does not mount"; return 1; }
    local okimg=1 want
    [ "$(label_of "$WORK/mnt")" = "$(label_of "$HW_DIR")" ] || { bad "image: label of its root ($(label_of "$WORK/mnt"))"; okimg=0; }
    for f in "$root"/*; do
        cmp -s "$f" "$WORK/mnt/$(basename "$f")" || { bad "image: $(basename "$f") differs"; okimg=0; }
    done
    for f in "$HW_DIR"/*; do
        [ "$(label_of "$WORK/mnt/$(basename "$f")")" = "$(label_of "$f")" ] || { bad "image: label of $(basename "$f")"; okimg=0; }
        want="$(stat -c '%a %u %g' "$f")"
        [ "$(stat -c '%a %u %g' "$WORK/mnt/$(basename "$f")")" = "$want" ] || { bad "image: mode/owner of $(basename "$f")"; okimg=0; }
    done
    [ "$(label_of "$WORK/mnt/$fstab")" = "$(label_of "$src")" ] || { bad "image: label of $fstab"; okimg=0; }
    umount "$WORK/mnt"
    [ "$okimg" = 1 ] || return 1
    ok "overlay image built and verified ($(ls "$root" | wc -l) files, labels match)"
}

check_all() {   # every precondition for `disable`; sets FAILED
    FAILED=0
    say "== checks (slot $SLOT)"
    [ -d "$HW_DIR" ] && ok "/vendor mounted" || bad "/vendor not mounted - boot TWRP normally first"
    read_vb || bad "cannot read $VB (or not a vendor_boot v4 image)"
    if "$VBG" --info "$WORK/vb.img" >> "$LOG" 2>&1; then
        ok "vendor_boot$SLOT parsed"
        vb_has_recovery "$WORK/vb.img" && ok "TWRP recovery fragment present (kept, verified by vbgraft)" \
            || bad "no 'recovery' fragment - unexpected vendor_boot layout"
        [ "$(vb_bootconfig "$WORK/vb.img")" -gt 0 ] 2>/dev/null && ok "bootconfig present (kept, verified by vbgraft)" \
            || bad "no bootconfig"
        local fsn; fsn="$(fs_name "$WORK/vb.img")"
        if [ -n "$fsn" ]; then
            ok "first-stage fstab: $fsn"
            has_line "$WORK/fs.cur" && bad "already disabled on this slot (use Status / Re-enable)"
        else
            bad "no first-stage fstab in the platform ramdisk"
        fi
    else
        bad "vbgraft could not parse vendor_boot$SLOT"
    fi
    has_part && bad "an overlay partition already exists in super (use Re-enable first)"
    local free; free="$(free_bytes)"
    if [ -n "$free" ] && [ "$free" -ge "$IMG_SIZE" ] 2>/dev/null; then
        ok "super free space $((free / 1048576)) MB"
    elif [ -n "$(stale_cow_parts)" ] && no_update_in_progress; then
        ok "super is full of stale update space ($(stale_cow_parts | tr '\n' ' ')) - will be reclaimed (no update in progress)"
    elif [ -n "$(stale_cow_parts)" ]; then
        bad "an update is in progress (its space can't be reclaimed) - finish or cancel it first"
    else
        bad "super free space '${free:-unknown}' below $((IMG_SIZE / 1048576)) MB"
    fi
    build_image
    return $FAILED
}

do_status() {
    prepare
    say "== encryption status (slot $SLOT)"
    read_vb
    if fs_name "$WORK/vb.img" >/dev/null && has_line "$WORK/fs.cur"; then
        say "  fstab line:       present in vendor_boot$SLOT ($(grep -o -E '^[[:space:]]*(nocrypt|neo_inject)' "$WORK/fs.cur" | tr -d ' '))"
    else
        say "  fstab line:       not present"
    fi
    "$LPT" has "$SLOT" "$PART$SLOT" && say "  $PART$SLOT:       present in super"
    "$LPT" has "$SLOT" "neo_inject$SLOT" && say "  neo_inject$SLOT:    present in super (DFE-NEO)"
    has_part || say "  overlay partition: not present"
    case "$(getprop ro.crypto.state)" in
        encrypted) say "  /data:            encrypted" ;;
        *)         say "  /data:            not encrypted (or not yet checked)" ;;
    esac
    ls "$STORE_DIR"/vendor_boot*.img >/dev/null 2>&1 \
        && say "  backups:          $(ls "$STORE_DIR"/vendor_boot*.img | wc -l) in TWRP/encryption_backups" \
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
    "$LPT" has "$SLOT" "$PART$SLOT" && "$LPT" remove "$SLOT" "$PART$SLOT" >> "$LOG" 2>&1 \
        && say "   removed $PART$SLOT from super"
}

do_disable() {
    prepare
    check_all || die "checks failed - nothing was changed"
    local bk="$BACKUP_DIR/vendor_boot$SLOT-$(date +%Y%m%d-%H%M%S).img"
    dd if="$VB" of="$bk" bs=1M 2>/dev/null && sha256sum "$bk" > "$bk.sha256" \
        || die "backup failed - nothing was changed"
    say "== backup: $bk"
    # 1. space, partition, image
    local free; free="$(free_bytes)"
    if [ -z "$free" ] || [ "$free" -lt "$IMG_SIZE" ]; then
        say "== reclaiming stale update space"
        no_update_in_progress || die "an update is in progress - nothing was changed"
        reclaim_stale_cow || die "could not reclaim space - nothing else was changed"
    fi
    say "== creating $PART$SLOT in super"
    "$LPT" add "$SLOT" "$PART$SLOT" "$IMG_SIZE" "vendor$SLOT" 2>&1 | tee -a "$LOG" \
        || die "could not create $PART$SLOT - vendor_boot was not changed"
    "$LPT" write "$SLOT" "$PART$SLOT" "$WORK/nocrypt.img" 2>&1 | tee -a "$LOG" \
        || { "$LPT" remove "$SLOT" "$PART$SLOT" >> "$LOG" 2>&1; die "could not write the overlay - removed it, vendor_boot was not changed"; }
    # 2. first-stage fstab line (vbgraft verifies everything else is unchanged)
    say "== adding the first-stage mount line to vendor_boot$SLOT"
    local fsn
    fsn="$(fs_name "$WORK/vb.img")" || { restore_vb "$bk"; die "no first-stage fstab - rolled back"; }
    { cat "$WORK/fs.cur"; echo "$LINE"; } > "$WORK/fs.new"
    "$VBG" --src "$WORK/vb.img" --fstab-set "$fsn" "$WORK/fs.new" --out "$WORK/new.img" --max-size "$VB_PART_SIZE" 2>&1 | tee -a "$LOG" \
        || { restore_vb "$bk"; die "vbgraft could not rebuild vendor_boot - rolled back"; }
    # 3. verify the new image before and after writing it
    FAILED=0
    vb_has_recovery "$WORK/new.img" && ok "TWRP recovery fragment intact" || bad "TWRP recovery fragment missing"
    [ "$(vb_bootconfig "$WORK/new.img")" = "$(vb_bootconfig "$WORK/vb.img")" ] && ok "bootconfig intact" || bad "bootconfig changed"
    "$VBG" --src "$WORK/new.img" --fstab-get "$fsn" 2>/dev/null | grep -q -x "$LINE" && ok "mount line in $fsn" \
        || bad "mount line missing in the rebuilt image"
    [ "$FAILED" = 0 ] || { restore_vb "$bk"; die "rebuilt vendor_boot failed verification - rolled back"; }
    dd if="$WORK/new.img" of="$VB" bs=1M conv=fsync 2>/dev/null || { restore_vb "$bk"; die "write failed - rolled back"; }
    dd if="$VB" of="$WORK/check.img" bs=1M count=$(( $(stat -c%s "$WORK/new.img") / 1048576 + 1 )) 2>/dev/null
    [ "$(head -c "$(stat -c%s "$WORK/new.img")" "$WORK/check.img" | sha256sum | cut -d' ' -f1)" = \
      "$(sha256sum "$WORK/new.img" | cut -d' ' -f1)" ] || { restore_vb "$bk"; die "vendor_boot read-back mismatch - rolled back"; }
    ok "vendor_boot$SLOT written and read back identically"
    say "== applied and verified. TWRP will now format /data."
    say "   (do NOT reboot before the format finishes)"
}

do_postformat() {
    mkdir -p "$STORE_DIR"
    cp -f "$BACKUP_DIR"/vendor_boot*.img* "$STORE_DIR"/ 2>/dev/null \
        && say "== vendor_boot backup saved to Internal Storage/TWRP/encryption_backups" \
        || say "!! no backup to save (was Disable run in this session?)"
    chown -R 1023:1023 /data/media/0/TWRP 2>/dev/null
    say "== done: boot Android and set it up. /data stays unencrypted."
    say "   After every OTA, re-apply before the new slot's first boot."
}

do_enable() {
    prepare
    say "== re-enabling encryption on slot $SLOT"
    read_vb || die "cannot read $VB"
    local bk="$BACKUP_DIR/vendor_boot$SLOT-pre-enable-$(date +%Y%m%d-%H%M%S).img"
    cp "$WORK/vb.img" "$bk" && sha256sum "$bk" > "$bk.sha256"
    local fsn
    fsn="$(fs_name "$WORK/vb.img")" || die "no first-stage fstab - nothing changed"
    if has_line "$WORK/fs.cur"; then
        grep -v -E '^[[:space:]]*(nocrypt|neo_inject)[[:space:]]' "$WORK/fs.cur" > "$WORK/fs.new"
        "$VBG" --src "$WORK/vb.img" --fstab-set "$fsn" "$WORK/fs.new" --out "$WORK/new.img" --max-size "$VB_PART_SIZE" >> "$LOG" 2>&1 \
            || die "vbgraft could not rebuild vendor_boot - nothing changed"
        vb_has_recovery "$WORK/new.img" || die "rebuilt image lost the TWRP fragment - nothing changed"
        [ "$(vb_bootconfig "$WORK/new.img")" = "$(vb_bootconfig "$WORK/vb.img")" ] || die "rebuilt image changed bootconfig - nothing changed"
        "$VBG" --src "$WORK/new.img" --fstab-get "$fsn" 2>/dev/null | has_line /dev/stdin && die "line still present after rebuild - nothing changed"
        dd if="$WORK/new.img" of="$VB" bs=1M conv=fsync 2>/dev/null || { restore_vb "$bk"; die "write failed - rolled back"; }
        ok "mount line removed from vendor_boot$SLOT (TWRP fragment + bootconfig verified)"
    else
        ok "no mount line on this slot"
    fi
    local p
    for p in "$PART$SLOT" "neo_inject$SLOT"; do
        "$LPT" has "$SLOT" "$p" || continue
        "$LPT" remove "$SLOT" "$p" >> "$LOG" 2>&1 && ok "$p removed from super" \
            || say "!! could not remove $p (harmless: unused once the mount line is gone)"
    done
    say "== removed. TWRP will now format /data so Android re-encrypts it."
}

do_dfe_active() {
    prepare >/dev/null 2>&1
    read_vb
    if { fs_name "$WORK/vb.img" >/dev/null && has_line "$WORK/fs.cur"; } || has_part; then
        echo DFE_ACTIVE; exit 0
    fi
    echo DFE_INACTIVE; exit 1
}

case "$1" in
    status)     do_status ;;
    dryrun)     prepare; check_all && say "== dry run PASSED - Disable would proceed" \
                         || die "dry run FAILED - Disable would refuse (nothing changed)" ;;
    disable)    do_disable ;;
    postformat) do_postformat ;;
    enable)     do_enable ;;
    dfe-active) do_dfe_active ;;
    *)          echo "usage: $0 status|dryrun|disable|postformat|enable|dfe-active"; exit 1 ;;
esac
