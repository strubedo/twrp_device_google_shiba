#!/system/bin/bash
# twrp_root.sh - install / remove root on the active slot's init_boot.
#
#   twrp_root.sh status          print STOCK | KERNELSU | MAGISK | UNKNOWN
#                                (KERNELSU also for root built into the boot
#                                kernel: KernelSU family or APatch). The short
#                                name for the chip goes to $W/root_name.
#   twrp_root.sh name            that short name: KernelSU | KSU-Next | SukiSU |
#                                APatch | Magisk | (empty = not rooted)
#   twrp_root.sh info            human-readable details (Root: Show status)
#   twrp_root.sh kernel          main-page kernel chip: "WIDTH|Kernel 6.1.162 · Stock"
#                                (Stock | the kernel's brand, e.g. Wild | Custom,
#                                plus " · SUSFS"); WIDTH picks the chip image
#   twrp_root.sh install-ksu     KernelSU (LKM) via bundled ksud
#   twrp_root.sh install-ksun    KernelSU-Next (LKM) via the ksud in its app
#   twrp_root.sh install-suki    SukiSU (LKM) via the ksud in its app
#                                (the app's APK must be in Download/: the
#                                ramdisk has no room to bundle every patcher)
#   twrp_root.sh install-magisk  Magisk via its own boot_patch.sh
#   twrp_root.sh install-apatch  APatch: KernelPatch into the BOOT kernel (not
#                                init_boot) with kptools + kpimg from the APatch
#                                APK in Download/; the SuperKey comes from the
#                                TWRP page ($W/apatch_key, 0600) or, for the
#                                other slot after an OTA, from the running kernel
#   twrp_root.sh flash-kernel IMG  a custom kernel's boot image onto boot
#                                (KMI must match the kernel it replaces)
#   twrp_root.sh remove          restore stock init_boot (either tool), or
#                                unpatch APatch from boot
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
# Root can also be built into the kernel itself (a custom kernel with KernelSU,
# KernelSU-Next, SukiSU or APatch in boot) - init_boot is stock then; see
# kernel_scan. `status` reports KERNELSU for that too, installs refuse it, and
# remove explains how to undo it.
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

# kernel_scan [SLOT] -> prints that slot's BOOT kernel facts, one per line:
#   ROOT=none|KernelSU|KSU-Next|SukiSU|APatch   root built into the kernel
#   SUSFS=0|1                                   SUSFS patches present
#   BANNER=6.1.162-android14-11-g...            the kernel's release string
# Markers (from the projects' sources): every KernelSU-family kernel logs with
# the "KernelSU: " prefix; KernelSU-Next adds avc_spoof (extras.c), SukiSU its
# sukisu_ functions / "KernelSU Stealth"; APatch's KernelPatch carries the
# magic KP1158. Cached per slot, keyed on the boot image's first MiB, so the
# main-page chip doesn't unpack 64 MB after every operation.
# kernel_root_of KERNEL -> none | APatch | KernelSU | KSU-Next | SukiSU
# Fixed strings (-F) only: toybox grep -E with | alternatives takes ~10 s per
# pattern on a 46 MB monolithic kernel (Infinity) - 20 s of TWRP splash.
kernel_root_of() {
    if grep -a -q 'KP1158' "$1"; then echo APatch
    elif grep -a -q -F -e 'KernelSU: ' -e 'Android KernelSU' -e ksu_handle_ "$1"; then
        if grep -a -q -F -e sukisu_ -e 'KernelSU Stealth' "$1"; then echo SukiSU
        elif grep -a -q 'avc_spoof' "$1"; then echo KSU-Next
        else echo KernelSU
        fi
    else echo none
    fi
}
# kernel_banner_of KERNEL -> its release string (6.1.162-android14-11-g...)
kernel_banner_of() { grep -a -m1 -o 'Linux version [^ ]*' "$1" | awk '{print $3}' || true; }
kernel_scan() {
    local s="${1:-$SLOT}"
    local boot="/dev/block/by-name/boot${s}" d="$W/kdetect" key cache
    [[ -b "$boot" ]] || { echo "ROOT=none"; echo "SUSFS=0"; echo "BANNER="; return 0; }
    key="$(head -c 1048576 "$boot" | md5sum | cut -c1-16)"
    cache="$W/kernel_scan${s}.$key"
    if [[ ! -f "$cache" ]]; then
        rm -f "$W"/kernel_scan"${s}".*
        rm -rf "$d"; mkdir -p "$d"
        local root=none susfs=0 banner=""
        if dd if="$boot" of="$d/boot.img" bs=1M 2>/dev/null \
                && ( cd "$d" && "$MAGISKBOOT" unpack boot.img >/dev/null 2>&1 ) \
                && [[ -f "$d/kernel" ]]; then
            local k="$d/kernel"
            root="$(kernel_root_of "$k")"
            grep -a -q -i 'susfs' "$k" && susfs=1
            banner="$(kernel_banner_of "$k")"
        fi
        rm -rf "$d"
        printf 'ROOT=%s\nSUSFS=%s\nBANNER=%s\n' "$root" "$susfs" "$banner" > "$cache"
    fi
    cat "$cache"
}
kscan_get() { kernel_scan "${2:-}" | sed -n "s/^$1=//p"; }   # kscan_get KEY [SLOT]

# kernel_ksu [SLOT] -> success if that slot's boot kernel has root built in
# (KernelSU family or APatch). Name kept from v9.46.
kernel_ksu() { [[ "$(kscan_get ROOT "${1:-}")" != none ]]; }

# lkm_family IMG -> KernelSU | KSU-Next | SukiSU: which project's kernelsu.ko
# an LKM-patched init_boot carries (same markers as kernel_scan)
lkm_family() {
    local d="$W/lkm"; rm -rf "$d"; mkdir -p "$d"
    local fam=KernelSU
    if ( cd "$d" && "$MAGISKBOOT" unpack "$1" >/dev/null 2>&1 \
            && "$MAGISKBOOT" cpio ramdisk.cpio "extract kernelsu.ko kernelsu.ko" >/dev/null 2>&1 ); then
        if grep -a -q -F -e sukisu_ -e 'KernelSU Stealth' "$d/kernelsu.ko"; then fam=SukiSU
        elif grep -a -q 'avc_spoof' "$d/kernelsu.ko"; then fam=KSU-Next
        fi
    fi
    rm -rf "$d"
    echo "$fam"
}

