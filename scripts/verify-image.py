#!/usr/bin/env python3
"""Verify a packed boot image before flashing it.

Checks the things that actually went wrong during bring-up:

  * Android boot header shape (magic, page size, header version)
  * the DTB placing rule the ABL enforces: the FDT must begin exactly where the
    gzip stream ends (delta == 0), otherwise the ABL logs
    "DTB offset is incorrect, kernel image does not have appended DTB"
  * the cmdline that is really embedded in the image
  * that the initramfs really contains our /init and that it mounts configfs
    (without that mount no USB device ever appears, even with a perfect kernel)

usage: verify-image.py <boot.img>
exit status: 0 all good, 1 something is wrong
"""
import gzip
import struct
import sys

FDT_MAGIC = struct.pack('>I', 0xD00DFEED)
OK = 'OK'
BAD = 'FAIL'


def find_init(raw_cpio):
    """Return the bytes of ./init inside a newc cpio archive."""
    pos = 0
    while pos + 110 <= len(raw_cpio):
        hdr = raw_cpio[pos:pos + 110]
        if hdr[:6] != b'070701':
            break
        namesize = int(hdr[94:102], 16)
        filesize = int(hdr[54:62], 16)
        name = raw_cpio[pos + 110:pos + 110 + namesize - 1].decode('utf-8', 'replace')
        data_start = (pos + 110 + namesize + 3) & ~3
        if name.lstrip('./') == 'init':
            return raw_cpio[data_start:data_start + filesize]
        pos = (data_start + filesize + 3) & ~3
    return None


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    path = sys.argv[1]
    data = open(path, 'rb').read()
    problems = []

    def check(name, ok, detail=''):
        mark = OK if ok else BAD
        print(f"  [{mark:4}] {name}{(': ' + detail) if detail else ''}")
        if not ok:
            problems.append(name)

    print(f"image: {path}  ({len(data)} bytes)\n")

    # --- header -------------------------------------------------------------
    if data[:8] != b'ANDROID!':
        print("  [FAIL] not an Android boot image")
        return 1

    ks, ka, rs, ra, ss, sa, ta, ps, hv, osv = struct.unpack('<10I', data[8:48])
    check('page size is 4096', ps == 4096, str(ps))
    check('header version is 0 or 1', hv in (0, 1), str(hv))
    check('kernel section non-empty', ks > 0, f'{ks} bytes')
    check('ramdisk section non-empty', rs > 0, f'{rs} bytes')

    kernel = data[ps:ps + ks]
    rd_off = ps + ((ks + ps - 1) // ps) * ps
    ramdisk = data[rd_off:rd_off + rs]

    # --- DTB placement ------------------------------------------------------
    try:
        import zlib
        do = zlib.decompressobj(16 + zlib.MAX_WBITS)
        do.decompress(kernel)
        gz_end = len(kernel) - len(do.unused_data)
        gz_ok = True
    except Exception as exc:                     # noqa: BLE001
        gz_end = -1
        gz_ok = False
        print(f"         gzip decompression failed: {exc}")

    fdt = kernel.find(FDT_MAGIC)
    check('kernel blob contains an FDT', fdt >= 0, f'offset {fdt}')
    if gz_ok and fdt >= 0:
        check('DTB starts where the gzip stream ends (delta == 0)',
              fdt == gz_end, f'gz_end={gz_end} fdt={fdt} delta={fdt - gz_end}')

    # --- cmdline ------------------------------------------------------------
    cmd = data[64:64 + 512].split(b'\x00')[0].decode('ascii', 'replace')
    print(f"         cmdline: {cmd or '(empty)'}")
    check('cmdline is not empty', bool(cmd))

    # --- initramfs ----------------------------------------------------------
    init = find_init(gzip.decompress(ramdisk))
    check('/init exists in the initramfs', init is not None,
          f'{len(init)} bytes' if init else '')
    if init:
        text = init.decode('utf-8', 'replace')
        check('/init mounts configfs', 'mount -t configfs' in text,
              'required for the USB gadget to appear')

    print()
    if problems:
        print(f'RESULT: {len(problems)} problem(s): ' + ', '.join(problems))
        return 1

    print('RESULT: image looks correct')
    return 0


if __name__ == '__main__':
    sys.exit(main())
