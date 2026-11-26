#!/bin/sh
#
# Install this device's own WLAN board data (BDF).
#
# linux-firmware ships board-2.bin built from Qualcomm reference boards; for
# this phone that means the DB845C calibration is used even though Xiaomi ships
# a BDF tuned for its own RF front end. The phone keeps those files on its
# "modem" partition (a vfat image with image/bdwlan.bin and image/bdwlan.bXX,
# where XX is the WLAN board id the firmware reports).
#
# The vendor driver picks the file by the board id from the WLAN firmware
# capability message: 0xFF means bdwlan.bin, anything else bdwlan.bXX. This unit
# reports 0xFF, and mainline asks the firmware for the board entry named
# "bus=snoc,qmi-board-id=ff,qmi-chip-id=30214". So: copy that device's blob into
# the matching entry of board-2.bin, once, and let the driver pick it up.
#
# Nothing is redistributed: the calibration is read from the phone itself, and
# the original board-2.bin is kept next to it for rollback.
#
set -u

FW_DIR=/lib/firmware/ath10k/WCN3990/hw1.0
BOARD="$FW_DIR/board-2.bin"
BACKUP="$FW_DIR/board-2.bin.equuleus-orig"
MNT=/run/equuleus-wifi-bdf
PLAT_DEV=18800000.wifi
PLAT_DRV=/sys/bus/platform/drivers/ath10k_snoc

say() { printf 'wifi-bdf: %s\n' "$*"; }

[ -f "$BOARD" ] || { say "no $BOARD, keeping stock"; exit 0; }

