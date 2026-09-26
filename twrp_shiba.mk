#
# TWRP product for Google Pixel 8 (shiba, zuma / Tensor G3)
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/base.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/virtual_ab_ota/launch_with_vendor_ramdisk.mk)

# TWRP common config
$(call inherit-product, vendor/twrp/config/common.mk)

# Device
$(call inherit-product, device/google/shiba/device.mk)

PRODUCT_DEVICE := shiba
PRODUCT_NAME := twrp_shiba
PRODUCT_BRAND := google
PRODUCT_MODEL := Pixel 8
PRODUCT_MANUFACTURER := Google
