#!/bin/bash
# Verify the boot image that CI actually published, not one built locally.
#
# Everything checked so far was produced on this machine. The published artifact is
# built on a fresh runner against stock v7.1-rc1, so it is the only real evidence
# that the release is usable.
set -u
IMG=${IMG:-$(cd "$(dirname "$0")/.." && pwd)/release-verify/boot.img}
REPO=$(cd "$(dirname "$0")/.." && pwd)

[ -f "$IMG" ] || { echo "找不到 $IMG"; exit 1; }

echo "=== 镜像大小 ==="
ls -l "$IMG" | awk '{printf "  %.2f MiB\n", $5/1048576}'

echo
echo "=== 用仓库自己的校验脚本 ==="
python3 "$REPO/scripts/verify-image.py" "$IMG" 2>&1 | tail -20

echo
echo "=== 提取 initramfs 检查固件 ==="
WORK=$(mktemp -d)
# The image is: header, kernel, ramdisk, dtb. Parse the header for sizes.
python3 - "$IMG" "$WORK" <<'PY'
import struct
import sys
import gzip
import os

img, work = sys.argv[1], sys.argv[2]
data = open(img, 'rb').read()

MAGIC = b'ANDROID!'
if data[:8] != MAGIC:
    sys.exit('not an Android boot image')

kernel_size = struct.unpack_from('<I', data, 8)[0]
ramdisk_size = struct.unpack_from('<I', data, 16)[0]
page = struct.unpack_from('<I', data, 36)[0]
header_size = struct.unpack_from('<I', data, 0x66c)[0] if len(data) > 0x670 else 0

print(f'  page size:    {page}')
print(f'  kernel:       {kernel_size} bytes')
print(f'  ramdisk:      {ramdisk_size} bytes')
print(f'  header_size:  0x{header_size:x}')

# Kernel starts at page 1.
off = page
off += (kernel_size + page - 1) // page * page
ramdisk = data[off:off + ramdisk_size]

out = os.path.join(work, 'initramfs.cpio.gz')
open(out, 'wb').write(ramdisk)
print(f'  extracted:    {out} ({len(ramdisk)} bytes)')
PY

echo
echo "=== initramfs 里的固件 ==="
gzip -dc "$WORK/initramfs.cpio.gz" 2>/dev/null | cpio -t 2>/dev/null | grep -E 'firmware' | sort

echo
echo "=== 关键固件是否齐全 ==="
LIST=$(gzip -dc "$WORK/initramfs.cpio.gz" 2>/dev/null | cpio -t 2>/dev/null)
for f in qcom/a630_sqe.fw qcom/a630_gmu.bin qcom/a630_zap.mdt \
         tas2557_uCDSP.bin qca/crbtfw21.tlv qca/crnv21.bin; do
    if echo "$LIST" | grep -q "$f"; then
        echo "  [OK]   $f"
    else
        echo "  [FAIL] $f"
    fi
done

rm -rf "$WORK"
