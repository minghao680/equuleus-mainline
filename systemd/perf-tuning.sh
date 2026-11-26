#!/bin/sh
#
# Runtime performance tuning for this SoC.
#
# Two settings, both measured on the device:
#
#  1. Disable the big cluster's deep idle state (cpu-sleep, ~885 us exit
#     latency). With it enabled, wake-up latency showed up as ping jitter:
#     average RTT 1.94/1.90/2.26 ms and mdev 1.01/1.13/2.22 ms, against
#     1.19/1.16/1.17 ms and mdev 0.58/0.10/0.12 ms with it disabled. The little
#     cores keep their deep state, so idle power does not collapse.
#
#  2. Hold the UFS controller at its top gear instead of letting
#     simple_ondemand drop it to 50 MHz. Raw 200 MiB direct reads went from
#     1079 to 1335 MiB/s. Queue depth and readahead are raised to match; the
#     scheduler becomes none because mq-deadline adds latency on a device that
#     reorders internally anyway.
#
# Nothing here is destructive and every value is re-applied on boot, so the
# unit is safe to leave enabled on any equuleus.
#
set -u

CONF=/etc/equuleus/perf-tuning.conf
BIG_IDLE_DISABLE=1
UFS_TUNE=1
UFS_MIN_FREQ=200000000
UFS_SCHEDULER=none
UFS_NR_REQUESTS=32
UFS_READ_AHEAD_KB=512
[ -r "$CONF" ] && . "$CONF"

say() { printf 'perf-tuning: %s\n' "$*"; }

write() { # path value
    [ -w "$1" ] || return 1
    printf '%s\n' "$2" > "$1" 2>/dev/null
}

if [ "$BIG_IDLE_DISABLE" = 1 ]; then
    n=0
    for cpu in 4 5 6 7; do
        p=/sys/devices/system/cpu/cpu$cpu/cpuidle/state1/disable
        [ -e "$p" ] || continue
        # Only meaningful when state1 is the deep (non-WFI) state.
        name=$(cat "/sys/devices/system/cpu/cpu$cpu/cpuidle/state1/name" 2>/dev/null)
        case "$name" in
            *sleep*) write "$p" 1 && n=$((n + 1)) ;;
        esac
    done
    say "deep idle disabled on $n big-core(s)"
fi

if [ "$UFS_TUNE" = 1 ]; then
    ufs=/sys/class/devfreq/1d84000.ufshc
    if [ -d "$ufs" ]; then
        write "$ufs/min_freq" "$UFS_MIN_FREQ" && say "UFS floor ${UFS_MIN_FREQ} Hz"
    fi
    # Tune every UFS LUN block device, not just one hardcoded node.
    for dev in /sys/block/sd*/; do
        case "$(cat "$dev/device/type" 2>/dev/null)" in
            *UFS*|0) : ;;
        esac
        [ -e "$dev/queue/scheduler" ] || continue
        # Only touch devices that expose the UFS devfreq parent.
        [ -e "$dev/device/../.." ] || continue
        write "$dev/queue/scheduler" "$UFS_SCHEDULER"
        write "$dev/queue/nr_requests" "$UFS_NR_REQUESTS"
        write "$dev/queue/read_ahead_kb" "$UFS_READ_AHEAD_KB"
    done
    say "UFS queue: scheduler=$UFS_SCHEDULER nr_requests=$UFS_NR_REQUESTS read_ahead=${UFS_READ_AHEAD_KB}K"
fi

exit 0