#!/bin/bash
# =============================================================================
# Extract the proprietary Qualcomm firmware this device needs from a stock
# fastboot ROM the user supplies.
#
# None of it can be redistributed, so it is deliberately not in this repository
# and not in the release builds. Everything here comes out of a ROM you own.
#
# What gets installed into the rootfs:
#
#   /lib/firmware/qcom/sdm845/mi8/     adsp, cdsp, modem, mba, wlanmdsp, bdwlan
#   /lib/firmware/qcom/a630_{zap,sqe,gmu}   Adreno 630
#   /lib/firmware/tas2557_uCDSP.bin    speaker amplifier
#   /lib/firmware/image/              what tqftpserv serves to the modem
#
# Environment:
#   ROM_DIR   directory containing modem.img and vendor.img (or miui-adb-vendor.raw)
#   ROOT      rootfs directory to populate
#
# usage: scripts/prepare-firmware.sh
# =============================================================================

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/lib/sudo.sh"
ROOT=${ROOT:-$HOME/rootfs-arm64}
ROM_DIR=${ROM_DIR:-}
MNT=$(mktemp -d)
trap '$SUDO umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -n "$ROM_DIR" ] || die "set ROM_DIR to the directory holding modem.img and vendor.img"
[ -d "$ROOT" ] || die "rootfs not found: $ROOT"

MODEM=$ROM_DIR/modem.img
[ -f "$MODEM" ] || die "missing $MODEM"

VENDOR=""
for c in "$ROM_DIR/vendor.img" "$ROM_DIR/miui-adb-vendor.raw"; do
    [ -f "$c" ] && VENDOR=$c && break
done
[ -n "$VENDOR" ] || die "missing vendor.img (or miui-adb-vendor.raw) in $ROM_DIR"

FW=$ROOT/lib/firmware
MIIMG=$FW/qcom/sdm845/mi8
$SUDO mkdir -p "$MIIMG"

# -----------------------------------------------------------------------------
say "unpacking modem.img"
$SUDO mount -o loop,ro "$MODEM" "$MNT"
for f in adsp cdsp modem; do
    $SUDO cp -f "$MNT"/image/$f.mdt           "$MIIMG/$f.mbn"
    $SUDO cp -f "$MNT"/image/$f.mdt           "$MIIMG/$f.mdt" 2>/dev/null || true
    for seg in "$MNT"/image/$f.b[0-9][0-9]; do
        [ -f "$seg" ] || continue
        $SUDO cp -f "$seg" "$MIIMG/"
    done
    for jsn in "$MNT"/image/"${f}r.jsn" "$MNT"/image/"${f}uw.jsn" "$MNT"/image/"${f}ua.jsn"; do
        [ -f "$jsn" ] && $SUDO cp -f "$jsn" "$MIIMG/" || true
    done
done
for f in mba.mbn wlanmdsp.mbn bdwlan.bin; do
    [ -f "$MNT/image/$f" ] && $SUDO cp -f "$MNT/image/$f" "$MIIMG/" || true
done
$SUDO umount "$MNT"

# -----------------------------------------------------------------------------
say "unpacking vendor image"
# vendor.img in a stock fastboot ROM is an Android sparse image, which cannot be
# loop-mounted directly:
#   mount: wrong fs type, bad option, bad superblock
# Convert it first. modem.img is plain FAT and needs no such step.
VENDOR_MOUNT=$VENDOR
if head -c 4 "$VENDOR" 2>/dev/null | od -A n -t x1 | grep -q '3a ff 26 ed'; then
    command -v simg2img >/dev/null 2>&1 \
        || die "vendor.img is a sparse image and simg2img is not installed (android-sdk-libsparse-utils)"
    echo "  sparse image detected, converting"
    VENDOR_MOUNT=${TMPDIR:-/tmp}/vendor-raw.img
    simg2img "$VENDOR" "$VENDOR_MOUNT"
    echo "  converted: $(stat -c%s "$VENDOR_MOUNT") bytes"
fi

$SUDO mount -o loop,ro "$VENDOR_MOUNT" "$MNT"
for f in a630_zap.elf a630_sqe.fw a630_gmu.bin tas2557_uCDSP.bin; do
    p=$($SUDO find "$MNT" -name "$f" -type f 2>/dev/null | head -1)
    [ -n "${p:-}" ] || { echo "  not found: $f"; continue; }
    case "$f" in
        a630_*)
            $SUDO mkdir -p "$FW/qcom"
            out="$FW/qcom/$f"
            if [ "$f" = a630_zap.elf ]; then
                # Different kernel versions look for different names.
                $SUDO cp -f "$p" "$FW/qcom/a630_zap.mbn"
                $SUDO cp -f "$p" "$FW/qcom/a630_zap.mdt"
                echo "  $FW/qcom/a630_zap.{mbn,mdt}"
                continue
            fi
            $SUDO cp -f "$p" "$out"
            echo "  $out"
            ;;
        *)
            $SUDO cp -f "$p" "$FW/$f"
            echo "  $FW/$f"
            ;;
    esac
done
$SUDO umount "$MNT"

# -----------------------------------------------------------------------------
say "staging what tqftpserv serves"
# The modem asks for /readonly/vendor/firmware_mnt/image/<name>, which tqftpserv
# maps onto /lib/firmware/. It also reads the remoteproc firmware-name from the
# device tree, so the same files serve both entry points.
$SUDO rm -rf "$FW/image"
$SUDO mkdir -p "$FW/image"
for f in "$MIIMG"/*; do
    [ -f "$f" ] || continue
    $SUDO cp -f "$f" "$FW/image/"
done
echo "  $($SUDO ls -1 "$FW/image" | wc -l) files in $FW/image"

# -----------------------------------------------------------------------------
say "done"
echo "  firmware installed under $FW"
echo
echo "  Note: adsp.mbn is a copy of adsp.mdt and the segments live beside it."
echo "  qcom_mdt_load resolves them by basename, exactly like the reference"
echo "  implementation does."
