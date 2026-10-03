# TWRP for Pixel 8 - entry point for the KernelSU app.
# KernelSU sources this (SKIPUNZIP=1: nothing else is extracted) with MODPATH =
# /data/adb/modules_update/<id>. We do the install here, then flag the
# "module" for removal: the flag moves with it into modules/ at the next boot,
# where KernelSU deletes it.
SKIPUNZIP=1
E="$TMPDIR/shiba_twrp_entry"
rm -rf "$E"; mkdir -p "$E"
unzip -o -q "$ZIPFILE" shiba_install.sh -d "$E" || abort "! cannot unpack shiba_install.sh"
. "$E/shiba_install.sh"
rm -rf "$E"
unzip -o -q "$ZIPFILE" module.prop -d "$MODPATH"
touch "$MODPATH/remove"
ui_print "- (this installer entry disappears at the next reboot)"
