#!/bin/sh
# Wi-Fi hotspot for equuleus, off by default.
#
#   hotspot start [wifi|mobile]   share the Wi-Fi uplink (default) or mobile data
#   hotspot stop                  tear everything down
#   hotspot status                show what is running
#
# Why the script exists instead of a NetworkManager hotspot profile: NM would
# take wlan0 down and lose the uplink it is supposed to share. The AP therefore
# lives on a second virtual interface (ap0) on the *same channel* as the STA
# connection - the WCN3990 firmware allows concurrent STA+AP only on one channel,
# and pointing the AP at another channel makes hostapd fail to start.
set -u

AP=ap0
AP_NET=192.168.50.0/24
AP_IP=192.168.50.1
TABLE=200
CONF=/etc/equuleus/hotspot.conf
HOSTAPD_CONF=/etc/hostapd/equuleus-hotspot.conf
DNSMASQ_CONF=/etc/dnsmasq.d/equuleus-hotspot.conf
HOSTAPD_PID=/run/hostapd-hotspot.pid

log() { printf '[hotspot] %s\n' "$*"; }

load_conf() {
    SSID=Equuleus-AP
    PSK=equuleus1234
    # shellcheck disable=SC1090
    [ -r "$CONF" ] && . "$CONF"
    : "${SSID:=Equuleus-AP}" "${PSK:=equuleus1234}"
}

uplink_iface() {
    case "${1:-wifi}" in
        mobile) u=$(ip -o route show default 2>/dev/null \
                   | awk '$0 ~ /dev (qmapmux|rmnet|wwan)/ {
                          for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
                       }') ;;
        *)      u=wlan0 ;;
    esac
    printf '%s' "${u:-}"
}

ensure_dnsmasq_conf() {
    if [ ! -f "$DNSMASQ_CONF" ]; then
        cat > "$DNSMASQ_CONF" <<EOF
interface=$AP
bind-dynamic
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,12h
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
EOF
    fi
}

drop_dnsmasq_conf() {
    # With the hotspot down there is no ap0; keeping a config that names it makes
    # dnsmasq log errors on every restart, so remove it again.
    rm -f "$DNSMASQ_CONF"
    systemctl restart dnsmasq 2>/dev/null || true
}

ensure_hostapd_conf() { # channel, hw_mode
    mkdir -p /etc/hostapd
    # 5 GHz needs ieee80211ac=1; without it hostapd reports "Failed to set
    # beacon parameters" and the AP never comes up.
    ac_line=""
    [ "$2" = "a" ] && ac_line="ieee80211ac=1"
    cat > "$HOSTAPD_CONF" <<EOF
interface=$AP
driver=nl80211
ssid=$SSID
hw_mode=$2
channel=$1
ieee80211n=1
$ac_line
wmm_enabled=1
wpa=2
wpa_passphrase=$PSK
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
auth_algs=1
EOF
}

