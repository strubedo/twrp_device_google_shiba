#!/usr/bin/env bash
# make_images.sh - ready-to-flash TWRP images, one per firmware build, for
# users without root or a custom recovery:
#     fastboot flash vendor_boot shiba-twrp-<ver>-<BUILD>.img
# Each image is the stock vendor_boot of that exact build (from Google's factory
# zip) with our TWRP fragment grafted in - the same graft as the installers.
#
#   ./make_images.sh v9.40 FACTORY.zip ...
#
# Refuses unless the built TWRP fragment carries that version. Every image is
# built with the C and the Python vbgraft and kept only if both are
# byte-identical. Writes dist/shiba-twrp-<ver>-<BUILD>.img + an images SHA256SUMS.
set -euo pipefail
cd "$(dirname "$0")"
TREE="$PWD"
TWRP="$(cd ../../.. && pwd)"
VBC="$TWRP/out/host/linux-x86/bin/vbgraft"
VBPY="$TREE/vbgraft/vbgraft.py"
PY="${PY:-$HOME/.venvs/twrp-theme/bin/python}"
FRAG="$TWRP/out/target/product/shiba/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4"
PART=67108864
MAX_FRAGMENT=46000000

die() { echo "make_images: $*" >&2; exit 1; }
[[ $# -ge 2 ]] || die "usage: $0 vX.Y FACTORY.zip ..."
VER="$1"; shift
[[ "$VER" =~ ^v[0-9]+\.[0-9]+$ ]] || die "version must look like v9.40"
[[ -x "$VBC" ]] || die "no host vbgraft at $VBC - run ./build.sh"
[[ -f "$FRAG" ]] || die "no recovery fragment - run ./build.sh"
(( $(stat -c %s "$FRAG") <= MAX_FRAGMENT )) || die "fragment too big for the bootloader"
FRAGVER="$(lz4 -dc "$FRAG" | grep -a -o -m1 -- "-shiba-v[0-9][0-9.]*+\?" || true)"
[[ "$FRAGVER" == "-shiba-$VER" ]] || die "the built fragment is '${FRAGVER#-}', not shiba-$VER - build the tagged release first"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p dist
SUMS="dist/shiba-twrp-$VER-images.sha256"
: > "$SUMS"
echo "== TWRP shiba-$VER fragment: $(stat -c %s "$FRAG") bytes"
for z in "$@"; do
    [[ -f "$z" ]] || die "no such file: $z"
    # the build number from inside the zip (its top folder), not the file name
    top="$(unzip -Z1 "$z" | head -1 | cut -d/ -f1)"
    [[ "$top" =~ ^shiba-([a-z0-9.]+)$ ]] || die "$z: not a shiba factory image (top folder '$top')"
    BUILD="$(echo "${BASH_REMATCH[1]}" | tr a-z A-Z)"
    unzip -p "$z" "$top/image-shiba-*.zip" > "$W/i.zip" && unzip -p "$W/i.zip" vendor_boot.img > "$W/vb.img" \
        || die "$z: no vendor_boot.img inside"
    out="dist/shiba-twrp-$VER-$BUILD.img"
    "$VBC" --src "$W/vb.img" --recovery-frag "$FRAG" --out "$W/c.img" --max-size $PART > "$W/c.log" 2>&1 \
        || { cat "$W/c.log"; die "$BUILD: C vbgraft failed"; }
    "$PY" "$VBPY" --src "$W/vb.img" --recovery-frag "$FRAG" --out "$W/p.img" --max-size $PART > "$W/p.log" 2>&1 \
        || { cat "$W/p.log"; die "$BUILD: Python vbgraft failed"; }
    cmp -s "$W/c.img" "$W/p.img" || die "$BUILD: C and Python grafts differ - not publishing"
    mv "$W/c.img" "$out"
    ( cd dist && sha256sum "$(basename "$out")" ) >> "$SUMS"
    echo "- $BUILD: $(basename "$out") ($(stat -c %s "$out") bytes, C == Python)"
    rm -f "$W"/*
done
echo "== $SUMS"
cat "$SUMS"