# dump the partition to a file
read_part() { dd if="$PART" of="$1" bs=1M 2>/dev/null; }

# kmi -> e.g. android14-6.1 (from 6.1.162-android14-11-g...): the KMI of the
# kernel in this slot's BOOT partition - the one the patched init_boot will
# boot with. Not uname -r: TWRP runs the kernel that was in boot when it
# started, which isn't the slot's kernel any more after a kernel flash or
# restore (v9.48: "cannot derive KMI from kernel '6.1.162-Wild'" right after
# putting the stock kernel back). Branded custom kernels can drop the
# androidNN part from their name (6.1.162-Wild); a GKI kernel's Linux version
# then still says which KMI it is, where only one Android release uses it.
kmi() {
    local r; r="$(kscan_get BANNER)"
    [[ -n "$r" || "$SLOT" != "$RUN_SLOT" ]] || r="$(uname -r)"
    [[ -n "$r" ]] || die "cannot read the kernel version in boot${SLOT}"
    kmi_of "$r"
}
# kmi_of RELEASE -> its KMI (the same rules for an image that isn't flashed yet)
kmi_of() {
    local r="$1"
    local ver="${r%%.*}.$(echo "$r" | cut -d. -f2)"
    ver="${ver%%-*}"
    local rel; rel="$(echo "$r" | grep -o 'android[0-9]*' | head -1 || true)"
    if [[ -z "$rel" ]]; then
        case "$ver" in          # GKI: Linux version -> its one Android release
            6.1)  rel=android14 ;;
            6.6)  rel=android15 ;;
            6.12) rel=android16 ;;
            *)    die "cannot derive the KMI from kernel '$r' (no androidNN in its name, and Linux $ver is used by more than one Android release). Nothing was changed." ;;
        esac
        echo "- Kernel '$r' doesn't name its KMI; Linux $ver is ${rel}-${ver}" >&2
    fi
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
    # The /tmp copy is for the rollback below; keep one that survives a reboot
    # on Internal Storage too, next to the vendor_boot backups.
    local keep=/data/media/0/TWRP/init_boot_backups
    if [[ -d /data/media/0 ]] && mkdir -p "$keep" && cp "$b" "$keep/" 2>/dev/null; then
        chown -R 0:1023 /data/media/0/TWRP 2>/dev/null; chmod 660 "$keep/${b##*/}" 2>/dev/null
        say "- Backed up current init_boot${SLOT} to Internal Storage: TWRP/init_boot_backups/${b##*/}" >&2
    else
        say "- Backed up current init_boot${SLOT} to $b (Internal Storage not available - lost at reboot)" >&2
    fi
    echo "$b"
}

require_state() {
    local want="$1" cur; cur="$(state_of "$W/current.img")"
    [[ "$cur" == "$want" ]] || die "init_boot${SLOT} is $cur; this action needs $want${2:+ ($2)}"
    if [[ "$want" == STOCK ]] && kernel_ksu; then
        [[ "$(kscan_get ROOT)" == APatch ]] \
            && die "this slot's kernel (boot${SLOT}) is patched with APatch - it's rooted; use Remove root first"
        die "this slot's kernel (boot${SLOT}) already has $(kscan_get ROOT) built in (custom kernel) - it's rooted; not adding a second root"
    fi
}

# ---- actions ---------------------------------------------------------------

# root_name STATE -> the short name for the chip (empty when not rooted)
root_name() {
    case "$1" in
        MAGISK)   echo Magisk ;;
        KERNELSU) if kernel_ksu; then kscan_get ROOT; else lkm_family "$W/current.img"; fi ;;
        *)        echo "" ;;
    esac
}

do_status() {
    read_part "$W/current.img"
    local st; st="$(state_of "$W/current.img")"
    if [[ "$st" == STOCK ]] && kernel_ksu; then st=KERNELSU; fi
    root_name "$st" > "$W/root_name" 2>/dev/null || true
    echo "$st"
}

do_name() { do_status >/dev/null; cat "$W/root_name"; }

# Root: Show status - what is rooted, how, and with which kernel
do_info() {
    read_part "$W/current.img"
    local ib; ib="$(state_of "$W/current.img")"
    local kroot; kroot="$(kscan_get ROOT)"
    local susfs; susfs="$(kscan_get SUSFS)"
    local banner; banner="$(kscan_get BANNER)"
    say "Slot:      ${SLOT#_}"
    case "$ib" in
        KERNELSU) say "init_boot: $(lkm_family "$W/current.img") (LKM - kernelsu.ko loaded at boot)" ;;
        MAGISK)   say "init_boot: Magisk" ;;
        STOCK)    say "init_boot: stock" ;;
        *)        say "init_boot: $ib" ;;
    esac
    if [[ "$kroot" == APatch ]]; then
        say "Kernel:    APatch (KernelPatch patched into boot${SLOT})"
    elif [[ "$kroot" != none ]]; then
        say "Kernel:    $kroot built in$([[ "$susfs" == 1 ]] && echo " + SUSFS") (custom kernel in boot${SLOT})"
    else
        say "Kernel:    no root built in$([[ "$susfs" == 1 ]] && echo " (SUSFS patches present)")"
    fi
    say "Release:   ${banner:-unknown}"
    local st="$ib"; [[ "$st" == STOCK && "$kroot" != none ]] && st=KERNELSU
    local n; n="$(root_name "$st")"
    say "Root:      ${n:-not rooted}"
    if [[ "$ib" == KERNELSU && "$kroot" != none ]]; then
        say "! Two roots: a $kroot kernel AND $(lkm_family "$W/current.img") in init_boot."
        say "! Use Root: Remove root to take the init_boot one off (the kernel's stays)."
    fi
    echo "$st"
}

