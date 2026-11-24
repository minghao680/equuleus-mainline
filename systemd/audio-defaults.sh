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
waited=0
while [ ! -r /proc/asound/card$card/pcm ]; do
    [ "$waited" -lt 60 ] || { echo 'audio-defaults: no sound card'; exit 0; }
    waited=$((waited + 1))
    sleep 1
done

if ! command -v amixer >/dev/null 2>&1; then
    echo 'audio-defaults: amixer not installed'
    exit 0
fi

# The card device appears before q6routing registers its mixer controls, and
# setting a switch that does not exist yet is a silent no-op. Wait for the
# controls themselves, not just for the card.
probe="QUAT_MI2S_RX Audio Mixer MultiMedia1"
waited=0
while [ "$waited" -lt 60 ]; do
    if amixer -c "$card" sget "$probe" >/dev/null 2>&1; then
        break
    fi
    waited=$((waited + 1))
    sleep 1
done

enabled=0
for fe in 1 2 3 4; do
    name="QUAT_MI2S_RX Audio Mixer MultiMedia$fe"
    if amixer -c "$card" sget "$name" >/dev/null 2>&1; then
        amixer -c "$card" sset "$name" on >/dev/null 2>&1 && enabled=$((enabled + 1))
    fi
done

echo "audio-defaults: enabled $enabled speaker route(s)"