#!/usr/bin/env python3
"""check_libs.py - find shared libraries missing from the recovery ramdisk.

Walks every ELF under the recovery staging root's /system (bin + lib64),
follows DT_NEEDED recursively, and reports each library that the linker would
fail to find at runtime ("CANNOT LINK EXECUTABLE"), with who needs it and
whether the build already produced it (so it only needs copying).

Usage: check_libs.py [recovery_root] [product_out]
Exit status: 0 = nothing missing, 1 = missing libraries (printed).

Libraries of vendor binaries are resolved against the real /vendor at runtime,
so ELFs under recovery/root/vendor are not checked here.
"""
import os
import shutil
import subprocess
import sys

TOP = os.environ.get("ANDROID_BUILD_TOP", os.path.expanduser("~/twrp"))
R = sys.argv[1] if len(sys.argv) > 1 else os.path.join(TOP, "out/target/product/shiba/recovery/root")
P = sys.argv[2] if len(sys.argv) > 2 else os.path.join(TOP, "out/target/product/shiba")

READELF = shutil.which("llvm-readelf") or shutil.which("readelf")
if not READELF:
    for cand in ("prebuilts/clang/host/linux-x86/llvm-binutils-stable/llvm-readelf",):
        p = os.path.join(TOP, cand)
        if os.path.exists(p):
            READELF = p
if not READELF:
    sys.exit("check_libs: no readelf/llvm-readelf found")

# where the recovery linker's default namespace looks
RAMDISK_LIB_DIRS = [os.path.join(R, "system/lib64"), os.path.join(R, "system/lib64/hw")]
# where the build leaves libraries it produced (candidates to copy in)
BUILT_LIB_DIRS = [os.path.join(P, "system/lib64"), os.path.join(P, "system_ext/lib64"),
                  os.path.join(P, "recovery/root/system/lib64")]
# provided by the runtime/linker itself, never files in lib64
IMPLICIT = {"libc.so", "libm.so", "libdl.so", "ld-android.so", "linux-vdso.so.1"}


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def needed(path):
    out = subprocess.run([READELF, "-d", path], capture_output=True, text=True).stdout
    libs = []
    for line in out.splitlines():
        if "(NEEDED)" in line and "[" in line:
            libs.append(line.split("[", 1)[1].split("]", 1)[0])
    return libs


def find(lib, dirs):
    for d in dirs:
        p = os.path.join(d, lib)
        if os.path.exists(p):
            return p
    return None


def main():
    roots = []
    for sub in ("system/bin", "system/lib64"):
        base = os.path.join(R, sub)
        for dirpath, _, files in os.walk(base):
            for fn in files:
                p = os.path.join(dirpath, fn)
                if not os.path.islink(p) and is_elf(p):
                    roots.append(p)

    missing = {}          # lib -> set(needed_by)
    seen = set()
    queue = [(p, os.path.relpath(p, R)) for p in roots]
    while queue:
        path, label = queue.pop()
        if path in seen:
            continue
        seen.add(path)
        for lib in needed(path):
            if lib in IMPLICIT:
                continue
            if find(lib, RAMDISK_LIB_DIRS):
                continue
            missing.setdefault(lib, set()).add(label)
            built = find(lib, BUILT_LIB_DIRS)
            if built:  # follow its deps too - they'll be needed once it's copied
                queue.append((built, lib + " (built, not in ramdisk)"))

    if not missing:
        print(f"check_libs: OK - {len(seen)} ELF files, no missing libraries")
        return 0
    print(f"check_libs: {len(missing)} missing libraries ({len(seen)} ELF files checked):")
    for lib in sorted(missing):
        built = find(lib, BUILT_LIB_DIRS)
        where = os.path.relpath(built, P) if built else "NOT BUILT"
        users = ", ".join(sorted(missing[lib])[:3])
        more = f" (+{len(missing[lib]) - 3} more)" if len(missing[lib]) > 3 else ""
        print(f"  {lib:55s} [{where}]  <- {users}{more}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
