# Out-of-tree build of otg_host_ready.ko against the exact GKI kernel source
# (android14-5.15-2024-01_r11) configured with the phone's /proc/config.gz.
#   make            -> otg_host_ready.ko
obj-m := otg_host_ready.o

KDIR  ?= $(HOME)/ref/gki-5.15
CLANG ?= $(HOME)/twrp/prebuilts/clang/host/linux-x86/clang-r510928/bin
AOC   ?= /tmp/aoc_usb_driver.ko

all: extra.symvers
	PATH=$(CLANG):$$PATH $(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 LLVM_IAS=1 \
		KBUILD_EXTRA_SYMBOLS=$(CURDIR)/extra.symvers KBUILD_MODPOST_WARN=1 modules

extra.symvers: $(AOC) gen_symvers.py
	PATH=$(CLANG):$$PATH python3 gen_symvers.py $(AOC) $@

clean:
	PATH=$(CLANG):$$PATH $(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 clean
	rm -f extra.symvers
