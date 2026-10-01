#!/usr/bin/env bash
# extract_vendor.sh - pull the vendor tree (bin, etc, lib64) out of a Pixel
# factory image, the way ~/Downloads/shiba-a16/vendor was made, for
# check_vendor_compat.py and fstab/VINTF reading. Needs debugfs (e2fsprogs).
#
#   extract_vendor.sh FACTORY.zip OUTDIR      e.g. ... shiba-a15
# -> OUTDIR/vendor/{bin,etc,lib64}, OUTDIR/img/vendor.img
set -euo pipefail
z="$1"; out="$2"
mkdir -p "$out/img" "$out/vendor"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "== inner image zip"
unzip -p "$z" '*/image-shiba-*.zip' > "$tmp/i.zip"
echo "== vendor.img"
unzip -p "$tmp/i.zip" vendor.img > "$out/img/vendor.img"
file "$out/img/vendor.img"
for d in bin etc lib64; do
    echo "== /$d"
    /usr/sbin/debugfs -R "rdump /$d $out/vendor" "$out/img/vendor.img" 2>/dev/null
done
echo "== done: $(find "$out/vendor" -type f | wc -l) files in $out/vendor"
