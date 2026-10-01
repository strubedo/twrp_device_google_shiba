#!/system/bin/bash
# twrp_root.sh - install / remove root on the active slot's init_boot.
#
#   twrp_root.sh status          print STOCK | KERNELSU | MAGISK | UNKNOWN
#   twrp_root.sh install-ksu     KernelSU (LKM) via bundled ksud
#   twrp_root.sh install-magisk  Magisk via its own boot_patch.sh
#   twrp_root.sh remove          restore stock init_boot (either tool)
#   ... ACTION other             act on the slot we are NOT running (after an
#                                OTA: "Reinstall root after OTA", twinstall.cpp);
#                                the KMI then comes from that slot's boot image
#
# Safety rules, applied to every write:
#   1. detect the current state first; installs require STOCK (never layer
#      one root tool over the other), remove requires a known patch
#   2. back up the current init_boot before writing
#   3. verify the new image's state BEFORE flashing
#   4. after flashing, read the partition back and compare byte-for-byte;
#      on mismatch, write the backup back and fail
#
# Detection keys (verified against real images, see git history):
#   MAGISK   ramdisk has .backup/.magisk
#   KERNELSU ramdisk has kernelsu.ko AND init.real
#   STOCK    neither (a leftover stock_image.sha1 alone does not count)
set -euo pipefail

TOOLS=/system/etc/twrp_root
MAGISKBOOT=/system/bin/magiskboot
KSUD=/system/bin/ksud
W=/tmp/twrp_root
RUN_SLOT="$(getprop ro.boot.slot_suffix)"
SLOT="$RUN_SLOT"
if [[ "${2:-}" == other ]]; then
    case "$RUN_SLOT" in _a) SLOT=_b ;; _b) SLOT=_a ;; *) SLOT="" ;; esac
fi
PART="/dev/block/by-name/init_boot${SLOT}"

