#!/usr/bin/env python3
"""vbgraft.py - graft a TWRP recovery ramdisk fragment into a vendor_boot v4 image.

Python port of vbgraft/vbgraft.cpp (same logic, same verification, same
output bytes) so the universal installer runs on Linux, macOS and Windows
without an AOSP build. Needs the `lz4` package (pip install lz4) only when a
platform fragment carries a merged stock recovery (factory layout).

  vbgraft.py --info IMG
  vbgraft.py --src TARGET.img (--recovery-from DONOR.img | --recovery-frag FILE)
             --out OUT.img [--max-size BYTES]

TARGET: the vendor_boot to install into (stock, or an older TWRP image).
  Header fields, vendor cmdline, board name, DTB and bootconfig are copied
  verbatim. The platform fragment (type 1) is kept as-is if it only holds
  first_stage_ramdisk/; if it also carries a merged stock recovery only the
  first_stage_ramdisk entries are kept (cpio entries copied byte-for-byte,
  re-compressed as lz4 legacy HC-12). Other non-recovery fragments pass
  through untouched, in order. Any existing recovery fragment (type 2) is dropped.
DONOR / FILE: our recovery fragment - from the type-2 fragment of a TWRP
  vendor_boot, or the build output. Appended last, named "recovery".

The output is re-parsed and verified against the intended layout before it is
written; any mismatch -> nothing is written, exit 1.
"""
import os
import struct
import sys

VENDOR_BOOT_MAGIC = b"VNDRBOOT"
# struct vendor_boot_img_hdr_v4 (packed, little-endian) - system/tools/mkbootimg bootimg.h
HDR = struct.Struct("<8sIIIII2048sI16sIIQIIII")          # 2128 bytes
ENTRY = struct.Struct("<III32s16I")                       # 108 bytes
NAME_SIZE = 32
TYPE_NONE, TYPE_PLATFORM, TYPE_RECOVERY, TYPE_DLKM = 0, 1, 2, 3
LZ4_LEGACY_MAGIC = 0x184C2102
LZ4_LEGACY_BLOCK = 8 * 1024 * 1024
HDR_FIELDS = ("magic", "header_version", "page_size", "kernel_addr", "ramdisk_addr",
              "vendor_ramdisk_size", "cmdline", "tags_addr", "name", "header_size",
              "dtb_size", "dtb_addr", "vendor_ramdisk_table_size",
              "vendor_ramdisk_table_entry_num", "vendor_ramdisk_table_entry_size",
              "bootconfig_size")


def die(msg):
    sys.stderr.write("vbgraft: %s\n" % msg)
    sys.exit(1)


