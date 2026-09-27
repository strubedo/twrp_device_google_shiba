LOCAL_PATH := device/google/shiba

# A/B
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    boot \
    init_boot \
    vendor_boot \
    vendor_kernel_boot \
    dtbo \
    vbmeta \
    vbmeta_system \
    vbmeta_vendor \
    system \
    system_ext \
    system_dlkm \
    product \
    vendor \
    vendor_dlkm

# Dynamic partitions
PRODUCT_USE_DYNAMIC_PARTITIONS := true

PRODUCT_SHIPPING_API_LEVEL := 34

# fastbootd (userspace fastboot in recovery) + the AOSP example fastboot HAL,
# built for the recovery partition. Enough for flashing logical partitions;
# slot commands also need a boot control HAL (added separately).
PRODUCT_PACKAGES += \
    fastbootd \
    android.hardware.fastboot-service.example_recovery

# servicemanager: TWRP already requires the *system* servicemanager and relinks
# it (and system libvintf) into the recovery ramdisk. Do NOT add
# servicemanager.recovery: it installs to the same path, needs the recovery
# variant of libvintf (VintfObjectRecovery), and whichever copy lands last
# wins -> "cannot locate symbol ...VintfObjectRecovery11GetInstance" and a
# crash loop. The system servicemanager must be built before vendorbootimage
# (same missing-dependency class as task_profiles.json), see build command.

# Boot control HAL (slot switching in TWRP, fastboot set_active/current-slot).
# TEMPORARY: the HAL binary, .rc and VINTF fragment in recovery/root are
# Google's prebuilts from the AP2A factory recovery ramdisk. Before publishing,
# build android.hardware.boot-service.default_recovery-pixel from
# device/google/gs-common/bootctrl/aidl instead.
# libtrusty (its only dependency missing from the ramdisk) is built from source.
PRODUCT_PACKAGES += \
    libtrusty.recovery

# Trusty secure-storage proxy for recovery, built from AOSP source with the
# SystemSuspend wakelock compiled out (patches/system_core.patch). The vendor
# storageproxyd blocks forever in acquire_wake_lock() in recovery.
PRODUCT_PACKAGES += \
    storageproxyd.recovery

# vbgraft: rebuilds a slot's vendor_boot with our recovery fragment on the
# phone ("Install TWRP to slot", e.g. after an OTA). Same tool as repack.sh
# on the host. See device/google/shiba/vbgraft.
PRODUCT_PACKAGES += \
    vbgraft.recovery

PRODUCT_SOONG_NAMESPACES += $(LOCAL_PATH)
