#!/usr/bin/env bash
# test_installer.sh - run install_twrp.py against fake adb/fastboot that act like
# a Pixel 8, with synthetic vendor_boot / factory images. No phone involved.
# Needs: python3 + lz4 (pip), cpio, lz4 (CLI), the TWRP tree (for mkbootimg.py).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"        # device/google/shiba/vbgraft
TREE="$(dirname "$HERE")"                     # device/google/shiba
TWRP="${TWRP:-$HOME/twrp}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/fx" && cd "$W/fx"
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
cd "$W"
mkdir -p "$W/bin" "$W/rel" "$W/home/Downloads"
cp "$TREE/install_twrp.py" "$HERE/vbgraft.py" "$W/rel/" && cp "$W/fx/twrp.lz4" "$W/rel/recovery.cpio.lz4"
FACTORY_IMG="$W/fx/factory.img"

# ---- fakes -------------------------------------------------------------------
cat > "$W/bin/adb" <<'EOF'
#!/usr/bin/env python3
import os, sys, shutil
a, S = sys.argv[1:], os.environ["FAKE_DIR"]
prop = lambda k: os.environ.get("FAKE_" + k.replace(".", "_").upper(), "")
if a == ["get-state"]:
    print("bootloader" if os.path.exists(S + "/inbl") else os.environ.get("FAKE_STATE", "device"))
elif a[:2] == ["shell", "getprop"]:
    print(prop(a[2]))
elif a[:3] == ["shell", "su", "-c"]:
    if os.environ.get("FAKE_ROOT") == "1": print("uid=0(root) gid=0(root) context=u:r:ksu:s0")
    else: print("/system/bin/sh: su: inaccessible or not found"); sys.exit(127)
elif a[:3] == ["exec-out", "su", "-c"]:
    if os.environ.get("FAKE_ROOT") != "1": sys.exit(127)
    sys.stdout.buffer.write(open(os.environ["FAKE_VB"], "rb").read())
elif a == ["reboot", "bootloader"]:
    open(S + "/inbl", "w").close(); open(S + "/log", "a").write("adb reboot bootloader\n")
else:
    sys.exit("fake adb: unhandled %r" % a)
EOF
cat > "$W/bin/fastboot" <<'EOF'
#!/usr/bin/env python3
import os, sys, shutil
a, S = sys.argv[1:], os.environ["FAKE_DIR"]
log = lambda m: open(S + "/log", "a").write(m + "\n")
if a == ["devices"]:
    if os.path.exists(S + "/inbl"): print("39161FAKE\tfastboot")
elif a[0] == "getvar":
    v = os.environ.get("FAKE_FB_" + a[1].replace("-", "_").replace(":", "_").upper(), "")
    sys.stderr.write("%s: %s\nFinished. Total time: 0.001s\n" % (a[1], v))
elif a[0] == "flash":
    shutil.copy(a[2], S + "/flashed_" + a[1] + ".img"); log("fastboot flash " + a[1])
    sys.stderr.write("Sending '%s'\nWriting '%s'\nFinished.\n" % (a[1], a[1]))
elif a == ["reboot", "recovery"]:
    log("fastboot reboot recovery")
else:
    sys.exit("fake fastboot: unhandled %r" % a)
EOF
chmod +x "$W/bin/adb" "$W/bin/fastboot"

