# Out-of-tree build of otg_host_ready.ko against the exact GKI kernel source,
# configured like the phone's kernel (see README.md).
#
#   make                                  -> 5.15: CRCs from Google's aoc_usb_driver.ko ($(AOC))
#   make KDIR=~/ref/gki-6.1 SYMVERS=FILE  -> CRCs from Google's vmlinux.symvers for that
#                                            kernel build (ci.android.com, see README.md)
obj-m := otg_host_ready.o

KDIR    ?= $(HOME)/ref/gki-5.15
CLANG   ?= $(HOME)/twrp/prebuilts/clang/host/linux-x86/clang-r510928/bin
AOC     ?= /tmp/aoc_usb_driver.ko
SYMVERS ?=

ifeq ($(SYMVERS),)
EXTRA := $(CURDIR)/extra.symvers
else
EXTRA := $(SYMVERS)
endif

all: $(EXTRA)
	PATH=$(CLANG):$$PATH $(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 LLVM_IAS=1 \
		KBUILD_EXTRA_SYMBOLS="$(EXTRA)" KBUILD_MODPOST_WARN=1 modules
	# drop DWARF: it embeds build paths (/home/...) and is ~90% of the file;
	# vermagic, __versions CRCs and .gnu.linkonce.this_module are untouched
	$(CLANG)/llvm-strip --strip-debug otg_host_ready.ko

$(CURDIR)/extra.symvers: $(AOC) gen_symvers.py
	PATH=$(CLANG):$$PATH python3 gen_symvers.py $(AOC) $@

clean:
	PATH=$(CLANG):$$PATH $(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 clean
	rm -f extra.symvers
