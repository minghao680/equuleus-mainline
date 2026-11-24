#!/bin/sh
# Locate the persist partition without assuming udev has created by-partlabel.
#
# systemd starts the address units early, and `ls /dev/disk/by-partlabel/`
# is populated asynchronously by udev. On one boot that symlink was still
# missing when wifi-mac.service was checked, so the unit was skipped and the
# controller kept a random address:
#
#   wifi-mac.service - skipped, unmet condition check
#     ConditionPathExists=/dev/disk/by-partlabel/persist
#
# Reading the partition table with lsblk does not depend on udev, so it is the
# fallback while waiting a bounded time for the preferred path.
#
# Prints the block device on success; returns non-zero when no persist
# partition exists at all.

equuleus_persist_partition() {
    waited=0
    while [ "$waited" -lt 80 ]; do
        if [ -b /dev/disk/by-partlabel/persist ]; then
            printf '%s\n' /dev/disk/by-partlabel/persist
            return 0
        fi
        dev=$(lsblk -rno PARTLABEL,NAME 2>/dev/null \
              | awk '$1 == "persist" { print "/dev/" $2; exit }')
        if [ -n "${dev:-}" ] && [ -b "$dev" ]; then
            printf '%s\n' "$dev"
            return 0
        fi
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}