# ---- factory zips (inner image zip stored / deflated, right / wrong build) ------
python3 - "$W" "$FACTORY_IMG" <<'PY'
import sys, zipfile, os
W, vb = sys.argv[1], open(sys.argv[2], "rb").read()
def factory(build, inner_method, path):
    inner = os.path.join(W, "inner.zip")
    with zipfile.ZipFile(inner, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("android-info.txt", "require board=shiba\n")
        z.writestr("vendor_boot.img", vb)
        z.writestr("boot.img", b"x" * 1000)
    with zipfile.ZipFile(path, "w") as z:
        z.write(inner, "shiba-%s/image-shiba-%s.zip" % (build, build), compress_type=inner_method)
        z.writestr("shiba-%s/flash-all.sh" % build, "#!/bin/sh\n")
factory("ap2a.240905.003", zipfile.ZIP_STORED,   W + "/home/Downloads/shiba-ap2a.240905.003-factory-e3f78b31.zip")
factory("ap2a.240905.003", zipfile.ZIP_DEFLATED, W + "/deflated-factory.zip")
factory("bp1a.250405.007", zipfile.ZIP_STORED,   W + "/shiba-bp1a.250405.007-factory-00000000.zip")
PY

python3 -c "import struct,sys; open(sys.argv[1],'wb').write(struct.pack('<I',0x184C2102)+bytes(46000001))" "$W/big.lz4"

pass=0; fail=0
scenario() {  # scenario NAME EXPECT(ok|fail) GREP-FOR -- env... -- args...
    local name="$1" expect="$2" want="$3"; shift 3
    local envs=() ; while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
    local S="$W/s_$name"; rm -rf "$S"; mkdir -p "$S"
    ( cd "$W/rel" && env PATH="$W/bin:$PATH" HOME="$W/home" FAKE_DIR="$S" FAKE_VB="$FACTORY_IMG" \
        FAKE_STATE=device FAKE_RO_PRODUCT_DEVICE=shiba FAKE_RO_BUILD_ID=AP2A.240905.003 \
        FAKE_RO_BOOT_SLOT_SUFFIX=_a FAKE_FB_PRODUCT=shiba FAKE_FB_UNLOCKED=yes FAKE_FB_CURRENT_SLOT=a \
        FAKE_FB_PARTITION_SIZE_VENDOR_BOOT_A=0x4000000 FAKE_FB_PARTITION_SIZE_VENDOR_BOOT_B=0x4000000 \
        "${envs[@]}" python3 install_twrp.py --out "$S/out" "$@" ) > "$S/stdout" 2>&1
    local rc=$? got=ok; [[ $rc == 0 ]] || got=fail
    if [[ "$got" == "$expect" ]] && grep -q -- "$want" "$S/stdout"; then
        pass=$((pass+1)); printf "  ok   %-24s %s\n" "$name" "$(grep -m1 -o -- "$want" "$S/stdout")"
    else
        fail=$((fail+1)); printf "  FAIL %-24s (rc %s, wanted %s / '%s')\n" "$name" "$rc" "$expect" "$want"
        tail -6 "$S/stdout" | sed 's/^/        /'
    fi
}

scenario root_dry_run         ok   "Dry run - nothing flashed"    FAKE_ROOT=1 -- --dry-run
scenario factory_auto_dry     ok   "Factory image: .*Downloads"   FAKE_ROOT=0 -- --dry-run
scenario factory_deflated     ok   "unpacking the inner image"    FAKE_ROOT=0 -- --factory "$W/deflated-factory.zip" --dry-run
scenario factory_wrong_build  fail "factory image is for BP1A"    FAKE_ROOT=0 -- --factory "$W/shiba-bp1a.250405.007-factory-00000000.zip" --dry-run
scenario no_root_no_zip       fail "no factory image for"         FAKE_ROOT=0 HOME="$W/empty" -- --dry-run
scenario not_shiba            fail "not 'husky'"                  FAKE_RO_PRODUCT_DEVICE=husky -- --dry-run
scenario no_adb_device        fail "no phone in Android"          FAKE_STATE=unauthorized -- --dry-run
scenario flash_root_slot_a    ok   "Done. The phone is booting"   FAKE_ROOT=1 --
scenario flash_factory_slot_b ok   "Flashing vendor_boot_b"       FAKE_ROOT=0 FAKE_RO_BOOT_SLOT_SUFFIX=_b FAKE_FB_CURRENT_SLOT=b --
scenario locked_bootloader    fail "bootloader is locked"         FAKE_ROOT=1 FAKE_FB_UNLOCKED=no --
scenario slot_mismatch        fail "differs from Android"         FAKE_ROOT=1 FAKE_FB_CURRENT_SLOT=b --
scenario wrong_product_fb     fail "fastboot reports product"     FAKE_ROOT=1 FAKE_FB_PRODUCT=akita --
scenario partition_too_small  fail "larger than vendor_boot_a"    FAKE_ROOT=1 FAKE_FB_PARTITION_SIZE_VENDOR_BOOT_A=0x1000 --
scenario partition_size_blank fail "could not read the size"      FAKE_ROOT=1 FAKE_FB_PARTITION_SIZE_VENDOR_BOOT_A= --
scenario frag_too_big         fail "won't boot on this phone"     FAKE_ROOT=1 -- --frag "$W/big.lz4" --dry-run

# what was flashed must be exactly vbgraft's verified output, and the backup the original
python3 - "$W" "$FACTORY_IMG" <<'PY'
import sys, os, filecmp, glob
W, orig = sys.argv[1], sys.argv[2]
for s, slot in (("flash_root_slot_a", "_a"), ("flash_factory_slot_b", "_b")):
    d = os.path.join(W, "s_" + s)
    flashed = os.path.join(d, "flashed_vendor_boot%s.img" % slot)
    grafted = glob.glob(os.path.join(d, "out", "*-twrp-*.img"))[0]
    backup = glob.glob(os.path.join(d, "out", "*-original-*.img"))[0]
    ok = filecmp.cmp(flashed, grafted, False) and filecmp.cmp(backup, orig, False)
    log = open(os.path.join(d, "log")).read().split("\n")
    print("  %s  %-24s flashed == grafted, backup == original; sequence: %s"
          % ("ok  " if ok else "FAIL", s, " | ".join(l for l in log if l)))
for s in ("locked_bootloader", "slot_mismatch", "wrong_product_fb", "partition_too_small", "partition_size_blank"):
    flashed = glob.glob(os.path.join(W, "s_" + s, "flashed_*"))
    print("  %s  %-24s nothing flashed" % ("ok  " if not flashed else "FAIL", s))
PY
echo "== $pass passed, $fail failed"
