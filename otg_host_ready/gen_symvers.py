#!/usr/bin/env python3
"""Make a Module.symvers-style file from a Google-built module's __versions.

No full kernel build here, so there's no Module.symvers with the running
kernel's symbol CRCs. aoc_usb_driver.ko was built by Google against this exact
kernel (android14-5.15-2024-01_r11) and imports dwc3_otg_host_ready plus the
usual core symbols, so its __versions table has the CRCs we need.

  gen_symvers.py MODULE.ko OUT.symvers
"""
import struct
import subprocess
import sys
import tempfile

ko, out = sys.argv[1], sys.argv[2]
with tempfile.NamedTemporaryFile() as t:
    subprocess.run(["llvm-objcopy", "-O", "binary", "--only-section=__versions", ko, t.name], check=True)
    data = open(t.name, "rb").read()

# arm64: struct modversion_info { unsigned long crc; char name[56]; }
ENTRY = 64
if len(data) == 0 or len(data) % ENTRY:
    sys.exit(f"unexpected __versions size {len(data)}")

owner = {"dwc3_otg_host_ready": ("dwc3-exynos-usb", "EXPORT_SYMBOL_GPL")}
lines = []
for off in range(0, len(data), ENTRY):
    crc, = struct.unpack_from("<Q", data, off)
    name = data[off + 8:off + ENTRY].split(b"\0", 1)[0].decode()
    mod, kind = owner.get(name, ("vmlinux", "EXPORT_SYMBOL"))
    lines.append(f"0x{crc:08x}\t{name}\t{mod}\t{kind}\t")
open(out, "w").write("\n".join(lines) + "\n")
print(f"{len(lines)} symbols from {ko}")
for l in lines:
    if l.split("\t")[1] in ("module_layout", "dwc3_otg_host_ready", "_printk"):
        print("  " + l.replace("\t", "  "))
