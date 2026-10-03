// lptool: minimal logical-partition tool for the recovery (Pixel 8 / shiba).
// Built on AOSP's liblp + fs_mgr dm-linear helpers (Apache-2.0).
//
//   lptool info   SLOT                    partitions of SLOT (_a/_b) + free space
//   lptool has    SLOT NAME               exit 0 if NAME exists in SLOT's metadata
//   lptool add    SLOT NAME SIZE LIKE     add NAME (SIZE bytes, rounded up by
//                                         liblp) to the group partition LIKE is in
//   lptool remove SLOT NAME               remove NAME from SLOT's metadata
//   lptool write  SLOT NAME IMAGE         map NAME writable, write IMAGE, read it
//                                         back and compare, unmap
//
// Every change re-reads the metadata afterwards and checks the result.
// SLOT is explicit (no guessing). The super device is /dev/block/by-name/super.
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include <fs_mgr_dm_linear.h>
#include <liblp/builder.h>
#include <liblp/liblp.h>

using namespace android::fs_mgr;

static const char* kSuper = "/dev/block/by-name/super";

static int fail(const char* fmt, const char* a = "", const char* b = "") {
    fprintf(stderr, "lptool: ");
    fprintf(stderr, fmt, a, b);
    fprintf(stderr, "\n");
    return 1;
}

static bool slot_number(const std::string& slot, uint32_t* out) {
    if (slot != "_a" && slot != "_b") return false;
    *out = SlotNumberForSlotSuffix(slot);
    return true;
}

static std::unique_ptr<LpMetadata> read_md(uint32_t slot) { return ReadMetadata(kSuper, slot); }

static const LpMetadataPartition* find(const LpMetadata& md, const std::string& name) {
    for (const auto& p : md.partitions)
        if (GetPartitionName(p) == name) return &p;
    return nullptr;
}

static int cmd_info(uint32_t slot) {
    auto md = read_md(slot);
    if (!md) return fail("cannot read super metadata");
    for (const auto& p : md->partitions)
        printf("%-24s %-36s %llu\n", GetPartitionName(p).c_str(),
               GetPartitionGroupName(md->groups[p.group_index]).c_str(),
               (unsigned long long)GetPartitionSize(*md, p));
    auto b = MetadataBuilder::New(*md);
    if (!b) return fail("cannot parse super metadata");
    printf("free %llu\n", (unsigned long long)(b->AllocatableSpace() - b->UsedSpace()));
    return 0;
}

static int cmd_add(uint32_t slot, const std::string& name, uint64_t size, const std::string& like) {
    auto md = read_md(slot);
    if (!md) return fail("cannot read super metadata");
    if (find(*md, name)) return fail("%s already exists", name.c_str());
    const LpMetadataPartition* ref = find(*md, like);
    if (!ref) return fail("reference partition %s not found", like.c_str());
    std::string group = GetPartitionGroupName(md->groups[ref->group_index]);
    auto b = MetadataBuilder::New(*md);
    if (!b) return fail("cannot parse super metadata");
    Partition* p = b->AddPartition(name, group, LP_PARTITION_ATTR_NONE);
    if (!p) return fail("cannot add %s to group %s", name.c_str(), group.c_str());
    if (!b->ResizePartition(p, size)) return fail("not enough free space in group %s for %s", group.c_str(), name.c_str());
    auto out = b->Export();
    if (!out) return fail("cannot export metadata");
    if (!UpdatePartitionTable(kSuper, *out, slot)) return fail("writing super metadata failed");
    auto check = read_md(slot);                 // verify: re-read from disk
    const LpMetadataPartition* np = check ? find(*check, name) : nullptr;
    if (!np || GetPartitionSize(*check, *np) < size) return fail("verify failed: %s not in metadata after write", name.c_str());
    printf("added %s (%llu bytes) to %s\n", name.c_str(), (unsigned long long)GetPartitionSize(*check, *np), group.c_str());
    return 0;
}

