#!/system/bin/sh
# twrp_otg_watch.sh - USB OTG in TWRP: switch the port to host mode when a USB
# device needs it, and auto-mount USB storage at /usb-otg.
#
# Started by init with TWRP (init.recovery.zuma.rc, service twrp.otgwatch).
#
# Why the switching: in recovery, the USB-C controller (tcpci_max77759)
# registers the port as sink-only (/sys/class/typec/port0/port_type [sink],
# read-only) - Android's USB HAL, which makes it dual-role, isn't there. So a
# flash drive is never detected by the USB-C chip. Instead, after LeeGarChat's
# zuma OTG method (OrangeFox Pixel tree, used with permission): force the
# controller's OTG ID to host and turn on 5 V for the device through the
# charger's CHARGER_MODE vote. otg_host_ready.ko supplies host_ready (the AoC
# step). Field-tested on shiba A15 (6.1): drive enumerated as sde.
#
# The USB power reading (power_supply/usb/online) means "a PC or charger" only
# while WE don't supply 5 V - in host mode it reads our own output. Hence:
#   PC mode  - gadget (adb/MTP) bound, no 5 V. USB power off for a while ->
#              nothing powers us, maybe a drive -> probe.
#   probe    - host mode for PROBE_S seconds: a USB device appears -> host;
#              nothing -> back to PC mode, next probe after a growing delay
#              (BACKOFF_MIN..BACKOFF_MAX s) to spare the battery.
#   host     - 5 V stays on while a USB device is attached (the power reading
#              is ignored); device gone -> PC mode.
# A PC or charger shows up as USB power during PC mode, so it stays there.
#
# Mounting (unchanged): a USB disk appears -> mount at /usb-otg once per
# plug-in through TWRP (`twrp mount`, so TWRP shows the right size), direct
# mount as a fallback; disk gone -> unmount. A deliberate unmount in TWRP is
# respected until the next plug-in.
#
# Log: /tmp/twrp_otg.log

MP=/usb-otg
LOG=/tmp/twrp_otg.log
log() { echo "$(date +%T) $*" >> "$LOG"; }

VBUS=/sys/class/power_supply/usb/online
OTG_ID=/sys/devices/platform/11210000.usb/dwc3_exynos_otg_id
CHG_VALUE=/sys/kernel/debug/gvotables/CHARGER_MODE/force_int_value
CHG_ACTIVE=/sys/kernel/debug/gvotables/CHARGER_MODE/force_int_active
UDC=/config/usb_gadget/g1/UDC
UDC_NAME=11210000.dwc3
PROBE_S=5           # seconds in host mode waiting for a device to appear
BACKOFF_MIN=3       # seconds without USB power before the first probe
BACKOFF_MAX=15      # longest wait between empty probes

usb_disk() {    # first sd* block device whose sysfs path goes through USB
    for d in /sys/block/sd*; do
        [ -e "$d" ] || continue
        case "$(readlink -f "$d")" in */usb*) echo "${d##*/}"; return 0 ;; esac
    done
    return 1
}

usb_device_present() {  # any device on the USB host bus (1-1, 2-1.3, ...), not root hubs
    ls /sys/bus/usb/devices/ 2>/dev/null | grep -q -E '^[0-9]+-[0-9.]+$'
}

is_mounted() { grep -q " $MP " /proc/mounts; }

direct_mount() {    # $1 = block device; fallback only
    mkdir -p "$MP"
    for fs in vfat exfat ext4 f2fs; do
        case $fs in
            vfat) opts=noatime,utf8,flush ;;
            *)    opts=noatime ;;
        esac
        if mount -t $fs -o $opts "$1" "$MP" 2>/dev/null; then
            log "mounted $1 at $MP directly ($fs) - TWRP may show 0 MB until remounted"
            return 0
        fi
    done
    log "could not mount $1 (not vfat/exfat/ext4/f2fs?)"
    return 1
}

host_on() {
    echo > "$UDC" 2>/dev/null                   # gadget off (the port can't be both)
    echo 49 > "$CHG_VALUE"; echo 1 > "$CHG_ACTIVE"   # 5 V out for the device
    echo 0 > "$OTG_ID"                           # controller -> host
}

