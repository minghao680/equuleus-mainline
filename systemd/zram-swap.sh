#!/bin/sh
#
# zram-backed swap.
#
# The kernel already has CONFIG_ZRAM and CONFIG_ZSWAP-off, with zstd as the
# default compressor, but nothing configures the device: disksize stays 0 and
# the system runs without any swap at all. On an 8 GB headless box that means a
# memory spike takes the machine down instead of slowing it down.
#
# zram is the right kind of swap here - there is no separate swap partition on
# this device and writing to UFS would be both slower and worse for the flash.
#
# Tuning lives in /etc/equuleus/zram.conf.
#
set -u

CONF=/etc/equuleus/zram.conf
SIZE_PERCENT=50   # of MemTotal
PRIORITY=100
ALGORITHM=zstd
SWAPPINESS=150
[ -r "$CONF" ] && . "$CONF"

say() { printf 'zram-swap: %s\n' "$*"; }

DEV=/dev/zram0
SYS=/sys/block/zram0

[ -e "$SYS" ] || { say "no zram0, kernel has no zram support"; exit 0; }

# Already in use? Leave it alone.
if grep -q '^/dev/zram0 ' /proc/swaps 2>/dev/null; then
    say "zram0 already active as swap"
    exit 0
fi

mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
[ -n "${mem_kb:-}" ] || { say "cannot read MemTotal"; exit 0; }
size_bytes=$((mem_kb * 1024 * SIZE_PERCENT / 100))

if [ "$ALGORITHM" != "" ] && [ -w "$SYS/comp_algorithm" ]; then
    echo "$ALGORITHM" > "$SYS/comp_algorithm" 2>/dev/null || \
        say "compressor $ALGORITHM not available, using the default"
fi

if ! echo "$size_bytes" > "$SYS/disksize" 2>/dev/null; then
    say "could not set disksize"
    exit 0
fi

if ! mkswap "$DEV" >/dev/null 2>&1; then
    say "mkswap failed"
    exit 0
fi

if ! swapon -p "$PRIORITY" "$DEV" 2>/dev/null; then
    say "swapon failed"
    exit 0
fi

# zram compresses, so pages in swap cost far less than anonymous memory; the
# stock swappiness of 60 keeps the kernel from using it.
if [ -w /proc/sys/vm/swappiness ]; then
    echo "$SWAPPINESS" > /proc/sys/vm/swappiness
fi

# Transparent huge pages and zram swap do not mix on this kernel. With THP set
# to "always" khugepaged tries to collapse pages that live in zram, ends up
# blocked on I/O, and takes kworkers - and eventually pid 1 - into uninterruptible
# sleep; the box then reports a load of 4.00 with no CPU use and stops responding.
# That was reproduced once here. "madvise" keeps THP available for programs that
# ask for it and stops the background scanner.
THP=/sys/kernel/mm/transparent_hugepage/enabled
if [ -w "$THP" ] && ! grep -q '\[madvise\]' "$THP" 2>/dev/null; then
    echo madvise > "$THP" 2>/dev/null && say "THP switched to madvise (required with zram)"
fi
if [ -w /sys/kernel/mm/transparent_hugepage/khugepaged/defrag ]; then
    echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null
fi

say "zram0 active: $((size_bytes / 1024 / 1024)) MB, priority $PRIORITY, swappiness $(cat /proc/sys/vm/swappiness)"
exit 0