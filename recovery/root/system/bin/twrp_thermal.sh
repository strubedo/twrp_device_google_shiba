#!/system/bin/sh
# twrp_thermal.sh - a CPU temperature governor for TWRP.
#
# Started by init with TWRP (init.recovery.zuma.rc, service twrp.thermal).
#
# Android throttles on skin temperature through Google's thermal HAL, which
# doesn't run in recovery: there only the kernel's own trip points act, the
# first (passive) one at 90 C on the big core. Long jobs - an OTA install
# (~17 min of lz4 + hashing), TWRP Remote streaming - ran the cores at
# 91-93 C (~200 F). This steps the big and mid clusters' scaling_max_freq one
# OPP down while the hottest CPU zone is at HIGH_C or more, and one OPP up
# again once it is at LOW_C or less - a cool phone keeps full speed. Never
# below FLOOR_* (TWRP stays usable; the kernel's trips still act above us).
# The little cores are left alone: they're never the hot spot.
HIGH_C=82
LOW_C=75
POLL_S=2
BIG=/sys/devices/system/cpu/cpufreq/policy8
MID=/sys/devices/system/cpu/cpufreq/policy4
FLOOR_BIG=1557000
FLOOR_MID=1328000

log() { echo "twrp_thermal: $*" > /dev/kmsg; }

ZONES=""
for z in /sys/class/thermal/thermal_zone*; do
    case "$(cat "$z/type" 2>/dev/null)" in BIG|MID|LITTLE) ZONES="$ZONES $z/temp" ;; esac
done
[ -n "$ZONES" ] || { log "no BIG/MID/LITTLE thermal zones - not running"; exit 0; }

# next_opp POLICY down|up FLOOR -> the neighbouring OPP of scaling_max_freq
# (scaling_available_frequencies is ascending), or nothing at the end/floor
next_opp() {
    cur=$(cat "$1/scaling_max_freq") out=""
    for f in $(cat "$1/scaling_available_frequencies"); do
        if [ "$2" = down ]; then
            [ "$f" -lt "$cur" ] && [ "$f" -ge "$3" ] && out=$f
        elif [ "$f" -gt "$cur" ] && [ -z "$out" ]; then
            out=$f
        fi
    done
    echo "$out"
}

log "on: step down at ${HIGH_C} C, up at ${LOW_C} C (big >= $FLOOR_BIG, mid >= $FLOOR_MID kHz)"
while :; do
    t=0
    for z in $ZONES; do
        v=$(cat "$z" 2>/dev/null) || continue
        [ "$v" -gt "$t" ] && t=$v
    done
    dir=""
    [ "$t" -ge $((HIGH_C * 1000)) ] && dir=down
    [ "$t" -le $((LOW_C * 1000)) ] && dir=up
    if [ -n "$dir" ]; then
        for p in "$BIG:$FLOOR_BIG" "$MID:$FLOOR_MID"; do
            pol=${p%%:*} floor=${p##*:}
            n=$(next_opp "$pol" "$dir" "$floor")
            [ -n "$n" ] || continue
            echo "$n" > "$pol/scaling_max_freq" \
                && log "$((t / 1000)) C: ${pol##*/} max -> $n ($dir)"
        done
    fi
    sleep "$POLL_S"
done