say()  { echo "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[[ -n "$SLOT" && -b "$PART" ]] || die "cannot find init_boot for slot '$SLOT'"
mkdir -p "$W"

# ---- helpers ---------------------------------------------------------------

# state_of IMG -> STOCK | KERNELSU | MAGISK | UNKNOWN
state_of() {
    local img="$1" d="$W/detect"
    rm -rf "$d"; mkdir -p "$d"
    ( cd "$d" && "$MAGISKBOOT" unpack "$img" >/dev/null 2>&1 ) || { echo UNKNOWN; return; }
    [[ -f "$d/ramdisk.cpio" ]] || { echo UNKNOWN; return; }
    has() { ( cd "$d" && "$MAGISKBOOT" cpio ramdisk.cpio "exists $1" >/dev/null 2>&1 ); }
    if has .backup/.magisk; then echo MAGISK
    elif has kernelsu.ko && has init.real; then echo KERNELSU
    else echo STOCK
    fi
}

# dump the partition to a file
read_part() { dd if="$PART" of="$1" bs=1M 2>/dev/null; }

# kmi -> e.g. android14-5.15  (from 5.15.137-android14-11-g...). For the running
# slot that's the running kernel; for the other slot (after an OTA it may carry
# a different kernel, e.g. android15-6.1) it's read from that slot's boot image.
kmi() {
    local r
    if [[ "$SLOT" == "$RUN_SLOT" ]]; then
        r="$(uname -r)"
    else
        local d="$W/kboot"; rm -rf "$d"; mkdir -p "$d"
        dd if="/dev/block/by-name/boot${SLOT}" of="$d/boot.img" bs=1M 2>/dev/null || die "cannot read boot${SLOT}"
        ( cd "$d" && "$MAGISKBOOT" unpack boot.img >/dev/null 2>&1 ) || die "cannot unpack boot${SLOT}"
        # grep the binary itself (-a): with pipefail, `strings | grep -m1` dies of
        # SIGPIPE (exit 141) when grep stops at the first match
        r="$(grep -a -m1 -o 'Linux version [^ ]*' "$d/kernel" | awk '{print $3}')"
        [[ -n "$r" ]] || die "cannot read the kernel version in boot${SLOT}"
    fi
    local ver="${r%%.*}.$(echo "$r" | cut -d. -f2)"
    local rel; rel="$(echo "$r" | grep -o 'android[0-9]*' | head -1)"
    [[ -n "$rel" ]] || die "cannot derive KMI from kernel '$r'"
    echo "${rel}-${ver}"
}

# flash IMG with backup + readback verification, rollback on mismatch
flash_verified() {
    local img="$1" want="$2" backup="$3"
    local got; got="$(state_of "$img")"
    [[ "$got" == "$want" ]] || die "new image is $got, expected $want - not flashing"
    say "- Flashing init_boot${SLOT}"
    dd if="$img" of="$PART" bs=1M conv=fsync 2>/dev/null || die "write failed"
    local n; n="$(stat -c %s "$img")"
    read_part "$W/readback.img"
    if ! cmp -s -n "$n" "$img" "$W/readback.img"; then
        say "! Readback mismatch - restoring backup"
        dd if="$backup" of="$PART" bs=1M conv=fsync 2>/dev/null
        die "flash verification failed; original init_boot restored"
    fi
    say "- Verified: init_boot${SLOT} is now $want"
}

backup_current() {
    local b="$W/init_boot${SLOT}.backup.$(date +%Y%m%d-%H%M%S).img"
    read_part "$b"
    say "- Backed up current init_boot${SLOT} to $b" >&2
    echo "$b"
}

require_state() {
    local want="$1" cur; cur="$(state_of "$W/current.img")"
    [[ "$cur" == "$want" ]] || die "init_boot${SLOT} is $cur; this action needs $want${2:+ ($2)}"
}

# ---- actions ---------------------------------------------------------------

do_status() { read_part "$W/current.img"; state_of "$W/current.img"; }

do_install_ksu() {
    read_part "$W/current.img"
    require_state STOCK "use Remove root first"
    # The KernelSU module only loads into a kernel with a matching KMI. Check
    # before touching anything, instead of failing inside boot-patch (or
    # worse, producing an image whose kernelsu.ko never loads).
    local k; k="$(kmi)"
    local kmis; kmis="$("$KSUD" boot-info supported-kmis 2>/dev/null)"
    [[ -n "$kmis" ]] || die "ksud reports no supported KMIs - bundled ksud is broken. Nothing was changed."
    if ! grep -qx "$k" <<< "$kmis"; then
        say "! The kernel on slot ${SLOT#_} has KMI $k"
        say "! The bundled KernelSU supports: $(tr '\n' ' ' <<< "$kmis")"
        die "KernelSU can't root this kernel. Use Install Magisk, or a TWRP with a newer ksud. Nothing was changed."
    fi
    say "- Kernel KMI $k is supported by the bundled KernelSU"
    local backup; backup="$(backup_current)"
    say "- Patching with KernelSU (KMI $k)"
    rm -f "$W/ksu_patched.img"
    "$KSUD" boot-patch -b "$W/current.img" --kmi "$k" -o "$W" --out-name ksu_patched.img >/dev/null \
        || die "ksud boot-patch failed"
    flash_verified "$W/ksu_patched.img" KERNELSU "$backup"
    say "- Done. Install/open the KernelSU manager app after booting."
}

do_install_magisk() {
    read_part "$W/current.img"
    require_state STOCK "use Remove root first"
    local backup; backup="$(backup_current)"
    say "- Patching with Magisk"
    rm -rf "$W/magisk"; cp -a "$TOOLS/magisk" "$W/magisk"; chmod 755 "$W/magisk"/*
    ( cd "$W/magisk" && OUTFD=1 KEEPVERITY=true KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false \
        RECOVERYMODE=false ASH_STANDALONE=1 ./busybox sh boot_patch.sh "$W/current.img" >/dev/null 2>&1 ) \
        || die "Magisk boot_patch.sh failed"
    flash_verified "$W/magisk/new-boot.img" MAGISK "$backup"
    say "- Done. Install the Magisk app (full APK) after booting."
}

do_remove() {
    read_part "$W/current.img"
    local cur; cur="$(state_of "$W/current.img")"
    local backup restored="$W/restored.img"
    case "$cur" in
        KERNELSU)
            backup="$(backup_current)"
            say "- Removing KernelSU"
            rm -f "$restored"
            "$KSUD" boot-restore -b "$W/current.img" -o "$W" --out-name restored.img >/dev/null \
                || die "ksud boot-restore failed"
            # ksud leaves its stock_image.sha1 marker behind; strip it
            local d="$W/strip"; rm -rf "$d"; mkdir -p "$d"
            ( cd "$d" && "$MAGISKBOOT" unpack "$restored" >/dev/null 2>&1 \
                && "$MAGISKBOOT" cpio ramdisk.cpio "rm stock_image.sha1" >/dev/null 2>&1 \
                && "$MAGISKBOOT" repack "$restored" "$W/restored_clean.img" >/dev/null 2>&1 ) \
                || die "cleanup repack failed"
            restored="$W/restored_clean.img" ;;
        MAGISK)
            backup="$(backup_current)"
            say "- Removing Magisk"
            local d="$W/mrestore"; rm -rf "$d"; mkdir -p "$d"
            ( cd "$d" && "$MAGISKBOOT" unpack "$W/current.img" >/dev/null 2>&1 \
                && "$MAGISKBOOT" cpio ramdisk.cpio restore >/dev/null 2>&1 \
                && "$MAGISKBOOT" repack "$W/current.img" "$restored" >/dev/null 2>&1 ) \
                || die "Magisk ramdisk restore failed"
            ;;
        STOCK) die "init_boot${SLOT} is already stock - nothing to remove" ;;
        *)     die "init_boot${SLOT} state is $cur - refusing to guess" ;;
    esac
    flash_verified "$restored" STOCK "$backup"
    say "- Done. Uninstall the old manager app in Android."
}

case "${1:-}" in
    status)         do_status ;;
    kmi)            kmi ;;          # read-only: KMI of the (other) slot's kernel
    detect)         [[ -f "${2:-}" ]] || die "usage: $0 detect IMAGE"; state_of "$(realpath "$2")" ;;
    install-ksu)    do_install_ksu ;;
    install-magisk) do_install_magisk ;;
    remove)         do_remove ;;
    *) echo "usage: $0 status|install-ksu|install-magisk|remove" >&2; exit 2 ;;
esac
