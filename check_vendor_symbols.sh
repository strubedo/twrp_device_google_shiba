#!/usr/bin/env bash
# check_vendor_symbols.sh - which C++/libbase/libutils/libbinder symbols do a
# firmware's vendor binaries need that OUR recovery's libraries don't export?
# check_vendor_compat.py only checks versioned symbols; libc++ and friends are
# unversioned, which is how A15's citadeld slipped through ("cannot locate
# symbol _ZNSt3__122__libcpp_verbose_abortEPKcz" - A15+ vendors ship their own,
# newer libc++ since VNDK is gone).
#   check_vendor_symbols.sh VENDOR_DIR [binary-or-lib relative to VENDOR_DIR ...]
# Default set: the decryption stack (KeyMint, Gatekeeper, citadeld, Weaver + libs).
set -uo pipefail
V="${1:?usage: $0 VENDOR_DIR [files...]}"; shift
NM="${NM:-$HOME/twrp/prebuilts/clang/host/linux-x86/clang-r510928/bin/llvm-nm}"
R="${R:-$HOME/twrp/out/target/product/shiba/recovery/root/system/lib64}"
FILES=("$@")
[[ ${#FILES[@]} -gt 0 ]] || FILES=(
    bin/hw/citadeld bin/hw/android.hardware.weaver-service.citadel
    bin/hw/android.hardware.gatekeeper-service.trusty
    bin/hw/android.hardware.security.keymint-service.rust.trusty
    lib64/libnos_citadeld_proxy.so lib64/libnos_client_citadel.so
    lib64/android.hardware.weaver-impl.nos.so lib64/android.hardware.weaver2-impl.nos.so
    lib64/android.hardware.weaver-bridge.nos.so)

T="$(mktemp)"; P="$(mktemp)"; trap 'rm -f "$T" "$P"' EXIT
READELF="$(dirname "$NM")/llvm-readelf"
# The linker searches our /system/lib64 first and falls back to /vendor/lib64,
# so each NEEDED library comes from us if we ship it, else from the vendor.
provider() { [[ -f "$R/$1" ]] && echo "$R/$1" || { [[ -f "$V/lib64/$1" ]] && echo "$V/lib64/$1"; }; }
echo "recovery libs: $R"

missing=0
for f in "${FILES[@]}"; do
    p="$V/$f"
    [[ -f "$p" ]] || { echo "-- $f: not in this vendor"; continue; }
    # exports of the libraries this file actually binds to (ours first, then vendor's)
    : > "$P"
    for so in $("$READELF" -d "$p" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
        lib="$(provider "$so")"
        [[ -n "$lib" ]] && "$NM" -D --defined-only "$lib" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' >> "$P"
    done
    sort -u -o "$T" "$P"
    # C++ std (libc++), android::base, android:: (libutils/libbinder) - the
    # unversioned ones that come from our ramdisk unless the vendor ships them
    syms="$("$NM" -D --undefined-only "$p" 2>/dev/null | awk '{print $NF}' \
            | grep -E '^_ZN(K)?St3__1|^_ZN(K)?7android' | sort -u)"
    out=""
    while read -r s; do
        [[ -z "$s" ]] && continue
        # a versioned reference (sym@VER) binds to an unversioned definition in
        # bionic's linker (our recovery libs are unversioned): compare base names
        grep -qxF "${s%%@*}" "$T" || out+="     $s"$'\n'
    done <<< "$syms"
    if [[ -n "$out" ]]; then
        n=$(grep -c . <<< "$out"); missing=$((missing + n))
        echo "-- $f: $n missing"; printf '%s' "$out" | head -8
    else
        echo "-- $f: ok"
    fi
done
echo "== $missing missing symbol(s)"
[[ $missing == 0 ]]
