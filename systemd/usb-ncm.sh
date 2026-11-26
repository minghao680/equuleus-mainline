#!/bin/sh
# Configure the ACM/NCM gadget when the handset's controller has a UDC.
set -eu

CONF=/etc/equuleus/usb-ncm.conf
ENABLED=1
ADDRESS=192.168.42.1
PREFIX=24
if [ -r "$CONF" ]; then
    . "$CONF"
fi

G=/sys/kernel/config/usb_gadget/g1
UDC=a600000.usb
UDC_PATH=/sys/class/udc/$UDC
FUNC=$G/functions/ncm.usb0
LINK=$G/configs/c.1/ncm.usb0

say() { printf 'usb-ncm: %s\n' "$*"; }

# The UDC can disappear while a Type-C role change is in progress.
# Its next add event retries setup.
[ -d "$UDC_PATH" ] && [ -d "$G" ] || exit 0
current=$(cat "$G/UDC")
if [ -n "$current" ] && [ "$current" != "$UDC" ]; then
    say "gadget registered to unexpected controller $current"
    exit 1
fi

bind_gadget() {
    [ -d "$UDC_PATH" ] || return 0
    if ! printf '%s\n' "$UDC" > "$G/UDC"; then
        [ ! -d "$UDC_PATH" ] || return 1
    fi
}

if [ "$ENABLED" = 1 ] && [ ! -L "$LINK" ]; then
    # Allocate the function before touching the working ACM connection.
    mkdir -p "$FUNC"
    if [ -n "$current" ]; then
        printf '\n' > "$G/UDC"
    fi

    if ! ln -s "$FUNC" "$LINK"; then
        bind_gadget
        exit 1
    fi
    if ! bind_gadget; then
        # Restore ACM if the composite gadget could not bind.
        unlink "$LINK"
        bind_gadget
        exit 1
    fi
elif [ -z "$current" ]; then
    bind_gadget
fi

[ "$ENABLED" = 1 ] && [ -L "$LINK" ] || exit 0
[ -d "$UDC_PATH" ] || exit 0
iface=$(tr -d '\000\n' < "$FUNC/ifname")
if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface" ]; then
    say "NCM interface unavailable"
    exit 1
fi

ip address replace "$ADDRESS/$PREFIX" dev "$iface"
ip link set dev "$iface" up
say "$iface up at $ADDRESS/$PREFIX"