# kernel_label -> "WIDTH|Kernel 6.1.162 · Stock" for the main-page kernel chip
# (twrp-functions.cpp Update_Root_State). The slot's BOOT kernel (kernel_scan,
# cached), so it changes as soon as a kernel is flashed:
#   Stock   Google's build: 6.1.162-android14-11-g<sha>-ab<build id>
#   <Brand> a custom kernel that names itself: 6.1.162-Wild, ...-android14-...-Wild
#   Custom  anything else (own builds, -dirty, ...)
# plus " · SUSFS" when SUSFS is in it. WIDTH = chip image width: the text's
# width in IBM Plex Sans 33 (advances of ! .. ~ below, from the theme font)
# + 28 padding each side, rounded up to 16 - mkimages.py draws chip_kernel_240
# .. chip_kernel_784. Empty output when boot can't be read (no chip).
KW_CHARS='!"#$%&'"'"'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~'
KW_WIDTHS="9 14 24 20 31 23 8 11 11 15 20 9 13 9 13 20 20 20 20 20 20 20 20 20 20 10 10 20 20 20 16 29 21 22 20 22 19 18 23 23 13 17 21 17 27 23 23 20 23 21 19 19 22 20 29 20 20 19 10 13 10 20 19 20 18 19 17 19 18 11 17 19 8 8 17 9 29 19 18 19 19 12 16 12 19 16 25 17 16 15 11 10 11 20"
text_width() {   # ASCII only; space 8. The tables go in through the environment:
    # awk -v would process the backslash in KW_CHARS as an escape (toybox awk
    # drops it), shifting every later character's width by one
    KW_CHARS="$KW_CHARS" KW_WIDTHS="$KW_WIDTHS" awk -v s="$1" 'BEGIN {
        c = ENVIRON["KW_CHARS"]; w = ENVIRON["KW_WIDTHS"]
        split(w, a, " "); t = 0
        for (i = 1; i <= length(s); i++) { p = index(c, substr(s, i, 1)); t += p ? a[p] : 8 }
        print t }'
}
kernel_label() {
    local banner susfs root ver rest kind="" last
    banner="$(kscan_get BANNER)"; susfs="$(kscan_get SUSFS)"; root="$(kscan_get ROOT)"
    [[ -n "$banner" ]] || return 0
    ver="${banner%%-*}"; rest="${banner#"$ver"}"; rest="${rest#-}"
    if [[ "$banner" =~ -android[0-9]+-[0-9]+-g[0-9a-f]+-ab[0-9]+$ && ( "$root" == none || "$root" == APatch ) ]]; then
        kind=Stock                       # APatch patches Google's kernel; the root chip says APatch
    elif [[ -n "$rest" && "$rest" != android* ]]; then
        kind="${rest%%-*}"               # 6.1.162-Wild -> Wild
    else
        last="${banner##*-}"             # ...-android14-11-g<sha>-Wild -> Wild
        if [[ "$last" =~ ^[A-Za-z][A-Za-z0-9_+]*$ && ! "$last" =~ ^(dirty|ab[0-9]+|g[0-9a-f]+|android[0-9]+)$ ]]; then
            kind="$last"
        fi
    fi
    kind="$(printf '%s' "$kind" | tr -cd 'A-Za-z0-9_+.')"
    [[ -n "$kind" && ${#kind} -le 10 && "$kind" =~ [A-Za-z] ]] || kind=Custom
    local label="Kernel $ver · $kind" w
    w=$(( $(text_width "Kernel $ver$kind") + 26 ))       # " · " is 26 (both spaces)
    if [[ "$susfs" == 1 ]]; then label+=" · SUSFS"; w=$(( w + 26 + $(text_width SUSFS) )); fi
    w=$(( (w + 56 + 15) / 16 * 16 ))
    (( w >= 240 )) || w=240
    (( w <= 784 )) || w=784
    echo "$w|$label"
}

# A property of the RUNNING slot's installed system, read from its build.prop on a
# read-only mount - right whether or not /data is encrypted (the crypto script's
# live props only exist when it ran), and on a pending update's slot too (super
# is then mapped with snapshots).   installed_prop PROP -> value or "?"
installed_prop() {
    local m="$W/sysmnt" v=""
    mkdir -p "$m"
    if mount -t ext4 -o ro "/dev/block/mapper/system${RUN_SLOT}" "$m" 2>/dev/null; then
        v="$(grep -m1 "^$1=" "$m/system/build.prop" 2>/dev/null | cut -d= -f2 || true)"
        umount "$m" 2>/dev/null || true
    fi
    echo "${v:-?}"
}
do_android() { installed_prop ro.build.version.release; }   # main-page root chip
do_build()   { installed_prop ro.build.id; }                # build.sh --flash guard

# find_apk TOOL -> path of the newest app APK for TOOL in Download/ or the top
# level of Internal Storage that really is that app (carries MARKER), or nothing.
# KernelSU's own name pattern also matches KernelSU_Next*.apk - excluded.
find_apk() {
    local tool="$1" globs marker f k b bb="$W/tools/busybox"
    case "$tool" in
        ksu)    globs="KernelSU";                 marker='lib/arm64-v8a/libksud.so' ;;
        ksun)   globs="KernelSU_Next KernelSU-Next KSUN"; marker='lib/arm64-v8a/libksud.so' ;;
        suki)   globs="SukiSU";                   marker='lib/arm64-v8a/libksud.so' ;;
        magisk) globs="Magisk";                   marker='lib/arm64-v8a/libmagiskboot.so' ;;
        apatch) globs="APatch";                   marker='lib/arm64-v8a/libkptools.so' ;;
        *) return 0 ;;
    esac
    mkdir -p "$W/tools"
    [[ -x "$bb" ]] || { cp "$TOOLS/magisk/busybox" "$bb" && chmod 755 "$bb"; } || return 0
    local g list=""
    for g in $globs; do
        for f in /data/media/0/Download/"$g"*.apk /data/media/0/"$g"*.apk; do
            [[ -f "$f" ]] || continue
            b="${f##*/}"
            [[ "$tool" == ksu && "$b" =~ [Nn]ext|KSUN ]] && continue
            # sort key: ..._32601-release.apk -> 32601, APatch_11224_9a63e0f_... ->
            # 11224, Magisk-v30.7.apk -> 30007
            k="$(sed -n 's/^[^_]*_\([0-9][0-9]*\)[-._].*/\1/p' <<< "$b")"
            [[ -n "$k" ]] || k="$(sed -n 's/.*_\([0-9][0-9]*\)[-.].*/\1/p' <<< "$b")"
            [[ -n "$k" ]] || k="$(sed -n 's/.*v\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' <<< "$b" \
                                  | awk '{print $1*1000+$2}')"
            list+="${k:-0}:$f"$'\n'
        done
    done
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        # plain grep (not -q): with pipefail, grep -q's early exit can SIGPIPE unzip
        if "$bb" unzip -l "$f" 2>/dev/null | grep "$marker" >/dev/null; then echo "$f"; return 0; fi
    done <<< "$(sort -t: -k1,1nr <<< "$list" | cut -d: -f2-)"   # no < <(...): recovery has no /dev/fd
}

