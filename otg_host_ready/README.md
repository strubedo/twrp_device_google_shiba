# otg_host_ready - USB OTG in recovery on Pixel 8 (shiba)

> **2026-10-03 update (v9.42).** host_ready alone is not enough on Android 15+:
> in recovery the USB-C controller registers the port **sink-only**
> (`/sys/class/typec/port0/port_type` reads `[sink]`, read-only; Android's USB
> HAL is what makes it dual-role), so a drive is never even detected.
> `twrp_otg_watch.sh` now forces the OTG ID to host and turns on 5 V through
> the charger's CHARGER_MODE vote when nothing powers the port (LeeGarChat's
> zuma method), with this module supplying host_ready. On kernel 6.1 the module
> now finds `dwc3_otg_host_ready()` through a kprobe (no link-time dependency)
> and offers `/proc/otg_host_ready` (read 1/0, write 1/0); 5.15 keeps the
> direct link (its jump-table CFI would panic on a raw kprobe address). The 6.1
> build takes its CRCs from Google's `vmlinux.symvers` for the kernel build
> (`-abNNNNNNNN` in `uname -r`):
>
>     curl -fsSL -o ~/ref/gki-symvers/6.1-ab12946699.symvers \
>       https://ci.android.com/builds/submitted/12946699/kernel_aarch64/latest/raw/vmlinux.symvers
>     make clean KDIR=~/ref/gki-6.1
>     make KDIR=~/ref/gki-6.1 SYMVERS=~/ref/gki-symvers/6.1-ab12946699.symvers
>     cp otg_host_ready.ko ../recovery/root/lib/modules/6.1/
>
> All 19 imported CRCs matched Google's file; `.gnu.linkonce.this_module` 0x440.
> GKI keeps KMI CRCs stable within a generation, so one build covers 6.1.x.
>
> 5.15 (same source, direct link): Google's 5.15 vmlinux.symvers plus one line
> for the vendor symbol (KBUILD_EXTRA_SYMBOLS takes both; the Makefile quotes it):
>
>     printf '0xf76f2627\tdwc3_otg_host_ready\tdwc3-exynos-usb\tEXPORT_SYMBOL_GPL\t\n' \
>       > ~/ref/gki-symvers/5.15-dwc3.symvers
>     make clean KDIR=~/ref/gki-5.15
>     make KDIR=~/ref/gki-5.15 SYMVERS="$HOME/ref/gki-symvers/5.15-ab12057991.symvers $HOME/ref/gki-symvers/5.15-dwc3.symvers"
>     cp otg_host_ready.ko ../recovery/root/lib/modules/5.15/
>
> Checked (no Android 14 slot left to load-test): 19/19 CRCs match Google's,
> this_module 0x400, vermagic flags and module_layout 0x4bcc9336 identical to
> the proven previous 5.15 build.

## Why

Pixel's dwc3 OTG state machine (`drivers/usb/dwc3/dwc3-exynos-otg.c` in
`kernel/google-modules/soc/gs`) only goes from `a_idle` to `a_host` once
`dwc3_otg_host_ready(true)` has been called. In Android that call comes from
`aoc_usb_dev.c`'s probe (`kernel/google-modules/aoc`), i.e. only after the AoC
coprocessor is running. Recovery never starts AoC, so on attach the port goes
to host role (VBUS on, `new_data_role=host`, `otg_id=0`) and then sits in
`a_idle` forever: no xHCI controller, no devices.

`otg_host_ready.ko` makes that one call when loaded (and undoes it on unload).
Tested: SanDisk Cruzer Glide enumerates (xHCI up, usb-storage, `sde`/`sde1`).
AoC is only needed for USB audio offload, not for storage/HID devices.

## Kernel ABI

Built out-of-tree against the exact GKI source of the running kernel:

    uname -r: 5.15.137-android14-11-gbf4f9bc41c3b-ab11664771
    source:   kernel/common tag android14-5.15-2024-01_r11 (bf4f9bc41c3b)
    config:   the phone's /proc/config.gz, TRIM_UNUSED_KSYMS disabled only