host_off() {
    echo 0 > "$CHG_ACTIVE"                       # 5 V vote released
    echo 1 > "$OTG_ID"                           # controller -> device
    setprop sys.usb.ffs.ready 1
    echo "$UDC_NAME" > "$UDC" 2>/dev/null        # gadget back (adb/MTP)
    start adbd
}

log "watcher started"
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
roles=1
for f in "$VBUS" "$OTG_ID" "$CHG_VALUE" "$CHG_ACTIVE" "$UDC"; do
    [ -e "$f" ] || { log "role switching OFF: $f missing (mounting still works if host mode comes up by itself)"; roles=0; break; }
done
[ $roles = 1 ] && log "role switching on"

mode=pc; idle=0; backoff=$BACKOFF_MIN; t=0; gone=0
handled=""      # disk we've finished acting on for the current plug-in
tries=0
tick=0
while true; do
    # --- port role ---
    if [ $roles = 1 ]; then
        case $mode in
            pc)
                if [ "$(cat $VBUS 2>/dev/null)" = 1 ]; then
                    idle=0; backoff=$BACKOFF_MIN
                else
                    idle=$((idle + 1))
                    if [ $idle -ge $backoff ]; then
                        host_on; mode=probe; t=0
                    fi
                fi
                ;;
            probe)
                t=$((t + 1))
                if usb_device_present; then
                    mode=host; gone=0
                    log "USB device attached - host mode ($(ls /sys/bus/usb/devices/ | grep -E '^[0-9]+-[0-9.]+$' | tr '\n' ' '))"
                elif [ $t -ge $PROBE_S ]; then
                    host_off; mode=pc; idle=0
                    backoff=$((backoff * 2)); [ $backoff -gt $BACKOFF_MAX ] && backoff=$BACKOFF_MAX
                fi
                ;;
            host)
                if usb_device_present; then
                    gone=0
                else
                    gone=$((gone + 1))
                    if [ $gone -ge 2 ]; then
                        log "USB device removed - back to PC mode"
                        host_off; mode=pc; idle=0; backoff=$BACKOFF_MIN
                    fi
                fi
                ;;
        esac
    fi

    # --- storage (every 2 s, as before) ---
    tick=$((tick + 1))
    if [ $((tick % 2)) = 0 ]; then
        disk="$(usb_disk)"
        if [ -n "$disk" ]; then
            if [ "$disk" != "$handled" ]; then
                if is_mounted; then
                    handled="$disk"
                else
                    timeout 15 twrp mount "$MP" >/dev/null 2>&1
                    if is_mounted; then
                        log "TWRP mounted $MP ($disk)"
                        handled="$disk"; tries=0
                    elif [ $tries -lt 15 ]; then
                        tries=$((tries + 1))        # TWRP not ready yet - retry
                    else
                        part="/dev/block/${disk}1"
                        [ -b "$part" ] || part="/dev/block/$disk"
                        direct_mount "$part"
                        handled="$disk"; tries=0
                    fi
                fi
            fi
        else
            if [ -n "$handled" ]; then
                log "USB disk $handled removed"
                if is_mounted; then
                    timeout 10 twrp unmount "$MP" >/dev/null 2>&1
                    is_mounted && umount -l "$MP"
                    log "unmounted $MP"
                fi
                # If it was TWRP's selected storage, TWRP would keep it (an
                # unmount doesn't refresh partition details). Select Internal
                # Storage again; setting tw_storage_path makes TWRP update its
                # name, free size, backup folder and zip location itself
                # (DataManager::SetBackupFolder). Harmless if already selected.
                if [ -d /data/media/0 ]; then
                    sleep 1     # let TWRP finish the unmount command first
                    timeout 10 twrp set tw_storage_path /data/media/0 >/dev/null 2>&1 \
                        && log "storage: Internal Storage selected"
                fi
                handled=""; tries=0
            fi
        fi
    fi
    sleep 1
done
