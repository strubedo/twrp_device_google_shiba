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
# Built from source: device/google/shiba/bootctrl = gs-common/bootctrl/aidl at
# android-14.0.0_r75 (recovery variant only; markBootSuccessful never blows the
# anti-rollback fuses in recovery). Replaces Google's prebuilt from the AP2A
# factory recovery ramdisk. libtrusty (its one dependency missing from the
# ramdisk) is built from source too.
PRODUCT_PACKAGES += \
    android.hardware.boot-service.default_recovery-pixel \
    libtrusty.recovery

# std::__libcpp_verbose_abort for Android 15+ vendor HALs (citadeld, Weaver):
# their vendors ship a newer libc++ than ours. Preloaded by init.recovery.zuma.rc.
PRODUCT_PACKAGES += \
    libshiba_cxx_compat

# Trusty secure-storage proxy for recovery, built from AOSP source with the
# SystemSuspend wakelock compiled out (patches/system_core.patch). The vendor
# storageproxyd blocks forever in acquire_wake_lock() in recovery.
PRODUCT_PACKAGES += \
    storageproxyd.recovery

# vbgraft: rebuilds a slot's vendor_boot with our recovery fragment on the
# phone ("Install TWRP to slot", e.g. after an OTA). Same tool as repack.sh
# on the host. See device/google/shiba/vbgraft.
PRODUCT_PACKAGES += \
    vbgraft.recovery \
    twrp_remote.recovery

# lptool: adds/removes/writes the small logical partition in super that holds
# the "disable encryption" init overlay (twrp_encryption.sh). See lptool/.
PRODUCT_PACKAGES += \
    lptool

# Timezone database for recovery (TWRP's clock, and `date` in scripts: without
# it every TZ-aware call prints tzdata/posixrules errors). TWRP's tzdata_twrp
# copies it into recovery as a post-install side effect, which build.sh's wipe
# of the recovery staging dir erases and Make never redoes - so copy it from
# source here instead (TW_EXCLUDE_TZDATA in BoardConfig.mk).
PRODUCT_COPY_FILES += \
    system/timezone/output_data/iana/tzdata:$(TARGET_COPY_OUT_RECOVERY)/root/system/usr/share/zoneinfo/tzdata

PRODUCT_SOONG_NAMESPACES += $(LOCAL_PATH)
