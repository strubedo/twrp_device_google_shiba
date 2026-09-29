#!/system/bin/sh
# twrp_mtp_guard.sh - keep ADB alive if MTP can't come up.
#
# Started (init.recovery.zuma.rc) whenever sys.usb.config becomes mtp,adb.
# The gadget is only bound once TWRP's MTP server has written its FunctionFS
# descriptors (sys.usb.ffs.mtp.ready=1). If that never happens the gadget stays
# unbound and ADB is gone too - so after 10 s without it, fall back to adb.
# Log: /tmp/twrp_mtp.log

LOG=/tmp/twrp_mtp.log
i=0
while [ $i -lt 10 ]; do
    if [ "$(getprop sys.usb.ffs.mtp.ready)" = 1 ]; then
        echo "$(date +%T) MTP ready after ${i}s - gadget bound as mtp,adb" >> "$LOG"
        exit 0
    fi
    [ "$(getprop sys.usb.config)" = "mtp,adb" ] || exit 0   # MTP was turned off meanwhile
    sleep 1
    i=$((i + 1))
done
echo "$(date +%T) MTP not ready after 10s - falling back to adb (gadget was unbound)" >> "$LOG"
setprop sys.usb.config adb