static int cmd_remove(uint32_t slot, const std::string& name) {
    auto md = read_md(slot);
    if (!md) return fail("cannot read super metadata");
    if (!find(*md, name)) return fail("%s not found", name.c_str());
    DestroyLogicalPartition(name);              // unmap if mapped (ignore result)
    auto b = MetadataBuilder::New(*md);
    if (!b) return fail("cannot parse super metadata");
    b->RemovePartition(name);
    auto out = b->Export();
    if (!out || !UpdatePartitionTable(kSuper, *out, slot)) return fail("writing super metadata failed");
    auto check = read_md(slot);
    if (!check || find(*check, name)) return fail("verify failed: %s still in metadata", name.c_str());
    printf("removed %s\n", name.c_str());
    return 0;
}

static bool copy_and_verify(const std::string& image, const std::string& dev) {
    int in = open(image.c_str(), O_RDONLY | O_CLOEXEC);
    int out = open(dev.c_str(), O_RDWR | O_CLOEXEC);
    if (in < 0 || out < 0) {
        if (in >= 0) close(in);
        if (out >= 0) close(out);
        return false;
    }
    std::vector<char> buf(1 << 20), back(1 << 20);
    bool ok = true;
    off_t off = 0;
    for (;;) {
        ssize_t n = read(in, buf.data(), buf.size());
        if (n < 0) { ok = false; break; }
        if (n == 0) break;
        if (pwrite(out, buf.data(), n, off) != n) { ok = false; break; }
        off += n;
    }
    if (ok) ok = fsync(out) == 0;
    if (ok) {                                    // read back and compare
        lseek(in, 0, SEEK_SET);
        off = 0;
        for (;;) {
            ssize_t n = read(in, buf.data(), buf.size());
            if (n <= 0) { ok = n == 0; break; }
            if (pread(out, back.data(), n, off) != n || memcmp(buf.data(), back.data(), n) != 0) { ok = false; break; }
            off += n;
        }
    }
    close(in);
    close(out);
    return ok;
}

static int cmd_write(uint32_t slot, const std::string& name, const std::string& image) {
    auto md = read_md(slot);
    if (!md) return fail("cannot read super metadata");
    const LpMetadataPartition* p = find(*md, name);
    if (!p) return fail("%s not found", name.c_str());
    struct stat st;
    if (stat(image.c_str(), &st) != 0) return fail("cannot read %s", image.c_str());
    if ((uint64_t)st.st_size > GetPartitionSize(*md, *p)) return fail("%s is larger than %s", image.c_str(), name.c_str());
    DestroyLogicalPartition(name);
    CreateLogicalPartitionParams params;
    params.block_device = kSuper;
    params.metadata_slot = slot;
    params.partition_name = name;
    params.force_writable = true;
    params.timeout_ms = std::chrono::milliseconds(5000);
    std::string path;
    if (!CreateLogicalPartition(params, &path)) return fail("cannot map %s", name.c_str());
    bool ok = copy_and_verify(image, path);
    DestroyLogicalPartition(name);
    if (!ok) return fail("writing %s to %s failed or did not read back identically", image.c_str(), name.c_str());
    printf("wrote %s to %s (%lld bytes, verified)\n", image.c_str(), name.c_str(), (long long)st.st_size);
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: lptool info|has|add|remove|write SLOT ...\n");
        return 2;
    }
    std::string cmd = argv[1];
    uint32_t slot;
    if (!slot_number(argv[2], &slot)) return fail("SLOT must be _a or _b");
    if (cmd == "info" && argc == 3) return cmd_info(slot);
    if (cmd == "has" && argc == 4) {
        auto md = read_md(slot);
        return md && find(*md, argv[3]) ? 0 : 1;
    }
    if (cmd == "add" && argc == 6) return cmd_add(slot, argv[3], strtoull(argv[4], nullptr, 10), argv[5]);
    if (cmd == "remove" && argc == 4) return cmd_remove(slot, argv[3]);
    if (cmd == "write" && argc == 5) return cmd_write(slot, argv[3], argv[4]);
    fprintf(stderr, "usage: lptool info|has|add|remove|write SLOT ...\n");
    return 2;
}
