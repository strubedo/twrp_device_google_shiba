// vbgraft - graft a TWRP recovery ramdisk fragment into a vendor_boot v4 image.
//
// Same job as device/google/shiba/repack.sh, as one native tool that builds
// for the host (repack.sh) and for recovery (on-device "Install TWRP to slot",
// e.g. after an OTA replaced vendor_boot with a stock one). Both sides run the
// same code, so the same inputs give byte-identical images.
//
//   vbgraft --info IMG
//   vbgraft --src TARGET.img (--recovery-from DONOR.img | --recovery-frag FILE)
//           --out OUT.img [--max-size BYTES]
//   vbgraft --src IMG --fstab-get NAME
//           print first_stage_ramdisk's NAME (e.g. fstab.zuma) from the platform
//           fragment
//   vbgraft --src IMG --fstab-set NAME FILE --out OUT.img [--max-size BYTES]
//           replace that file's contents with FILE; every other byte of every
//           other fragment, every other cpio entry, the header, dtb and
//           bootconfig are kept and verified
//           (--fstab-* are C++ only: used on the phone by twrp_encryption.sh)
//
// TARGET: the vendor_boot to install into (stock, or an older TWRP image).
//   Header fields, vendor cmdline, board name, DTB and bootconfig are copied
//   verbatim. The platform fragment (type 1) is kept as-is if it only holds
//   first_stage_ramdisk/; if it also carries a merged stock recovery (factory
//   layout) only the first_stage_ramdisk entries are kept (cpio entries copied
//   byte-for-byte, re-compressed as lz4 legacy HC-12). Other non-recovery
//   fragments pass through untouched, in order - except Android 15+'s type-0
//   "16K" fragment (kernel modules for the 16 KB page-size developer mode),
//   which is dropped: with it, stock A15's vendor_boot + our recovery is
//   ~67 MB, more than the 64 MB partition (and the bootloader's load limit).
//   The normal (4 KB) boot doesn't use it; its modules are in vendor_kernel_boot.
//   Any existing recovery fragment (type 2) is dropped.
// DONOR / FILE: our recovery fragment - taken from the type-2 fragment of a
//   running TWRP vendor_boot (on device) or from the build output (host).
//   Appended last, named "recovery".
//
// The output is re-parsed and verified against the intended layout before
// it is written; any mismatch -> nothing is written, exit 1.

#include <bootimg.h>
#include <lz4.h>
#include <lz4hc.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {

using Bytes = std::vector<uint8_t>;

[[noreturn]] void die(const std::string& msg) {
    fprintf(stderr, "vbgraft: %s\n", msg.c_str());
    exit(1);
}

Bytes read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) die("cannot read " + path + ": " + strerror(errno));
    return Bytes(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

void write_file(const std::string& path, const Bytes& data) {
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) die("cannot write " + path + ": " + strerror(errno));
    if (!data.empty() && fwrite(data.data(), 1, data.size(), f) != data.size()) die("short write " + path);
    if (fflush(f) != 0 || fsync(fileno(f)) != 0 || fclose(f) != 0) die("cannot finish " + path);
}

uint64_t align_up(uint64_t v, uint64_t a) { return (v + a - 1) / a * a; }

struct Fragment {
    uint32_t type = 0;
    std::string name;
    Bytes data;
};

// A parsed vendor_boot v4. Everything except the ramdisk section and its
// table is kept as raw bytes and written back verbatim.
struct VendorBoot {
    vendor_boot_img_hdr_v4 hdr{};
    Bytes dtb;
    Bytes bootconfig;
    std::vector<Fragment> frags;
};

