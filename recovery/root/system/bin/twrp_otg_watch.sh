#!/system/bin/sh
# twrp_otg_watch.sh - auto-mount USB OTG storage at /usb-otg when plugged in.
#
# Started by init with TWRP (init.recovery.zuma.rc, service twrp.otgwatch).
# Polls every 2 s:
#   * a USB mass-storage disk appears  -> mount it at /usb-otg, once per plug-in
#   * it disappears while mounted      -> unmount /usb-otg
# Mounting goes through TWRP itself (`twrp mount /usb-otg`, the
# openrecoveryscript command client) so TWRP's partition manager does the mount
# and refreshes the size it shows; mounting behind its back left it at 0 MB.
# If TWRP isn't listening yet (drive already in at boot) it retries for ~30 s,
# and only mounts directly if TWRP's mount can't (e.g. the disk landed on sdf
# while /usb-otg in twrp.flags expects sde1).
# If you unmount it in TWRP (safe removal), it stays unmounted until the next
# plug-in - the watcher never fights a deliberate unmount.
# The disk is found by bus (its sysfs path goes through the USB host), not by
# name. USB host itself needs otg_host_ready.ko (device/google/shiba/otg_host_ready).
#
# Log: /tmp/twrp_otg.log

MP=/usb-otg
LOG=/tmp/twrp_otg.log
log() { echo "$(date +%T) $*" >> "$LOG"; }

usb_disk() {    # first sd* block device whose sysfs path goes through USB
    for d in /sys/block/sd*; do
        [ -e "$d" ] || continue
        case "$(readlink -f "$d")" in */usb*) echo "${d##*/}"; return 0 ;; esac
    done
    return 1
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

log "watcher started"
handled=""      # disk we've finished acting on for the current plug-in
tries=0
while true; do
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
            handled=""; tries=0
        fi
    fi
    sleep 2
done
