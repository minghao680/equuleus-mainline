#!/bin/bash
# =============================================================================
# Build the initramfs: a static busybox, our init script, a tiny profile.
#
# The resulting image is what makes the phone observable: it mounts configfs,
# builds a USB CDC-ACM gadget and hands a shell to /dev/ttyGS0.
#
# Environment:
#   OUT       output directory              (default: ./out)
#   BUSYBOX   static aarch64 busybox binary (default: auto-detect)
#
# usage: scripts/build-initramfs.sh
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$REPO/out}
WORK=${WORK:-$(mktemp -d)}

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
say "locating a static aarch64 busybox"
if [ -n "${BUSYBOX:-}" ]; then
    [ -x "$BUSYBOX" ] || die "BUSYBOX=$BUSYBOX is not executable"
else
    BUSYBOX=""
    for candidate in \
        "$REPO/out/busybox" \
        "$HOME/busybox-aarch64" \
        /usr/bin/busybox-static \
        /bin/busybox
    do
        if [ -x "$candidate" ] && file "$candidate" 2>/dev/null | grep -q 'ARM aarch64'; then
            BUSYBOX=$candidate
            break
        fi
    done
fi

if [ -z "$BUSYBOX" ]; then
    cat >&2 <<'EOF'
error: no static aarch64 busybox found.

Provide one with BUSYBOX=/path/to/busybox, or put it at ./out/busybox.
It must be a statically linked aarch64 binary. Ways to get one:

  * postmarketOS / Alpine:
        apk add --root /tmp/bb --arch aarch64 busybox-static
        BUSYBOX=/tmp/bb/bin/busybox-static
  * Debian arm64 multiarch:
        sudo dpkg --add-architecture arm64
        sudo apt-get install busybox-static:arm64
        BUSYBOX=/bin/busybox   (after pointing at the arm64 copy)
  * or build it yourself:
        make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
        make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LDFLAGS=--static

Check with: file "$BUSYBOX"   -> should say "ARM aarch64 ... statically linked"
EOF
    exit 2
fi
echo "  using $BUSYBOX"

# -----------------------------------------------------------------------------
say "staging rootfs"
rm -rf "$WORK"
mkdir -p "$WORK"/{bin,sbin,etc,proc,sys,dev,tmp,root}
chmod 1777 "$WORK/tmp"

install -m 755 "$BUSYBOX" "$WORK/bin/busybox"

# applets used by init and by an interactive session
for a in sh ash ls cat mount umount sleep echo mkdir ln dmesg free ps \
         grep sed awk cut tr head tail sync date uname poweroff reboot \
         chmod chown dd df id env which find wc kill \
         switch_root mountpoint blkid mdev; do
    ln -sf /bin/busybox "$WORK/bin/$a"
done
ln -sf /bin/busybox "$WORK/sbin/mdev"
ln -sf /bin/busybox "$WORK/sbin/poweroff"
ln -sf /bin/busybox "$WORK/sbin/reboot"

install -m 755 "$REPO/initramfs/init" "$WORK/init"

# -----------------------------------------------------------------------------
# Firmware that has to be reachable before the root filesystem is mounted.
#
# msm is built in and loads the GPU firmware during probe, which happens while
# the initramfs is still the root. Without a630_sqe.fw here the GPU never comes
# up and the kernel logs "Direct firmware load for qcom/a630_sqe.fw failed".
# The file is proprietary, so it is only included when the caller points at it.
if [ -n "${GPU_FW_DIR:-}" ] && [ -d "$GPU_FW_DIR" ]; then
    say "adding GPU firmware to the initramfs"
    mkdir -p "$WORK/lib/firmware/qcom"
    n=0
    for f in a630_sqe.fw a630_gmu.bin a630_zap.mbn; do
        [ -f "$GPU_FW_DIR/$f" ] || continue
        cp -f "$GPU_FW_DIR/$f" "$WORK/lib/firmware/qcom/$f"
        echo "  qcom/$f"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || echo "  none of the a630 files found in $GPU_FW_DIR"
else
    echo "  GPU_FW_DIR not set - the GPU will not initialise at boot"
fi

cat > "$WORK/etc/profile" <<'EOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
echo
echo "equuleus mainline Linux - busybox shell"
echo
echo "  uname -a            kernel version"
echo "  cat /proc/cpuinfo   CPUs"
echo "  dmesg | tail -40    recent kernel log"
echo "  ls /sys/class/udc   USB device controllers"
echo "  ls /dev/disk/by-*   block devices (once UFS is up)"
echo
EOF

# -----------------------------------------------------------------------------
say "packing"
mkdir -p "$OUT"
( cd "$WORK" && find . -print0 \
    | cpio --null -o -H newc --quiet 2>/dev/null \
    | gzip -9 > "$OUT/initramfs.cpio.gz" )

rm -rf "$WORK"
ls -l "$OUT/initramfs.cpio.gz"
