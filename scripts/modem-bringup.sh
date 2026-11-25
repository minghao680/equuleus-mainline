#!/bin/sh
# Activate UIM sessions so ModemManager can use the SIM card(s).
#
# Why this exists: the modem firmware only activates a USIM application when a
# "GW provisioning" session exists for it, and it does not create that session
# on its own. ModemManager then fails with
#
#   Couldn't check unlock status: QMI operation failed: GW primary session index unknown
#
# The fix is three plain qmicli calls: bring the radio online, make sure the card
# is mapped onto logical slot 1, and activate the session WITH the application
# AID (without aid= qmicli powers the card off first, which the modem rejects
# with QMI error (3) 'Internal').
#
# Written for every card layout:
#   * no card        -> nothing to do, boot continues
#   * card in slot 1 -> normal case, usually needs no slot switch
#   * card in slot 2 -> common on this port; the card is switched onto logical 1
#   * two cards      -> primary session on logical 1 plus a best-effort secondary
#                       session on the other slot
# Every failure is logged and swallowed: a modem problem must never delay boot.
set -u

log() { printf '[modem-bringup] %s\n' "$*"; }

command -v qmicli >/dev/null 2>&1 || { log "qmicli not installed, skipping"; exit 0; }

# -----------------------------------------------------------------------------
# Wait for the QMI device.
i=0
while [ "$i" -lt 60 ]; do
    timeout 6 qmicli -d qrtr://0 --dms-get-manufacturer >/dev/null 2>&1 && break
    i=$((i + 1))
    sleep 2
done
[ "$i" -lt 60 ] || { log "modem never answered on qrtr://0"; exit 0; }

# -----------------------------------------------------------------------------
# The modem can come up in "shutting-down" mode, where the radio stays off and
# no card is scanned.
mode=$(timeout 15 qmicli -d qrtr://0 --dms-get-operating-mode 2>&1 \
       | sed -n "s/.*Mode: '\([a-z-]*\)'.*/\1/p" | head -1)
if [ "${mode:-}" != "online" ]; then
    timeout 20 qmicli -d qrtr://0 --dms-set-operating-mode=online >/dev/null 2>&1 || true
    log "operating mode ${mode:-unknown} -> online"
    sleep 2
fi

# -----------------------------------------------------------------------------
# Physical slots holding a card, and the logical slot each maps to.
# slot-status is the only reliable presence signal: get-card-status reports an
# error state even with an empty tray.
# The fields appear in the order "Physical slot N:" / "Card status:" /
# "Logical slot:", so the pair can only be printed when the logical line is
# reached - reading it at the card-status line would report the previous slot.
card_slots() {
    timeout 20 qmicli -d qrtr://0 --uim-get-slot-status 2>&1 | awk '
        /Physical slot [0-9]+:/ { p = $3; sub(":", "", p); here = 0 }
        /Card status: present/  { here = 1 }
        /Logical slot:/         { l = $3; if (here) print p ":" l }
    '
}

present=$(card_slots)
if [ -z "${present:-}" ]; then
    log "no card detected in any slot, nothing to activate"
    exit 0
fi
log "cards present (physical:logical): $(printf '%s' "$present" | tr '\n' ' ')"

# -----------------------------------------------------------------------------
# A primary GW session that already exists needs no work.
existing=$(timeout 20 qmicli -d qrtr://0 --uim-get-card-status 2>&1 \
           | sed -n '/Primary GW:/p' | head -1)
case "${existing:-}" in
    *"session doesn't exist"*|"") ;;
    *)
        log "primary GW session already exists, leaving it alone"
        exit 0
        ;;
esac

# -----------------------------------------------------------------------------
# Application AID of a slot. Retries, because the application is only reported
# a few seconds after the card is powered, and falls back to the other slot
# numbers when the caller cannot tell physical from logical.
aid_of() {
    want=$1
    n=0
    while [ "$n" -lt 10 ]; do
        aid=$(timeout 20 qmicli -d qrtr://0 --uim-get-card-status 2>&1 | awk -v want="$want" '
            /^Slot \[[0-9]+\]:/ { s = $0; gsub(/[^0-9]/, "", s); s += 0 }
            s == want && /Application ID:/ { look = 1; next }
            look && match($0, /([0-9A-Fa-f]{2}:){15}[0-9A-Fa-f]{2}/) {
                print substr($0, RSTART, RLENGTH); exit
            }
        ' | head -1)
        [ -n "${aid:-}" ] && { printf '%s\n' "$aid"; return 0; }
        # Fall back to any slot: a single card may be reported under its
        # physical number even after the logical mapping changed.
        aid=$(timeout 20 qmicli -d qrtr://0 --uim-get-card-status 2>&1 | awk '
            /Application ID:/ { look = 1; next }
            look && match($0, /([0-9A-Fa-f]{2}:){15}[0-9A-Fa-f]{2}/) {
                print substr($0, RSTART, RLENGTH); exit
            }
        ' | head -1)
        [ -n "${aid:-}" ] && { printf '%s\n' "$aid"; return 0; }
        n=$((n + 1))
        sleep 4
    done
    return 1
}

activate() { # logical-slot aid session-type
    lslot=$1; aid=$2; stype=$3
    [ -n "$aid" ] || { log "no AID for logical slot $lslot, skipping $stype"; return 0; }
    out=$(timeout 30 qmicli -d qrtr://0 --uim-change-provisioning-session=\
"session-type=$stype,activate=yes,slot=$lslot,aid=$aid" 2>&1 || true)
    case "$out" in
        *Successfully\ changed\ provisioning\ session*)
            log "$stype activated on logical slot $lslot" ;;
        *)
            log "$stype on logical slot $lslot: $(printf '%s' "$out" | head -1)" ;;
    esac
}

# -----------------------------------------------------------------------------
# Primary card: prefer one already on logical slot 1, otherwise take the first
# card and switch it onto logical slot 1.
primary_pair=$(printf '%s\n' "$present" | awk -F: '$2 == 1 { print; exit }')
[ -n "${primary_pair:-}" ] || primary_pair=$(printf '%s\n' "$present" | head -1)
pphys=$(printf '%s' "$primary_pair" | cut -d: -f1)
plogical=$(printf '%s' "$primary_pair" | cut -d: -f2)

if [ "${plogical:-1}" != "1" ]; then
    log "mapping physical slot $pphys (logical $plogical) onto logical slot 1"
    timeout 25 qmicli -d qrtr://0 --uim-switch-slot="$pphys" >/dev/null 2>&1 || true
    sleep 3
    plogical=1
fi

activate "$plogical" "$(aid_of "$plogical" || true)" primary-gw-provisioning

# -----------------------------------------------------------------------------
# A second card gets a best-effort secondary session and is never fatal.
second=$(printf '%s\n' "$present" | awk -F: -v skip="$pphys" '$1 != skip { print; exit }')
if [ -n "${second:-}" ]; then
    slogical=$(printf '%s' "$second" | cut -d: -f2)
    log "second card on logical slot $slogical"
    activate "$slogical" "$(aid_of "$slogical" || true)" secondary-gw-provisioning
fi

final=$(timeout 20 qmicli -d qrtr://0 --uim-get-card-status 2>&1 \
        | sed -n '/Primary GW:/p' | head -1 || true)
log "final primary GW: ${final:-unknown}"
exit 0