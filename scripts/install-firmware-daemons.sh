#!/bin/bash
# Install the device's Debian packages with APT in the arm64 rootfs.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(realpath -e -- "${ROOT:-$HOME/rootfs-arm64}")
MIRROR=${MIRROR:-https://deb.debian.org/debian}
SUITE=${SUITE:-trixie}

[[ $ROOT != / && -f $ROOT/etc/debian_version && -s $ROOT/var/lib/dpkg/status ]] || {
    echo "error: expected a bootstrapped Debian rootfs, got $ROOT" >&2
    exit 1
}

# Isolate the chroot's mounts from the build host. The policy below prevents
# package scripts from starting services while the image is being assembled.
if [[ ${1:-} != --isolated ]]; then
    . "$SCRIPT_DIR/lib/sudo.sh"
    exec $SUDO env ROOT="$ROOT" MIRROR="$MIRROR" SUITE="$SUITE" \
        unshare --mount --propagation private bash "$SCRIPT_DIR/install-firmware-daemons.sh" --isolated
fi

mount --bind /dev "$ROOT/dev"
mount -t proc proc "$ROOT/proc"
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$ROOT/run"

work=$(mktemp -d "$ROOT/run/equuleus-apt.XXXXXXXX")
chmod 0755 "$work"
mkdir "$work/empty.d"
policy="$ROOT/usr/sbin/policy-rc.d"
resolver="$ROOT/etc/resolv.conf"
restore() {
    local target=$1 backup=$2
    if [[ -e $backup || -L $backup ]]; then
        mv -fT -- "$backup" "$target"
    else
        rm -f -- "$target"
    fi
}
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -e $work/restore-policy ]]; then
        restore "$policy" "$work/policy-rc.d.orig" || status=1
    fi
    if [[ -e $work/restore-resolver ]]; then
        restore "$resolver" "$work/resolv.conf.orig" || status=1
    fi
    exit "$status"
}
trap cleanup EXIT

if [[ -e $policy || -L $policy ]]; then
    cp -a -- "$policy" "$work/policy-rc.d.orig"
fi
: > "$work/restore-policy"
printf '#!/bin/sh\nexit 101\n' > "$work/policy-rc.d"
install -m 0755 -T "$work/policy-rc.d" "$policy"

if [[ -e $resolver || -L $resolver ]]; then
    cp -a -- "$resolver" "$work/resolv.conf.orig"
fi
: > "$work/restore-resolver"
install -m 0644 -T /etc/resolv.conf "$resolver"

keyring=/usr/share/keyrings/debian-archive-keyring.gpg
printf 'deb [signed-by=%s] %s %s main non-free-firmware\n' \
    "$keyring" "$MIRROR" "$SUITE" > "$work/sources.list"
: > "$work/preferences"
if [[ $SUITE != sid ]]; then
    # Trixie's tqftpserv 1.1 rejects the modem's vendor firmware path. Allow
    # tqftpserv from sid while keeping its dependencies on the target suite.
    printf 'deb [signed-by=%s] %s sid main\n' "$keyring" "$MIRROR" >> "$work/sources.list"
    cat > "$work/preferences" <<'EOF'
Package: tqftpserv
Pin: release n=sid
Pin-Priority: 600

Package: *
Pin: release n=sid
Pin-Priority: -1
EOF
fi

chroot_work=${work#"$ROOT"}
apt_options=(
    -o "Dir::Etc::sourcelist=$chroot_work/sources.list"
    -o "Dir::Etc::sourceparts=$chroot_work/empty.d"
    -o "Dir::Etc::preferences=$chroot_work/preferences"
    -o "Dir::Etc::preferencesparts=$chroot_work/empty.d"
    -o Acquire::Retries=3
    -o Acquire::Languages=none
    -o APT::Update::Error-Mode=any
    -o Dpkg::Use-Pty=0
)
in_root() {
    chroot "$ROOT" env LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive "$@"
}

packages=(
    rmtfs protection-domain-mapper tqftpserv firmware-atheros
    network-manager network-manager-l10n wpasupplicant iw rfkill wireless-regdb
    isc-dhcp-client systemd-timesyncd bluez alsa-utils alsa-ucm-conf
    libvulkan1 mesa-vulkan-drivers vulkan-tools glmark2-es2-drm
    docker.io docker-cli containerd runc
    locales sudo bash-completion pciutils usbutils util-linux-extra
    curl wget rsync file vim man-db manpages tree jq htop psmisc lsof
    ethtool dnsutils iperf3 net-tools tcpdump

    # Modem data path. qrtr-tools provides qrtr-ns (the QIPCRTR name service) and
    # libqmi-utils provides qmicli/qmi-proxy; modemmanager needs both plus the
    # IPA net port the kernel now exposes. modemmanager pulls polkitd, which its
    # shipped unit Requires.
    libqmi-utils qrtr-tools modemmanager
    # Optional Wi-Fi hotspot: off by default, started by hand with `hotspot`.
    # hostapd runs the AP, dnsmasq hands out leases, iptables does the NAT.
    hostapd dnsmasq iptables
    # Shell, editing and scripting
    bc gawk time git ripgrep fd-find python3-venv screen tmux manpages-zh
    # Network and system diagnostics
    iputils-arping iputils-tracepath mtr-tiny netcat-openbsd socat
    lshw strace sysstat inotify-tools
    # Storage, file systems and archives
    parted gdisk dosfstools exfatprogs mtools ncdu
    zip unzip lz4 zstd pv
)
in_root apt-get "${apt_options[@]}" update
in_root apt-get "${apt_options[@]}" install -y --no-install-recommends "${packages[@]}"
in_root apt-get "${apt_options[@]}" check

# Build the locale data before selecting the locale for systemd and login.
if ! grep -Fxq 'zh_CN.UTF-8 UTF-8' "$ROOT/etc/locale.gen"; then
    printf '\nzh_CN.UTF-8 UTF-8\n' >> "$ROOT/etc/locale.gen"
fi
in_root locale-gen
in_root update-locale --locale-file /etc/locale.conf LANG=zh_CN.UTF-8
# The image ships UTC unless told otherwise, which leaves a phone in China eight
# hours off and breaks every timestamp in the journal. Keep the zone explicit.
timezone=${TZONE:-Asia/Shanghai}
if [ -e "$ROOT/usr/share/zoneinfo/$timezone" ]; then
    in_root ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
    printf '%s\n' "$timezone" > "$ROOT/etc/timezone"
else
    echo "warning: zoneinfo/$timezone is unavailable, leaving UTC" >&2
fi
in_root apt-get clean

if ! grep -aq '/readonly/vendor/firmware_mnt/image/' "$ROOT/usr/bin/tqftpserv"; then
    echo 'error: tqftpserv does not support the modem vendor firmware path' >&2
    exit 1
fi

# rmtfs -s starts MPSS once rmtfs is ready to serve its files.
systemctl --root="$ROOT" enable rmtfs.service pd-mapper.service tqftpserv.service systemd-timesyncd.service