VendorBoot parse(const Bytes& img, const std::string& what) {
    VendorBoot vb;
    if (img.size() < sizeof(vendor_boot_img_hdr_v4)) die(what + ": too small for a vendor_boot header");
    memcpy(&vb.hdr, img.data(), sizeof(vb.hdr));
    const vendor_boot_img_hdr_v4 h = vb.hdr;
    if (memcmp(h.magic, VENDOR_BOOT_MAGIC, VENDOR_BOOT_MAGIC_SIZE) != 0) die(what + ": not a vendor_boot image");
    if (h.header_version != 4) die(what + ": vendor_boot header v" + std::to_string(h.header_version) + ", need v4");
    if (h.page_size == 0 || (h.page_size & (h.page_size - 1))) die(what + ": bad page size");
    if (h.vendor_ramdisk_table_entry_size != sizeof(vendor_ramdisk_table_entry_v4))
        die(what + ": unexpected ramdisk table entry size " + std::to_string(h.vendor_ramdisk_table_entry_size));

    const uint64_t p = h.page_size;
    const uint64_t o_ramdisk = align_up(h.header_size, p);
    const uint64_t o_dtb = o_ramdisk + align_up(h.vendor_ramdisk_size, p);
    const uint64_t o_table = o_dtb + align_up(h.dtb_size, p);
    const uint64_t o_bootconfig = o_table + align_up(h.vendor_ramdisk_table_size, p);
    if (o_bootconfig + h.bootconfig_size > img.size()) die(what + ": truncated (sections exceed file size)");
    if (uint64_t(h.vendor_ramdisk_table_entry_num) * h.vendor_ramdisk_table_entry_size != h.vendor_ramdisk_table_size)
        die(what + ": ramdisk table size mismatch");

    vb.dtb.assign(img.begin() + o_dtb, img.begin() + o_dtb + h.dtb_size);
    vb.bootconfig.assign(img.begin() + o_bootconfig, img.begin() + o_bootconfig + h.bootconfig_size);

    for (uint32_t i = 0; i < h.vendor_ramdisk_table_entry_num; i++) {
        vendor_ramdisk_table_entry_v4 e;
        memcpy(&e, img.data() + o_table + i * sizeof(e), sizeof(e));
        const uint32_t size = e.ramdisk_size, offset = e.ramdisk_offset;
        if (uint64_t(offset) + size > h.vendor_ramdisk_size)
            die(what + ": fragment " + std::to_string(i) + " outside the ramdisk section");
        uint32_t board[VENDOR_RAMDISK_TABLE_ENTRY_BOARD_ID_SIZE];
        memcpy(board, reinterpret_cast<const uint8_t*>(&e) + offsetof(vendor_ramdisk_table_entry_v4, board_id),
               sizeof(board));
        for (uint32_t b : board)
            if (b) die(what + ": fragment " + std::to_string(i) + " has a board_id (unsupported)");
        char name[VENDOR_RAMDISK_NAME_SIZE + 1] = {};
        memcpy(name, reinterpret_cast<const uint8_t*>(&e) + offsetof(vendor_ramdisk_table_entry_v4, ramdisk_name),
               VENDOR_RAMDISK_NAME_SIZE);
        Fragment f;
        f.type = e.ramdisk_type;
        f.name = name;
        auto start = img.begin() + o_ramdisk + offset;
        f.data.assign(start, start + size);
        vb.frags.push_back(std::move(f));
    }
    return vb;
}

