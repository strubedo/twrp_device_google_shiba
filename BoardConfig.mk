#
# BoardConfig for TWRP on Google Pixel 8 (shiba, zuma / Tensor G3)
#
# v1 approach: build the recovery ramdisk only, then repack vendor_boot by hand
# with mkbootimg using the FACTORY vendor_ramdisk00 (platform fragment), the stock
# vendor cmdline/bootconfig, and our ramdisk as the "recovery" fragment.
# The vendor_boot.img the build produces is NOT flashed.
#

DEVICE_PATH := device/google/shiba

# Architecture (64-bit only userspace)
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a-dotprod
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a55
TARGET_IS_64_BIT := true
TARGET_SUPPORTS_64_BIT_APPS := true

# Platform
TARGET_BOARD_PLATFORM := zuma
TARGET_BOOTLOADER_BOARD_NAME := shiba
TARGET_NO_BOOTLOADER := true
TARGET_NO_RADIOIMAGE := true

# Kernel: none. On zuma the kernel lives in boot and the DTB/modules in
# vendor_kernel_boot; vendor_boot carries neither. TARGET_NO_KERNEL also skips
# vendor/twrp/build/tasks/kernel.mk, whose twrp-depmod hook breaks the build when
# TW_LOAD_VENDOR_MODULES is combined with TARGET_PREBUILT_KERNEL.
TARGET_NO_KERNEL := true
BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE := true

# Boot image layout (from stock vendor_boot, header v4)
BOARD_BOOT_HEADER_VERSION := 4
BOARD_KERNEL_BASE := 0x00000000
BOARD_KERNEL_PAGESIZE := 2048
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)
BOARD_MKBOOTIMG_ARGS += --kernel_offset 0x01008000
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset 0x02000000
BOARD_MKBOOTIMG_ARGS += --tags_offset 0x01000100
BOARD_RAMDISK_USE_LZ4 := true

# Stock vendor cmdline minus dyndbg="..." (quoting) and the trailing "bootconfig"
# token. Only affects the build's own vendor_boot, which we don't flash.
BOARD_KERNEL_CMDLINE := earlycon=exynos4210,0x10A00000 console=ttySAC0,115200 androidboot.console=ttySAC0 printk.devkmsg=on swiotlb=noforce cma_sysfs.experimental=Y cgroup_disable=memory rcupdate.rcu_expedited=1 androidboot.usbcontroller=11210000.dwc3 rcu_nocbs=all stack_depot_disable=off page_pinner=on swiotlb=1024 disable_dma32=on at24.write_timeout=100 log_buf_len=1024K
BOARD_BOOTCONFIG := \
    androidboot.usbcontroller=11210000.dwc3 \
    androidboot.boot_devices=13200000.ufs \
    androidboot.load_modules_parallel=true

# Recovery lives in vendor_boot as the "recovery" ramdisk fragment
BOARD_USES_RECOVERY_AS_BOOT := false
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 67108864

# Partitions / filesystems
BOARD_USES_METADATA_PARTITION := true
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_VENDOR_DLKM := vendor_dlkm
TARGET_COPY_OUT_SYSTEM_DLKM := system_dlkm

# All logical partitions are ext4 on AP2A.240605.024 (per stock fstab.zuma)
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDOR_DLKMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_DLKMIMAGE_FILE_SYSTEM_TYPE := ext4

# AVB: unlocked bootloader tolerates the modified vendor_boot; don't sign
BOARD_AVB_ENABLE := false

# Recovery
BOARD_VENDOR_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery.fstab
# Pixel format: ABGR_8888, same as stock shiba recovery and LeeGarChat's
# OrangeFox tree (github.com/leegarchat/twrp_device_google_pixels). Upstream
# TWRP also swaps R/B for RECOVERY_ABGR in minuitwrp graphics.cpp (gr_color)
# and resources.cpp (png_set_bgr + row copy); on Mali Pixels (zuma) that swap
# must be removed, so this tree carries that 3-line patch to bootable/recovery.
# Without it: yellow header. Other formats tried: RGBX orange, BGRA
# blue/purple, FORCE RGBA pink/red.
TARGET_RECOVERY_PIXEL_FORMAT := ABGR_8888
TARGET_USES_MKE2FS := true
RECOVERY_SDCARD_ON_DATA := true