# ksud_for TOOL -> the ksud to patch with: bundled for KernelSU, the app's own
# (lib/arm64-v8a/libksud.so) for KernelSU-Next / SukiSU - their kernelsu.ko and
# ksud must match their app.
ksud_for() {
    case "$1" in
        ksu) echo "$KSUD" ;;
        ksun|suki)
            local apk; apk="$(find_apk "$1")"
            [[ -n "$apk" ]] || return 1
            local out="$W/tools/ksud-$1"
            "$W/tools/busybox" unzip -p "$apk" lib/arm64-v8a/libksud.so > "$out" 2>/dev/null && [[ -s "$out" ]] \
                || return 1
            chmod 755 "$out"
            echo "$out" ;;
        *) return 1 ;;
    esac
}

tool_name() { case "$1" in ksu) echo KernelSU ;; ksun) echo KernelSU-Next ;; suki) echo SukiSU ;; magisk) echo Magisk ;; apatch) echo APatch ;; esac; }

# official app downloads (GitHub releases), for the "put the APK in Download" messages
tool_url() {
    case "$1" in
        ksu)    echo "github.com/tiann/KernelSU/releases" ;;
        ksun)   echo "github.com/KernelSU-Next/KernelSU-Next/releases" ;;
        suki)   echo "github.com/SukiSU-Ultra/SukiSU-Ultra/releases" ;;
        magisk) echo "github.com/topjohnwu/Magisk/releases" ;;
        apatch) echo "github.com/bmax121/APatch/releases" ;;
    esac
}
tool_glob() { case "$1" in ksu) echo KernelSU ;; ksun) echo KernelSU_Next ;; suki) echo SukiSU ;; magisk) echo Magisk ;; apatch) echo APatch ;; esac; }

# apk_missing TOOL WHAT -> stop: this root is installed with tools from its own
# app (no room in the recovery ramdisk to bundle every patcher), and its APK
# isn't in Download/. Nothing has been changed when this runs.
apk_missing() {
    local name; name="$(tool_name "$1")"
    say ""
    say "! $name needs its app's APK: TWRP patches with the $2"
    say "! inside it, so the root always matches your app version."
    say "!"
    say "!   1. Download the $name APK from"
    say "!      $(tool_url "$1")"
    say "!   2. Put it in /sdcard/Download  (Internal storage > Download)"
    say "!      keep the downloaded name: $(tool_glob "$1")*.apk"
    say "!   3. Run Advanced > ROOT > Install $name again"
    say ""
    die "No APK found. Nothing was changed."
}

do_install_ksu_family() {
    local tool="$1" name; name="$(tool_name "$tool")"
    # "Reinstall root after OTA" when the running slot's root is a custom kernel
    # (KernelSU / KernelSU-Next built in, e.g. Sultan + SUSFS): our KernelSU LKM
    # would be a different root on the new slot, without that kernel. Its owner
    # reflashes the kernel instead - say so, change nothing.
    # TW_ROOT_EXPLICIT=1: the user picked this tool for the updated slot
    # (Root after an OTA) - install it even so.
    if [[ "$SLOT" != "$RUN_SLOT" && "${TW_ROOT_EXPLICIT:-0}" != 1 ]] && kernel_ksu "$RUN_SLOT"; then
        say "- This slot is rooted by its kernel ($(kscan_get ROOT "$RUN_SLOT") built into boot${RUN_SLOT}),"
        say "  so TWRP doesn't install another root on the updated slot."
        say "  For root there: flash your custom kernel again after the update."
        exit 0
    fi
    read_part "$W/current.img"
    require_state STOCK "use Remove root first"
    # The KernelSU module only loads into a kernel with a matching KMI. Check
    # before touching anything, instead of failing inside boot-patch (or
    # worse, producing an image whose kernelsu.ko never loads).
    local ksud
    ksud="$(ksud_for "$tool")" || apk_missing "$tool" "ksud"
    [[ "$tool" == ksu ]] || say "- Patcher: ksud from ${name}'s app ($(find_apk "$tool" | sed 's#/data/media/0/##'))"
    local k; k="$(kmi)"
    local kmis; kmis="$("$ksud" boot-info supported-kmis 2>/dev/null)"
    [[ -n "$kmis" ]] || die "$name's ksud reports no supported KMIs - wrong or broken file. Nothing was changed."
    if ! grep -qx "$k" <<< "$kmis"; then
        say "! The kernel on slot ${SLOT#_} has KMI $k"
        say "! This $name supports: $(tr '\n' ' ' <<< "$kmis")"
        die "$name can't root this kernel. Try another root, or a newer $name. Nothing was changed."
    fi
    say "- Kernel KMI $k is supported by $name"
    local backup; backup="$(backup_current)"
    say "- Patching with $name (KMI $k)"
    rm -f "$W/ksu_patched.img"
    "$ksud" boot-patch -b "$W/current.img" --kmi "$k" -o "$W" --out-name ksu_patched.img >/dev/null \
        || die "$name's ksud boot-patch failed"
    flash_verified "$W/ksu_patched.img" KERNELSU "$backup"
    KSUD_APP="$ksud" app_setup "$tool"
}

do_install_ksu() { do_install_ksu_family ksu; }

