#!/usr/bin/env python3
"""Will another firmware's vendor services run in this recovery?

Resolves each service like the dynamic linker would, against:
  1. that firmware's /vendor/lib64   (what the phone would really have)
  2. this recovery's /system/lib64   (our ramdisk, Android 14-based)
and reports, per service:
  * NEEDED libraries found in neither place
  * undefined symbols (with symbol versions) that nothing in the load
    closure defines - these stop the service at startup
  * missing WEAK symbols separately (allowed to be absent)

  check_vendor_compat.py <extracted vendor dir> [service ...]
  default services: the decryption stack (KeyMint, Gatekeeper, Weaver, citadeld)
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
READELF = os.path.join(TOP, "prebuilts/clang/host/linux-x86/clang-r510928/bin/llvm-readelf")
RAMDISK_LIB = os.environ.get("RAMDISK_LIB") or os.path.join(TOP, "out/target/product/shiba/recovery/root/system/lib64")
DEFAULT = [
    "bin/hw/android.hardware.security.keymint-service.rust.trusty",
    "bin/hw/android.hardware.security.keymint-service.trusty",
    "bin/hw/android.hardware.gatekeeper-service.trusty",
    "bin/hw/android.hardware.weaver-service.citadel",
    "bin/hw/citadeld",
]

SYM = re.compile(r"^\s*\d+:\s+\S+\s+\d+\s+(\S+)\s+(\S+)\s+\S+\s+(\S+)\s+(\S+)")
_cache = {}


def elf(path):
    """-> (needed[], defined{name: set(versions)}, undefined[(name, ver, weak)],
            verneed[(file, version, weak)], verdef set(version))"""
    if path in _cache:
        return _cache[path]
    out = subprocess.run([READELF, "-d", "--dyn-syms", "-V", "-W", path],
                         capture_output=True, text=True).stdout
    needed = re.findall(r"\(NEEDED\)\s+Shared library: \[(.+?)\]", out)
    defined, undefined = {}, []
    verneed, verdef, cur_file, section = [], set(), None, None
    for line in out.splitlines():
        if "Version definition section" in line:
            section = "def"
        elif "Version needs section" in line:
            section = "need"
        elif line.startswith("Symbol table") or line.startswith("Dynamic section"):
            section = None
        if section == "def":
            m = re.search(r"Flags: (\S+)\s+Index: \d+\s+Cnt: \d+\s+Name: (\S+)", line)
            if m and m.group(1) != "BASE":
                verdef.add(m.group(2))
        elif section == "need":
            m = re.search(r"File: (\S+)", line)
            if m:
                cur_file = m.group(1)
            m = re.search(r"Name: (\S+)\s+Flags: (\S+)", line)
            if m and cur_file:
                verneed.append((cur_file, m.group(1), "WEAK" in m.group(2).upper()))
        m = SYM.match(line)
        if not m:
            continue
        typ, bind, ndx, name = m.groups()
        if typ in ("SECTION", "FILE"):
            continue
        base, _, ver = name.partition("@")
        ver = ver.lstrip("@")
        if ndx == "UND":
            if base:
                undefined.append((base, ver, bind == "WEAK"))
        else:
            defined.setdefault(base, set()).add(ver)
    _cache[path] = (needed, defined, undefined, verneed, verdef)
    return _cache[path]


def find_lib(name, dirs):
    for d in dirs:
        p = os.path.join(d, name)
        if os.path.isfile(p):
            return p
    return None


def check(service, vendor):
    dirs = [os.path.join(vendor, "lib64"), RAMDISK_LIB]
    root = os.path.join(vendor, service)
    if not os.path.isfile(root):
        return None
    closure, missing_libs, queue = {}, [], [root]
    while queue:                                   # linker-style breadth-first load
        p = queue.pop(0)
        if p in closure:
            continue
        closure[p] = elf(p)
        for n in closure[p][0]:
            q = find_lib(n, dirs)
            if q is None:
                missing_libs.append((os.path.basename(p), n))
            elif q not in closure:
                queue.append(q)
    provided = {}
    for _, defined, _, _, _ in closure.values():
        for s, vers in defined.items():
            provided.setdefault(s, set()).update(vers)
    unresolved, weak = [], []
    for p, (_, _, undef, _, _) in closure.items():
        for s, ver, is_weak in undef:
            have = provided.get(s)
            ok = have is not None and (not ver or ver in have)
            if not ok:
                (weak if is_weak else unresolved).append((os.path.basename(p), s, ver))
    # version requirements: each (library, version) an ELF needs must be
    # defined by that library - independent of whether the symbol is weak
    for p, (_, _, _, verneed, _) in closure.items():
        for f, ver, is_weak in verneed:
            lib = find_lib(f, dirs)
            if lib is None or is_weak:
                continue
            if ver not in elf(lib)[4]:
                unresolved.append((os.path.basename(p), f"<version {ver} not defined by {f}>", ""))
    return closure, missing_libs, unresolved, weak


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    vendor = sys.argv[1]
    services = sys.argv[2:] or DEFAULT
    bad = 0
    for svc in services:
        r = check(svc, vendor)
        name = os.path.basename(svc)
        if r is None:
            print(f"-- {name}: not in this firmware")
            continue
        closure, missing, unresolved, weak = r
        sources = sum(1 for p in closure if p.startswith(RAMDISK_LIB))
        status = "OK" if not missing and not unresolved else "BROKEN"
        bad += status != "OK"
        print(f"== {name}: {status}  ({len(closure) - 1} libs, {sources} from our recovery)")
        for who, lib in sorted(set(missing)):
            print(f"   missing lib   {lib}  (needed by {who})")
        for who, s, v in sorted(set(unresolved))[:25]:
            print(f"   unresolved    {s}{'@' + v if v else ''}  (in {who})")
        if len(set(unresolved)) > 25:
            print(f"   ... {len(set(unresolved)) - 25} more unresolved")
        if weak:
            print(f"   ({len(set(weak))} weak symbols absent - allowed)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