# Anti-rollback (irrelevant until decryption, kept so it's ready)
# These build-time values are only fallbacks. TW_OVERRIDE_SYSTEM_PROPS below
# replaces the SPL props with the INSTALLED system/vendor values at startup,
# and runatboot.sh refuses to start KeyMint unless they match exactly
# (a 2099 SPL at KeyMint start could upgrade /data keys past Android's SPL).
PLATFORM_VERSION := 99.87.36
PLATFORM_VERSION_LAST_STABLE := $(PLATFORM_VERSION)
PLATFORM_SECURITY_PATCH := 2099-12-31
VENDOR_SECURITY_PATCH := $(PLATFORM_SECURITY_PATCH)
BOOT_SECURITY_PATCH := $(PLATFORM_SECURITY_PATCH)

# Build-system relaxations for the minimal manifest
BUILD_BROKEN_DUP_RULES := true
BUILD_BROKEN_MISSING_REQUIRED_MODULES := true
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true

# TWRP
TW_THEME := portrait_hdpi
# Set by build.sh from the latest device-tree git tag (v9.9-* -> shiba-v9.9,
# `+` when there are changes since the tag). Plain `m` builds show shiba-dev.
TW_DEVICE_VERSION := $(if $(SHIBA_VERSION),$(SHIBA_VERSION),shiba-dev)
TW_BRIGHTNESS_PATH := "/sys/class/backlight/panel0-backlight/brightness"
TW_MAX_BRIGHTNESS := 3827
TW_DEFAULT_BRIGHTNESS := 1500
TW_CUSTOM_BATTERY_PATH := "/sys/class/power_supply/battery"
TW_EXTRA_LANGUAGES := false
TW_USE_TOOLBOX := true
TW_INCLUDE_RESETPROP := true
TW_INCLUDE_LIBRESETPROP := true
TW_INCLUDE_REPACKTOOLS := true
TW_INCLUDE_LPTOOLS := true
TW_INCLUDE_BASH := true
TW_INCLUDE_FASTBOOTD := true

# Decryption prerequisite: take the security patch levels from the installed
# system (/system_root) and vendor partitions before runatboot.sh runs.
TW_OVERRIDE_SYSTEM_PROPS := "ro.build.version.security_patch;ro.vendor.build.security_patch"
TW_OVERRIDE_PROPS_ADDITIONAL_PARTITIONS := vendor
# resetprop: twrp_crypto_start.sh sets the SPL props itself, because TWRP's
# metadata unlock (Decrypt_Data, from Setup_Fstab_Partitions) runs BEFORE
# TW_OVERRIDE_SYSTEM_PROPS is applied.
TW_INCLUDE_RESETPROP := true

# Decryption stage 3: TWRP's crypto stack (vold, keystore2, decrypt UI).
# FBE (fileencryption=...wrappedkey_v0) + metadata encryption
# (metadata_encryption=:wrappedkey_v0), fscrypt policy v2 - same flags as
# LeeGarChat's working OrangeFox tree for zuma.
TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true
TW_INCLUDE_FBE_METADATA_DECRYPT := true
TW_USE_FSCRYPT_POLICY := 2

# Shared libraries the crypto stack links against that TWRP's relink list
# doesn't copy into the ramdisk (Android 14 names: KeyMint V3, keystore2 V4,
# RKP V3). Found by check_libs.py; without them recovery and keystore2 fail
# with CANNOT LINK EXECUTABLE. check_libs.py also runs as a build.sh gate.
SHIBA_CRYPTO_LIBS := \
    android.hardware.confirmationui-V1-ndk \
    android.hardware.gatekeeper-V1-ndk \
    android.hardware.security.keymint-V3-ndk \
    android.hardware.security.rkp-V3-ndk \
    android.hardware.weaver-V2-ndk \
    android.security.aaid_aidl-cpp \
    android.system.keystore2-V4-ndk \
    android.system.suspend-V1-ndk \
    lib_android_keymaster_keymint_utils \
    libsysutils