// Lay out exactly like mkbootimg.py: page-aligned header, fragments
// back-to-back, then DTB, ramdisk table, bootconfig - each page-padded.
Bytes build(const VendorBoot& vb) {
    vendor_boot_img_hdr_v4 h = vb.hdr;
    const uint64_t p = h.page_size;
    uint64_t ramdisk_size = 0;
    for (const auto& f : vb.frags) ramdisk_size += f.data.size();
    h.vendor_ramdisk_size = static_cast<uint32_t>(ramdisk_size);
    h.dtb_size = static_cast<uint32_t>(vb.dtb.size());
    h.vendor_ramdisk_table_entry_num = static_cast<uint32_t>(vb.frags.size());
    h.vendor_ramdisk_table_entry_size = sizeof(vendor_ramdisk_table_entry_v4);
    h.vendor_ramdisk_table_size = h.vendor_ramdisk_table_entry_num * h.vendor_ramdisk_table_entry_size;
    h.bootconfig_size = static_cast<uint32_t>(vb.bootconfig.size());

    Bytes out;
    auto pad = [&]() { out.resize(align_up(out.size(), p), 0); };
    auto put = [&](const void* d, size_t n) {
        const uint8_t* b = static_cast<const uint8_t*>(d);
        out.insert(out.end(), b, b + n);
    };

    put(&h, sizeof(h));
    const uint32_t header_size = h.header_size;
    if (header_size > sizeof(h)) out.resize(header_size, 0);
    pad();
    uint32_t offset = 0;
    std::vector<vendor_ramdisk_table_entry_v4> table;
    for (const auto& f : vb.frags) {
        vendor_ramdisk_table_entry_v4 e;
        memset(&e, 0, sizeof(e));
        e.ramdisk_size = static_cast<uint32_t>(f.data.size());
        e.ramdisk_offset = offset;
        e.ramdisk_type = f.type;
        if (f.name.size() >= VENDOR_RAMDISK_NAME_SIZE) die("fragment name too long: " + f.name);
        memcpy(reinterpret_cast<uint8_t*>(&e) + offsetof(vendor_ramdisk_table_entry_v4, ramdisk_name),
               f.name.data(), f.name.size());
        table.push_back(e);
        put(f.data.data(), f.data.size());
        offset += static_cast<uint32_t>(f.data.size());
    }
    pad();
    put(vb.dtb.data(), vb.dtb.size());
    pad();
    for (const auto& e : table) put(&e, sizeof(e));
    pad();
    put(vb.bootconfig.data(), vb.bootconfig.size());
    pad();
    return out;
}

// ---- lz4 legacy frames (the kernel's initramfs lz4 format) ----------------
constexpr uint32_t kLz4LegacyMagic = 0x184C2102;
constexpr size_t kLz4LegacyBlock = 8 * 1024 * 1024;

uint32_t rd32(const uint8_t* p) { return p[0] | p[1] << 8 | p[2] << 16 | uint32_t(p[3]) << 24; }
void wr32(Bytes& b, uint32_t v) { for (int i = 0; i < 4; i++) b.push_back(uint8_t(v >> (8 * i))); }

Bytes lz4_legacy_decompress(const Bytes& in) {
    Bytes out;
    size_t pos = 0;
    if (in.size() < 4 || rd32(in.data()) != kLz4LegacyMagic) die("platform fragment is not lz4 legacy");
    while (pos + 4 <= in.size()) {
        uint32_t n = rd32(in.data() + pos);
        pos += 4;
        if (n == kLz4LegacyMagic) continue;  // (concatenated) frame header
        if (n > uint32_t(LZ4_compressBound(kLz4LegacyBlock)) || pos + n > in.size()) die("corrupt lz4 legacy block");
        size_t old = out.size();
        out.resize(old + kLz4LegacyBlock);
        int r = LZ4_decompress_safe(reinterpret_cast<const char*>(in.data() + pos),
                                    reinterpret_cast<char*>(out.data() + old), int(n), int(kLz4LegacyBlock));
        if (r < 0) die("lz4 decompression failed");
        out.resize(old + size_t(r));
        pos += n;
    }
    if (pos != in.size()) die("trailing bytes after lz4 legacy data");
    return out;
}

Bytes lz4_legacy_compress_hc12(const Bytes& in) {
    Bytes out;
    wr32(out, kLz4LegacyMagic);
    Bytes buf(LZ4_compressBound(kLz4LegacyBlock));
    for (size_t pos = 0; pos < in.size(); pos += kLz4LegacyBlock) {
        int len = int(std::min(kLz4LegacyBlock, in.size() - pos));
        int n = LZ4_compress_HC(reinterpret_cast<const char*>(in.data() + pos), reinterpret_cast<char*>(buf.data()),
                                len, int(buf.size()), LZ4HC_CLEVEL_MAX);
        if (n <= 0) die("lz4 compression failed");
        wr32(out, uint32_t(n));
        out.insert(out.end(), buf.begin(), buf.begin() + n);
    }
    return out;
}

// ---- cpio newc -------------------------------------------------------------
struct CpioEntry {
    std::string name;
    size_t start, end;  // byte range of header+name+data (incl. padding)
};

