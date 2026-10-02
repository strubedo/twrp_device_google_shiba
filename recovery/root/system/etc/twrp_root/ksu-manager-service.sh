#!/system/bin/sh
# twrp_ksu_manager - one-shot root module placed by TWRP (twrp_root.sh) after
# Install KernelSU when the KernelSU manager app isn't installed yet. At the
# first Android boot it installs that app, logs the result to
# /data/adb/twrp_ksu_manager.log and removes itself.
#
# pm's output must NOT go straight into the log: pm hands its stdout/stderr to
# system_server, which may not write files in /data/adb (SELinux), and the
# binder call then fails ("Failed transaction"). Capture it in a pipe instead.
MODDIR=${0%/*}
LOG=/data/adb/twrp_ksu_manager.log
PKG=me.weishu.kernelsu

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep 5

log() { echo "$*" >> "$LOG"; }
log "$(date '+%Y-%m-%d %H:%M:%S') twrp_ksu_manager"
if pm path "$PKG" </dev/null >/dev/null 2>&1 && [ ! -f "$MODDIR/force" ]; then
    log "manager already installed - nothing to do"
else
    [ -f "$MODDIR/force" ] && log "forced reinstall (test): pm install -r keeps the app's data"
    # system_server reads the APK, so stage it where it may (shell_data_file)
    TMP=/data/local/tmp/twrp-ksu-manager.apk
    cp "$MODDIR/manager.apk" "$TMP" && chmod 644 "$TMP"
    out="$(pm install -r "$TMP" </dev/null 2>&1)"
    rc=$?
    log "$out"
    log "pm install exit $rc"
    rm -f "$TMP"
fi

rm -rf "$MODDIR"
