#!/usr/bin/env bash
# Repack Pixel 8 (shiba) vendor_boot with TWRP.
#   fragment 00 (platform) = factory first_stage_ramdisk only (fs_frag.lz4)
#   fragment 01 (recovery) = our TWRP ramdisk from the build
# Header, offsets, vendor cmdline and bootconfig = factory AP2A.240605.024.
#
# Inputs live outside the tree in $STOCK_DIR (default ~/shiba-stock):
#   fs_frag.lz4    factory first_stage_ramdisk, repacked as legacy lz4
#   fvb/bootconfig factory vendor bootconfig
# Output: $STOCK_DIR/twrp_vendor_boot.img
#
# TODO (feature 3b): derive all of the above from a factory zip or a
# vendor_boot dumped from the phone, instead of hard-coding AP2A values.
set -euo pipefail

DEVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$DEVICE_DIR/../../.." && pwd)"
STOCK_DIR="${STOCK_DIR:-$HOME/shiba-stock}"
cd "$STOCK_DIR"

MKBOOTIMG="$TOP/system/tools/mkbootimg/mkbootimg.py"
UNPACK="$TOP/system/tools/mkbootimg/unpack_bootimg.py"
PLATFORM_FRAG="fs_frag.lz4"
RECOVERY_FRAG="$TOP/out/target/product/shiba/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4"
BOOTCONFIG="fvb/bootconfig"
OUT="twrp_vendor_boot.img"

VENDOR_CMDLINE='exynos_drm.load_sequential=1 g2d.load_sequential=1 samsung_iommu_v9.load_sequential=1 swiotlb=noforce disable_dma32=on earlycon=exynos4210,0x10870000 console=ttySAC0,115200 androidboot.console=ttySAC0 printk.devkmsg=on cma_sysfs.experimental=Y cgroup_disable=memory rcupdate.rcu_expedited=1 rcu_nocbs=all swiotlb=1024 cgroup.memory=nokmem sysctl.kernel.sched_pelt_multiplier=4 kasan=off at24.write_timeout=100 log_buf_len=1024K bootconfig'

for f in "$MKBOOTIMG" "$UNPACK" "$PLATFORM_FRAG" "$RECOVERY_FRAG" "$BOOTCONFIG"; do
    [[ -f "$f" ]] || { echo "MISSING: $f" >&2; exit 1; }
done

rm -f "$OUT"
rm -rf verify

# --vendor_boot must come BEFORE the fragments: mkbootimg groups every arg
# after a --vendor_ramdisk_fragment into that fragment.
python3 "$MKBOOTIMG" \
    --vendor_boot "$OUT" \
    --header_version 4 \
    --pagesize 0x00000800 \
    --base 0x00000000 \
    --kernel_offset 0x10008000 \
    --ramdisk_offset 0x11000000 \
    --tags_offset 0x10000100 \
    --dtb_offset 0x0000000011f00000 \
    --vendor_cmdline "$VENDOR_CMDLINE" \
    --board '' \
    --vendor_bootconfig "$BOOTCONFIG" \
    --ramdisk_type 1 --ramdisk_name '' --vendor_ramdisk_fragment "$PLATFORM_FRAG" \
    --ramdisk_type 2 --ramdisk_name recovery --vendor_ramdisk_fragment "$RECOVERY_FRAG"

# Verify: unpack and require both fragments byte-identical to their sources.
python3 "$UNPACK" --boot_img "$OUT" --out verify >/dev/null
cmp "$PLATFORM_FRAG" verify/vendor_ramdisk00
cmp "$RECOVERY_FRAG" verify/vendor_ramdisk01
[[ ! -e verify/vendor_ramdisk02 ]] || { echo "UNEXPECTED extra fragment" >&2; exit 1; }

echo "recovery fragment built: $(date -r "$RECOVERY_FRAG" '+%F %H:%M')"
ls -l "$OUT"
echo "OK: both fragments verified - safe to flash"