uint32_t hex8(const uint8_t* p) {
    char s[9];
    memcpy(s, p, 8);
    s[8] = 0;
    char* e;
    unsigned long v = strtoul(s, &e, 16);
    if (*e) die("bad cpio header field");
    return uint32_t(v);
}

std::vector<CpioEntry> cpio_entries(const Bytes& c) {
    std::vector<CpioEntry> v;
    size_t pos = 0;
    for (;;) {
        if (pos + 110 > c.size() || memcmp(c.data() + pos, "070701", 6) != 0) die("bad cpio (not newc?)");
        uint32_t filesize = hex8(c.data() + pos + 54);
        uint32_t namesize = hex8(c.data() + pos + 94);
        size_t name_end = pos + 110 + namesize;
        if (namesize == 0 || name_end > c.size()) die("bad cpio name");
        std::string name(reinterpret_cast<const char*>(c.data() + pos + 110), namesize - 1);
        size_t data_start = align_up(name_end, 4);
        size_t end = align_up(data_start + filesize, 4);
        if (end > c.size() + 3) die("bad cpio entry size");
        if (name == "TRAILER!!!") return v;
        v.push_back({name, pos, std::min(end, c.size())});
        pos = end;
    }
}

bool is_first_stage(const std::string& n) {
    return n == "first_stage_ramdisk" || n.rfind("first_stage_ramdisk/", 0) == 0;
}

void append_trailer(Bytes& out) {
    const char name[] = "TRAILER!!!";
    char hdr[111];
    snprintf(hdr, sizeof(hdr), "070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X", 0u, 0u, 0u, 0u, 1u,
             0u, 0u, 0u, 0u, 0u, 0u, unsigned(sizeof(name)), 0u);
    out.insert(out.end(), hdr, hdr + 110);
    out.insert(out.end(), name, name + sizeof(name));
    out.resize(align_up(out.size(), 4), 0);
}

// Keep only first_stage_ramdisk entries of a merged platform fragment.
// Returns false (and leaves `out` alone) if there's nothing to strip.
bool strip_platform(const Bytes& lz4, Bytes* out, size_t* kept, size_t* dropped) {
    Bytes c = lz4_legacy_decompress(lz4);
    auto entries = cpio_entries(c);
    bool merged = false, has_fs = false;
    for (const auto& e : entries) {
        if (is_first_stage(e.name)) has_fs = true;
        else if (e.name != ".") merged = true;
    }
    if (!has_fs) die("platform fragment has no first_stage_ramdisk");
    if (!merged) return false;
    Bytes s;
    *kept = *dropped = 0;
    for (const auto& e : entries) {
        if (is_first_stage(e.name)) {
            s.insert(s.end(), c.begin() + e.start, c.begin() + e.end);
            ++*kept;
        } else {
            ++*dropped;
        }
    }
    append_trailer(s);
    *out = lz4_legacy_compress_hc12(s);
    return true;
}

// ---- first-stage fstab in the platform fragment ----------------------------
// The one entry first_stage_ramdisk/.../NAME (exactly one, regular file).
size_t find_fstab(const std::vector<CpioEntry>& entries, const Bytes& c, const std::string& name) {
    size_t found = SIZE_MAX;
    int n = 0;
    for (size_t i = 0; i < entries.size(); i++) {
        const std::string& p = entries[i].name;
        if (!is_first_stage(p)) continue;
        if (p.size() < name.size() + 1 || p.compare(p.size() - name.size() - 1, std::string::npos, "/" + name) != 0)
            continue;
        uint32_t mode = hex8(c.data() + entries[i].start + 14);
        if ((mode & 0170000) != 0100000) continue;  // regular files only
        found = i;
        n++;
    }
    if (n != 1) die("expected one first_stage_ramdisk/.../" + name + ", found " + std::to_string(n));
    return found;
}

Bytes entry_data(const Bytes& c, const CpioEntry& e) {
    const uint8_t* h = c.data() + e.start;
    uint32_t filesize = hex8(h + 54), namesize = hex8(h + 94);
    size_t data_start = align_up(e.start + 110 + namesize, 4);
    return Bytes(c.begin() + data_start, c.begin() + data_start + filesize);
}

