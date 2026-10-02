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
# The work is done by vbgraft (device/google/shiba/vbgraft) - the same tool
# recovery runs on the phone for "Install TWRP to slot", so the PC and the
# phone produce byte-identical images from the same inputs. Nothing
# version-specific is hard-coded:
#   * header fields, vendor cmdline, board name, DTB and bootconfig are copied
#     verbatim from SRC
#   * the platform fragment (type 1) is reused: if it also carries a merged
#     stock recovery (factory layout) only first_stage_ramdisk/ is kept,
#     otherwise its bytes are kept
#   * every other non-recovery fragment is passed through, in order - except
#     Android 15+'s type-0 "16K" fragment (16 KB page-size developer mode),
#     which is dropped: stock + TWRP would not fit the 64 MB partition
#   * any existing recovery fragment (type 2) is dropped and ours appended
# vbgraft re-parses its output and verifies all of that before writing.
# Base: $STOCK_DIR/factory/vendor_boot.img links to vendor_boot-<BUILD ID>.img
# (build.sh --flash only flashes a slot running that build).
set -euo pipefail

DEVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$DEVICE_DIR/../../.." && pwd)"
STOCK_DIR="${STOCK_DIR:-$HOME/shiba-stock}"

SRC="$(realpath "${1:-$STOCK_DIR/factory/vendor_boot.img}")"
OUT="$(realpath -m "${2:-$STOCK_DIR/twrp_vendor_boot.img}")"

VBGRAFT="$TOP/out/host/linux-x86/bin/vbgraft"
RECOVERY_FRAG="$TOP/out/target/product/shiba/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4"
PARTITION_SIZE=67108864   # vendor_boot_a/_b on shiba

for f in "$SRC" "$VBGRAFT" "$RECOVERY_FRAG"; do
    [[ -f "$f" ]] || { echo "MISSING: $f (host vbgraft: m vbgraft)" >&2; exit 1; }
done

rm -f "$OUT"
"$VBGRAFT" --src "$SRC" --recovery-frag "$RECOVERY_FRAG" --out "$OUT" --max-size "$PARTITION_SIZE"
echo "recovery fragment built: $(date -r "$RECOVERY_FRAG" '+%F %H:%M')"
echo "OK: safe to flash"
