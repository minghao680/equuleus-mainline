#!/bin/sh
#
# Raise the CPU ceiling for single-thread work (e.g. a Minecraft server).
#
# On SDM845 the big cluster's cpufreq hardware LUT contains a 2.8032 GHz entry.
# Mainline's qcom-cpufreq-hw driver reports that entry as CPUFREQ_BOOST_FREQ and
# leaves boost disabled, so the default ceiling is 2.6496 GHz. Boost alone is not
# enough: schedutil derives its next request from the current frequency, so it
# never asks for a frequency above the one it is already at and the boost OPP is
# never selected. Pairing boost with the performance governor is what actually
# reaches 2.8032 GHz.
#
# Settings live in /etc/equuleus/cpu-boost.conf.
#
set -u

CONF=/etc/equuleus/cpu-boost.conf
BOOST=1
GOVERNOR=performance
POLICIES=all
[ -r "$CONF" ] && . "$CONF"

say() {
    printf 'cpu-boost: %s\n' "$*"
}

# The cpufreq policies appear once the driver has probed; give them a moment so
# the unit cannot run before /sys/devices/system/cpu/cpufreq exists.
waited=0
while [ ! -d /sys/devices/system/cpu/cpufreq/policy0 ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
[ -d /sys/devices/system/cpu/cpufreq/policy0 ] || {
    say 'no cpufreq policies found, nothing to do'
    exit 0
}

if [ "$BOOST" = 1 ]; then
    if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 1 > /sys/devices/system/cpu/cpufreq/boost
        say "boost enabled; big cluster ceiling now $(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq 2>/dev/null) kHz"
    else
        say 'no boost control exposed by this kernel'
    fi
fi

applied=0
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue

    if [ "$POLICIES" = big ]; then
        # policy0..3 are the four Kryo silver cores, policy4..7 the gold ones.
        cpu=$(basename "$policy" | sed 's/^policy//')
        [ "$cpu" -lt 4 ] && continue
    fi

    if echo "$GOVERNOR" > "$policy/scaling_governor" 2>/dev/null; then
        applied=$((applied + 1))
        say "$(basename "$policy") governor=$GOVERNOR max=$(cat "$policy/scaling_max_freq" 2>/dev/null) kHz"
    else
        say "$(basename "$policy") could not set governor=$GOVERNOR"
    fi
done

say "applied to $applied cluster(s)"
exit 0