def read_file(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        die("cannot read %s: %s" % (path, e.strerror))


def write_file(path, data):
    try:
        with open(path, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
    except OSError as e:
        die("cannot write %s: %s" % (path, e.strerror))


def align_up(v, a):
    return (v + a - 1) // a * a


class Fragment:
    def __init__(self, type_, name, data):
        self.type, self.name, self.data = type_, name, data


class VendorBoot:
    def __init__(self):
        self.hdr = None          # dict of header fields
        self.dtb = b""
        self.bootconfig = b""
        self.frags = []


def parse(img, what):
    vb = VendorBoot()
    if len(img) < HDR.size:
        die(what + ": too small for a vendor_boot header")
    h = dict(zip(HDR_FIELDS, HDR.unpack_from(img, 0)))
    vb.hdr = h
    if h["magic"] != VENDOR_BOOT_MAGIC:
        die(what + ": not a vendor_boot image")
    if h["header_version"] != 4:
        die("%s: vendor_boot header v%d, need v4" % (what, h["header_version"]))
    p = h["page_size"]
    if p == 0 or (p & (p - 1)):
        die(what + ": bad page size")
    if h["vendor_ramdisk_table_entry_size"] != ENTRY.size:
        die("%s: unexpected ramdisk table entry size %d" % (what, h["vendor_ramdisk_table_entry_size"]))

    o_ramdisk = align_up(h["header_size"], p)
    o_dtb = o_ramdisk + align_up(h["vendor_ramdisk_size"], p)
    o_table = o_dtb + align_up(h["dtb_size"], p)
    o_bootconfig = o_table + align_up(h["vendor_ramdisk_table_size"], p)
    if o_bootconfig + h["bootconfig_size"] > len(img):
        die(what + ": truncated (sections exceed file size)")
    if h["vendor_ramdisk_table_entry_num"] * h["vendor_ramdisk_table_entry_size"] != h["vendor_ramdisk_table_size"]:
        die(what + ": ramdisk table size mismatch")

    vb.dtb = img[o_dtb:o_dtb + h["dtb_size"]]
    vb.bootconfig = img[o_bootconfig:o_bootconfig + h["bootconfig_size"]]
    for i in range(h["vendor_ramdisk_table_entry_num"]):
        e = ENTRY.unpack_from(img, o_table + i * ENTRY.size)
        size, offset, rtype, rname = e[0], e[1], e[2], e[3]
        if offset + size > h["vendor_ramdisk_size"]:
            die("%s: fragment %d outside the ramdisk section" % (what, i))
        if any(e[4:]):
            die("%s: fragment %d has a board_id (unsupported)" % (what, i))
        name = rname.split(b"\0", 1)[0].decode("latin-1")
        start = o_ramdisk + offset
        vb.frags.append(Fragment(rtype, name, img[start:start + size]))
    return vb


def build(vb):
    """Lay out exactly like mkbootimg.py / vbgraft.cpp."""
    h = dict(vb.hdr)
    p = h["page_size"]
    h["vendor_ramdisk_size"] = sum(len(f.data) for f in vb.frags)
    h["dtb_size"] = len(vb.dtb)
    h["vendor_ramdisk_table_entry_num"] = len(vb.frags)
    h["vendor_ramdisk_table_entry_size"] = ENTRY.size
    h["vendor_ramdisk_table_size"] = len(vb.frags) * ENTRY.size
    h["bootconfig_size"] = len(vb.bootconfig)

    out = bytearray(HDR.pack(*(h[k] for k in HDR_FIELDS)))
    if h["header_size"] > len(out):
        out += b"\0" * (h["header_size"] - len(out))

    def pad():
        out.extend(b"\0" * (align_up(len(out), p) - len(out)))

    pad()
    table = bytearray()
    offset = 0
    for f in vb.frags:
        name = f.name.encode("latin-1")
        if len(name) >= NAME_SIZE:
            die("fragment name too long: " + f.name)
        table += ENTRY.pack(len(f.data), offset, f.type, name, *([0] * 16))
        out += f.data
        offset += len(f.data)
    pad()
    out += vb.dtb
    pad()
    out += table
    pad()
    out += vb.bootconfig
    pad()
    return bytes(out)


# ---- lz4 legacy frames (the kernel's initramfs lz4 format) -----------------
def _lz4():
    try:
        import lz4.block
        return lz4.block
    except ImportError:
        die("this image needs the lz4 Python package: pip install lz4")


def lz4_legacy_decompress(data):
    block = _lz4()
    if len(data) < 4 or struct.unpack_from("<I", data, 0)[0] != LZ4_LEGACY_MAGIC:
        die("platform fragment is not lz4 legacy")
    out = bytearray()
    pos = 0
    while pos + 4 <= len(data):
        n = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        if n == LZ4_LEGACY_MAGIC:
            continue  # (concatenated) frame header
        if pos + n > len(data):
            die("corrupt lz4 legacy block")
        try:
            out += block.decompress(data[pos:pos + n], uncompressed_size=LZ4_LEGACY_BLOCK)
        except Exception:
            die("lz4 decompression failed")
        pos += n
    if pos != len(data):
        die("trailing bytes after lz4 legacy data")
    return bytes(out)


def lz4_legacy_compress_hc12(data):
    block = _lz4()
    out = bytearray(struct.pack("<I", LZ4_LEGACY_MAGIC))
    for pos in range(0, len(data), LZ4_LEGACY_BLOCK):
        c = block.compress(data[pos:pos + LZ4_LEGACY_BLOCK], mode="high_compression",
                           compression=12, store_size=False)
        out += struct.pack("<I", len(c)) + c
    return bytes(out)


# ---- cpio newc ---------------------------------------------------------------
def cpio_entries(c):
    entries = []
    pos = 0
    while True:
        if pos + 110 > len(c) or c[pos:pos + 6] != b"070701":
            die("bad cpio (not newc?)")
        try:
            filesize = int(c[pos + 54:pos + 62], 16)
            namesize = int(c[pos + 94:pos + 102], 16)
        except ValueError:
            die("bad cpio header field")
        name_end = pos + 110 + namesize
        if namesize == 0 or name_end > len(c):
            die("bad cpio name")
        name = c[pos + 110:name_end - 1].decode("latin-1")
        data_start = align_up(name_end, 4)
        end = align_up(data_start + filesize, 4)
        if end > len(c) + 3:
            die("bad cpio entry size")
        if name == "TRAILER!!!":
            return entries
        entries.append((name, pos, min(end, len(c))))
        pos = end


def is_first_stage(n):
    return n == "first_stage_ramdisk" or n.startswith("first_stage_ramdisk/")


def trailer():
    name = b"TRAILER!!!\0"
    hdr = ("070701" + "%08X" * 13 % (0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(name), 0)).encode()
    t = hdr + name
    return t + b"\0" * (align_up(len(t), 4) - len(t))


def strip_platform(lz4data):
    """Keep only first_stage_ramdisk entries of a merged platform fragment.
    Returns (new_data, kept, dropped), or None if there's nothing to strip."""
    c = lz4_legacy_decompress(lz4data)
    entries = cpio_entries(c)
    has_fs = any(is_first_stage(n) for n, _, _ in entries)
    merged = any(not is_first_stage(n) and n != "." for n, _, _ in entries)
    if not has_fs:
        die("platform fragment has no first_stage_ramdisk")
    if not merged:
        return None
    s = bytearray()
    kept = dropped = 0
    for n, start, end in entries:
        if is_first_stage(n):
            s += c[start:end]
            kept += 1
        else:
            dropped += 1
    s += trailer()
    return lz4_legacy_compress_hc12(bytes(s)), kept, dropped


TYPE_NAMES = {TYPE_NONE: "none", TYPE_PLATFORM: "platform", TYPE_RECOVERY: "recovery", TYPE_DLKM: "dlkm"}


def print_info(vb, what):
    name = vb.hdr["name"].split(b"\0", 1)[0].decode("latin-1")
    print("%s: vendor_boot v%d page=%d name='%s' dtb=%d bootconfig=%d fragments=%d"
          % (what, vb.hdr["header_version"], vb.hdr["page_size"], name, len(vb.dtb),
             len(vb.bootconfig), len(vb.frags)))
    for i, f in enumerate(vb.frags):
        print("  fragment %d: type=%d (%s) name='%s' size=%d"
              % (i, f.type, TYPE_NAMES.get(f.type, "?"), f.name, len(f.data)))


def same_identity(a, b):
    """Header fields that must survive the graft unchanged."""
    return all(a[k] == b[k] for k in ("page_size", "kernel_addr", "ramdisk_addr", "tags_addr",
                                      "header_size", "dtb_addr", "cmdline", "name"))


def usage():
    sys.stderr.write("usage: vbgraft.py --info IMG\n"
                     "       vbgraft.py --src TARGET.img (--recovery-from DONOR.img | --recovery-frag FILE)\n"
                     "                  --out OUT.img [--max-size BYTES]\n")
    sys.exit(2)


def main(argv):
    opts = {}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a not in ("--info", "--src", "--recovery-from", "--recovery-frag", "--out", "--max-size") \
                or i + 1 >= len(argv):
            usage()
        opts[a] = argv[i + 1]
        i += 2

    if "--info" in opts:
        print_info(parse(read_file(opts["--info"]), opts["--info"]), opts["--info"])
        return 0
    src, out_path = opts.get("--src"), opts.get("--out")
    donor, frag_file = opts.get("--recovery-from"), opts.get("--recovery-frag")
    if not src or not out_path or (donor is None) == (frag_file is None):
        usage()
    max_size = int(opts.get("--max-size", "0"), 0)

    target = parse(read_file(src), src)
    print_info(target, "source")

    if donor is not None:
        d = parse(read_file(donor), donor)
        recs = [f.data for f in d.frags if f.type == TYPE_RECOVERY]
        if len(recs) != 1:
            die("%s: expected exactly one recovery fragment, found %d" % (donor, len(recs)))
        recovery = recs[0]
        print("recovery fragment: from %s (%d bytes)" % (donor, len(recovery)))
    else:
        recovery = read_file(frag_file)
        print("recovery fragment: %s (%d bytes)" % (frag_file, len(recovery)))
    if len(recovery) < 4 or struct.unpack_from("<I", recovery, 0)[0] != LZ4_LEGACY_MAGIC:
        die("recovery fragment is not lz4 legacy")

    out = VendorBoot()
    out.hdr, out.dtb, out.bootconfig = dict(target.hdr), target.dtb, target.bootconfig
    platforms = 0
    for f in target.frags:
        if f.type == TYPE_RECOVERY:
            print("  dropping existing recovery fragment '%s'" % f.name)
            continue
        nf = Fragment(f.type, f.name, f.data)
        if f.type == TYPE_PLATFORM:
            platforms += 1
            r = strip_platform(f.data)
            if r:
                nf.data = r[0]
                print("  platform fragment had merged stock recovery -> kept %d first_stage entries, dropped %d"
                      % (r[1], r[2]))
            else:
                print("  platform fragment is first_stage only -> reusing its bytes")
        else:
            print("  passing through fragment '%s' (type=%d)" % (f.name, f.type))
        out.frags.append(nf)
    if platforms != 1:
        die("expected exactly one platform fragment, found %d" % platforms)
    out.frags.append(Fragment(TYPE_RECOVERY, "recovery", recovery))

    img = build(out)

    # ---- verify by re-parsing what we are about to write ----
    chk = parse(img, "output")
    if not same_identity(chk.hdr, target.hdr):
        die("VERIFY: header/cmdline/name differ from source")
    if chk.dtb != target.dtb:
        die("VERIFY: dtb differs from source")
    if chk.bootconfig != target.bootconfig:
        die("VERIFY: bootconfig differs from source")
    if len(chk.frags) != len(out.frags):
        die("VERIFY: fragment count")
    for i, (a, b) in enumerate(zip(chk.frags, out.frags)):
        if (a.type, a.name, a.data) != (b.type, b.name, b.data):
            die("VERIFY: fragment %d differs" % i)
    if max_size and len(img) > max_size:
        die("VERIFY: output %d bytes > partition %d" % (len(img), max_size))

    write_file(out_path, img)
    print_info(chk, "output")
    pct = ", %d%% of partition" % (len(img) * 100 // max_size) if max_size else ""
    print("OK: %s (%d bytes%s) - header/cmdline/dtb/bootconfig match source, fragments verified"
          % (out_path, len(img), pct))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
