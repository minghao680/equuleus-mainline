#!/bin/sh
# Enable the default playback and capture routes so aplay/arecord work without
# manual mixer setup.
#
# The sound card comes up with its frontends registered but no backend enabled:
#
#   MultiMedia1: ASoC: no backend DAIs enabled for MultiMedia1, possibly
#   missing ALSA mixer-based routing or UCM profile
#
# and aplay/arecord then fail with "audio open error: Invalid argument", or with
# EIO from pcm_write/pcm_read once half a route exists.
#
# q6routing exposes one switch per frontend/backend pair. Playback is routed
# through QUAT_MI2S_RX to the TAS2557 speaker amplifier. The SLIMBUS playback
# backend is left off on purpose: it needs the WCD9340 codec link, and enabling
# it makes prepare fail with -EINVAL and silences the speaker path.
#
# Capture uses the reverse pairs, "MultiMediaN Mixer SLIMBUS_0_TX". The
# microphone itself is analog on this board: the DMIC path records digital
# silence, while AMIC1 carries the signal. The codec chain is
#
#   AMIC1 -> ADC1 -> DEC0 -> CDC_IF TX0 -> AIF1_CAP -> SLIMBUS_0_TX
#
# Controls are addressed by name, not by numid: numids are assigned in
# registration order and are not guaranteed to survive a kernel change.
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

# Capture: connect the codec's capture backend to a frontend that playback does
# NOT use. A frontend cannot carry both directions at once - with the capture
# switch on MultiMedia1 as well, the DSP refuses playback routing and aplay
# fails with EIO. MultiMedia1 therefore stays playback-only and capture lives on
# MultiMedia2:
#
#   arecord -D hw:0,1 ...
cap=0
for fe in 2 3 4; do
    name="MultiMedia$fe Mixer SLIMBUS_0_TX"
    if amixer -c "$card" sget "$name" >/dev/null 2>&1; then
        amixer -c "$card" sset "$name" on >/dev/null 2>&1 && cap=$((cap + 1))
    fi
done

# Always succeed: a missing control must not abort the unit under set -e.
set_ctl() { # name value
    amixer -c "$card" sset "$1" "$2" >/dev/null 2>&1 || true
}

set_ctl 'ADC MUX0' 'AMIC'      # ADC0 input: analog, not DMIC
set_ctl 'AMIC MUX0' 'ADC1'     # ADC1 carries AMIC1
set_ctl 'ADC1 Volume' '90%'
set_ctl 'DEC0 Volume' '100%'
set_ctl 'CDC_IF TX0 MUX' 'DEC0'
set_ctl 'AIF1_CAP Mixer SLIM TX0' 'on'

echo "audio-defaults: enabled $cap capture route(s)"

if arecord -D "hw:$card,1" -f S16_LE -r 48000 -c 2 -d 1 /tmp/audio-defaults-probe.wav >/dev/null 2>&1; then
    echo 'audio-defaults: capture verified on hw:0,1 (AMIC1)'
else
    echo 'audio-defaults: capture did not open'
fi
rm -f /tmp/audio-defaults-probe.wav