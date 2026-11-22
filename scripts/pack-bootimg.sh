#!/bin/bash
# =============================================================================
# Pack a boot image the Xiaomi ABL actually accepts.
#
# Two details matter and both were painful to discover:
#
#  1. The DTB must start EXACTLY where the gzip stream ends. The ABL computes
#     the end of the compressed kernel and expects the FDT magic right there.
#     Any padding makes it log
#         BootLinux: GetImage failed! DTB offset is incorrect,
#                   kernel image does not have appended DTB
#     (it then usually falls back and still jumps, but do not rely on it).
#
#  2. The header must be version 0 or 1 with page size 4096 and the standard
#     offset layout for this device.
#
# Environment:
#   OUT     output directory   (default: ./out)
#   INITRD  initramfs path     (default: $OUT/initramfs.cpio.gz)
#   CMDLINE kernel cmdline     (default: see below)
#
# usage: scripts/pack-bootimg.sh <Image.gz> <dtb> [output.img]
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$REPO/out}
INITRD=${INITRD:-$OUT/initramfs.cpio.gz}
CMDLINE=${CMDLINE:-"ignore_loglevel loglevel=8 panic=10"}

KGZ=${1:?usage: pack-bootimg.sh <Image.gz> <dtb> [output.img]}
DTB=${2:?usage: pack-bootimg.sh <Image.gz> <dtb> [output.img]}
IMG=${3:-$OUT/boot.img}

# The boot partition on this device is 64 MiB; writing a full-size image keeps
# the ABL happy and matches how the stock images are shipped.
BOOT_PART_SIZE=${BOOT_PART_SIZE:-67108864}

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for f in "$KGZ" "$DTB" "$INITRD"; do
    [ -f "$f" ] || die "missing input: $f"
done
command -v mkbootimg >/dev/null 2>&1 || die "mkbootimg not found (android-sdk / mkbootimg package)"

mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# -----------------------------------------------------------------------------
say "concatenating kernel + dtb (no padding)"
cat "$KGZ" "$DTB" > "$WORK/kernel.img"

python3 - "$WORK/kernel.img" <<'PY'
import struct, sys, zlib

path = sys.argv[1]
d = open(path, 'rb').read()

do = zlib.decompressobj(16 + zlib.MAX_WBITS)
do.decompress(d)
gz_end = len(d) - len(do.unused_data)

# Look only at where the gzip stream actually ends. Searching from offset 0 can
# match the very same four bytes by coincidence inside the compressed data,
# which reports a negative delta and fails a perfectly good image.
_FDT = struct.pack('>I', 0xD00DFEED)
fdt = gz_end if d[gz_end:gz_end + 4] == _FDT else d.find(_FDT, gz_end)

print(f"  kernel blob : {len(d)} bytes")
print(f"  gzip ends at: {gz_end}")
print(f"  FDT at      : {fdt}")
print(f"  delta       : {fdt - gz_end}")

if fdt != gz_end:
    print("error: the DTB is not immediately after the gzip stream;", file=sys.stderr)
    print("       the ABL will refuse or mis-handle this image.", file=sys.stderr)
    sys.exit(1)
PY

# -----------------------------------------------------------------------------
say "packing"
rm -f "$IMG"
mkbootimg \
    --kernel   "$WORK/kernel.img" \
    --ramdisk  "$INITRD" \
    --cmdline  "$CMDLINE" \
    --base             0x00000000 \
    --kernel_offset    0x00008000 \
    --ramdisk_offset   0x01000000 \
    --tags_offset      0x00000100 \
    --pagesize         4096 \
    --header_version   1 \
    --output "$IMG" >/dev/null

echo "  packed: $(stat -c%s "$IMG") bytes"

# -----------------------------------------------------------------------------
say "padding to the boot partition size"
truncate -s "$BOOT_PART_SIZE" "$IMG"
echo "  final : $(stat -c%s "$IMG") bytes"
echo "  cmdline: $CMDLINE"
