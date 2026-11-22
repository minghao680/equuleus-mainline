#!/bin/sh
# Apply the factory WiFi MAC address at boot.
#
# ath10k gets its permanent address from the device tree (local-mac-address) or
# from the QMI firmware. On this board neither supplies one, so it falls back to
# eth_random_addr() and logs "invalid MAC address; choosing random".
#
# The factory value lives on the device, in the persist partition, as a single
# line of text:
#
#     wlan0=a45046f3ed3c
#
# Nothing device-specific is stored here - this script only knows how to parse
# whatever that file contains. If persist is absent or unreadable it does
# nothing and the random address stays, which still works.

PERSIST=/persist
MACFILE="$PERSIST/wlan_mac.bin"
IFACE=wlan0

# The persist partition is not in fstab; mount it read-only just for this.
if [ ! -e "$MACFILE" ]; then
    mkdir -p "$PERSIST"
    if [ -b /dev/disk/by-partlabel/persist ]; then
        mount -o ro /dev/disk/by-partlabel/persist "$PERSIST" 2>/dev/null || true
    fi
fi

[ -r "$MACFILE" ] || { echo "[mac] no $MACFILE, keeping whatever ath10k chose"; exit 0; }

# Expect "wlan0=001122334455"; tolerate colons and upper case.
raw=$(tr -d ' \r\n' < "$MACFILE" | sed -n 's/^wlan0=//p')
[ -n "$raw" ] || raw=$(tr -d ' \r\n' < "$MACFILE" | sed 's/^[^=]*=//')

hex=$(echo "$raw" | tr -d ':-' | tr 'A-F' 'a-f')
case "$hex" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "[mac] unparsable MAC in $MACFILE, leaving it alone"; exit 0 ;;
esac

mac=$(echo "$hex" | sed 's/../&:/g; s/:$//')

# Wait for the interface to exist before touching it.
i=0
while [ "$i" -lt 100 ]; do
    [ -e "/sys/class/net/$IFACE" ] && break
    i=$((i + 1))
    sleep 0.1
done
[ -e "/sys/class/net/$IFACE" ] || { echo "[mac] $IFACE never appeared"; exit 0; }

ip link set "$IFACE" down 2>/dev/null || true
if ip link set "$IFACE" address "$mac"; then
    echo "[mac] $IFACE set to $mac"
else
    echo "[mac] failed to set $IFACE address"
fi
ip link set "$IFACE" up 2>/dev/null || true