start() {
    load_conf
    up=${1:-wifi}
    wan=$(uplink_iface "$up")
    if [ -z "$wan" ] || [ ! -d "/sys/class/net/$wan" ]; then
        log "no usable uplink for '$up'"; exit 1
    fi

    # The AP must sit on the channel the STA is already using.
    chan=$(iw dev wlan0 info 2>/dev/null | sed -n 's/.*channel \([0-9]*\).*/\1/p' | head -1)
    freq=$(iw dev wlan0 info 2>/dev/null | sed -n 's/.*(\([0-9]*\) MHz).*/\1/p' | head -1)
    [ -n "${chan:-}" ] || { log "wlan0 is not connected, cannot pick a channel"; exit 1; }
    if [ "${freq:-0}" -lt 3000 ] 2>/dev/null; then hw=g; else hw=a; fi
    log "uplink=$wan channel=$chan ($hw)"

    stop_quiet
    # stop_quiet removed the interface; make sure nothing stale is left behind.
    [ -d "/sys/class/net/$AP" ] && { log "failed to remove $AP"; exit 1; }

    iw dev wlan0 interface add "$AP" type __ap || { log "could not create $AP"; exit 1; }
    # hostapd has to configure the interface itself, so leave it down here.
    ip link set "$AP" down
    sleep 1
    ensure_hostapd_conf "$chan" "$hw"

    hostapd -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF" > /var/log/hostapd-hotspot.log 2>&1 || {
        log "hostapd failed, see /var/log/hostapd-hotspot.log"; tail -3 /var/log/hostapd-hotspot.log; exit 1; }
    sleep 2

    ip addr flush dev "$AP" 2>/dev/null
    ip addr add "$AP_IP/24" dev "$AP"
    ip link set "$AP" up

    ensure_dnsmasq_conf
    systemctl restart dnsmasq 2>/dev/null || true

    # Sharing mobile data needs its own routing table: without the on-link route
    # for the modem's gateway the kernel calls the default route unreachable.
    sysctl -q -w net.ipv4.ip_forward=1
    if [ "$wan" != "wlan0" ]; then
        ip rule del from "$AP_NET" lookup "$TABLE" 2>/dev/null
        ip route flush table "$TABLE" 2>/dev/null
        gw=$(ip route show default dev "$wan" 2>/dev/null | sed -n 's/.*via \([0-9.]*\).*/\1/p' | head -1)
        onlink=$(ip -4 route show dev "$wan" proto kernel scope link 2>/dev/null | head -1 | awk '{print $1}')
        [ -n "$onlink" ] && ip route add "$onlink" dev "$wan" table "$TABLE"
        [ -n "$gw" ] && ip route add default via "$gw" dev "$wan" table "$TABLE"
        ip route add "$AP_NET" dev "$AP" src "$AP_IP" table "$TABLE" 2>/dev/null
        ip rule add from "$AP_NET" lookup "$TABLE"
        for i in "$AP" "$wan"; do printf 2 > "/proc/sys/net/ipv4/conf/$i/rp_filter" 2>/dev/null; done
    fi

    iptables -t nat -C POSTROUTING -s "$AP_NET" -o "$wan" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "$AP_NET" -o "$wan" -j MASQUERADE
    iptables -C FORWARD -i "$AP" -o "$wan" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$AP" -o "$wan" -j ACCEPT
    iptables -C FORWARD -i "$wan" -o "$AP" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$wan" -o "$AP" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    log "started: ssid=$SSID channel=$chan uplink=$wan addr=$AP_IP/24"
    log "clients get 192.168.50.10-100 via DHCP; traffic is NATed to $wan"
}

stop_quiet() {
    # Kill every hostapd that belongs to this helper, including instances started
    # by hand from an older config file; a leftover hostapd keeps ap0 alive and
    # the next start fails with "AP-DISABLED".
    [ -f "$HOSTAPD_PID" ] && kill "$(cat "$HOSTAPD_PID" 2>/dev/null)" 2>/dev/null
    pkill -f 'hostapd.*(/etc/hostapd/equuleus|hotspot)' 2>/dev/null
    pkill -f "hostapd.*$AP" 2>/dev/null
    sleep 1
    rm -f "$HOSTAPD_PID"
    # Deleting through iw is what the driver expects for a virtual AP iface.
    iw dev "$AP" del 2>/dev/null
    ip link del "$AP" 2>/dev/null
    sleep 1
}

stop() {
    stop_quiet
    ip link del "$AP" 2>/dev/null
    ip rule del from "$AP_NET" lookup "$TABLE" 2>/dev/null
    ip route flush table "$TABLE" 2>/dev/null
    for wan in wlan0 $(uplink_iface mobile); do
        [ -n "${wan:-}" ] || continue
        iptables -t nat -D POSTROUTING -s "$AP_NET" -o "$wan" -j MASQUERADE 2>/dev/null
        iptables -D FORWARD -i "$AP" -o "$wan" -j ACCEPT 2>/dev/null
        iptables -D FORWARD -i "$wan" -o "$AP" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    done
    drop_dnsmasq_conf
    log "stopped"
}

status() {
    printf '[hotspot] ap0: '; ip -br addr show "$AP" 2>/dev/null || echo "absent"
    printf '[hotspot] hostapd: '; [ -f "$HOSTAPD_PID" ] && echo "running (pid $(cat "$HOSTAPD_PID"))" || echo "not running"
    printf '[hotspot] clients: '; iw dev "$AP" station dump 2>/dev/null | grep -c '^Station'
    printf '[hotspot] policy: '; ip rule show 2>/dev/null | grep -c "$TABLE"
    printf '[hotspot] uplink: '; ip -o route show default 2>/dev/null | head -2 | tr '\n' ' '; echo
}

case "${1:-status}" in
    start)  start "${2:-wifi}" ;;
    stop)   stop ;;
    status) status ;;
    *)      echo "usage: hotspot start [wifi|mobile] | stop | status" >&2; exit 2 ;;
esac