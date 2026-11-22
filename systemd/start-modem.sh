#!/bin/sh
# Start the modem (MPSS) remoteproc.
#
# The WCN3990 Wi-Fi firmware actually runs on the modem, not on the WLAN chip:
# ath10k only waits for the WLFW QMI service to appear. qcom_q6v5_mss sets
# auto_boot = false, so unlike the ADSP the modem is never started on its own,
# and the QMI service therefore never shows up.
#
# Started from userspace rather than at probe time because remoteproc is built
# in and probes before the root filesystem is mounted, so firmware in
# /lib/firmware is not visible to it yet.

is_modem() {
    rp=$1
    # The remoteproc name is the platform device name, e.g. "4080000.remoteproc",
    # so name matching alone is not enough.
    case "$(cat "$rp/name" 2>/dev/null)" in
        *mss*|*mpss*|*modem*) return 0 ;;
    esac
    case "$(cat "$rp/device/of_node/compatible" 2>/dev/null)" in
        *mss-pil*|*mss*) return 0 ;;
    esac
    return 1
}

found=0
for rp in /sys/class/remoteproc/remoteproc*; do
    [ -e "$rp/state" ] || continue
    is_modem "$rp" || continue
    found=1
    state=$(cat "$rp/state" 2>/dev/null)
    if [ "$state" = "running" ]; then
        echo "$rp already running"
        continue
    fi
    echo "starting $rp ($(cat "$rp/name" 2>/dev/null))"
    echo start > "$rp/state" || echo "  start failed: $?"
done

[ "$found" -eq 1 ] || echo "no modem remoteproc found"
