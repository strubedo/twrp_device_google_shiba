# Android 14 -> 17 compatibility analysis (shiba)

Offline analysis, 2026-10-01 (no flashing). Goal: this TWRP working on Pixel 8
with Android 14, 15, 16 and 17. Proven so far: **Android 14 only** (incl. OTAs).

## Sources used
- Android 16 factory image CP1A.260505.005, extracted in `~/Downloads/shiba-a16/`
  (`img/` boot/vendor_boot/vendor_dlkm/vendor images, `vendor/` extracted tree).
- Android 17 factory zip `~/Downloads/shiba-cp3a.260905.009-factory-28934677.zip`
  (NOT extracted yet).
- LeeGar's OrangeFox tree `~/ref/leegar_pixels` (`docs/decrypt.en.md`): targets
  Pixel 6-11 on current Android; builds zuma with kernel **6.12** (`-k 6.12`).
- Our `patches/system_vold.patch`, `recovery.fstab`.

## Findings

### 1. /data encryption modes - unchanged (good)
A16 `vendor/etc/fstab.zuma` /data: `fileencryption=:aes-256-hctr2:inlinecrypt_optimized+wrappedkey_v0`,
`metadata_encryption=:wrappedkey_v0`, `keydirectory=/metadata/vold/metadata_encryption` -
identical to A14 (our `recovery.fstab`). A16 dropped `compress_extension=apex` (harmless).

### 2. NEW in A16: multi-device /data (`device=zoned:/dev/block/by-name/zoned_device`)
**CLOSED - not on shiba**: `/dev/block/by-name/zoned_device` does not exist on this
Pixel 8 (checked 2026-10-01), so nothing to port.
The shared zuma fstab declares a second, zoned block device for f2fs /data. Our
vold/libfstab do NOT handle this (LeeGar patched libfstab parsing of
`device=zoned:`/`exp:`/`exp_alias:`, MetadataCrypt multi-device mapping with key
subdirectories by basename, metadata timeout 30->120).
**Only matters if shiba has the partition** - check on the phone:
`adb shell ls -l /dev/block/by-name/zoned_device` (absent = nothing to do).

### 3. Lock-screen / Weaver formats - already handled in our vold patch
- packed 5-byte `.weaver` (version + slot big-endian) - parsed when size == 5
- `.weaver` names with leading zeros (`0<handle>`, `00<handle>`)
- Weaver keySize 0 -> 16 fallback (Titan M3; harmless on M2)
- AIDL Weaver + AIDL Gatekeeper
- spblob **v4 (Android 17)**: SP800-108 with HMAC-SHA512 - implemented (from
  LeeGar), **research-grade, never verified on a real A17 phone**. Highest risk.

### 4. KeyMint / HAL loading
- zuma uses the **Rust** Trusty KeyMint (v5 + RPC v3) - our A16 prep already
  covers it: libbinder_ndk NDK36 no-op export, schema-8 VINTF bind-mount
  (A16 ships schema 9; recovery libvintf max 8.0). Matches LeeGar's notes.
- A16 vendor (extracted tree) has: KeyMint V1/V3/V5 ndk, weaver-V2-ndk,
  gatekeeper-V1-ndk, `android.hardware.boot-service.default-pixel` (AIDL).
- A17: unknown - may need newer NDK symbols. Run `check_vendor_compat.py`
  against the A17 vendor tree once extracted.

### 5. Kernel - KMI and our modules (checked 2026-10-01)
| Build | Kernel | KMI |
|---|---|---|
| A14 AP2A.240905.003 | 5.15.137-android14-11 | android14-5.15 |
| A15 BP1A.250405.007.B1 (Apr 2025, QPR2) | 6.1.99-android14-11-gd7dac4b14270-ab12946699 | android14-6.1 |
| A16 CP1A.260505.005 | 6.1.145-android14-11-gfa1d6308d1fe-ab14691759 | android14-6.1 |
| A17 CP3A.260905.009 | 6.1.162-android14-11-g2ec90535fa34-ab15810641 | android14-6.1 |

- Shiba moves to the **6.1 kernel already within Android 15** and stays on the
  same KMI (`android14-6.1`) through Android 17.
- **KernelSU**: TWRP's bundled ksud (v3.3.0) supports android12-5.10 ... android14-5.15,
  **android14-6.1**, android15-6.6, android16-6.12, android17-6.18 -> covered for all.
  (The host ksud in ~/KernelSU is the old v3.2.5 without `boot-info`.)
- **otg_host_ready.ko**: built for android14-5.15 - one rebuild for **android14-6.1**
  should cover A15/16/17 (verify the vendor symbol CRC per build, as for 5.15).
- How these were read: `unpack_bootimg.py` (AOSP, in the TWRP tree) + `lz4 -dc` +
  `strings` (the A16+ kernels are LZ4-legacy compressed in boot.img).

### 6. Anti-rollback
Firmware from **May 2025 onward** raises the anti-rollback level (one-way).
A15 builds before May 2025 are safe to try; A16/A17 on the phone are one-way.

## Next steps (in order)
1. ~~Phone checks~~ DONE: no zoned_device; KMIs above; KernelSU covers all.
2. Build **otg_host_ready.ko for android14-6.1** (GKI source tag matching 6.1.x +
   vendor CRCs from the A15/A16/A17 vendor_dlkm `aoc_usb_driver.ko`).
3. Extract the A15 + A17 vendor trees; run `check_vendor_compat.py` on their
   KeyMint/Gatekeeper/Weaver/citadeld; read their fstab.zuma.
4. Android 15 BP1A.250405.007.B1 (Apr 2025, pre-anti-rollback) real-device test:
   decrypt, OTG, root, OTA path - and the first test of TWRP on the 6.1 kernel.
   Downloaded + SHA-256 verified: factory `e3f1e44d...`, OTA `1e0873e1...`.
5. Only then A16/A17 on the phone (one-way).