TARGET_RECOVERY_DEVICE_MODULES += $(SHIBA_CRYPTO_LIBS)
TW_RECOVERY_ADDITIONAL_RELINK_LIBRARY_FILES += \
    $(foreach lib,$(SHIBA_CRYPTO_LIBS),$(TARGET_OUT_SHARED_LIBRARIES)/$(lib).so)

# service: query servicemanager from scripts (twrp_crypto_start.sh verifies
# IWeaver registered). Its vndbinder twin vndservice is a vendor tool - the
# script uses the phone's own /vendor/bin/vndservice (real /vendor is mounted).
TARGET_RECOVERY_DEVICE_MODULES += service
TW_RECOVERY_ADDITIONAL_RELINK_BINARY_FILES += \
    $(TARGET_OUT_EXECUTABLES)/service

# Fallback decryption (no /vendor needed - damaged super, missing slot, vendor
# ABI break): AOSP's Trusty KeyMint built from source
# (system/core/trusty/keymint), copied to the ramdisk as
# /system/bin/android.hardware.security.keymint-service.rust.trusty. Needs only
# liblog, libbinder_ndk, libc. Weaver comes from recovery-tensor-daemon
# (device.mk); twrp_crypto_start.sh picks the vendor path first.
TARGET_RECOVERY_DEVICE_MODULES += android.hardware.security.keymint-service.rust.trusty
TW_RECOVERY_ADDITIONAL_RELINK_BINARY_FILES += \
    $(TARGET_OUT_VENDOR_EXECUTABLES)/hw/android.hardware.security.keymint-service.rust.trusty
# Same for Gatekeeper (Trusty TA client, system/core/trusty/gatekeeper): our
# decrypt flow needs its auth token for the synthetic-password key.
TARGET_RECOVERY_DEVICE_MODULES += android.hardware.gatekeeper-service.trusty
TW_RECOVERY_ADDITIONAL_RELINK_BINARY_FILES += \
    $(TARGET_OUT_VENDOR_EXECUTABLES)/hw/android.hardware.gatekeeper-service.trusty
TW_EXCLUDE_APEX := true
# The official TWRP app can't be installed here (it installs to /system, which
# is read-only with dm-verity on Pixel 8), only knows official devices, and its
# "flash TWRP" assumes boot/recovery partitions. Our "TWRP: Install to other
# slot" (twrp_install_slot.sh) covers that job. Also removes the reboot prompt.
TW_EXCLUDE_TWRPAPP := true
# Timezone data comes from device.mk (PRODUCT_COPY_FILES) instead of TWRP's
# tzdata_twrp, whose post-install copy is lost when build.sh wipes staging.
TW_EXCLUDE_TZDATA := true
TW_NO_SCREEN_BLANK := true
TW_NO_HAPTICS := true
# MTP over FunctionFS: init.recovery.zuma.rc adds the configfs mtp,adb rule
# TWRP lacks (ffs.mtp + ffs.adb, bound once both servers are ready) and a
# guard that falls back to adb if MTP isn't ready in 10 s.
# (Previously excluded: without that rule, enabling MTP unbound the gadget.)

# Touch: Goodix BRL chain from vendor_dlkm (first stage already has
# touch_offload, touch_bus_negotiator, systrace).
# Primary source: ramdisk copies in /lib/modules/5.15 (checked because of
# TW_LOAD_VENDOR_BOOT_MODULES). Fallback: the mounted vendor_dlkm, which always
# matches the installed kernel.
TW_LOAD_VENDOR_MODULES := "heatmap.ko goog_touch_interface.ko goodix_brl_touch.ko otg_host_ready.ko"
TW_LOAD_VENDOR_BOOT_MODULES := true