# After Install KernelSU / Install Magisk, on a phone where that root tool's
# app isn't installed yet, put in place what the app or Magisk's zip installer
# normally provides, so the app gets installed at the next boot by a one-shot
# module. Never fatal: root is already installed and verified at this point.
#   app_setup ksu|magisk      (FORCE_APP_SETUP=1: stage even if installed - testing)
app_setup() {
    local tool="$1" pkg name glob marker fallback=""
    case "$tool" in
        ksu)    pkg=me.weishu.kernelsu;   name=KernelSU; glob=KernelSU; marker='lib/arm64-v8a/libksud.so' ;;
        ksun)   pkg=com.rifsxd.ksunext;   name=KernelSU-Next; glob=KernelSU_Next; marker='lib/arm64-v8a/libksud.so' ;;
        suki)   pkg=com.sukisu.ultra;     name=SukiSU;   glob=SukiSU;   marker='lib/arm64-v8a/libksud.so' ;;
        magisk) pkg=com.topjohnwu.magisk; name=Magisk;   glob=Magisk;   marker='lib/arm64-v8a/libmagiskboot.so'
                fallback="$TOOLS/magisk/stub.apk" ;;
        apatch) pkg=me.bmax.apatch;       name=APatch;   glob=APatch;   marker='lib/arm64-v8a/libkptools.so' ;;
        *) die "app_setup: unknown tool '$tool'" ;;
    esac
    if [[ ! -f /data/system/packages.xml ]]; then
        say "- /data isn't decrypted: install the $name app yourself after booting"
        return 0
    fi
    # KernelSU family: kernelsu.ko runs /data/adb/ksud at boot (modules,
    # post-fs-data...). It must be the ksud that patched init_boot - that tool's
    # own (KSUD_APP for KernelSU-Next / SukiSU) - also when switching from another
    # KernelSU-family root, whose ksud would otherwise stay (kept as ksud.bak).
    # -f, not -x: /data is mounted noexec in recovery.
    if [[ "$tool" =~ ^(ksu|ksun|suki)$ ]]; then
        local want="${KSUD_APP:-$KSUD}"
        if [[ -f /data/adb/ksud ]] && cmp -s "$want" /data/adb/ksud; then
            :
        elif { [[ ! -f /data/adb/ksud ]] || cp -p /data/adb/ksud /data/adb/ksud.bak; } \
                && mkdir -p /data/adb && cp "$want" /data/adb/ksud && chown 0:0 /data/adb/ksud \
                && chmod 0755 /data/adb/ksud && chcon u:object_r:ksu_file:s0 /data/adb/ksud; then
            say "- Placed ${name}'s ksud in /data/adb$([[ -f /data/adb/ksud.bak ]] && echo " (previous one: ksud.bak)")"
        else
            say "! Could not place /data/adb/ksud - open the $name app after booting to finish"
        fi
    fi
    if [[ "${FORCE_APP_SETUP:-}" != 1 ]]; then
        if grep -a -q "$pkg" /data/system/packages.xml; then
            say "- $name app already installed"; return 0
        fi
        # Magisk's app may be hidden under a random package name; its database
        # existing means Magisk was set up with an app before
        if [[ "$tool" == magisk && -f /data/adb/magisk.db ]]; then
            say "- Magisk was set up before (its app may be hidden) - not installing another"; return 0
        fi
    fi
    # The app comes from internal storage (too big to bundle: the bootloader
    # can't load a larger recovery ramdisk): the highest version of
    # <Name>*.apk in Download/ or the top level, accepted only if it carries
    # the tool's own library. busybox runs from an executable copy named
    # busybox (the image copy isn't +x; busybox picks its applet by its name).
    local apk; apk="$(find_apk "$tool")"
    if [[ -n "$apk" ]]; then
        say "- $name app: ${apk#/data/media/0/}"
    elif [[ -n "$fallback" && -f "$fallback" ]]; then
        apk="$fallback"
        say "- $name app: the bundled stub (it downloads the full app when first opened)"
    else
        say "- Root is installed. The $name app isn't, and no APK was found:"
        say "  get it from $(tool_url "$tool")"
        say "  and install it in Android - or put it in /sdcard/Download and run"
        say "  Install $name again to have it installed at the next boot."
        return 0
    fi
    # What the app (KernelSU) or Magisk's zip installer (Magisk) normally puts
    # in /data/adb, so the root tool can run modules - including ours - at boot.
    # -f/-d, not -x: /data is mounted noexec in recovery, so bash's [[ -x ]]
    # (kernel access()) is false even for real executables there.
    if [[ "$tool" == magisk && ! -d /data/adb/magisk ]]; then
        if mkdir -p /data/adb/magisk && cp -a "$TOOLS/magisk/." /data/adb/magisk/ \
                && chown -R 0:0 /data/adb/magisk && chmod 0755 /data/adb/magisk \
                && chmod 0755 /data/adb/magisk/* && chcon -R u:object_r:adb_data_file:s0 /data/adb/magisk; then
            say "- Set up /data/adb/magisk (as Magisk's own installer does)"
        else
            rm -rf /data/adb/magisk
            say "! Could not set up /data/adb/magisk - install the Magisk app yourself after booting"
            return 0
        fi
    fi
    # one-shot module: installs that app at the next boot, then removes itself
    local m="/data/adb/modules/twrp_${tool}_app"
    rm -rf "$m"
    if mkdir -p "$m" && cp "$apk" "$m/app.apk" && echo "$pkg" > "$m/package" \
            && cp "$TOOLS/app-install-service.sh" "$m/service.sh" \
            && printf '%s\n' "id=twrp_${tool}_app" "name=$name app installer (TWRP)" version=1 \
                versionCode=1 "author=shiba TWRP" \
                "description=Installs the $name app at the next boot, then removes itself" > "$m/module.prop" \
            && chown 0:0 /data/adb/modules && chown -R 0:0 "$m" && chmod 0755 /data/adb/modules "$m" "$m/service.sh" \
            && chmod 0644 "$m/app.apk" "$m/package" "$m/module.prop" \
            && chcon u:object_r:adb_data_file:s0 /data/adb/modules && chcon -R u:object_r:adb_data_file:s0 "$m"; then
        say "- The $name app will be installed automatically at the next boot"
        # test switch: reinstall over an installed app (pm install -r keeps its data)
        [[ "${FORCE_APP_SETUP:-}" == 1 ]] && touch "$m/force" && chcon u:object_r:adb_data_file:s0 "$m/force" \
            && say "- (forced: an installed app is reinstalled in place)"
        return 0
    else
        rm -rf "$m"
        say "! Could not stage the $name app - install it yourself after booting"
    fi
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
    app_setup magisk
}

# ---- APatch (KernelPatch in the boot kernel) ------------------------------
# APatch roots the kernel itself: kptools injects kpimg (KernelPatch) into the
# kernel Image in boot, which then finds kernel functions through kallsyms. So
# it needs CONFIG_KALLSYMS, not a matching KMI, and lives in BOOT - init_boot
# stays stock. magiskboot unpacks/repacks the boot image (it decompresses the
# kernel), kptools only patches the raw kernel.
BOOTPART="/dev/block/by-name/boot${SLOT}"
KEYFILE="$W/apatch_key"

# apatch_tools -> KPTOOLS and KPIMG from the newest APatch APK, or return 1
apatch_tools() {
    local apk; apk="$(find_apk apatch)"
    [[ -n "$apk" ]] || return 1
    KPTOOLS="$W/tools/kptools"; KPIMG="$W/tools/kpimg"
    "$W/tools/busybox" unzip -p "$apk" lib/arm64-v8a/libkptools.so > "$KPTOOLS" 2>/dev/null && [[ -s "$KPTOOLS" ]] \
        && "$W/tools/busybox" unzip -p "$apk" assets/kpimg > "$KPIMG" 2>/dev/null && [[ -s "$KPIMG" ]] \
        || return 1
    chmod 755 "$KPTOOLS"
    APATCH_APK="$apk"
}

# boot_kernel_dir IMG DIR -> DIR holds magiskboot's unpack of IMG (DIR/kernel)
boot_kernel_dir() {
    rm -rf "$2"; mkdir -p "$2"
    ( cd "$2" && "$MAGISKBOOT" unpack "$1" >/dev/null 2>&1 ) && [[ -f "$2/kernel" ]]
}

# key_ok KEY -> APatch's own rule (PatchesViewModel): 8-63 chars, a letter and a
# digit. The TWRP page only allows letters and digits.
key_ok() { [[ "$1" =~ ^[A-Za-z0-9]{8,63}$ && "$1" =~ [A-Za-z] && "$1" =~ [0-9] ]]; }

backup_boot() {
    local b="$W/boot${SLOT}.backup.$(date +%Y%m%d-%H%M%S).img"
    dd if="$BOOTPART" of="$b" bs=1M 2>/dev/null || die "cannot read boot${SLOT}"
    local keep=/data/media/0/TWRP/boot_backups
    if [[ -d /data/media/0 ]] && mkdir -p "$keep" && cp "$b" "$keep/" 2>/dev/null; then
        chown -R 0:1023 /data/media/0/TWRP 2>/dev/null; chmod 660 "$keep/${b##*/}" 2>/dev/null
        say "- Backed up boot${SLOT} to Internal Storage: TWRP/boot_backups/${b##*/}" >&2
    else
        say "- Backed up boot${SLOT} to $b (Internal Storage not available - lost at reboot)" >&2
    fi
    echo "$b"
}

