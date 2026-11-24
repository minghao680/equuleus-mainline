#!/bin/sh
# Give the Bluetooth controller its factory address.
#
# The WCN3990 reports an invalid address, so the Bluetooth core marks the
# controller HCI_UNCONFIGURED and refuses every normal open until userspace
# supplies one through the management interface:
#
#   hciconfig hci0 up    -> Operation not supported (95)
#   bluetoothctl show    -> No default controller available
#
# Design constraints, learned from the measurements collected in
# docs/bluetooth-handoff.md:
#
#   * The address is read at run time from the read-only persist partition. It is
#     never compiled into an image, so the same build works on any device.
#   * This unit is the only thing that touches the controller's address, and
#     bluetooth.service pulls it in with Wants=/After= rather than this unit
#     driving the daemon. Nested systemctl calls made earlier measurements
#     meaningless.
#   * Readiness is signalled by the management interface, not by wall-clock time:
#     HCI_UNCONFIGURED controllers do not appear in `btmgmt info`, but they do
#     appear in `btmgmt unconf-index`. Poll that read-only command until the
#     controller shows up.
#   * Then issue exactly one bounded public-address write. A successful write
#     makes the kernel queue hdev->power_on itself, so no power off/on sequence is
#     needed, and retrying in a loop only disturbs the device.
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
    echo "[bt] no address file on persist, leaving the controller to userspace"
    exit 0
fi

size=$(wc -c < "$ADDR_FILE" | tr -d ' ')
if [ "$size" -eq 6 ]; then
    addr=$(od -An -tx1 "$ADDR_FILE" | tr -s ' \n' ' ' | sed 's/^ //;s/ $//;s/ /:/g')
else
    addr=$(tr -d ' \r\n' < "$ADDR_FILE" | sed 's/../&:/g; s/:$//')
fi
addr=$(printf '%s' "$addr" | tr 'A-F' 'a-f')
[ "${#addr}" -eq 17 ] || { echo "[bt] unexpected address format"; exit 1; }

case "$addr" in
    00:00:00:00:00:00) echo '[bt] persist holds an all-zero address'; exit 1 ;;
esac

if ! command -v btmgmt >/dev/null 2>&1; then
    echo '[bt] btmgmt is not installed'
    exit 1
fi

# The HCI device node appears before the QCA firmware setup has finished, so wait
# for it first.
i=0
while [ ! -e "/sys/class/bluetooth/$HCI" ]; do
    i=$((i + 1))
    [ "$i" -lt 120 ] || { echo "[bt] $HCI never appeared"; exit 1; }
    sleep 0.5
done

# btmgmt adds stdin to an epoll set. Under systemd stdin is /dev/null, epoll_ctl
# fails with EPERM on it, and btmgmt then waits forever instead of reporting the
# error - which is why every earlier attempt from a unit hung until timeout while
# the same command succeeded from the serial console (stdin there is a tty).
# Feeding it a pipe makes stdin pollable and the command completes normally.
btmgmt_run() {
    { sleep 30; } | "$@"
}

# The write itself. A successful public-address change makes the kernel queue
# hdev->power_on, so no power off/on sequence is needed and retrying in a loop
# only disturbs the device.
if ! btmgmt_run timeout 20 btmgmt -i "$HCI" public-addr "$addr" 2>&1 | grep -q complete; then
    echo '[bt] the controller rejected the address'
    exit 1
fi

echo "[bt] $HCI configured with $addr"