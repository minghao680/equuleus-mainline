#!/bin/sh
# Enable the default playback route so aplay works without manual mixer setup.
#
# The sound card comes up with its frontends registered but no backend enabled:
#
#   MultiMedia1: ASoC: no backend DAIs enabled for MultiMedia1, possibly
#   missing ALSA mixer-based routing or UCM profile
#
# and aplay then fails with "audio open error: Invalid argument".
#
# q6routing exposes one switch per frontend/backend pair. Turning on
# QUAT_MI2S_RX for the MultiMedia frontends routes playback to the TAS2557
# speaker amplifier, which is the output this device uses. The SLIMBUS backend
# is left off: it needs the WCD9340 codec link, and enabling it makes prepare
# fail with -EINVAL and silences the speaker path.
set -eu

card=0

if ! command -v amixer >/dev/null 2>&1; then
    echo 'audio-defaults: amixer not installed'
    exit 0
fi

# The card device and the q6routing controls do not appear together: the card
# registers early, while the routing switches only exist once the ADSP services
# are up. Setting a switch that is not there yet is a silent no-op, so wait for
# the control itself rather than for the card (there is no /proc/asound/card0/pcm
# file; the entries are pcm0p and pcm0c).
probe="QUAT_MI2S_RX Audio Mixer MultiMedia1"
waited=0
until amixer -c "$card" sget "$probe" >/dev/null 2>&1; do
    if [ "$waited" -ge 180 ]; then
        echo 'audio-defaults: routing controls never appeared'
        exit 0
    fi
    sleep 2
    waited=$((waited + 2))
done

enabled=0
for fe in 1 2 3 4; do
    name="QUAT_MI2S_RX Audio Mixer MultiMedia$fe"
    if amixer -c "$card" sget "$name" >/dev/null 2>&1; then
        amixer -c "$card" sset "$name" on >/dev/null 2>&1 && enabled=$((enabled + 1))
    fi
done

echo "audio-defaults: enabled $enabled speaker route(s) after ${waited}s"