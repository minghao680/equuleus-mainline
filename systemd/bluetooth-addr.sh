#!/bin/sh
# Give the Bluetooth controller its factory address.
#
# The WCN3990 comes up as HCI_UNCONFIGURED because hci_qca marks the address
# invalid, so every normal open is refused until userspace supplies one:
#
#   hciconfig hci0 up    -> Operation not supported (95)
#   bluetoothctl show    -> No default controller available
#
# Measured behaviour on this device, which shaped this design:
#   * btmgmt only accepts the address many minutes after hci0 appears.
#   * A single attempt after a quiet period succeeds; a loop that retries every
#     few seconds failed for 900-1000 s straight, and btmgmt blocking inside the
#     loop appears to be what keeps the controller from finishing setup.
#   * bluetoothd must not be running while the address changes: with it active
#     the call blocks, and stopping it makes the next call return "complete".
#
# So this makes at most one attempt per invocation, and a timer invokes it again
# every ten minutes. Nothing here blocks the boot.
set -eu

PERSIST=/persist
HCI=hci0

. /usr/local/lib/equuleus/persist-part.sh

if [ ! -r "$PERSIST/wlan_bt/bt.mac" ]; then
    mkdir -p "$PERSIST"
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
    addr=$(tr -d ' \r\n' < "$ADDR_FILE" | sed 's/../&:/g; s/:$//')
fi
addr=$(printf '%s' "$addr" | tr 'A-F' 'a-f')
[ "${#addr}" -eq 17 ] || { echo "[bt] unexpected address format: $addr"; exit 0; }

i=0
while [ ! -e "/sys/class/bluetooth/$HCI" ]; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || { echo "[bt] $HCI never appeared"; exit 0; }
    sleep 0.5
done

if ! command -v btmgmt >/dev/null 2>&1; then
    echo '[bt] btmgmt not installed'
    exit 0
fi

# sysfs has no address attribute for hci0 in this kernel, so use hciconfig.
current=$(cat "/sys/class/bluetooth/$HCI/address" 2>/dev/null | tr 'A-F' 'a-f')
if [ -z "$current" ] && command -v hciconfig >/dev/null 2>&1; then
    current=$(hciconfig "$HCI" 2>/dev/null | sed -n 's/.*BD Address: \([0-9A-Fa-f:]*\).*/\1/p' | tr 'A-F' 'a-f')
fi

if [ -n "$current" ] && [ "$current" = "$addr" ]; then
    # Already applied; make sure the daemon that consumes it is running.
    if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet bluetooth.service; then
        systemctl start bluetooth.service >/dev/null 2>&1 || true
    fi
    exit 0
fi

# The controller only accepts an address after it has been opened at least once,
# and it is bluetoothd that opens it: with bluetoothd never running, btmgmt has no
# management index at all ("Index list with 0 items") and every public-addr call
# blocks until it is killed. Starting the daemon powers the controller, stopping it
# hands the device back, and the address then applies immediately. Measured:
#
#   systemctl start bluetooth.service   -> bt active
#   systemctl stop  bluetooth.service
#   btmgmt -i hci0 public-addr ...      -> hci0 Set Public Address complete
#   btmgmt -i hci0 power on             -> hci0 Set Powered complete  -> UP RUNNING
#
# bluetoothd exits on its own while the controller is unconfigured, so the start
# is expected to "fail" from systemd's point of view while still doing the work.
# Starting the daemon is what opens the controller, and it must actually reach
# "active" before it is stopped again: stopping too early leaves the controller
# unpowered, btmgmt then has no management index and every call blocks. The start
# job itself has to be issued without blocking, otherwise systemd waits for
# bluetoothd to give up and holds this unit in "activating" for a minute or more.
if command -v systemctl >/dev/null 2>&1; then
    systemctl start --no-block bluetooth.service >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 30 ]; do
        systemctl is-active --quiet bluetooth.service && break
        i=$((i + 1))
        sleep 1
    done
    # Give the daemon a moment to run its initial power-on after going active.
    sleep 5
    systemctl stop --no-block bluetooth.service >/dev/null 2>&1 || true
    sleep 3
fi

if ! timeout 15 btmgmt -i "$HCI" public-addr "$addr" 2>&1 | grep -q complete; then
    # Expected before the controller has settled; the timer comes back.
    echo '[bt] controller not ready, will retry on the next timer tick'
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start bluetooth.service >/dev/null 2>&1 || true
    fi
    exit 0
fi

attempt=0
while [ "$attempt" -lt 10 ]; do
    attempt=$((attempt + 1))
    timeout 5 btmgmt -i "$HCI" power on >/dev/null 2>&1 && break
    sleep 2
done

echo "[bt] $HCI configured with $addr"

if command -v systemctl >/dev/null 2>&1; then
    systemctl start bluetooth.service >/dev/null 2>&1 || true
fi