# flash_boot_verified IMG BACKUP WANT(patched|stock)
flash_boot_verified() {
    local img="$1" backup="$2" want="$3" d="$W/apcheck"
    boot_kernel_dir "$img" "$d" || die "new boot image doesn't unpack - not flashing"
    if grep -a -q 'KP1158' "$d/kernel"; then
        [[ "$want" == patched ]] || die "new boot image still has APatch - not flashing"
    else
        [[ "$want" == stock ]] || die "new boot image has no APatch - not flashing"
    fi
    rm -rf "$d"
    say "- Flashing boot${SLOT}"
    dd if="$img" of="$BOOTPART" bs=1M conv=fsync 2>/dev/null || die "write failed"
    local n; n="$(stat -c %s "$img")"
    dd if="$BOOTPART" of="$W/readback.img" bs=1M 2>/dev/null
    if ! cmp -s -n "$n" "$img" "$W/readback.img"; then
        say "! Readback mismatch - restoring backup"
        dd if="$backup" of="$BOOTPART" bs=1M conv=fsync 2>/dev/null
        die "flash verification failed; original boot restored"
    fi
    rm -f "$W/readback.img" "$W"/kernel_scan"${SLOT}".*
    say "- Verified: boot${SLOT} is now $([[ "$want" == patched ]] && echo "patched with APatch" || echo "without APatch")"
}

