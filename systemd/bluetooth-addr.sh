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

. /usr/local/lib/equuleus/persist-part.sh

if [ ! -r "$PERSIST/wlan_bt/bt.mac" ]; then
    mkdir -p "$PERSIST"
    # by-partlabel is created asynchronously by udev; wait for it or read the
    # partition table instead of skipping the address.
    persist_dev=$(equuleus_persist_partition) || persist_dev=
    if [ -n "${persist_dev:-}" ]; then
        mount -o ro -t ext4 "$persist_dev" "$PERSIST" 2>/dev/null || true
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

# Every call is bounded: btmgmt blocks indefinitely if the controller is
# unresponsive, which would leave this unit stuck in "activating" and hold up boot.
#
# The unit retries through systemd, so a run that finds the address already in
# place must succeed instead of configuring it again and looping.
# sysfs has no address attribute for hci0 in this kernel, so fall back to hciconfig.
current=$(cat "/sys/class/bluetooth/$HCI/address" 2>/dev/null | tr 'A-F' 'a-f')
if [ -z "$current" ] && command -v hciconfig >/dev/null 2>&1; then
    current=$(hciconfig "$HCI" 2>/dev/null | sed -n 's/.*BD Address: \([0-9A-Fa-f:]*\).*/\1/p' | tr 'A-F' 'a-f')
fi
want=$(printf '%s' "$addr" | tr 'A-F' 'a-f')
if [ -n "$current" ] && [ "$current" = "$want" ]; then
    echo "[bt] $HCI already uses $addr"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl try-restart bluetooth.service >/dev/null 2>&1 || \
            systemctl start bluetooth.service >/dev/null 2>&1 || true
    fi
    exit 0
fi

# The controller is not ready to accept an address for a while after hci0
# appears: on real boots every attempt during the first two minutes blocked and
# timed out, while the same call succeeded instantly a few minutes later. So this
# makes a few bounded attempts and, if they all fail, exits non-zero and lets
# systemd retry the unit instead of holding up boot.
set_ok=0
attempt=0
while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    if timeout 4 btmgmt -i "$HCI" public-addr "$addr" 2>&1 | grep -q complete; then
        set_ok=1
        break
    fi
    sleep 2
done

if [ "$set_ok" -ne 1 ]; then
    echo "[bt] controller not ready yet, asking systemd to retry"
    exit 1
fi

# power on can report "Invalid Index" until the management index exists for the
# newly configured controller, so retry that too. bluetoothd would also power the
# controller, so this is best effort.
attempt=0
while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    out=$(timeout 5 btmgmt -i "$HCI" power on 2>&1 || true)
    case "$out" in
        *complete*) break ;;
    esac
    sleep 2
done

echo "[bt] $HCI configured with $addr"

# bluetooth.service is not ordered after this unit, so start it now that an
# address exists. Without it bluetoothd gives up on the unconfigured controller.
if command -v systemctl >/dev/null 2>&1; then
    systemctl try-restart bluetooth.service >/dev/null 2>&1 || \
        systemctl start bluetooth.service >/dev/null 2>&1 || true
fi