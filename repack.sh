#!/usr/bin/env bash
# Graft our TWRP recovery ramdisk into any shiba vendor_boot image.
#
#   repack.sh [SRC_VENDOR_BOOT] [OUT]
#
#   SRC_VENDOR_BOOT  a vendor_boot.img from a factory image, or dumped from the
#                    phone (stock, OrangeFox, or an older build of ours).
#                    Default: $STOCK_DIR/factory/vendor_boot.img
#   OUT              Default: $STOCK_DIR/twrp_vendor_boot.img
#
# Everything version-specific comes from SRC, nothing is hard-coded:
#   * header version, page size, base/offsets, vendor cmdline, board name and
#     vendor bootconfig are copied verbatim (unpack_bootimg --format=mkbootimg)
#   * the platform fragment (type 1) is reused: if it also carries a merged
#     stock recovery (factory layout), only first_stage_ramdisk/ is kept,
#     otherwise (already split, e.g. OrangeFox or ours) its bytes are kept
#   * every other non-recovery fragment is passed through untouched, in order
#     (e.g. Android 16's type-0 "16K" fragment for 16 KB page-size boot)
#   * any existing recovery fragment (type 2) is dropped and ours appended
# Afterwards the result is unpacked and checked against SRC.
set -euo pipefail

DEVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$DEVICE_DIR/../../.." && pwd)"
STOCK_DIR="${STOCK_DIR:-$HOME/shiba-stock}"

SRC="$(realpath "${1:-$STOCK_DIR/factory/vendor_boot.img}")"
OUT="$(realpath -m "${2:-$STOCK_DIR/twrp_vendor_boot.img}")"

MKBOOTIMG="$TOP/system/tools/mkbootimg/mkbootimg.py"
UNPACK="$TOP/system/tools/mkbootimg/unpack_bootimg.py"
RECOVERY_FRAG="$TOP/out/target/product/shiba/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4"
PARTITION_SIZE=67108864   # vendor_boot_a/_b on shiba

for f in "$SRC" "$MKBOOTIMG" "$UNPACK" "$RECOVERY_FRAG"; do
    [[ -f "$f" ]] || { echo "MISSING: $f" >&2; exit 1; }
done
for t in lz4 cpio python3; do
    command -v "$t" >/dev/null || { echo "MISSING tool: $t" >&2; exit 1; }
done

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# Split unpack_bootimg's NUL-separated mkbootimg args into global args and
# per-fragment (type, name, path).
parse_args() {  # $1 = args file; sets GLOBAL[], FTYPE[], FNAME[], FPATH[]
    local -a A
    mapfile -d '' -t A < "$1"
    GLOBAL=(); FTYPE=(); FNAME=(); FPATH=()
    local i=0 ctype="" cname=""
    while (( i < ${#A[@]} )); do
        case "${A[i]}" in
            --ramdisk_type)  ctype="${A[i+1]}"; i=$((i+2)) ;;
            --ramdisk_name)  cname="${A[i+1]}"; i=$((i+2)) ;;
            --board_id*)     i=$((i+2)) ;;   # none on Pixel; dropped
            --vendor_ramdisk_fragment)
                FTYPE+=("$ctype"); FNAME+=("$cname"); FPATH+=("${A[i+1]}")
                ctype=""; cname=""; i=$((i+2)) ;;
            --vendor_ramdisk)
                echo "SRC is not a header v4 fragment image" >&2; exit 1 ;;
            *) GLOBAL+=("${A[i]}"); i=$((i+1)) ;;
        esac
    done
}

echo "source: $SRC"
python3 "$UNPACK" --boot_img "$SRC" --out "$W/src" --format=mkbootimg -0 > "$W/src.args"
parse_args "$W/src.args"
SRC_GLOBAL=("${GLOBAL[@]}")

# Exactly one platform fragment expected.
PLAT=""
for k in "${!FTYPE[@]}"; do
    echo "  fragment $k: type=${FTYPE[k]} name='${FNAME[k]}' size=$(stat -c %s "${FPATH[k]}")"
    if [[ "${FTYPE[k]}" == "1" ]]; then
        [[ -z "$PLAT" ]] || { echo "more than one platform fragment" >&2; exit 1; }
        PLAT="${FPATH[k]}"
    fi
done
[[ -n "$PLAT" ]] || { echo "no platform fragment in SRC" >&2; exit 1; }

