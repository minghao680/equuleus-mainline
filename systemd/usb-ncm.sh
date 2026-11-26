#!/bin/sh
#
# Add a USB network function (NCM) to the existing gadget.
#
# The initramfs builds gadget g1 with a single ACM function, which is what the
# serial console rides on. That is enough to get in, but it means the USB cable
# can only carry a terminal. Adding NCM on the same gadget gives the link a
# network interface as well, so the phone is reachable over USB at low latency
# and without Wi-Fi - useful as a fallback path and for file transfer.
#
# The function is added to the existing gadget rather than replacing it, so the
# console keeps working. Settings live in /etc/equuleus/usb-ncm.conf.
#
set -u

CONF=/etc/equuleus/usb-ncm.conf
ENABLED=1
ADDRESS=192.168.42.1
PREFIX=24
[ -r "$CONF" ] && . "$CONF"

say() { printf 'usb-ncm: %s\n' "$*"; }

[ "$ENABLED" = 1 ] || { say "disabled by config"; exit 0; }

G=/sys/kernel/config/usb_gadget/g1
UDC_DEV=a600000.usb

[ -d "$G" ] || { say "gadget g1 not present, nothing to extend"; exit 0; }

# Already there? Just make sure the interface is configured.
if [ -L "$G/configs/c.1/ncm.usb0" ]; then
    say "ncm.usb0 already linked"
else
    # The config cannot be changed while the gadget is bound to a UDC.
    if [ -s "$G/UDC" ]; then
        cur=$(cat "$G/UDC" 2>/dev/null)
        printf '\n' > "$G/UDC" 2>/dev/null
        sleep 1
    else
        cur=$UDC_DEV
    fi

    mkdir -p "$G/functions/ncm.usb0" 2>/dev/null
    ( cd "$G/configs/c.1" && ln -sf "$G/functions/ncm.usb0" ncm.usb0 ) 2>/dev/null

    if [ -L "$G/configs/c.1/ncm.usb0" ]; then
        say "ncm.usb0 added to gadget g1"
    else
        say "could not link ncm.usb0"
    fi

    printf '%s\n' "${cur:-$UDC_DEV}" > "$G/UDC" 2>/dev/null
    sleep 2
fi

# The kernel creates usb0 once the function is linked and the gadget is bound.
waited=0
while [ ! -e /sys/class/net/usb0 ] && [ "$waited" -lt 20 ]; do
    sleep 1
    waited=$((waited + 1))
done

if [ ! -e /sys/class/net/usb0 ]; then
    say "usb0 did not appear"
    exit 0
fi

# Static addressing: this is a point-to-point link to one host, so there is no
# DHCP server to talk to.
ip addr flush dev usb0 2>/dev/null
ip addr add "$ADDRESS/$PREFIX" dev usb0 2>/dev/null
ip link set usb0 up 2>/dev/null

say "usb0 up at $ADDRESS/$PREFIX (host should use the next address on that subnet)"
exit 0