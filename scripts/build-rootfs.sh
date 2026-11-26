#!/bin/bash
# Build the standard Debian arm64 userland, install device packages and configure systemd.
# Set BUILD_IMAGE=0 to stage ROM firmware before generating the ext4 image.
set -euo pipefail
export LC_ALL=C.UTF-8

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/lib/sudo.sh"
OUT=${OUT:-$REPO/out}
ROOT=${ROOT:-$HOME/rootfs-arm64}
IMG=${IMG:-$OUT/rootfs.ext4}
SIZE_MB=${SIZE_MB:-4096}
MIRROR=${MIRROR:-https://deb.debian.org/debian}
SUITE=${SUITE:-trixie}
BUILD_IMAGE=${BUILD_IMAGE:-1}

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $BUILD_IMAGE == 0 || $BUILD_IMAGE == 1 ]] || die 'BUILD_IMAGE must be 0 or 1'
for tool in mmdebstrap arch-test systemctl; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
arch-test arm64 || die 'arm64 execution unavailable (install and register qemu-user-static)'

$SUDO mkdir -p -- "$ROOT"
ROOT=$(realpath -e -- "$ROOT")
[[ $ROOT != / ]] || die 'ROOT must be a staging directory'
if [[ -z $($SUDO ls -A -- "$ROOT") ]]; then
    say "building standard Debian $SUITE arm64 rootfs"
    $SUDO mmdebstrap --architecture=arm64 --variant=standard \
        --components=main,non-free-firmware \
        --include=systemd-sysv,udev,dbus,kmod,iproute2,iputils-ping,ca-certificates,openssh-server,e2fsprogs,util-linux,procps,less,nano,python3-minimal \
        "$SUITE" "$ROOT" "$MIRROR"
    new_root=1
else
    say "reusing existing rootfs at $ROOT"
    new_root=0
fi

ROOT="$ROOT" SUITE="$SUITE" MIRROR="$MIRROR" bash "$REPO/scripts/install-firmware-daemons.sh"

say 'configuring the rootfs'
if [[ $new_root == 1 ]]; then
    printf 'equuleus\n' | $SUDO tee "$ROOT/etc/hostname" >/dev/null
    $SUDO tee "$ROOT/etc/hosts" >/dev/null <<'EOF'
127.0.0.1 localhost
127.0.1.1 equuleus
::1       localhost ip6-localhost ip6-loopback
EOF
    # openssh-server creates host keys during bootstrap. Generate each phone's
    # keys on its own rootfs so installations have separate SSH identities.
    [[ $(realpath -e -- "$ROOT/etc/ssh") == "$ROOT/etc/ssh" ]] || die 'unexpected /etc/ssh path'
    $SUDO rm -f -- "$ROOT"/etc/ssh/ssh_host_*_key{,.pub}
fi

$SUDO install -d "$ROOT/etc/systemd/system/sshd-keygen.service.d"
$SUDO tee "$ROOT/etc/systemd/system/sshd-keygen.service.d/10-equuleus.conf" >/dev/null <<'EOF'
[Unit]
# An empty machine-id is committed at startup and may skip ConditionFirstBoot.
ConditionFirstBoot=
ConditionPathIsReadWrite=/etc/ssh
ConditionPathIsSymbolicLink=!/etc/ssh
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
EOF

# The initramfs mounts userdata. Ask systemd to grow the ext4 filesystem to
# the size of its backing device after switching to the real root.
$SUDO touch "$ROOT/etc/fstab"
fstab=$($SUDO awk '
    $1 !~ /^#/ && $2 == "/" && $3 == "ext4" {
        root_found = 1
        if ($4 !~ /(^|,)x-systemd\.growfs(,|$)/) $4 = $4 ",x-systemd.growfs"
    }
    { print }
    END {
        if (!root_found) print "UUID=__ROOT_UUID__ / ext4 defaults,noatime,x-systemd.growfs 0 1"
    }
' "$ROOT/etc/fstab")
printf '%s\n' "$fstab" | $SUDO tee "$ROOT/etc/fstab" >/dev/null

# USB CDC-ACM is the console on the headless device.
$SUDO install -d "$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d" "$ROOT/usr/local/sbin"
$SUDO tee "$ROOT/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
EOF

# ADSP uses firmware on the real root. The packaged rmtfs unit owns MPSS startup.
for unit in adsp-start wifi-mac bluetooth-addr audio-defaults cpu-boost perf-tuning wifi-bdf zram-swap modem-bringup data-bringup; do
    $SUDO install -m 0644 "$REPO/systemd/$unit.service" "$ROOT/etc/systemd/system/$unit.service"
