#!/bin/sh
# Read the factory WLAN address from the phone's read-only persist partition.
set -eu

persist=/persist
iface=wlan0

. /usr/local/lib/equuleus/persist-part.sh

if [ ! -r "$persist/wlan_mac.bin" ] && [ ! -r "$persist/wlan_bt/wlan.mac" ]; then
    # by-partlabel is created asynchronously by udev; wait for it or read the
    # partition table instead of giving up and leaving a random address.
    persist_dev=$(equuleus_persist_partition) || exit 0
    persist=$(mktemp -d /run/equuleus-wlan.XXXXXXXX)
    if ! mount -t ext4 -o ro,noload "$persist_dev" "$persist"; then
        rmdir "$persist"
        exit 0
    fi
    trap 'umount "$persist" && rmdir "$persist"' EXIT
fi

if [ -r "$persist/wlan_mac.bin" ]; then
    hex=$(sed -n 's/^wlan0=//p' "$persist/wlan_mac.bin" | tr -d ' :\r\n-' | tr A-F a-f)
elif [ -r "$persist/wlan_bt/wlan.mac" ]; then
    [ "$(wc -c < "$persist/wlan_bt/wlan.mac")" -eq 6 ] || exit 0
    hex=$(od -An -tx1 "$persist/wlan_bt/wlan.mac" | tr -d ' \n')
else
    exit 0
fi

# Reject invalid, all-zero and multicast addresses.
case "$hex" in
    *[!0-9a-f]*|000000000000|?[13579bdf]*) exit 0 ;;
esac
[ "${#hex}" -eq 12 ] || exit 0
mac=$(printf '%s\n' "$hex" | sed 's/../&:/g; s/:$//')

# Keep the address available to NetworkManager even if ath10k registers wlan0
# after this service runs. Saved profiles without an explicit override use it.
install -d /run/NetworkManager/conf.d
umask 077
conf=$(mktemp /run/NetworkManager/conf.d/.equuleus-wlan.XXXXXXXX)
cat > "$conf" <<EOF
[connection-equuleus-wlan]
match-device=interface-name:$iface
wifi.cloned-mac-address=$mac
EOF
mv -f -- "$conf" /run/NetworkManager/conf.d/90-equuleus-wlan.conf

# Apply it to the link before NetworkManager starts scanning, when available.
i=0
while [ ! -e "/sys/class/net/$iface" ] && [ "$i" -lt 100 ]; do
    i=$((i + 1))
    sleep 0.1
done
if [ -e "/sys/class/net/$iface" ]; then
    ip link set dev "$iface" address "$mac" || echo 'wifi-mac: NetworkManager will apply the factory address on connection'
fi
