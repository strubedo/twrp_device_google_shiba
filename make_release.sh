#!/usr/bin/env bash
# make_release.sh - package a release of this TWRP for users:
#   dist/shiba-twrp-<version>.zip  with the TWRP recovery fragment, the universal
#   installer (install_twrp.py + vbgraft.py), the PC remote, docs, licenses,
#   and SHA256SUMS.
# Refuses unless: the tree is clean and HEAD is tagged (so the release is exactly
# a tag), the build's recovery fragment carries that same version string, and the
# fragment passes the bootloader size limit.
set -euo pipefail
cd "$(dirname "$0")"
TREE="$PWD"
TWRP_TOP="$(cd ../../.. && pwd)"
# TWRP Remote lives in the common kit (vendor/strubedo/twrp_remote), shared
# with the other device trees
KIT="$TWRP_TOP/vendor/strubedo"
REMOTE="$KIT/twrp_remote"
FRAG="$TWRP_TOP/out/target/product/shiba/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4"
MAX_FRAGMENT=46000000          # same limit as build.sh / install_twrp.py

die() { echo "make_release: $*" >&2; exit 1; }

# 1. a clean, tagged tree
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git work tree: $TREE"
STATUS="$(git status --porcelain)" || die "git status failed"
[[ -z "$STATUS" ]] || die "uncommitted changes - commit (and tag) first"
TAG="$(git describe --tags --exact-match HEAD 2>/dev/null)" || die "HEAD is not tagged - tag the release commit"
VER="${TAG%%-*}"                         # v9.34-app-installers -> v9.34
echo "== Release $VER (tag $TAG, $(git rev-parse --short HEAD))"
# the kit is part of the release too: it must be committed, and its commit is recorded
[[ -f "$REMOTE/twrp_remote.py" ]] || die "TWRP Remote not found at $REMOTE (the common kit, vendor/strubedo)"
[[ -z "$(git -C "$KIT" status --porcelain)" ]] || die "uncommitted changes in the kit ($KIT) - commit first"
KITREV="$(git -C "$KIT" rev-parse --short HEAD)"
echo "- kit (vendor/strubedo): $KITREV"

# 2. the fragment is from this build
[[ -f "$FRAG" ]] || die "no recovery fragment at $FRAG - run ./build.sh first"
[[ "$(head -c4 "$FRAG" | od -An -tx4 | tr -d ' ')" == "184c2102" ]] || die "fragment is not lz4 legacy"
SIZE="$(stat -c %s "$FRAG")"
(( SIZE <= MAX_FRAGMENT )) || die "fragment is $SIZE bytes (> $MAX_FRAGMENT won't boot)"
FRAGVER="$(lz4 -dc "$FRAG" | grep -a -o -m1 -- "-shiba-v[0-9][0-9.]*+\?" || true)"
[[ "$FRAGVER" == "-shiba-$VER" ]] \
    || die "the built fragment says '${FRAGVER:-no version}', the tag is $VER - rebuild (./build.sh) after tagging"
echo "- fragment: $SIZE bytes, version ${FRAGVER#-}"

# 3. assemble
NAME="shiba-twrp-$VER"
OUT="$TREE/dist/$NAME"
rm -rf "$OUT" "$OUT.zip"; mkdir -p "$OUT/twrp_remote" "$OUT/licenses"
cp "$FRAG" "$OUT/recovery.cpio.lz4"
cp install_twrp.py vbgraft/vbgraft.py README.md LICENSE THIRD_PARTY_NOTICES.md "$OUT/"
cp licenses/* "$OUT/licenses/"
cp "$REMOTE"/{twrp_remote.py,twrp_remote.png,install_linux.sh,build_windows.bat,install_windows.bat,install_windows.ps1,LICENSE} \
   "$OUT/twrp_remote/"
cat > "$OUT/INSTALL.txt" <<EOF
TWRP $VER for Google Pixel 8 (shiba) - unofficial

Works on any firmware: the installer grafts TWRP onto your phone's own
vendor_boot and keeps a backup of the original.

Requirements: unlocked bootloader, Android platform-tools (adb, fastboot),
Python 3 with lz4 (pip install lz4), USB debugging on.
Your vendor_boot is read from the phone if it's rooted; otherwise download the
factory image for your exact build (Settings > About phone > Build number) from
https://developers.google.com/android/images#shiba into Downloads.

  python3 install_twrp.py --dry-run     (check everything, flash nothing)
  python3 install_twrp.py               (install)

Then in TWRP: enter your PIN, Advanced > KEEP TWRP > Install to both slots.
Read README.md first (anti-rollback, backups, encryption).
EOF
( cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | sed 's|^\./||' \
    | xargs sha256sum > SHA256SUMS )
( cd "$TREE/dist" && zip -q -r "$NAME.zip" "$NAME" )
echo "- $(find "$OUT" -type f | wc -l) files"
echo "== dist/$NAME.zip ($(stat -c %s "$TREE/dist/$NAME.zip") bytes)"
sha256sum "$TREE/dist/$NAME.zip"

# 4. the flashable zip: one file for every firmware, flashed on the phone from
#    TWRP (Install), the Magisk app or the KernelSU app (flashable/install.sh
#    grafts onto the phone's own vendor_boot, both slots, verified)
VBS="$TWRP_TOP/out/target/product/shiba/system/bin/vbgraft_static"
[[ -f "$VBS" ]] || die "no vbgraft_static build - run ./build.sh (it builds vbgraft_static)"
[[ "$VBS" -nt vbgraft/vbgraft.cpp ]] || die "vbgraft_static is older than vbgraft.cpp - run ./build.sh"
file "$VBS" | grep -q 'statically linked' || die "vbgraft_static is not statically linked"
FNAME="$NAME-flashable"
FOUT="$TREE/dist/$FNAME"
rm -rf "$FOUT" "$FOUT.zip"; mkdir -p "$FOUT/META-INF/com/google/android" "$FOUT/tools"
cp flashable/update-binary flashable/updater-script "$FOUT/META-INF/com/google/android/"
cp flashable/shiba_install.sh flashable/customize.sh "$FOUT/"
# KernelSU treats any zip containing "install.sh" as a legacy module (and then
# never runs customize.sh) - make sure that name never sneaks in
[[ ! -e "$FOUT/install.sh" ]] || die "flashable zip must not contain install.sh (KernelSU legacy mode)"
sed -e "s/@VERSION@/$VER/" -e "s/@VERSIONCODE@/$(echo "${VER#v}" | tr -cd '0-9')/" flashable/module.prop.in > "$FOUT/module.prop"
echo "shiba-$VER" > "$FOUT/VERSION"
cp "$FRAG" "$FOUT/recovery.cpio.lz4"
cp "$VBS" "$FOUT/tools/vbgraft"
( cd "$FOUT" && sha256sum recovery.cpio.lz4 tools/vbgraft > SHA256SUMS && zip -q -X -r "$FOUT.zip" . )
rm -rf "$FOUT"
echo "== dist/$FNAME.zip ($(stat -c %s "$FOUT.zip") bytes) - flash from TWRP, Magisk or KernelSU"
sha256sum "$FOUT.zip"