do_install_apatch() {
    [[ -b "$BOOTPART" ]] || die "cannot find boot${SLOT}"
    local key=""
    if [[ -f "$KEYFILE" ]]; then key="$(cat "$KEYFILE")"; rm -f "$KEYFILE"; fi
    read_part "$W/current.img"
    require_state STOCK "use Remove root first - APatch replaces it"
    apatch_tools || apk_missing apatch "kptools and kpimg"
    say "- Patcher: kptools + kpimg from APatch's app (${APATCH_APK#/data/media/0/})"
    # Reinstall after an OTA (other slot): the running kernel carries the key
    if [[ -z "$key" && "$SLOT" != "$RUN_SLOT" ]]; then
        local rd="$W/aprun"
        dd if="/dev/block/by-name/boot${RUN_SLOT}" of="$W/aprun.img" bs=1M 2>/dev/null \
            && boot_kernel_dir "$W/aprun.img" "$rd" \
            && key="$("$KPTOOLS" -i "$rd/kernel" -l 2>/dev/null | sed -n 's/^superkey=//p' | head -1)"
        rm -rf "$rd" "$W/aprun.img"
        [[ -n "$key" ]] || die "can't read the SuperKey from slot ${RUN_SLOT#_}'s kernel - use Advanced > ROOT > Install APatch after the first boot. Nothing was changed."
        say "- SuperKey: the same as slot ${RUN_SLOT#_}"
    fi
    [[ -n "$key" ]] || die "no SuperKey - start from Advanced > ROOT > Install APatch. Nothing was changed."
    key_ok "$key" || die "the SuperKey needs 8-63 letters and digits, with at least one of each. Nothing was changed."
    local d="$W/ap"
    rm -rf "$d"; mkdir -p "$d"
    dd if="$BOOTPART" of="$d/boot.img" bs=1M 2>/dev/null || die "cannot read boot${SLOT}"
    ( cd "$d" && "$MAGISKBOOT" unpack boot.img >/dev/null 2>&1 ) && [[ -f "$d/kernel" ]] \
        || die "cannot unpack boot${SLOT}. Nothing was changed."
    # plain grep (not -q) into /dev/null: with pipefail, -q's early exit can SIGPIPE kptools
    if ! "$KPTOOLS" -i "$d/kernel" -f 2>/dev/null | grep 'CONFIG_KALLSYMS=y' >/dev/null; then
        die "this kernel has no CONFIG_KALLSYMS - APatch can't patch it. Nothing was changed."
    fi
    "$KPTOOLS" -i "$d/kernel" -f 2>/dev/null | grep 'CONFIG_KALLSYMS_ALL=y' >/dev/null \
        || say "! CONFIG_KALLSYMS_ALL is off - APatch may not boot (the backup restores it)"
    local backup; backup="$(backup_boot)"
    say "- Patching the kernel with APatch (KernelPatch)"
    mv "$d/kernel" "$d/kernel.ori"
    "$KPTOOLS" -p -i "$d/kernel.ori" -S "$key" -k "$KPIMG" -o "$d/kernel" > "$d/kptools.log" 2>&1 \
        || { sed 's/^/   /' "$d/kptools.log" | grep -v -i superkey | tail -5; die "kptools patch failed. Nothing was changed."; }
    key=""
    ( cd "$d" && "$MAGISKBOOT" repack boot.img new-boot.img >/dev/null 2>&1 ) || die "repack failed. Nothing was changed."
    flash_boot_verified "$d/new-boot.img" "$backup" patched
    rm -rf "$d"
    apatch_android_setup
    # root is installed and verified at this point: the app step only warns
    ( app_setup apatch ) || say "! Could not stage the APatch app - install it from Download/ after booting"
    say "- Keep your SuperKey written down: the APatch app doesn't show it."
}

# apatch_android_setup - what the APatch app's "Install (AndroidPatch)" does
# (APatchApp.installApatch): apd and its tools from the APK into /data/adb.
# KernelPatch starts /data/adb/apd at boot by itself (verified on shiba: no app
# step needed), and apd then runs modules - including our app installer.
# Never fatal: the kernel root is already installed and verified.
apatch_android_setup() {
    if [[ ! -f /data/system/packages.xml ]]; then
        say "- /data isn't decrypted: open the APatch app after booting and tap Install"
        return 0
    fi
    local bb="$W/tools/busybox" ap=/data/adb/ap
    local ver; ver="$(sed -n 's/^[^_]*_\([0-9][0-9]*\)[-._].*/\1/p' <<< "${APATCH_APK##*/}")"
    if mkdir -p "$ap/bin" "$ap/log" \
            && "$bb" unzip -p "$APATCH_APK" lib/arm64-v8a/libapd.so > /data/adb/apd.new && [[ -s /data/adb/apd.new ]] \
            && mv -f /data/adb/apd.new /data/adb/apd && chmod 0755 /data/adb/apd \
            && ln -sf /data/adb/apd "$ap/bin/apd" && ln -sf /data/adb/apd "$ap/bin/magiskpolicy" \
            && ln -sf /data/adb/apd "$ap/bin/resetprop" \
            && "$bb" unzip -p "$APATCH_APK" lib/arm64-v8a/libbusybox.so > "$ap/bin/busybox" && chmod 0755 "$ap/bin/busybox" \
            && cp "$KPTOOLS" "$ap/bin/kptools" && chmod 0755 "$ap/bin/kptools" \
            && touch "$ap/package_config" "$ap/su_path" \
            && { [[ -s "$ap/su_path" ]] || echo /system/bin/su > "$ap/su_path"; } \
            && { [[ -z "$ver" ]] || echo "$ver" > "$ap/version"; } \
            && chown -R 0:0 /data/adb/apd "$ap" \
            && chcon u:object_r:adb_data_file:s0 /data/adb/apd && chcon -R u:object_r:adb_data_file:s0 "$ap"; then
        say "- Set up AndroidPatch (apd) in /data/adb, as the APatch app's Install does"
    else
        rm -f /data/adb/apd.new
        say "! Could not set up apd - open the APatch app after booting and tap Install (AndroidPatch)"
    fi
}

do_remove_apatch() {
    [[ -b "$BOOTPART" ]] || die "cannot find boot${SLOT}"
    if ! apatch_tools; then
        say "! Removing APatch needs kptools from the APatch APK in Download/."
        say "! Or restore your boot backup: TWRP/boot_backups/ (Install > Install Image > boot)."
        die "Nothing was changed."
    fi
    local d="$W/ap"
    rm -rf "$d"; mkdir -p "$d"
    dd if="$BOOTPART" of="$d/boot.img" bs=1M 2>/dev/null || die "cannot read boot${SLOT}"
    ( cd "$d" && "$MAGISKBOOT" unpack boot.img >/dev/null 2>&1 ) && [[ -f "$d/kernel" ]] \
        || die "cannot unpack boot${SLOT}. Nothing was changed."
    local backup; backup="$(backup_boot)"
    say "- Removing APatch"
    mv "$d/kernel" "$d/kernel.ori"
    "$KPTOOLS" -u -i "$d/kernel.ori" -o "$d/kernel" >/dev/null 2>&1 || die "kptools unpatch failed. Nothing was changed."
    ( cd "$d" && "$MAGISKBOOT" repack boot.img new-boot.img >/dev/null 2>&1 ) || die "repack failed. Nothing was changed."
    flash_boot_verified "$d/new-boot.img" "$backup" stock
    rm -rf "$d"
    say "- Done. Uninstall the APatch app in Android if you don't need it."
}

do_remove() {
    read_part "$W/current.img"
    local cur; cur="$(state_of "$W/current.img")"
    local backup restored="$W/restored.img" app=""
    case "$cur" in
        KERNELSU)
            backup="$(backup_current)"
            app="$(lkm_family "$W/current.img")"   # KernelSU | KSU-Next | SukiSU
            say "- Removing $app"
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
            app=Magisk
            say "- Removing Magisk"
            local d="$W/mrestore"; rm -rf "$d"; mkdir -p "$d"
            ( cd "$d" && "$MAGISKBOOT" unpack "$W/current.img" >/dev/null 2>&1 \
                && "$MAGISKBOOT" cpio ramdisk.cpio restore >/dev/null 2>&1 \
                && "$MAGISKBOOT" repack "$W/current.img" "$restored" >/dev/null 2>&1 ) \
                || die "Magisk ramdisk restore failed"
            ;;
        STOCK)
            if [[ "$(kscan_get ROOT)" == APatch ]]; then do_remove_apatch; return 0; fi
            kernel_ksu && die "$(kscan_get ROOT) is built into this slot's kernel (boot${SLOT}, custom kernel), not init_boot - to remove it, flash the stock boot image for your build (TWRP: Install > Install Image > boot)"
            die "init_boot${SLOT} is already stock - nothing to remove" ;;
        *)     die "init_boot${SLOT} state is $cur - refusing to guess" ;;
    esac
    flash_verified "$restored" STOCK "$backup"
    say "- Done. Uninstall the $app app in Android if you don't need it."
}

