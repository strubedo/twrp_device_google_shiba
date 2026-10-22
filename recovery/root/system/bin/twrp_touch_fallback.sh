#!/system/bin/sh
# twrp_touch_fallback.sh - touchscreen drivers when the slot's vendor_dlkm
# can't be read (damaged super, a slot whose system was released after an
# update): load a matching set bundled in the ramdisk.
#
# Run by TWRP (partitionmanager.cpp, patched) right after its own module
# loader, which takes the drivers from the slot's own vendor_dlkm - always the
# exact match for its kernel, so that stays first. This script only acts if
# no touchscreen is registered yet and the touch driver is not loaded.
#
# Which modules: this phone's row in /system/etc/twrp_devices.conf (by
# androidboot.hardware), loaded in that order - the last is the driver itself
# (Pixel 8 / 8a goodix_brl_touch, 8 Pro ftm5).
#
# Sets: /system/etc/touch_fallback/<release>/ (heatmap, goog_touch_interface,
# goodix_brl_touch, ftm5 where we have it) from Google's factory images, one
# per vendor_dlkm build, named after the drivers' vermagic. FROM_BUILD names
# the factory build, KERNELS lists the `uname -r` of that build's own kernel
# (boot.img "Linux version") - not the same string: Google builds the kernel
# and the drivers separately. Order: exact `uname -r` match; a set whose
# KERNELS lists it (stock kernels); same kernel git hash; same version number;
# else the newest set of the same major.minor (custom kernels; a kernel module
# only loads into a compatible kernel - if it doesn't, insmod just fails and
# nothing changes).
# Only sets that have every module of this phone's row count (husky's ftm5 is
# not in every set). Dependencies (systrace, touch_offload,
# touch_bus_negotiator, the display drivers) are loaded by the first stage
# already.
#
# Log: /tmp/twrp_touch.log

LOG=/tmp/twrp_touch.log
log() { echo "$(date +%T) $*" >> "$LOG"; }
BASE=/system/etc/touch_fallback
DEVICES=/system/etc/twrp_devices.conf

# Touch already working: an input device with INPUT_PROP_DIRECT (bit 1 of
# "B: PROP=" in /proc/bus/input/devices; goodix_ts0 has 2, gpio_keys and the
# twrp_remote keyboard 0). Catches drivers built into a custom kernel (never in
# /proc/modules) and TWRP's second call per boot. PROP is hex, so bit 1 is set
# when the last digit is 2, 3, 6, 7, a, b, e or f. twrp_remote's virtual
# touchscreen (TV boxes only) doesn't count.
touchscreen() {
    awk '/^N: Name=/ { n = substr($0, 9) }
        /^B: PROP=/ && n !~ /twrp_remote/ && /[2367abef]$/ { print n; exit }' /proc/bus/input/devices 2>/dev/null
}
# The driver TWRP just loaded from the slot's vendor_dlkm registers its input
# device a moment later (Pixel 8, Infinity kernel: module at 2.27 s, goodix_ts0
# at 3.05 s), so give it up to 2 s before falling back. Costs nothing when
# touch comes up; a real fallback starts 2 s later.
waited=0
ts="$(touchscreen)"
while [ -z "$ts" ] && [ "$waited" -lt 10 ]; do
    sleep 0.2
    waited=$((waited + 1))
    ts="$(touchscreen)"
done
if [ -n "$ts" ]; then
    log "touch already working ($ts$([ "$waited" -gt 0 ] && echo ", after $((waited * 2))00 ms")) - nothing to do"
    exit 0
fi

hw="$(getprop ro.boot.hardware)"
mods="$(grep -v '^#' "$DEVICES" 2>/dev/null | awk -F'|' -v d="$hw" '$1 == d { print $3; exit }' | sed 's/\.ko//g')"
if [ -z "$mods" ]; then
    log "no touch modules for '$hw' in $DEVICES"
    exit 0
fi
driver="${mods##* }"
# A set counts only if it has all of this phone's modules.
has_mods() { for m in $mods; do [ -f "$1/$m.ko" ] || return 1; done; }

if grep -q "^$driver " /proc/modules; then
    log "touch driver already loaded - nothing to do"
    exit 0
fi

rel="$(uname -r)"
dir="$BASE/$rel"
has_mods "$dir" || dir=""
# Stock kernel: the set of the factory build it shipped with. Needed because
# neither the hash nor the build number has to match: CP3A.261005.005 runs
# 6.1.162-android14-11-g9dd05ae3a1de-ab16261587 with drivers
# ...-gd7a0a08e0e15-ab16261946, and the "same version" step below would take
# the September set (g622c1358585b sorts first). A new set needs its KERNELS.
if [ -z "$dir" ]; then
    for k in "$BASE"/*/KERNELS; do
        [ -f "$k" ] && grep -qxF "$rel" "$k" && has_mods "${k%/KERNELS}" &&
            { dir="${k%/KERNELS}"; log "no exact set for kernel $rel - stock kernel of $(cat "$dir/FROM_BUILD" 2>/dev/null): $(basename "$dir")"; break; }
    done
fi
# The trailing build number differs between a kernel and its own firmware's
# modules (seen on a Sept 2024 slot: kernel ...-ab12057991, modules
# ...-ab12076200), so an exact match is rare. The git hash (-g<hash>-) is the
# real source version: same hash = same kernel source -> prefer that set.
if [ -z "$dir" ]; then
    hash="$(echo "$rel" | sed -n 's/.*-\(g[0-9a-f]\{8,\}\)-.*/\1/p')"
    if [ -n "$hash" ]; then
        for d in "$BASE"/*-"$hash"-*; do
            has_mods "$d" && { dir="$d"; log "no exact set for kernel $rel - same source ($hash): $(basename "$d")"; break; }
        done
    fi
fi
if [ -z "$dir" ]; then
    # Same version number next (6.1.99): Google's own firmware pairs a kernel
    # and vendor_dlkm drivers built from different snapshots (BP1A: kernel
    # gd7dac4b14270, drivers g6da6a63a1d3d) - they still load together.
    ver="$(echo "$rel" | cut -d- -f1)"
    for d in "$BASE/$ver"-*; do
        has_mods "$d" && { dir="$d"; log "no exact set for kernel $rel - same version ($ver): $(basename "$d")"; break; }
    done
fi
if [ -z "$dir" ]; then
    mm="$(echo "$rel" | cut -d. -f1-2)"          # e.g. 6.1
    best=""; bestp=-1
    for d in "$BASE/$mm".*; do
        has_mods "$d" || continue
        p="$(basename "$d" | cut -d. -f3 | cut -d- -f1)"
        case "$p" in ''|*[!0-9]*) continue ;; esac
        if [ "$p" -gt "$bestp" ]; then bestp=$p; best=$d; fi
    done
    dir="$best"
    [ -n "$dir" ] && log "no set for kernel $rel - trying the closest: $(basename "$dir")"
fi
if [ -z "$dir" ]; then
    log "no touch driver set with $mods for kernel $rel"
    exit 0
fi

for m in $mods; do
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
