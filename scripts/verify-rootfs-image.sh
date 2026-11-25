#!/bin/bash
# Inspect the flashable filesystem and run a few arm64 userspace checks.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/scripts/lib/sudo.sh"
IMG=${IMG:-$REPO/out/rootfs.ext4}
[[ -s $IMG ]] || { echo "error: image missing: $IMG" >&2; exit 1; }

mount_dir=$(mktemp -d)
cleanup() {
    if mountpoint -q "$mount_dir"; then
        $SUDO umount "$mount_dir"
    fi
    rmdir "$mount_dir"
}
trap cleanup EXIT
$SUDO mount -t ext4 -o loop,ro,noload "$IMG" "$mount_dir"

$SUDO chroot "$mount_dir" env VERIFY_RELEASE="${VERIFY_RELEASE:-0}" /bin/sh -eu <<'EOF'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C.UTF-8

if [ "$VERIFY_RELEASE" = 1 ]; then
    for file in /etc/ssh/ssh_host_*_key /etc/NetworkManager/system-connections/*; do
        if [ -f "$file" ] || [ -L "$file" ]; then
            echo 'error: release image contains a saved network profile or SSH host key' >&2
            exit 1
        fi
    done
fi

for pkg in bluez network-manager network-manager-l10n wpasupplicant firmware-atheros \
    wireless-regdb tqftpserv rmtfs protection-domain-mapper systemd-timesyncd \
    docker.io docker-cli containerd runc libvulkan1 mesa-vulkan-drivers vulkan-tools \
    locales sudo pciutils usbutils vim isc-dhcp-client alsa-utils alsa-ucm-conf openssh-server \
    manpages-zh python3-venv glmark2-es2-drm \
    libqmi-utils qrtr-tools modemmanager polkitd; do
    if [ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg")" != installed ]; then
        echo "error: package not installed: $pkg" >&2
        exit 1
    fi
done

for cmd in nmtui nmcli bluetoothctl btmgmt sudo dhclient iperf3 \
    aplay amixer vulkaninfo docker dockerd containerd runc resize2fs \
    lsusb lspci lshw htop lsof strace iostat pidstat inotifywait \
    ssh curl wget dig nc socat arping tracepath mtr traceroute tcpdump \
    lsblk findmnt fdisk parted gdisk ncdu rsync mkfs.vfat mkfs.exfat mdir \
    tar gzip bzip2 xz zip unzip lz4 zstd pv \
    man vim bc gawk /usr/bin/time git rg fdfind jq python3 screen tmux glmark2-es2-drm \
    qmicli qrtr-ns mmcli; do
    command -v "$cmd" >/dev/null || { echo "error: command missing: $cmd" >&2; exit 1; }
done

# Execute metadata-only commands to catch missing shared library dependencies.
/usr/libexec/bluetooth/bluetoothd --version
NetworkManager --version
nm_config=$(NetworkManager --print-config 2>&1)
if printf '%s\n' "$nm_config" | grep -q '^# WARNING:'; then
    echo 'error: NetworkManager reported an invalid configuration' >&2
    exit 1
fi
docker --version
for elf in /usr/bin/rmtfs /usr/bin/tqftpserv /usr/bin/vulkaninfo /usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so; do
    dependencies=$(ldd "$elf")
    if printf '%s\n' "$dependencies" | grep -F 'not found'; then
        echo "error: an ELF dependency of $elf is missing" >&2
        exit 1
    fi
done

board=/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
if [ ! -s "$board" ] && [ ! -s "$board.xz" ] && [ ! -s "$board.zst" ]; then
    echo 'error: ath10k WCN3990 board-2.bin is missing' >&2
    exit 1
fi
for firmware in qca/crbtfw21.tlv qca/crnv21.bin tas2557_uCDSP.bin \
    qcom/sdm845/mi8/adsp.mbn image/wlanmdsp.mbn; do
    [ -s "/lib/firmware/$firmware" ] || { echo "error: missing firmware: $firmware" >&2; exit 1; }
done
[ -s /usr/share/vulkan/icd.d/freedreno_icd.json ]
grep -aq '/readonly/vendor/firmware_mnt/image/' /usr/bin/tqftpserv

[ "$(LC_ALL=zh_CN.UTF-8 locale charmap)" = UTF-8 ]
locale -a | grep -Fx 'zh_CN.utf8'
grep -Fx 'LANG=zh_CN.UTF-8' /etc/locale.conf
# A UTC phone in China is eight hours off in every timestamp.
[ "$(readlink -f /etc/localtime)" = "$(readlink -f /usr/share/zoneinfo/Asia/Shanghai)" ] || {
    echo 'error: timezone is not Asia/Shanghai' >&2
    exit 1
}
awk '$1 !~ /^#/ && $2 == "/" && $3 == "ext4" && $4 ~ /(^|,)x-systemd\.growfs(,|$)/ { ok=1 } END { exit !ok }' /etc/fstab
[ -x /usr/lib/systemd/systemd-growfs ]

# Wi-Fi SSH is the only usable login once the phone is off the USB cable.
grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config.d/10-equuleus.conf
grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config.d/10-equuleus.conf
[ -x /usr/local/sbin/audio-defaults.sh ]

# udev creates by-partlabel asynchronously, so the address helpers must not depend
# on it alone: without this the factory MAC was skipped on one boot and the
# controller kept a random address.
[ -r /usr/local/lib/equuleus/persist-part.sh ]
grep -q 'equuleus_persist_partition' /usr/local/sbin/wifi-mac.sh
grep -q 'equuleus_persist_partition' /usr/local/sbin/bluetooth-addr.sh
for unit in wifi-mac bluetooth-addr; do
    if grep -q 'ConditionPathExists=/dev/disk/by-partlabel/persist' "/etc/systemd/system/$unit.service"; then
        echo "error: $unit.service depends on a by-partlabel condition that can race udev" >&2
        exit 1
    fi
done

# The Bluetooth address helper is pulled in by bluetooth.service itself, and it
# must read the address at run time rather than carrying a per-device constant.
# Only a literal assignment counts; the helper legitimately mentions the all-zero
# address when rejecting it.
[ -r /etc/systemd/system/bluetooth.service.d/10-equuleus.conf ]
grep -q 'After=bluetooth-addr.service' /etc/systemd/system/bluetooth.service.d/10-equuleus.conf
grep -q 'bt.mac' /usr/local/sbin/bluetooth-addr.sh
if grep -qE '(addr=|address=)[0-9a-f]{2}:[0-9a-f]{2}:' /usr/local/sbin/bluetooth-addr.sh; then
    echo 'error: bluetooth-addr.sh assigns a hard-coded address' >&2
    exit 1
fi

# The modem data path needs the IPA firmware next to the other mi8 blobs, and
# ModemManager must be ordered after the QRTR name service.
for f in ipa_fws.mdt ipa_fws.b02; do
    [ -s "/lib/firmware/qcom/sdm845/mi8/$f" ] || {
        echo "error: missing IPA firmware: $f" >&2
        exit 1
    }
done
[ -x /usr/bin/qrtr-ns ]
grep -q 'After=qrtr-ns.service' /etc/systemd/system/ModemManager.service.d/10-equuleus.conf

# The modem helper turns the card's slot into the primary UIM session; without it
# ModemManager reports "GW primary session index unknown" and the modem fails.
[ -x /usr/local/sbin/modem-bringup.sh ]
grep -q 'uim-change-provisioning-session' /usr/local/sbin/modem-bringup.sh
grep -q 'aid' /usr/local/sbin/modem-bringup.sh

# The data helper connects one IPv4 bearer and applies its addresses, because
# ModemManager does not configure a QRTR modem's netdev itself.
[ -x /usr/local/sbin/data-bringup.sh ]
grep -q 'simple-connect' /usr/local/sbin/data-bringup.sh
grep -q 'ip-type=ipv4' /usr/local/sbin/data-bringup.sh
# Dual-stack bearers negotiate addresses but deliver no downlink on this modem.
if grep -q 'ip-type=ipv4v6' /usr/local/sbin/data-bringup.sh; then
    echo 'error: data-bringup asks for a dual-stack bearer, which breaks data' >&2
    exit 1
fi
[ -d /etc/equuleus ]

# The hotspot helper exists for users who need it, but it must stay off unless
# started by hand: no unit and no boot hook may reference it.
[ -x /usr/local/sbin/hotspot ]
grep -q 'hotspot start' /usr/local/sbin/hotspot
grep -q '^SSID=' /etc/equuleus/hotspot.conf
command -v hostapd >/dev/null && command -v dnsmasq >/dev/null
if $SUDO grep -rls 'hotspot' "$mount_dir/etc/systemd/system/" 2>/dev/null | grep -q .; then
    echo 'error: something in /etc/systemd enables the hotspot' >&2
    exit 1
fi

# Wi-Fi power save must be turned off on every connection, or an SSH session pays
# a per-packet wake-up penalty.
[ -x /etc/NetworkManager/dispatcher.d/90-wifi-powersave ]
grep -q 'set power_save off' /etc/NetworkManager/dispatcher.d/90-wifi-powersave

EOF

for unit in adsp-start bluetooth bluetooth-addr wifi-mac NetworkManager rmtfs \
    tqftpserv pd-mapper systemd-timesyncd docker containerd ssh sshd-keygen audio-defaults \
    qrtr-ns ModemManager modem-bringup data-bringup; do
    if ! $SUDO systemctl --root="$mount_dir" --quiet is-enabled "$unit.service"; then
        echo "error: unit not enabled: $unit.service" >&2
        exit 1
    fi
done
if $SUDO systemctl --root="$mount_dir" --quiet is-enabled modem-start.service 2>/dev/null; then
    echo 'error: modem-start.service duplicates rmtfs -s' >&2
    exit 1
fi
printf 'Verified packages, firmware, locale, root growth and units in %s\n' "$IMG"
