#!/system/bin/sh
# twrp_touch_fallback.sh - touchscreen drivers when the slot's vendor_dlkm
# can't be read (damaged super, a slot whose system was released after an
# update): load a matching set bundled in the ramdisk.
#
# Run by TWRP (partitionmanager.cpp, patched) right after its own module
# loader, which takes the drivers from the slot's own vendor_dlkm - always the
# exact match for its kernel, so that stays first. This script only acts if
# the touch driver is still not loaded.
#
# Sets: /system/etc/touch_fallback/<kernel release>/ (heatmap,
# goog_touch_interface, goodix_brl_touch) from Google's factory images, one per
# kernel build. Exact `uname -r` match first; else the newest set of the same
# major.minor (a kernel module only loads into a compatible kernel - if it
# doesn't, insmod just fails and nothing changes). Dependencies (systrace,
# touch_offload, touch_bus_negotiator, the display drivers) are loaded by the
# first stage already.
#
# Log: /tmp/twrp_touch.log

LOG=/tmp/twrp_touch.log
log() { echo "$(date +%T) $*" >> "$LOG"; }
BASE=/system/etc/touch_fallback

if grep -q '^goodix_brl_touch ' /proc/modules; then
    log "touch driver already loaded - nothing to do"
    exit 0
fi

rel="$(uname -r)"
dir="$BASE/$rel"
# The trailing build number differs between a kernel and its own firmware's
# modules (seen on a Sept 2024 slot: kernel ...-ab12057991, modules
# ...-ab12076200), so an exact match is rare. The git hash (-g<hash>-) is the
# real source version: same hash = same kernel source -> prefer that set.
if [ ! -d "$dir" ]; then
    hash="$(echo "$rel" | sed -n 's/.*-\(g[0-9a-f]\{8,\}\)-.*/\1/p')"
    if [ -n "$hash" ]; then
        for d in "$BASE"/*-"$hash"-*; do
            [ -d "$d" ] && { dir="$d"; log "no exact set for kernel $rel - same source ($hash): $(basename "$d")"; break; }
        done
    fi
fi
if [ ! -d "$dir" ]; then
    mm="$(echo "$rel" | cut -d. -f1-2)"          # e.g. 6.1
    best=""; bestp=-1
    for d in "$BASE/$mm".*; do
        [ -d "$d" ] || continue
        p="$(basename "$d" | cut -d. -f3 | cut -d- -f1)"
        case "$p" in ''|*[!0-9]*) continue ;; esac
        if [ "$p" -gt "$bestp" ]; then bestp=$p; best=$d; fi
    done
    dir="$best"
    [ -n "$dir" ] && log "no set for kernel $rel - trying the closest: $(basename "$dir")"
fi
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    log "no touch driver set for kernel $rel"
    exit 0
fi

for m in heatmap goog_touch_interface goodix_brl_touch; do
    grep -q "^$m " /proc/modules && continue
    if insmod "$dir/$m.ko" 2>>"$LOG"; then
        log "loaded $m ($(basename "$dir"))"
    else
        log "FAILED to load $m from $(basename "$dir")"
        exit 0
    fi
done
log "touch driver loaded from the fallback set"
exit 0
