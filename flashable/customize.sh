# TWRP for Pixel 8 - entry point for the KernelSU app (and Magisk's module path).
# The app treats this zip as a module: we do the install here, then flag the
# "module" for removal, so nothing stays installed after the next reboot.
SKIPUNZIP=1
E="$TMPDIR/shiba_twrp_entry"
rm -rf "$E"; mkdir -p "$E"
unzip -o -q "$ZIPFILE" install.sh -d "$E" || abort "! cannot unpack install.sh"
. "$E/install.sh"
rm -rf "$E"
unzip -o -q "$ZIPFILE" module.prop -d "$MODPATH"
touch "$MODPATH/remove"
ui_print "- (this installer entry disappears at the next reboot)"
