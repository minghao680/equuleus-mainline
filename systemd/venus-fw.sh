#!/bin/sh
#
# Install the hardware video codec firmware from the phone's own modem partition.
#
# The Venus block needs a firmware image that TrustZone accepts. linux-firmware
# ships a generic `qcom/venus-5.2/venus.mbn`, but this handset boots with
# `androidboot.secureboot=1`, so the PAS authentication step rejects anything
# that is not signed for this device - the generic blob fails with -EINVAL and
# the codec never probes. Xiaomi ships the signed image on the modem partition
# instead, so this reads it from there. Nothing is redistributed.
#
# The layout matters. ath10k-style single-file firmware does not work here:
# qcom_mdt_load() takes the file named by the driver as the ELF header and then
# loads each segment from a sibling file whose name is that path with the last
# three characters replaced by "b%02d":
#
#   qcom/venus-5.2/venus.mbn   (the MDT header, renamed)
#   qcom/venus-5.2/venus.b02   segment 2, exactly p_filesz bytes
#   qcom/venus-5.2/venus.b03   segment 3
#   ...
#
# The vendor partition stores the same thing as venus.mdt + venus.bNN, so the
# only transformation needed is renaming .mdt to .mbn.
#
set -u

FW_DIR=/lib/firmware/qcom/venus-5.2
TARGET="$FW_DIR/venus.mbn"
MNT=/run/equuleus-venus-fw
PLAT_DEV=aa00000.video-codec
PLAT_DRV=/sys/bus/platform/drivers/qcom-venus

say() { printf 'venus-fw: %s\n' "$*"; }

# Already installed and the driver is happy? Nothing to do.
if [ -f "$TARGET" ] && [ -e "/sys/class/video4linux/video12" ]; then
    say "already installed"
    exit 0
fi

part=
for u in /sys/class/block/*/uevent; do
    grep -q '^PARTNAME=modem$' "$u" 2>/dev/null || continue
    part=/dev/$(basename "$(dirname "$u")")
    break
done
if [ -z "$part" ]; then
    say "no partition named 'modem', leaving Venus alone"
    exit 0
fi

mkdir -p "$MNT" "$FW_DIR"
if ! mount -o ro "$part" "$MNT" 2>/dev/null; then
    say "cannot mount $part read-only"
    exit 0
fi

src_mdt="$MNT/image/venus.mdt"
if [ ! -s "$src_mdt" ]; then
    say "$src_mdt not found"
    umount "$MNT" 2>/dev/null
    exit 0
fi

# Clear any half-installed set first, so a stale segment cannot be paired with a
# new header.
rm -f "$FW_DIR"/venus.b?? "$FW_DIR"/venus.mbn 2>/dev/null

cp "$src_mdt" "$TARGET" || { say "copy of venus.mdt failed"; umount "$MNT" 2>/dev/null; exit 0; }

copied=0
for f in "$MNT"/image/venus.b??; do
    [ -f "$f" ] || continue
    cp "$f" "$FW_DIR/$(basename "$f")" && copied=$((copied + 1))
done
umount "$MNT" 2>/dev/null

say "installed venus.mbn ($(wc -c < "$TARGET" 2>/dev/null) bytes) and $copied segment(s)"

# Probe the codec now so it works without a reboot.
if [ -e "/sys/bus/platform/devices/$PLAT_DEV" ] && [ -e "$PLAT_DRV/bind" ]; then
    if [ ! -e /sys/class/video4linux/video12 ]; then
        say "re-probing $PLAT_DEV"
        printf '%s\n' "$PLAT_DEV" > "$PLAT_DRV/unbind" 2>/dev/null
        sleep 2
        printf '%s\n' "$PLAT_DEV" > "$PLAT_DRV/bind" 2>/dev/null
        sleep 3
    fi
fi

if [ -e /sys/class/video4linux/video12 ]; then
    say "encoder at /dev/video12, decoder at /dev/video13"
else
    say "codec did not come up; firmware may not match this device"
fi

exit 0