done
# QMI helper that activates the UIM session before ModemManager probes the modem.
$SUDO install -m 0755 "$REPO/scripts/modem-bringup.sh" "$ROOT/usr/local/sbin/modem-bringup.sh"
# ModemManager negotiates data addresses but nothing applies them on a QRTR
# modem, so the bearer is connected and configured here.
$SUDO install -m 0755 "$REPO/scripts/data-bringup.sh" "$ROOT/usr/local/sbin/data-bringup.sh"
# Optional hotspot helper. It is installed but nothing starts it: there is no
# unit and no boot hook on purpose, so the AP stays off until someone runs
# "hotspot start".
$SUDO install -m 0755 "$REPO/scripts/hotspot.sh" "$ROOT/usr/local/sbin/hotspot"
$SUDO install -D -m 0644 "$REPO/config/hotspot.conf" "$ROOT/etc/equuleus/hotspot.conf"
$SUDO install -d -m 0755 "$ROOT/etc/equuleus"
# bluetooth.service must pull the address helper in, not the other way round.
$SUDO install -D -m 0644 "$REPO/systemd/bluetooth.service.d-10-equuleus.conf" \
    "$ROOT/etc/systemd/system/bluetooth.service.d/10-equuleus.conf"
# ModemManager resolves the modem's QMI services through the QRTR name service.
$SUDO install -D -m 0644 "$REPO/systemd/ModemManager-10-equuleus.conf" \
    "$ROOT/etc/systemd/system/ModemManager.service.d/10-equuleus.conf"
for helper in wifi-mac bluetooth-addr net-stability audio-defaults cpu-boost perf-tuning wifi-bdf zram-swap; do
    $SUDO install -m 0755 "$REPO/systemd/$helper.sh" "$ROOT/usr/local/sbin/$helper.sh"
done
# Tuning for zram-swap.service: size, priority, compressor, swappiness.
$SUDO install -D -m 0644 "$REPO/config/zram.conf" "$ROOT/etc/equuleus/zram.conf"
# Tuning for perf-tuning.service: idle latency and UFS gear.
$SUDO install -D -m 0644 "$REPO/config/perf-tuning.conf" "$ROOT/etc/equuleus/perf-tuning.conf"
# BBR plus the fq qdisc it pairs with; both are built into the kernel.
$SUDO install -D -m 0644 "$REPO/config/90-equuleus-network.conf" "$ROOT/etc/sysctl.d/90-equuleus-network.conf"
# Tuning for cpu-boost.service: boost OPP plus the governor that can reach it.
$SUDO install -D -m 0644 "$REPO/config/cpu-boost.conf" "$ROOT/etc/equuleus/cpu-boost.conf"
$SUDO install -D -m 0644 "$REPO/systemd/persist-part.sh" \
    "$ROOT/usr/local/lib/equuleus/persist-part.sh"

# There is no display on this device and no passwordless local login other than the
# USB console, so Wi-Fi SSH needs root password authentication to be usable. The
# stock openssh-server configuration refuses it.
$SUDO install -d "$ROOT/etc/ssh/sshd_config.d"
$SUDO tee "$ROOT/etc/ssh/sshd_config.d/10-equuleus.conf" >/dev/null <<'EOF'
# The only ways into this device are the USB serial console and Wi-Fi SSH. With no
# working display, password login for root is the practical option.
PermitRootLogin yes
PasswordAuthentication yes
EOF

# NetworkManager handles Wi-Fi, saved profiles and DHCP. Apply the factory MAC
# before it manages wlan0 and retain it during scans and association.
$SUDO install -D -m 0644 "$REPO/config/NetworkManager-equuleus.conf" \
    "$ROOT/etc/NetworkManager/conf.d/20-equuleus.conf"
# Power save costs a per-packet wake-up penalty that makes an SSH session feel
# sluggish; the dispatcher turns it off for every Wi-Fi connection.
$SUDO install -D -m 0755 -o root -g root \
    "$REPO/systemd/NetworkManager-90-wifi-powersave" \
    "$ROOT/etc/NetworkManager/dispatcher.d/90-wifi-powersave"
for unit in systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service networking.service; do
    if $SUDO test -f "$ROOT/usr/lib/systemd/system/$unit"; then
        $SUDO systemctl --root="$ROOT" disable "$unit"
    fi
done
$SUDO systemctl --root="$ROOT" enable serial-getty@ttyGS0.service adsp-start.service \
    wifi-mac.service NetworkManager.service bluetooth-addr.service \
    bluetooth.service \
    audio-defaults.service cpu-boost.service wifi-bdf.service ssh.service sshd-keygen.service docker.service containerd.service \
    qrtr-ns.service ModemManager.service modem-bringup.service data-bringup.service \
    zram-swap.service perf-tuning.service
$SUDO systemctl --root="$ROOT" set-default multi-user.target

if [[ $BUILD_IMAGE == 1 ]]; then
    ROOT="$ROOT" OUT="$OUT" IMG="$IMG" SIZE_MB="$SIZE_MB" bash "$REPO/scripts/make-rootfs-image.sh"
else
    printf 'rootfs ready for firmware staging at %s\n' "$ROOT"
fi
