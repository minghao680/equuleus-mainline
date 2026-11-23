#!/bin/sh
# Give the WCN3990 Bluetooth controller its factory address.
#
# It comes up as 00:00:00:00:00:00 and stays DOWN, so bluetoothctl reports
# "No default controller available".
#
# Two files on the persist partition hold the addresses, both 6 raw bytes:
#
#   /persist/wlan_bt/bt.mac      a4 50 46 b3 ed 3c
#   /persist/wlan_bt/wlan.mac    a4 50 46 f3 ed 3c
#
# They differ in one nibble, so do not substitute one for the other. Read at
# runtime so no device-specific value is stored in the repository.

PERSIST=/persist
HCI=hci0

if [ ! -d "$PERSIST/wlan_bt" ]; then
    mkdir -p "$PERSIST"
    if [ -b /dev/disk/by-partlabel/persist ]; then
        mount -o ro /dev/disk/by-partlabel/persist "$PERSIST" 2>/dev/null || true
    fi
fi

# Prefer the dedicated file; fall back to the older layout if present.
ADDR_FILE=""
for cand in "$PERSIST/wlan_bt/bt.mac" "$PERSIST/bluetooth/bdaddr"; do
    [ -r "$cand" ] && ADDR_FILE=$cand && break
done

if [ -z "$ADDR_FILE" ]; then
    echo "[bt] no address file found, leaving the controller at its default"
    exit 0
fi

# bt.mac is 6 raw bytes; bdaddr would be text. Handle both.
size=$(wc -c < "$ADDR_FILE" | tr -d ' ')
if [ "$size" -eq 6 ]; then
    addr=$(od -A n -t x1 "$ADDR_FILE" | tr -d ' \n' \
           | sed 's/../&:/g; s/:$//')
else
    raw=$(tr -d ' \r\n' < "$ADDR_FILE")
    addr=$(echo "$raw" | tr -d ':-' | tr 'A-F' 'a-f' | sed 's/../&:/g; s/:$//')
fi

case "$addr" in
    [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
    *) echo "[bt] unparsable address from $ADDR_FILE: $addr"; exit 0 ;;
esac

# 00:00:00:00:00:00 is what the controller reports when it has none; never
# write that back.
if [ "$addr" = "00:00:00:00:00:00" ]; then
    echo "[bt] address file is all zeroes, skipping"
    exit 0
fi

i=0
while [ "$i" -lt 50 ]; do
    [ -e "/sys/class/bluetooth/$HCI" ] && break
    i=$((i + 1))
    sleep 0.1
done
[ -e "/sys/class/bluetooth/$HCI" ] || { echo "[bt] $HCI never appeared"; exit 0; }

# The controller must be up before btmgmt can talk to it: against a DOWN controller
# btmgmt blocks indefinitely and the unit hangs in "activating", which is what
# happened on hardware. Bringing it up first, with a timeout, keeps the unit bounded.
hciconfig "$HCI" up 2>/dev/null || true

if command -v btmgmt >/dev/null 2>&1; then
    # A controller that cannot init will never accept an address; do not wait on it.
    if timeout 15 btmgmt --index 0 info >/dev/null 2>&1; then
        timeout 10 btmgmt --index 0 power off 2>/dev/null || true
        timeout 10 btmgmt --index 0 public-addr "$addr" 2>&1 | tail -2 || true
        hciconfig "$HCI" up 2>/dev/null || true
    else
        echo "[bt] $HCI did not respond to btmgmt; leaving the address alone"
        exit 0
    fi
else
    echo "[bt] btmgmt not available"
fi

echo "[bt] $HCI address set to $addr"
