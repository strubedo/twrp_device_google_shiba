#!/usr/bin/env bash
# get_aoc_crcs.sh - for each firmware image, pull aoc_usb_driver.ko out of
# vendor_kernel_boot (the 4K kernel's first-stage modules; vendor_boot only
# carries the _16k set on A16+) and print the CRCs otg_host_ready.ko needs.
#
#   get_aoc_crcs.sh IMAGE.zip...     (factory zip, or the inner image-shiba-*.zip)
# Output per firmware in /tmp/aoc: aoc-<build>.ko, sym-<build>.symvers
set -euo pipefail
export PATH="$HOME/twrp/prebuilts/clang/host/linux-x86/clang-r510928/bin:$PATH"
UNPACK="$HOME/twrp/system/tools/mkbootimg/unpack_bootimg.py"
GEN="$(dirname "$(realpath "$0")")/gen_symvers.py"
W=/tmp/aoc
mkdir -p "$W"

for z in "$@"; do
    n="$(basename "$z" | sed 's/.*shiba-\([a-z0-9]*\)\..*/\1/')"
    echo "== $n  ($(basename "$z"))"
    if [[ "$(basename "$z")" == image-shiba-* ]]; then
        cp "$z" "$W/i.zip"
    else
        unzip -p "$z" '*/image-shiba-*.zip' > "$W/i.zip"
    fi
    unzip -p "$W/i.zip" vendor_kernel_boot.img > "$W/vkb-$n.img"
    rm -rf "$W/vkb-$n" "$W/i.zip"
    python3 "$UNPACK" --boot_img "$W/vkb-$n.img" --out "$W/vkb-$n" > /dev/null
    for r in "$W/vkb-$n"/vendor_ramdisk*; do
        lz4 -dc "$r" | (cd "$W" && cpio -i --quiet --to-stdout '*aoc_usb_driver.ko') || true
    done > "$W/aoc-$n.ko"
    [[ -s "$W/aoc-$n.ko" ]] || { echo "   aoc_usb_driver.ko NOT found"; continue; }
    echo "   kernel dir: $(for r in "$W/vkb-$n"/vendor_ramdisk*; do lz4 -dc "$r" | cpio -t 2>/dev/null; done | grep -m1 -o 'lib/modules/[^/]*')"
    python3 "$GEN" "$W/aoc-$n.ko" "$W/sym-$n.symvers" | sed 's/^/   /'
done