# Does the platform fragment carry anything besides first_stage_ramdisk/?
lz4 -dc "$PLAT" | cpio -t 2>/dev/null > "$W/plat.list"
if grep -qvE '^(\.|first_stage_ramdisk(/.*)?)$' "$W/plat.list"; then
    echo "  platform fragment has merged stock recovery -> keeping first_stage_ramdisk/ only"
    mkdir "$W/plat"
    lz4 -dc "$PLAT" | (cd "$W/plat" && cpio -idm --quiet 2>/dev/null)
    [[ -d "$W/plat/first_stage_ramdisk" ]] || { echo "no first_stage_ramdisk in platform fragment" >&2; exit 1; }
    (cd "$W/plat" && find first_stage_ramdisk | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet) \
        | lz4 -l -12 --favor-decSpeed > "$W/platform.lz4"
else
    echo "  platform fragment is already first_stage only -> reusing its bytes"
    cp "$PLAT" "$W/platform.lz4"
fi

# --vendor_boot must come BEFORE the fragments: mkbootimg groups every arg
# after a --vendor_ramdisk_fragment into that fragment.
# Keep source order; drop type-2 (recovery) fragments; ours goes last.
FRAG_ARGS=(); EXP_TYPE=(); EXP_NAME=(); EXP_FILE=()
for k in "${!FTYPE[@]}"; do
    case "${FTYPE[k]}" in
        2) echo "  dropping existing recovery fragment '${FNAME[k]}'"; continue ;;
        1) file="$W/platform.lz4" ;;
        *) file="${FPATH[k]}"; echo "  passing through fragment $k (type=${FTYPE[k]} name='${FNAME[k]}')" ;;
    esac
    FRAG_ARGS+=(--ramdisk_type "${FTYPE[k]}" --ramdisk_name "${FNAME[k]}" --vendor_ramdisk_fragment "$file")
    EXP_TYPE+=("${FTYPE[k]}"); EXP_NAME+=("${FNAME[k]}"); EXP_FILE+=("$file")
done
FRAG_ARGS+=(--ramdisk_type 2 --ramdisk_name recovery --vendor_ramdisk_fragment "$RECOVERY_FRAG")
EXP_TYPE+=(2); EXP_NAME+=(recovery); EXP_FILE+=("$RECOVERY_FRAG")

rm -f "$OUT"
python3 "$MKBOOTIMG" --vendor_boot "$OUT" "${SRC_GLOBAL[@]}" "${FRAG_ARGS[@]}"

# ---- verify -------------------------------------------------------------
python3 "$UNPACK" --boot_img "$OUT" --out "$W/out" --format=mkbootimg -0 > "$W/out.args"
parse_args "$W/out.args"

(( ${#FTYPE[@]} == ${#EXP_TYPE[@]} ))              || { echo "VERIFY: expected ${#EXP_TYPE[@]} fragments, got ${#FTYPE[@]}" >&2; exit 1; }
for k in "${!EXP_TYPE[@]}"; do
    [[ "${FTYPE[k]}" == "${EXP_TYPE[k]}" && "${FNAME[k]}" == "${EXP_NAME[k]}" ]] \
                                                   || { echo "VERIFY: fragment $k type/name mismatch" >&2; exit 1; }
    cmp -s "${EXP_FILE[k]}" "${FPATH[k]}"           || { echo "VERIFY: fragment $k bytes differ" >&2; exit 1; }
done
echo "  output fragments: $(for k in "${!FTYPE[@]}"; do printf '[%s type=%s] ' "${FNAME[k]:-platform}" "${FTYPE[k]}"; done)"

# Global args must match SRC, except the bootconfig path (compare contents).
strip_bc() { local -a in=("$@") o=(); local j=0
    while (( j < ${#in[@]} )); do
        if [[ "${in[j]}" == --vendor_bootconfig ]]; then j=$((j+2)); else o+=("${in[j]}"); j=$((j+1)); fi
    done; printf '%s\0' "${o[@]}"; }
cmp -s <(strip_bc "${SRC_GLOBAL[@]}") <(strip_bc "${GLOBAL[@]}") \
                                                   || { echo "VERIFY: header/cmdline differ from SRC" >&2; exit 1; }
cmp -s "$W/src/bootconfig" "$W/out/bootconfig"     || { echo "VERIFY: bootconfig differs from SRC" >&2; exit 1; }

SIZE=$(stat -c %s "$OUT")
(( SIZE <= PARTITION_SIZE ))                       || { echo "VERIFY: $SIZE > partition size" >&2; exit 1; }

echo "recovery fragment built: $(date -r "$RECOVERY_FRAG" '+%F %H:%M')"
echo "output: $OUT ($SIZE bytes, $((SIZE * 100 / PARTITION_SIZE))% of partition)"
echo "OK: header/cmdline/bootconfig match source, fragments verified - safe to flash"