# reroot-action -> which install-* recreates the RUNNING slot's root on the
# other slot after an OTA (twinstall.cpp, "Reinstall root after OTA"), or none
# ---- Custom kernel (Root after an OTA > Custom kernel) ---------------------
# flash-kernel [other] IMG: a whole boot image - a custom kernel, e.g. a GKI
# kernel with KernelSU-Next built in - onto this slot's boot. Checks first: it
# fits the partition, unpacks to a kernel with the same KMI as the kernel it
# replaces (the slot's vendor modules must load), and its built-in root
# doesn't stack on a root in init_boot. Then backup, readback verify, restore.
do_flash_kernel() {
    local img="${2:-}"; [[ "$img" == other ]] && img="${3:-}"
    [[ -n "$img" && -f "$img" ]] || die "usage: $0 flash-kernel [other] BOOT_IMAGE - no file '$img'. Nothing was changed."
    [[ -b "$BOOTPART" ]] || die "cannot find boot${SLOT}"
    local n psize; n="$(stat -c %s "$img")"; psize="$(blockdev --getsize64 "$BOOTPART")"
    (( n <= psize )) || die "${img##*/} is $n bytes, boot${SLOT} only $psize. Nothing was changed."
    local d="$W/newk"
    boot_kernel_dir "$img" "$d" || die "${img##*/} isn't a boot image with a kernel. Nothing was changed."
    local banner root; banner="$(kernel_banner_of "$d/kernel")"; root="$(kernel_root_of "$d/kernel")"
    rm -rf "$d"
    [[ -n "$banner" ]] || die "can't read the kernel version in ${img##*/}. Nothing was changed."
    local newk oldk; newk="$(kmi_of "$banner")"; oldk="$(kmi)"
    [[ "$newk" == "$oldk" ]] \
        || die "${img##*/} has a $newk kernel, slot ${SLOT#_} needs $oldk (its vendor modules wouldn't load). Nothing was changed."
    say "- Kernel: $banner (KMI $newk$([[ "$root" != none ]] && echo ", $root built in"))"
    say "- Replaces: $(kscan_get BANNER)"
    if [[ "$root" != none ]]; then
        read_part "$W/current.img"
        local st; st="$(state_of "$W/current.img")"
        [[ "$st" == STOCK ]] \
            || die "init_boot${SLOT} has $st root and this kernel has $root built in - two roots. Remove root first. Nothing was changed."
    fi
    [[ "${TW_DRY_RUN:-0}" == 1 ]] && { say "- Dry run: checks passed, nothing flashed"; return 0; }
    local backup; backup="$(backup_boot)"
    say "- Flashing boot${SLOT}"
    dd if="$img" of="$BOOTPART" bs=1M conv=fsync 2>/dev/null || die "write failed"
    dd if="$BOOTPART" of="$W/readback.img" bs=1M 2>/dev/null
    if ! cmp -s -n "$n" "$img" "$W/readback.img"; then
        say "! Readback mismatch - restoring backup"
        dd if="$backup" of="$BOOTPART" bs=1M conv=fsync 2>/dev/null
        die "flash verification failed; original boot restored"
    fi
    rm -f "$W/readback.img" "$W"/kernel_scan"${SLOT}".*
    say "- Verified: boot${SLOT} is now ${img##*/}"
}

do_reroot_action() {
    local st; st="$(do_status)"
    case "$st" in
        MAGISK)   echo install-magisk ;;
        KERNELSU) case "$(cat "$W/root_name" 2>/dev/null)" in
                      KSU-Next) echo install-ksun ;;
                      SukiSU)   echo install-suki ;;
                      APatch)   echo install-apatch ;;
                      *)        echo install-ksu ;;   # kernel root: install-* explains, changes nothing
                  esac ;;
        *)        echo none ;;
    esac
}

case "${1:-}" in
    status)         do_status ;;
    name)           do_name ;;      # short root name for the chip (empty = not rooted)
    info)           do_info ;;      # Root: Show status
    reroot-action)  do_reroot_action ;;
    android)        do_android ;;   # read-only: Android version of the running slot
    kernel)         kernel_label ;; # read-only: main-page kernel chip (WIDTH|label)
    build)          do_build ;;     # read-only: build ID of the running slot
    stage-app)      app_setup "${2:-}" ;;   # the app-install part of install-ksu/-magisk alone (testing)
    kmi)            kmi ;;          # read-only: KMI of the (other) slot's kernel
    detect)         [[ -f "${2:-}" ]] || die "usage: $0 detect IMAGE"; state_of "$(realpath "$2")" ;;
    install-ksu)    do_install_ksu ;;
    install-ksun)   do_install_ksu_family ksun ;;
    install-suki)   do_install_ksu_family suki ;;
    install-magisk) do_install_magisk ;;
    install-apatch) do_install_apatch ;;
    flash-kernel)   do_flash_kernel "$@" ;;
    remove)         do_remove ;;
    *) echo "usage: $0 status|name|info|install-ksu|install-ksun|install-suki|install-magisk|install-apatch|flash-kernel|remove" >&2; exit 2 ;;
esac