const Fragment& platform_of(const VendorBoot& vb, size_t* index) {
    int n = 0;
    for (size_t i = 0; i < vb.frags.size(); i++)
        if (vb.frags[i].type == VENDOR_RAMDISK_TYPE_PLATFORM) { *index = i; n++; }
    if (n != 1) die("expected exactly one platform fragment, found " + std::to_string(n));
    return vb.frags[*index];
}

// New platform fragment with NAME's data replaced (same header otherwise).
Bytes set_fstab(const Bytes& lz4, const std::string& name, const Bytes& data) {
    Bytes c = lz4_legacy_decompress(lz4);
    auto entries = cpio_entries(c);
    size_t t = find_fstab(entries, c, name);
    Bytes s;
    for (size_t i = 0; i < entries.size(); i++) {
        const CpioEntry& e = entries[i];
        if (i != t) {
            s.insert(s.end(), c.begin() + e.start, c.begin() + e.end);
            continue;
        }
        const uint8_t* h = c.data() + e.start;
        uint32_t namesize = hex8(h + 94);
        char sz[9];
        snprintf(sz, sizeof(sz), "%08X", unsigned(data.size()));
        Bytes hdr(h, h + 110);
        memcpy(hdr.data() + 54, sz, 8);              // c_filesize
        s.insert(s.end(), hdr.begin(), hdr.end());
        s.insert(s.end(), h + 110, h + 110 + namesize);
        s.resize(align_up(s.size(), 4), 0);
        s.insert(s.end(), data.begin(), data.end());
        s.resize(align_up(s.size(), 4), 0);
    }
    append_trailer(s);
    return lz4_legacy_compress_hc12(s);
}

const char* type_name(uint32_t t) {
    switch (t) {
        case VENDOR_RAMDISK_TYPE_NONE: return "none";
        case VENDOR_RAMDISK_TYPE_PLATFORM: return "platform";
        case VENDOR_RAMDISK_TYPE_RECOVERY: return "recovery";
        case VENDOR_RAMDISK_TYPE_DLKM: return "dlkm";
        default: return "?";
    }
}

void print_info(const VendorBoot& vb, const std::string& what) {
    char name[VENDOR_BOOT_NAME_SIZE + 1] = {};
    memcpy(name, vb.hdr.name, VENDOR_BOOT_NAME_SIZE);
    printf("%s: vendor_boot v%u page=%u name='%s' dtb=%zu bootconfig=%zu fragments=%zu\n", what.c_str(),
           unsigned(vb.hdr.header_version), unsigned(vb.hdr.page_size), name, vb.dtb.size(), vb.bootconfig.size(),
           vb.frags.size());
    for (size_t i = 0; i < vb.frags.size(); i++)
        printf("  fragment %zu: type=%u (%s) name='%s' size=%zu\n", i, vb.frags[i].type,
               type_name(vb.frags[i].type), vb.frags[i].name.c_str(), vb.frags[i].data.size());
}

// Header fields that must survive the graft unchanged.
bool same_identity(const vendor_boot_img_hdr_v4& a, const vendor_boot_img_hdr_v4& b) {
    return a.page_size == b.page_size && a.kernel_addr == b.kernel_addr && a.ramdisk_addr == b.ramdisk_addr &&
           a.tags_addr == b.tags_addr && a.header_size == b.header_size && a.dtb_addr == b.dtb_addr &&
           memcmp(a.cmdline, b.cmdline, sizeof(a.cmdline)) == 0 && memcmp(a.name, b.name, sizeof(a.name)) == 0;
}

void usage() {
    fprintf(stderr,
            "usage: vbgraft --info IMG\n"
            "       vbgraft --src TARGET.img (--recovery-from DONOR.img | --recovery-frag FILE)\n"
            "               --out OUT.img [--max-size BYTES]\n"
            "       vbgraft --src IMG --fstab-get NAME\n"
            "       vbgraft --src IMG --fstab-set NAME FILE --out OUT.img [--max-size BYTES]\n");
    exit(2);
}

}  // namespace