Symbol CRCs come from Google's `aoc_usb_driver.ko` (`gen_symvers.py`), which
imports the same `dwc3_otg_host_ready`. Checked before shipping:
`.gnu.linkonce.this_module` size identical to Google's module (struct module
layout), vermagic flags match, every imported symbol has a CRC.

**After an OTA with a new kernel the module won't load** (CRC mismatch; harmless,
OTG just stays unavailable) until rebuilt against that kernel's tag + config.

## Kernel 6.1 (Android 15 QPR2 through Android 17)

Shiba moved to kernel 6.1 (KMI android14-6.1) within Android 15 and stays there
through Android 17. One build covers them all: `get_aoc_crcs.sh` showed
`dwc3_otg_host_ready` = 0xf76f2627 (unchanged since 5.15) and `module_layout` =
0xea759d7f in A15 BP1A.250405.007.B1, A16 CP1A.260505.005 and A17 CP3A.260905.009;
`.gnu.linkonce.this_module` = 0x440 in ours and Google's, vermagic flags match.
TWRP loads `/lib/modules/<major.minor>/` from uname, so the two builds ship side
by side: `lib/modules/5.15/` (A14) and `lib/modules/6.1/` (A15+).

    source: kernel/common tag android14-6.1-2025-09_r22 (fa1d6308d1fe = A16's kernel)
    config: extracted from A16's boot.img kernel (no 6.1 phone to pull config.gz from):
            unpack_bootimg.py -> lz4 -dc kernel > Image -> scripts/extract-ikconfig Image
    CRCs:   aoc_usb_driver.ko from **vendor_kernel_boot** (on A16+ vendor_boot only
            holds the _16k module set; vendor_dlkm has no USB modules)

    git clone --depth=1 -b android14-6.1-2025-09_r22 https://android.googlesource.com/kernel/common ~/ref/gki-6.1
    cd ~/ref/gki-6.1 && scripts/extract-ikconfig /tmp/a16boot/Image > .config
    scripts/config --disable TRIM_UNUSED_KSYMS
    # Kubuntu 26.04 glibc (C23 const strchr) breaks the host libbpf build (-Werror):
    sed -i '10741s/char \*next_path;/const char *next_path;/' tools/lib/bpf/libbpf.c
    command make ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig modules_prepare
    ./get_aoc_crcs.sh <factory zips...>        # -> /tmp/aoc/aoc-<build>.ko + CRC report
    cd device/google/shiba/otg_host_ready
    command make KDIR=$HOME/ref/gki-6.1 AOC=/tmp/aoc/aoc-cp1a.ko
    cp otg_host_ready.ko ../recovery/root/lib/modules/6.1/

## Rebuild

    # kernel tree (once per kernel version)
    git clone --depth=1 -b android14-5.15 https://android.googlesource.com/kernel/common ~/ref/gki-5.15
    cd ~/ref/gki-5.15 && git fetch --depth=1 origin <full sha of uname's -g hash> && git checkout FETCH_HEAD
    #   (full sha: git ls-remote origin 'refs/tags/android14-5.15*' | grep ^<short sha>)
    adb pull /proc/config.gz /tmp/device_config.gz; zcat /tmp/device_config.gz > .config
    scripts/config --disable TRIM_UNUSED_KSYMS
    export PATH=~/twrp/prebuilts/clang/host/linux-x86/clang-r510928/bin:$PATH
    command make ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig modules_prepare
    #   host needs: dwarves (pahole - keeps DEBUG_INFO_BTF_MODULES, part of
    #   struct module), libelf-dev (resolve_btfids)

    # module
    adb pull /lib/modules/aoc_usb_driver.ko /tmp/aoc_usb_driver.ko
    cd device/google/shiba/otg_host_ready && command make
    cp otg_host_ready.ko ../recovery/root/lib/modules/5.15/
