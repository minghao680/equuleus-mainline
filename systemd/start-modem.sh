#!/bin/sh
# Start the modem (MPSS) remoteproc.
#
# The WCN3990 Wi-Fi firmware actually runs on the modem, not on the WLAN chip:
# ath10k only waits for the WLFW QMI service to appear. qcom_q6v5_mss sets
# auto_boot = false, so unlike the ADSP the modem is never started on its own,
# and the QMI service therefore never shows up.
#
# Started from userspace rather than at probe time for the same reason the ADSP
# is: remoteproc is built in and probes before the root filesystem is mounted,
# so firmware in /lib/firmware is not visible to it yet.

found=0
for rp in /sys/class/remoteproc/remoteproc*; do
    [ -e "$rp/state" ] || continue
    name=$(cat "$rp/name" 2>/dev/null)
    case "$name" in
        *mss*|*mpss*|*modem*)
            echo "starting $rp ($name)"
            echo start > "$rp/state" || echo "  start failed: $?"
            found=1
            ;;
    esac
done

[ "$found" -eq 1 ] || echo "no modem remoteproc found"