int main(int argc, char** argv) {
    std::string info, src, donor, frag_file, out_path, fstab_get, fstab_set, fstab_file;
    uint64_t max_size = 0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (++i >= argc) usage();
            return argv[i];
        };
        if (a == "--info") info = next();
        else if (a == "--src") src = next();
        else if (a == "--recovery-from") donor = next();
        else if (a == "--recovery-frag") frag_file = next();
        else if (a == "--out") out_path = next();
        else if (a == "--max-size") max_size = strtoull(next().c_str(), nullptr, 0);
        else if (a == "--fstab-get") fstab_get = next();
        else if (a == "--fstab-set") { fstab_set = next(); fstab_file = next(); }
        else usage();
    }

    if (!info.empty()) {
        print_info(parse(read_file(info), info), info);
        return 0;
    }
    if (!fstab_get.empty()) {
        if (src.empty() || !out_path.empty() || !fstab_set.empty() || !donor.empty() || !frag_file.empty()) usage();
        VendorBoot vb = parse(read_file(src), src);
        size_t pi;
        Bytes c = lz4_legacy_decompress(platform_of(vb, &pi).data);
        auto entries = cpio_entries(c);
        Bytes d = entry_data(c, entries[find_fstab(entries, c, fstab_get)]);
        fwrite(d.data(), 1, d.size(), stdout);
        return 0;
    }
    if (!fstab_set.empty()) {
        if (src.empty() || out_path.empty() || !donor.empty() || !frag_file.empty()) usage();
        Bytes src_img = read_file(src);
        VendorBoot target = parse(src_img, src);
        Bytes data = read_file(fstab_file);
        size_t pi;
        platform_of(target, &pi);
        VendorBoot out = target;
        out.frags[pi].data = set_fstab(target.frags[pi].data, fstab_set, data);
        Bytes img = build(out);

        // ---- verify by re-parsing what we are about to write ----
        VendorBoot chk = parse(img, "output");
        if (!same_identity(chk.hdr, target.hdr)) die("VERIFY: header/cmdline/name differ from source");
        if (chk.dtb != target.dtb) die("VERIFY: dtb differs from source");
        if (chk.bootconfig != target.bootconfig) die("VERIFY: bootconfig differs from source");
        if (chk.frags.size() != target.frags.size()) die("VERIFY: fragment count");
        for (size_t i = 0; i < target.frags.size(); i++) {
            if (chk.frags[i].type != target.frags[i].type || chk.frags[i].name != target.frags[i].name)
                die("VERIFY: fragment " + std::to_string(i) + " type/name differ");
            if (i != pi && chk.frags[i].data != target.frags[i].data)
                die("VERIFY: fragment " + std::to_string(i) + " differs (only the platform fragment may change)");
        }
        Bytes oc = lz4_legacy_decompress(target.frags[pi].data), nc = lz4_legacy_decompress(chk.frags[pi].data);
        auto oe = cpio_entries(oc), ne = cpio_entries(nc);
        if (oe.size() != ne.size()) die("VERIFY: platform cpio entry count changed");
        size_t t = find_fstab(ne, nc, fstab_set);
        for (size_t i = 0; i < oe.size(); i++) {
            if (oe[i].name != ne[i].name) die("VERIFY: platform cpio entry " + std::to_string(i) + " renamed");
            if (i == t) continue;
            if (!std::equal(oc.begin() + oe[i].start, oc.begin() + oe[i].end, nc.begin() + ne[i].start,
                            nc.begin() + ne[i].end))
                die("VERIFY: platform cpio entry " + oe[i].name + " changed");
        }
        if (entry_data(nc, ne[t]) != data) die("VERIFY: " + fstab_set + " content differs from " + fstab_file);
        if (max_size && img.size() > max_size)
            die("VERIFY: output " + std::to_string(img.size()) + " bytes > partition " + std::to_string(max_size));
        write_file(out_path, img);
        printf("OK: %s (%zu bytes) - %s replaced (%zu -> %zu bytes); header/cmdline/dtb/bootconfig, other "
               "fragments and other cpio entries verified unchanged\n",
               out_path.c_str(), img.size(), ne[t].name.c_str(), entry_data(oc, oe[t]).size(), data.size());
        return 0;
    }
    if (src.empty() || out_path.empty() || donor.empty() == frag_file.empty()) usage();

    VendorBoot target = parse(read_file(src), src);
    print_info(target, "source");

    // Our recovery fragment.
    Bytes recovery;
    if (!donor.empty()) {
        VendorBoot d = parse(read_file(donor), donor);
        int n = 0;
        for (auto& f : d.frags)
            if (f.type == VENDOR_RAMDISK_TYPE_RECOVERY) { recovery = f.data; n++; }
        if (n != 1) die(donor + ": expected exactly one recovery fragment, found " + std::to_string(n));
        printf("recovery fragment: from %s (%zu bytes)\n", donor.c_str(), recovery.size());
    } else {
        recovery = read_file(frag_file);
        printf("recovery fragment: %s (%zu bytes)\n", frag_file.c_str(), recovery.size());
    }
    if (recovery.size() < 4 || rd32(recovery.data()) != kLz4LegacyMagic)
        die("recovery fragment is not lz4 legacy");

    // New fragment list.
    VendorBoot out = target;
    out.frags.clear();
    int platforms = 0;
    for (auto& f : target.frags) {
        if (f.type == VENDOR_RAMDISK_TYPE_RECOVERY) {
            printf("  dropping existing recovery fragment '%s'\n", f.name.c_str());
            continue;
        }
        if (f.name == "16K") {
            printf("  dropping fragment '16K' (%zu bytes: 16 KB page-size developer mode -\n"
                   "    that mode needs the stock vendor_boot; normal boots don't use it)\n",
                   f.data.size());
            continue;
        }
        Fragment nf = f;
        if (f.type == VENDOR_RAMDISK_TYPE_PLATFORM) {
            platforms++;
            size_t kept = 0, dropped = 0;
            if (strip_platform(f.data, &nf.data, &kept, &dropped))
                printf("  platform fragment had merged stock recovery -> kept %zu first_stage entries, dropped %zu\n",
                       kept, dropped);
            else
                printf("  platform fragment is first_stage only -> reusing its bytes\n");
        } else {
            printf("  passing through fragment '%s' (type=%u)\n", f.name.c_str(), f.type);
        }
        out.frags.push_back(std::move(nf));
    }
    if (platforms != 1) die("expected exactly one platform fragment, found " + std::to_string(platforms));
    out.frags.push_back({VENDOR_RAMDISK_TYPE_RECOVERY, "recovery", recovery});

    Bytes img = build(out);

    // ---- verify by re-parsing what we are about to write ----
    VendorBoot chk = parse(img, "output");
    if (!same_identity(chk.hdr, target.hdr)) die("VERIFY: header/cmdline/name differ from source");
    if (chk.dtb != target.dtb) die("VERIFY: dtb differs from source");
    if (chk.bootconfig != target.bootconfig) die("VERIFY: bootconfig differs from source");
    if (chk.frags.size() != out.frags.size()) die("VERIFY: fragment count");
    for (size_t i = 0; i < out.frags.size(); i++)
        if (chk.frags[i].type != out.frags[i].type || chk.frags[i].name != out.frags[i].name ||
            chk.frags[i].data != out.frags[i].data)
            die("VERIFY: fragment " + std::to_string(i) + " differs");
    if (max_size && img.size() > max_size)
        die("VERIFY: output " + std::to_string(img.size()) + " bytes > partition " + std::to_string(max_size));

    write_file(out_path, img);
    print_info(chk, "output");
    std::string pct = max_size ? ", " + std::to_string(img.size() * 100 / max_size) + "% of partition" : "";
    printf("OK: %s (%zu bytes%s) - header/cmdline/dtb/bootconfig match source, fragments verified\n",
           out_path.c_str(), img.size(), pct.c_str());
    return 0;
}
