#!/bin/sh
# Bring up the modem's IPv4 data bearer and apply its IP configuration.
#
# Two properties of this modem drive the design:
#
#   * ModemManager negotiates the addresses but does not apply them. That is the
#     job of a network manager, and NetworkManager does not manage a QRTR modem,
#     so nothing ever configures the rmnet link on its own.
#   * A data call can only be torn down and re-created reliably by restarting the
#     modem: reconnecting a bearer in the same boot leaves the rmnet mux link
#     without a working downlink (uplink keeps working, ingress never arrives).
#     So this script connects ONE bearer, only if none is up, and never
#     disconnects anything.
#
# IPv6 is deliberately not requested. An "ipv4v6" or "ipv6" bearer negotiates
# addresses but the modem then delivers no usable downlink at all - not even the
# IPv4 one - so dual-stack makes data worse, not better. See
# docs/STATUS.md for the measurements.
set -u

log() { printf '[data-bringup] %s\n' "$*"; }

APN_FILE=/etc/equuleus/data-apn
APN=cmnet
[ -r "$APN_FILE" ] && APN=$(sed -n '1s/[[:space:]]*$//p' "$APN_FILE")
[ -n "${APN:-}" ] || APN=cmnet

command -v mmcli >/dev/null 2>&1 && command -v qmicli >/dev/null 2>&1 || {
    log "modem tools missing, skipping"
    exit 0
}

# Wait for ModemManager to publish a modem object.
i=0
while [ "$i" -lt 60 ]; do
    mmcli -L 2>/dev/null | grep -q Modem && break
    i=$((i + 1))
    sleep 2
done
[ "$i" -lt 60 ] || { log "ModemManager published no modem, skipping"; exit 0; }

idx=$(mmcli -L 2>/dev/null | grep -oE 'Modem/[0-9]+' | head -1 | cut -d/ -f2)
[ -n "${idx:-}" ] || { log "could not determine the modem index"; exit 0; }

# No card means nothing to connect; do not sit in the registration wait below.
if timeout 15 mmcli -m "$idx" 2>/dev/null | grep -q 'sim-missing'; then
    log "no SIM in the modem, skipping data"
    exit 0
fi

# Wait for registration: a call started too early is rejected.
i=0
while [ "$i" -lt 60 ]; do
    reg=$(timeout 10 qmicli -d qrtr://0 --nas-get-serving-system 2>/dev/null \
          | grep -oE "Registration state: '[a-z-]+'")
    case "$reg" in *"'registered'"*) break ;; esac
    i=$((i + 1))
    sleep 2
done
[ "$i" -lt 60 ] || { log "modem did not register, skipping data"; exit 0; }

# Never disturb an existing bearer: a reconnect without a modem restart breaks
# the downlink.
for b in 0 1 2 3; do
    if timeout 10 mmcli -m "$idx" -b "$b" 2>/dev/null | grep -q 'connected: yes'; then
        iface=$(timeout 10 mmcli -m "$idx" -b "$b" 2>/dev/null \
                | sed -n 's/.*interface: *\([a-z0-9._]*\).*/\1/p' | head -1)
        if [ -n "${iface:-}" ] && [ -f "/sys/class/net/$iface/uevent" ]; then
            log "bearer $b already connected on $iface, leaving it alone"
            exit 0
        fi
    fi
done

log "connecting bearer (apn=$APN, ipv4)"
out=$(timeout 90 mmcli -m "$idx" --simple-connect="apn=$APN,ip-type=ipv4" 2>&1 || true)
case "$out" in
    *successfully\ connected*) log "bearer connected" ;;
    *) log "connect failed: $(printf '%s' "$out" | head -1)"; exit 0 ;;
esac
sleep 6

# Apply the configuration of whichever bearer owns a real interface.
bid=""
iface=""
for b in 0 1 2 3; do
    out=$(timeout 10 mmcli -m "$idx" -b "$b" 2>/dev/null) || continue
    printf '%s' "$out" | grep -q 'connected: yes' || continue
    ifc=$(printf '%s' "$out" | sed -n 's/.*interface: *\([a-z0-9._]*\).*/\1/p' | head -1)
    [ -n "${ifc:-}" ] && [ -f "/sys/class/net/$ifc/uevent" ] || continue
    bid=$b; iface=$ifc; break
done
[ -n "${bid:-}" ] || { log "no bearer with an interface found"; exit 0; }

cfg=$(timeout 10 mmcli -m "$idx" -b "$bid" 2>&1)
addr=$(printf '%s' "$cfg" | sed -n 's/.*address: *\([0-9.]*\/\?[0-9]*\).*/\1/p' | head -1)
pfx=$(printf '%s' "$cfg" | sed -n 's/.*prefix: *\([0-9]*\).*/\1/p' | head -1)
gw=$(printf '%s' "$cfg" | sed -n 's/.*gateway: *\([0-9.]*\).*/\1/p' | head -1)
mtu=$(printf '%s' "$cfg" | sed -n 's/.*mtu: *\([0-9]*\).*/\1/p' | head -1)
dns=$(printf '%s' "$cfg" | sed -n 's/.*dns: *\(.*\)$/\1/p' | head -1)

[ -n "${addr:-}" ] && [ -n "${pfx:-}" ] || { log "bearer reported no address"; exit 0; }

ip link set "$iface" up
[ -n "${mtu:-}" ] && ip link set "$iface" mtu "$mtu"
ip addr replace "$addr/$pfx" dev "$iface"
[ -n "${gw:-}" ] && ip route replace default via "$gw" dev "$iface" metric 700

log "configured $iface: $addr/$pfx via ${gw:-none} mtu ${mtu:-default} dns ${dns:-none}"

# Hand the DNS servers to systemd-resolved when it is running; otherwise leave
# /etc/resolv.conf alone rather than overwriting whatever manages it.
if [ -n "${dns:-}" ] && command -v resolvectl >/dev/null 2>&1 && \
   systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    set -- $(printf '%s' "$dns" | tr ',' ' ')
    for s in "$@"; do resolvectl dns "$iface" "$s" >/dev/null 2>&1 || true; done
fi
exit 0