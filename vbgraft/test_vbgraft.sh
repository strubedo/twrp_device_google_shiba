#!/usr/bin/env bash
# test_vbgraft.sh - compare vbgraft (C) with vbgraft.py on synthetic vendor_boot
# v4 images made by AOSP's mkbootimg.py: exit codes, stdout, stderr and output
# image bytes must be identical. Needs: python3 + lz4 (pip), cpio, lz4 (CLI).
#   VBC=path/to/vbgraft  (default: the host build in ~/twrp/out/host/linux-x86/bin)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TWRP="${TWRP:-$HOME/twrp}"
VBC="${VBC:-$TWRP/out/host/linux-x86/bin/vbgraft}"
VBPY="$HERE/vbgraft.py"
[[ -x "$VBC" ]] || { echo "no C vbgraft at $VBC (build it: m vbgraft, or set VBC=)"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cd "$W"
MK="python3 $TWRP/system/tools/mkbootimg/mkbootimg.py"

mkfrag() {   # mkfrag OUT.lz4 dir...   -> cpio newc of the dirs' contents, lz4 legacy -12
    local out="$1"; shift
    ( cd "$1" && find . | LC_ALL=C sort | cpio -o -H newc --quiet ) > "${out%.lz4}.cpio"
    lz4 -l -12 -q -f "${out%.lz4}.cpio" "$out"
}

# --- fixture trees --------------------------------------------------------
mkdir -p fs/first_stage_ramdisk/system/bin merged/first_stage_ramdisk/system/bin \
         merged/system/bin merged/res/images twrp/system/bin twrp/twres k16/lib/modules
echo "fstab first stage" > fs/first_stage_ramdisk/fstab.zuma
head -c 300000 /dev/urandom > fs/first_stage_ramdisk/system/bin/blob
cp -a fs/first_stage_ramdisk/. merged/first_stage_ramdisk/
printf '#!/system/bin/sh\necho stock recovery\n' > merged/init
head -c 2000000 /dev/urandom | base64 > merged/system/bin/recovery     # compressible
head -c 50000 /dev/urandom > merged/res/images/icon.png
head -c 9000000 /dev/zero | tr '\0' 'T' > twrp/system/bin/twrp_big     # > 8 MiB: 2 lz4 blocks
head -c 400000 /dev/urandom > twrp/twres/theme.bin
head -c 120000 /dev/urandom > k16/lib/modules/x_16k.ko
mkfrag fs.lz4 fs
mkfrag merged.lz4 merged
mkdir -p bigmerged && cp -a merged/. bigmerged/ && head -c 12000000 /dev/urandom | base64 > bigmerged/system/bin/huge
mkfrag bigmerged.lz4 bigmerged
mkfrag twrp.lz4 twrp
mkfrag oldtwrp.lz4 fs                      # stands in for an older recovery fragment
mkfrag k16.lz4 k16
head -c 180001 /dev/urandom > dtb
printf 'androidboot.hardware=zuma\nandroidboot.boot_devices=13200000.ufs\n' > bootconfig

vb() {  # vb OUT PAGESIZE [extra fragment args...]
    local out="$1" ps="$2"; shift 2
    $MK --header_version 4 --pagesize "$ps" --vendor_boot "$out" \
        --vendor_cmdline "console=ttynull androidboot.selinux=enforcing" --board shiba \
        --dtb dtb --vendor_bootconfig bootconfig "$@"
}
# factory layout: platform with merged stock recovery + Android 16 style 16K fragment
vb factory.img 4096 --ramdisk_type platform --ramdisk_name "" --vendor_ramdisk_fragment merged.lz4 \
                    --ramdisk_type none --ramdisk_name 16K --vendor_ramdisk_fragment k16.lz4
# factory layout whose platform fragment spans several 8 MiB lz4 blocks
vb factory_big.img 4096 --ramdisk_type platform --ramdisk_name "" --vendor_ramdisk_fragment bigmerged.lz4
# an older TWRP: first-stage-only platform + old recovery fragment, page 2048
vb oldtwrp.img 2048 --ramdisk_type platform --ramdisk_name "" --vendor_ramdisk_fragment fs.lz4 \
                    --ramdisk_type recovery --ramdisk_name recovery --vendor_ramdisk_fragment oldtwrp.lz4
# errors
vb boardid.img 4096 --ramdisk_type platform --ramdisk_name "" --board_id0 0x7 --vendor_ramdisk_fragment fs.lz4
vb twoplat.img 4096 --ramdisk_type platform --ramdisk_name a --vendor_ramdisk_fragment fs.lz4 \
                    --ramdisk_type platform --ramdisk_name b --vendor_ramdisk_fragment fs.lz4
printf 'not lz4 at all' > bad.frag

pass=0; fail=0
run() {  # run NAME ARGS...  -> both tools, compare exit code, stdout, output bytes
    local name="$1"; shift
    local ca=() pa=()
    for a in "$@"; do ca+=("${a//OUT/c_$name.img}"); pa+=("${a//OUT/p_$name.img}"); done
    "$VBC" "${ca[@]}" > c_$name.log 2> c_$name.err; local rc=$?
    python3 "$VBPY" "${pa[@]}" > p_$name.log 2> p_$name.err; local rp=$?
    sed -i "s/c_$name.img/OUT/g; s/^vbgraft: /E: /" c_$name.log c_$name.err
    sed -i "s/p_$name.img/OUT/g; s/^vbgraft: /E: /" p_$name.log p_$name.err
    local why=""
    [[ $rc == "$rp" ]] || why+=" exit($rc vs $rp)"
    cmp -s c_$name.log p_$name.log || why+=" stdout"; cmp -s c_$name.err p_$name.err || why+=" stderr"
    if [[ -f c_$name.img || -f p_$name.img ]]; then cmp -s c_$name.img p_$name.img || why+=" IMAGE-BYTES"; fi
    if [[ -z "$why" ]]; then pass=$((pass+1)); printf "  ok   %-26s exit %s %s\n" "$name" "$rc" \
            "$([[ -f c_$name.img ]] && echo "($(stat -c %s c_$name.img) bytes, identical)")"
    else fail=$((fail+1)); printf "  FAIL %-26s%s\n" "$name" "$why"; diff c_$name.log p_$name.log | head -5; fi
}

run info_factory          --info factory.img
run info_oldtwrp          --info oldtwrp.img
run graft_factory         --src factory.img --recovery-frag twrp.lz4 --out OUT --max-size 67108864
run graft_factory_big     --src factory_big.img --recovery-frag twrp.lz4 --out OUT
run graft_oldtwrp         --src oldtwrp.img --recovery-frag twrp.lz4 --out OUT
run graft_from_donor      --src factory.img --recovery-from c_graft_factory.img --out OUT
run regraft_own_output    --src c_graft_factory.img --recovery-frag twrp.lz4 --out OUT
run err_board_id          --src boardid.img --recovery-frag twrp.lz4 --out OUT
run err_two_platform      --src twoplat.img --recovery-frag twrp.lz4 --out OUT
run err_frag_not_lz4      --src factory.img --recovery-frag bad.frag --out OUT
run err_max_size          --src factory.img --recovery-frag twrp.lz4 --out OUT --max-size 1000000
run err_not_vendor_boot   --src dtb --recovery-frag twrp.lz4 --out OUT
run err_donor_no_recovery --src factory.img --recovery-from factory.img --out OUT

# the grafted factory image: fragment table names/types, and the stripped
# platform fragment must hold only first_stage_ramdisk entries
echo "== decompressed platform fragment of graft_factory (first entries):"
python3 - "$HERE" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import vbgraft as v
vb = v.parse(open("c_graft_factory.img", "rb").read(), "x")
for f in vb.frags: print("   type=%d name=%-9r %d bytes" % (f.type, f.name, len(f.data)))
c = v.lz4_legacy_decompress(vb.frags[0].data)
print("   platform entries:", [n for n, _, _ in v.cpio_entries(c)])
PY
echo "== $pass passed, $fail failed"
[[ $fail == 0 ]]
