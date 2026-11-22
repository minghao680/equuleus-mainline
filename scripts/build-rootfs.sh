#!/bin/bash
# =============================================================================
# Build a Debian arm64 root filesystem with systemd and turn it into an ext4
# image ready to flash to the phone's userdata partition.
#
# The kernel already provides everything systemd needs: cgroups, namespaces,
# tmpfs with POSIX ACLs, epoll/timerfd/signalfd, autofs. What is missing is a
# root filesystem, which is what this produces.
#
# Requirements on the build host:
#   mmdebstrap, arch-test, qemu-aarch64-static, mke2fs, a Debian mirror
#
# Environment:
#   ROOT      rootfs directory   (default: $HOME/rootfs-arm64)
#   IMG       output ext4 image  (default: ./out/rootfs.ext4)
#   SIZE_MB   image size         (default: 4096)
#   MIRROR    Debian mirror      (default: http://deb.debian.org/debian)
#   SUITE     Debian suite       (default: trixie)
#
# usage: scripts/build-rootfs.sh
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$REPO/out}
ROOT=${ROOT:-$HOME/rootfs-arm64}
IMG=${IMG:-$OUT/rootfs.ext4}
SIZE_MB=${SIZE_MB:-4096}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
SUITE=${SUITE:-trixie}

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in mmdebstrap mke2fs chroot; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
[ -e /usr/bin/qemu-aarch64-static ] || die "qemu-aarch64-static not found (apt install qemu-user-static)"
command -v arch-test >/dev/null 2>&1 || die "arch-test not found (apt install arch-test)"

sudo -n true 2>/dev/null || die "this script needs passwordless sudo"

mkdir -p "$OUT"

# -----------------------------------------------------------------------------
if [ -d "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
    say "reusing existing rootfs at $ROOT"
else
    say "building Debian $SUITE arm64 rootfs"
    rm -rf "$ROOT"
    sudo -n mmdebstrap \
        --arch=arm64 \
        --variant=minbase \
        --include=systemd,systemd-sysv,udev,dbus,dbus-broker,kmod,\
iproute2,iputils-ping,ifupdown,ca-certificates,openssh-server,\
e2fsprogs,util-linux,procps,less,nano \
        "$SUITE" "$ROOT" "$MIRROR"
fi

# -----------------------------------------------------------------------------
say "configuring the rootfs"

echo equuleus | sudo -n tee "$ROOT/etc/hostname" >/dev/null
sudo -n tee "$ROOT/etc/hosts" >/dev/null <<'EOF'
127.0.0.1	localhost
127.0.1.1	equuleus
::1		localhost ip6-localhost ip6-loopback
EOF

# The only console on this device is the USB CDC-ACM gadget, and it only exists
# after the initramfs created it, so systemd needs an explicit getty on it.
sudo -n mkdir -p "$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d"
sudo -n tee "$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
EOF

UUID=$(cat /proc/sys/kernel/random/uuid)
sudo -n tee "$ROOT/etc/fstab" >/dev/null <<EOF
# <file system>        <mount point>  <type>     <options>               <dump> <pass>
UUID=$UUID             /              ext4       defaults,noatime        0      1
proc                   /proc          proc       defaults                0      0
sysfs                  /sys           sysfs      defaults                0      0
devtmpfs               /dev           devtmpfs   mode=0755,nosuid        0      0
tmpfs                  /dev/shm       tmpfs      nosuid,nodev,mode=1777  0      0
tmpfs                  /tmp           tmpfs      nosuid,nodev            0      0
EOF

sudo -n mount --bind /dev  "$ROOT/dev"
sudo -n mount -t proc proc "$ROOT/proc"
sudo -n mount -t sysfs sys "$ROOT/sys"
sudo -n chroot "$ROOT" systemctl enable serial-getty@ttyGS0.service
sudo -n chroot "$ROOT" systemctl enable systemd-networkd.service
sudo -n chroot "$ROOT" systemctl set-default multi-user.target
sudo -n umount "$ROOT/sys" "$ROOT/proc" "$ROOT/dev" 2>/dev/null || true

# The ADSP firmware lives on this filesystem, but remoteproc is a built-in driver
# and probes before the root is mounted, so it fails with -ENOENT. Start it once
# more from userspace, where /lib/firmware is reachable.
sudo -n install -m 644 "$REPO/systemd/adsp-start.service" \
    "$ROOT/etc/systemd/system/adsp-start.service"
sudo -n mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
sudo -n ln -sf /etc/systemd/system/adsp-start.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/adsp-start.service"

# The modem needs starting too: the WCN3990 Wi-Fi firmware runs on it and
# qcom_q6v5_mss has auto_boot = false. That start is done by `rmtfs -s` - rmtfs
# spawns the modem once it is ready to serve file requests - so there is
# deliberately no separate modem-start unit here. Two starters would race, and
# the ordering that matters (rmtfs ready before the modem boots) only holds if
# rmtfs is the one doing it.
sudo -n install -m 644 "$REPO/systemd/modem-start.service" \
    "$ROOT/etc/systemd/system/modem-start.service.disabled" 2>/dev/null || true

# ath10k falls back to a random MAC unless the device tree or firmware supplies
# one. The factory address lives on the persist partition; this unit reads it at
# boot so no device-specific value is ever stored in the repository.
sudo -n install -m 755 "$REPO/systemd/wifi-mac.sh" "$ROOT/usr/local/sbin/wifi-mac.sh"
sudo -n install -m 644 "$REPO/systemd/wifi-mac.service" \
    "$ROOT/etc/systemd/system/wifi-mac.service"
sudo -n ln -sf /etc/systemd/system/wifi-mac.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/wifi-mac.service"

# -----------------------------------------------------------------------------
say "creating the ext4 image"
rm -f "$IMG"
truncate -s "${SIZE_MB}M" "$IMG"
sudo -n mke2fs -t ext4 -F -m 1 -L rootfs -U "$UUID" -d "$ROOT" "$IMG" >/dev/null

echo "  image : $IMG"
echo "  size  : $(stat -c%s "$IMG") bytes"
echo "  uuid  : $UUID"
sudo -n tune2fs -l "$IMG" 2>/dev/null | grep -E 'Filesystem UUID|Block count'

say "done"
echo "  flash with:"
echo "    fastboot -s <serial> flash userdata $IMG"
echo "    fastboot -s <serial> flash boot $OUT/boot.img"
