#!/system/bin/sh
# twrp_<tool>_app - one-shot root module placed by TWRP (twrp_root.sh,
# app_setup) after Install KernelSU / Install Magisk when that tool's app isn't
# installed yet. At the next Android boot it installs app.apk (package name in
# ./package), logs to /data/adb/twrp_app_install.log and removes itself.
# Runs under KernelSU and Magisk alike (both run modules' service.sh).
#
# pm's output must NOT go straight into the log: pm hands its stdout/stderr to
# system_server, which may not write files in /data/adb (SELinux), and the
# binder call then fails ("Failed transaction"). Capture it in a pipe instead.
MODDIR=${0%/*}
LOG=/data/adb/twrp_app_install.log
PKG="$(cat "$MODDIR/package")"

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep 5

log() { echo "${MODDIR##*/}: $*" >> "$LOG"; }   # prefixed: modules run in parallel
log "$(date '+%Y-%m-%d %H:%M:%S') $PKG"
if pm path "$PKG" </dev/null >/dev/null 2>&1 && [ ! -f "$MODDIR/force" ]; then
    log "already installed - nothing to do"
else
    [ -f "$MODDIR/force" ] && log "forced reinstall (test): pm install -r keeps the app's data"
    # system_server reads the APK, so stage it where it may (shell_data_file).
    # One file per module: root tools run modules' service.sh in parallel, and a
    # shared name let two installers overwrite each other's copy mid-install.
    TMP="/data/local/tmp/${MODDIR##*/}.apk"
    cp "$MODDIR/app.apk" "$TMP" && chmod 644 "$TMP"
    out="$(pm install -r "$TMP" </dev/null 2>&1)"
    rc=$?
    log "$out"
    log "pm install exit $rc"
    rm -f "$TMP"
fi

rm -rf "$MODDIR"