# Find the partition by its GPT name rather than a hardcoded device number.
part=
for u in /sys/class/block/*/uevent; do
    grep -q '^PARTNAME=modem$' "$u" 2>/dev/null || continue
    part=/dev/$(basename "$(dirname "$u")")
    break
done
if [ -z "$part" ]; then
    say "no partition named 'modem', keeping stock BDF"
    exit 0
fi

mkdir -p "$MNT"
if ! mount -o ro "$part" "$MNT" 2>/dev/null; then
    say "cannot mount $part read-only, keeping stock BDF"
    exit 0
fi

src="$MNT/image/bdwlan.bin"
if [ ! -s "$src" ]; then
    say "$src not found, keeping stock BDF"
    umount "$MNT" 2>/dev/null
    exit 0
fi

rc=0
python3 - "$src" "$BOARD" "$BACKUP" <<'PY' || rc=$?
import hashlib
import os
import struct
import sys

src, board_path, backup_path = sys.argv[1], sys.argv[2], sys.argv[3]

MAGIC = b'QCA-ATH10K-BOARD\x00'                       # padded to ALIGN(17,4) = 20
MAGIC_LEN = (len(MAGIC) + 3) & ~3
NAME_CHIPID = 'bus=snoc,qmi-board-id=ff,qmi-chip-id=30214'
NAME_PLAIN = 'bus=snoc,qmi-board-id=ff'
TARGETS = (NAME_CHIPID, NAME_PLAIN)


def align4(n):
    return (n + 3) & ~3


def parse(path):
    """Return (raw_prefix, entries) where an entry is dict(name, data, raw)."""
    blob = open(path, 'rb').read()
    if not blob.startswith(MAGIC):
        raise SystemExit('  board-2.bin has unexpected magic')
    off = MAGIC_LEN
    entries = []
    while off + 8 <= len(blob):
        ie_id, ie_len = struct.unpack_from('<II', blob, off)
        stride = align4(ie_len)
        if off + 8 + stride > len(blob):
            raise SystemExit('  truncated container at %#x' % off)
        raw = blob[off:off + 8 + stride]
        body = blob[off + 8:off + 8 + ie_len]
        name = None
        data = None
        if ie_id == 0:
            soff = 0
            while soff + 8 <= len(body):
                sid, slen = struct.unpack_from('<II', body, soff)
                sstride = align4(slen)
                if soff + 8 + sstride > len(body):
                    break
                chunk = body[soff + 8:soff + 8 + slen]
                soff += 8 + sstride
                if sid == 0:
                    name = chunk.decode('utf-8', 'replace')
                elif sid == 1:
                    data = chunk
        entries.append({'id': ie_id, 'name': name, 'data': data, 'raw': raw})
        off += 8 + stride
    if off != len(blob):
        # Trailing bytes are tolerated as long as they are padding.
        if blob[off:].strip(b'\x00'):
            raise SystemExit('  trailing garbage in container')
    return blob[:MAGIC_LEN], entries


def build_entry(name, data):
    nb = name.encode()
    body = struct.pack('<II', 0, len(nb)) + nb + b'\x00' * (align4(len(nb)) - len(nb))
    body += struct.pack('<II', 1, len(data)) + data + b'\x00' * (align4(len(data)) - len(data))
    return struct.pack('<II', 0, len(body)) + body


device_blob = open(src, 'rb').read()
if len(device_blob) < 64:
    raise SystemExit('  device BDF looks too small: %d bytes' % len(device_blob))

prefix, entries = parse(board_path)
want = hashlib.sha256(device_blob).hexdigest()

present = {}
for e in entries:
    if e['name'] in TARGETS:
        present[e['name']] = e

if all(e['data'] is not None and hashlib.sha256(e['data']).hexdigest() == want
       for e in present.values()) and len(present) == len(TARGETS):
    print('  already applied, nothing to do')
    sys.exit(2)

if not os.path.exists(backup_path):
    with open(backup_path, 'wb') as fh:
        fh.write(open(board_path, 'rb').read())
    print('  original saved to %s' % backup_path)

out = bytearray(prefix)
replaced = []
for e in entries:
    if e['name'] in TARGETS and e['id'] == 0:
        out += build_entry(e['name'], device_blob)
        replaced.append(e['name'])
    else:
        out += e['raw']

missing = [n for n in TARGETS if n not in replaced]
if NAME_CHIPID in missing:
    # Prepended so the driver hits it before any later duplicate for this name.
    out = bytearray(prefix) + build_entry(NAME_CHIPID, device_blob)
    for e in entries:
        if e['name'] == NAME_CHIPID:
            continue
        if e['name'] == NAME_PLAIN:
            out += build_entry(e['name'], device_blob)
        else:
            out += e['raw']
    replaced = [NAME_CHIPID] + ([NAME_PLAIN] if NAME_PLAIN in present else [])

tmp = board_path + '.new'
with open(tmp, 'wb') as fh:
    fh.write(out)
os.replace(tmp, board_path)

print('  device BDF: %d bytes sha256=%s' % (len(device_blob), want[:16]))
print('  board-2.bin rebuilt: %d -> %d bytes, replaced: %s'
      % (len(prefix) + sum(len(e['raw']) for e in entries), len(out), ', '.join(replaced)))
PY

if [ "$rc" -eq 2 ]; then
    say "BDF already current"
    umount "$MNT" 2>/dev/null
    exit 0
fi
if [ "$rc" -ne 0 ]; then
    say "rebuild failed (rc=$rc), keeping current board-2.bin"
    umount "$MNT" 2>/dev/null
    [ -f "$BACKUP" ] && cmp -s "$BACKUP" "$BOARD" || true
    exit 0
fi

umount "$MNT" 2>/dev/null

# The driver caches board data at probe time, so re-probe it once.
if [ -e "/sys/bus/platform/devices/$PLAT_DEV" ] && [ -e "$PLAT_DRV/unbind" ]; then
    say "re-probing $PLAT_DEV so the new BDF is used"
    echo "$PLAT_DEV" > "$PLAT_DRV/unbind" 2>/dev/null
    sleep 2
    echo "$PLAT_DEV" > "$PLAT_DRV/bind" 2>/dev/null
    sleep 1
fi

say "done"