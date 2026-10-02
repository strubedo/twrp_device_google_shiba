#!/usr/bin/env bash
# check_firmware_graft.sh - will TWRP install onto these firmwares?
# For each factory zip (or plain vendor_boot.img): take the stock vendor_boot,
# graft the current build's TWRP fragment with the C vbgraft AND vbgraft.py,
# and report: fragments, result size vs the partition, C == Python.
#   check_firmware_graft.sh FACTORY.zip|vendor_boot.img ...
# (Missed before the A15 test: A15+ vendor_boot carries a 19 MB "16K" fragment.)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TWRP="${TWRP:-$HOME/twrp}"
VBC="${VBC:-$TWRP/out/host/linux-x86/bin/vbgraft}"
VBPY="$HERE/vbgraft.py"
PY="${PY:-$HOME/.venvs/twrp-theme/bin/python}"
FRAG="${FRAG:-$TWRP/out/target/product/shiba/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4}"
PART=67108864
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
[[ -x "$VBC" && -f "$FRAG" ]] || { echo "need $VBC and $FRAG (run ./build.sh)"; exit 1; }
echo "TWRP fragment: $(stat -c %s "$FRAG") bytes"
rc=0
for src in "$@"; do
    name="$(basename "$src")"
    if [[ "$src" == *.zip ]]; then
        unzip -p "$src" '*/image-shiba-*.zip' > "$W/i.zip" 2>/dev/null \
            && unzip -p "$W/i.zip" vendor_boot.img > "$W/vb.img" 2>/dev/null \
            || { echo "== $name: no vendor_boot.img inside"; rc=1; continue; }
    else
        cp "$src" "$W/vb.img"
    fi
    echo "== $name"
    "$VBC" --info "$W/vb.img" | sed -n 's/^  fragment/   stock fragment/p'
    "$VBC" --src "$W/vb.img" --recovery-frag "$FRAG" --out "$W/c.img" --max-size $PART > "$W/c.log" 2>&1; rcc=$?
    "$PY" "$VBPY" --src "$W/vb.img" --recovery-frag "$FRAG" --out "$W/p.img" --max-size $PART > "$W/p.log" 2>&1; rcp=$?
    grep -E "dropping fragment|VERIFY|^vbgraft:" "$W/c.log" | sed 's/^/   /'
    if [[ $rcc == 0 && $rcp == 0 ]]; then
        s=$(stat -c %s "$W/c.img")
        same=$(cmp -s "$W/c.img" "$W/p.img" && echo "C == Python" || echo "C != PYTHON")
        echo "   OK: $s bytes ($(( s * 100 / PART ))% of partition), $same"
        [[ "$same" == "C == Python" ]] || rc=1
    else
        echo "   FAILS: C exit $rcc, Python exit $rcp"; rc=1
    fi
    rm -f "$W/c.img" "$W/p.img" "$W/vb.img" "$W/i.zip"
done
exit $rc
