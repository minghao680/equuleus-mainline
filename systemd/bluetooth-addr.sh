#!/bin/sh
# Give the WCN3990 Bluetooth controller its factory address.
#
# Why the order below matters, verified on hardware:
#
# hci_qca sets HCI_QUIRK_INVALID_BDADDR for this controller, so it comes up flagged
# HCI_UNCONFIGURED. While that flag is set, any normal open is refused:
#
#   hciconfig hci0 up        -> Can't init device hci0: Operation not supported (95)
#   bluetoothctl show        -> No default controller available
#
# The kernel only allows it to be configured through the management interface, which
# is what btmgmt talks to. `public-addr` is the call that supplies the address and
# lets the controller become a normal one; `power on` then brings it up.
#
#   btmgmt -i hci0 power off      -> "Invalid Index", expected: it is already down
#   btmgmt -i hci0 public-addr .. -> "Set Public Address complete"
#   btmgmt -i hci0 power on       -> "Set Powered complete, settings: powered br/edr"
#
# The address is six raw bytes in /persist/wlan_bt/bt.mac. Note bt.mac, not wlan.mac:
# they differ in one nibble.

PERSIST=/persist
HCI=hci0

if [ ! -d "$PERSIST/wlan_bt" ]; then
    mkdir -p "$PERSIST"
    if [ -b /dev/disk/by-partlabel/persist ]; then
        mount -o ro /dev/disk/by-partlabel/persist "$PERSIST" 2>/dev/null || true
    fi
fi

ADDR_FILE=""
for cand in "$PERSIST/wlan_bt/bt.mac" "$PERSIST/bluetooth/bdaddr"; do
    [ -r "$cand" ] && ADDR_FILE=$cand && break
done

if [ -z "$ADDR_FILE" ]; then
    echo "[bt] no address file found, leaving the controller unconfigured"
    exit 0
fi

size=$(wc -c < "$ADDR_FILE" | tr -d ' ')
if [ "$size" -eq 6 ]; then
    addr=$(od -An -tx1 "$ADDR_FILE" | tr -s ' \n' ' ' | sed 's/^ //;s/ $//;s/ /:/g')
else
    raw=$(tr -d ' \r\n' < "$ADDR_FILE")
    addr=$(echo "$raw" | tr -d ':-' | tr 'A-F' 'a-f' | sed 's/../&:/g; s/:$//')
fi

case "$addr" in
    [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
    *) echo "[bt] unparsable address from $ADDR_FILE: $addr"; exit 0 ;;
esac

if [ "$addr" = "00:00:00:00:00:00" ]; then
    echo "[bt] address file is all zeroes, skipping"
    exit 0
fi

i=0
while [ "$i" -lt 100 ]; do
    [ -e "/sys/class/bluetooth/$HCI" ] && break
    i=$((i + 1))
    sleep 0.1
done
[ -e "/sys/class/bluetooth/$HCI" ] || { echo "[bt] $HCI never appeared"; exit 0; }

if ! command -v btmgmt >/dev/null 2>&1; then
    echo "[bt] btmgmt not installed"
    exit 0
fi

# Every call is bounded: btmgmt blocks indefinitely if the controller is unresponsive,
# which would leave this unit stuck in "activating" and hold up the boot.
timeout 5 btmgmt -i "$HCI" power off >/dev/null 2>&1 || true
timeout 10 btmgmt -i "$HCI" public-addr "$addr" 2>&1 | grep -q complete || {
    echo "[bt] could not set the address on $HCI"
    exit 0
}
timeout 10 btmgmt -i "$HCI" power on >/dev/null 2>&1 || true

echo "[bt] $HCI configured with $addr"