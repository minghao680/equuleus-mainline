#!/bin/bash
# =============================================================================
# Compare the released rootfs with the local one, item by item.
#
# This is what exposed the largest defect in the project: the published image was
# 344 MB against a local 1.4 GB, missing bluez, NetworkManager, Docker, Vulkan, the
# Bluetooth units and the Bluetooth firmware. All of those had been installed into
# the local rootfs by hand during bring-up and were never in the scripts, so CI - which
# only runs the scripts - produced a much smaller image. Every local check passed
# because it inspected the hand-modified directory.
#
# usage: scripts/compare-released-rootfs.sh <released.ext4> [local-rootfs-dir]
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
IMG=${1:-}
LOCAL=${2:-${ROOT:-$HOME/rootfs-arm64}}

[ -n "$IMG" ] || { echo "usage: $0 <released.ext4> [local-rootfs-dir]"; exit 1; }
[ -f "$IMG" ] || { echo "找不到 $IMG"; exit 1; }
[ -d "$LOCAL" ] || { echo "找不到本地 rootfs: $LOCAL"; exit 1; }

MNT=$(mktemp -d)
sudo -n mount -o loop,ro "$IMG" "$MNT" 2>/dev/null || { echo "挂载失败"; exit 1; }

pass=0; diff=0

# $1 description, $2 path relative to the root
compare() {
    local desc=$1 rel=$2
    local dir base inrel=no inlocal=no
    dir=$(dirname "$rel")
    base=$(basename "$rel")

    sudo -n ls "$MNT/$dir" 2>/dev/null | grep -qx "$base" && inrel=yes
    sudo -n ls "$LOCAL/$dir" 2>/dev/null | grep -qx "$base" && inlocal=yes

    if [ "$inrel" = "$inlocal" ]; then
        printf '  [OK]   %-28s 发布=%s 本地=%s\n' "$desc" "$inrel" "$inlocal"
        pass=$((pass + 1))
    else
        printf '  [DIFF] %-28s 发布=%-3s 本地=%-3s\n' "$desc" "$inrel" "$inlocal"
        diff=$((diff + 1))
    fi
}

echo "===== 关键路径对比 ====="
compare "bluetoothd"         usr/libexec/bluetooth/bluetoothd
compare "bluetooth.service"  usr/lib/systemd/system/bluetooth.service
compare "bluetoothctl"       usr/bin/bluetoothctl
compare "btmgmt"             usr/bin/btmgmt
compare "hciconfig"          usr/bin/hciconfig
compare "bluetooth-addr.sh"  usr/local/sbin/bluetooth-addr.sh
compare "bluetooth-addr.unit" etc/systemd/system/bluetooth-addr.service
compare "bt addr enabled"    etc/systemd/system/multi-user.target.wants/bluetooth-addr.service
compare "BT patch fw"        lib/firmware/qca/crbtfw21.tlv
compare "BT nvm fw"          lib/firmware/qca/crnv21.bin
compare "NetworkManager"     usr/sbin/NetworkManager
compare "nmtui"              usr/bin/nmtui
compare "NM enabled"         etc/systemd/system/multi-user.target.wants/NetworkManager.service
compare "wifi-mac.sh"        usr/local/sbin/wifi-mac.sh
compare "wifi-mac enabled"   etc/systemd/system/multi-user.target.wants/wifi-mac.service
compare "tqftpserv"          usr/bin/tqftpserv
compare "pd-mapper"          usr/bin/pd-mapper
compare "rmtfs"              usr/bin/rmtfs
compare "docker"             usr/bin/docker
compare "dockerd"            usr/sbin/dockerd
compare "vulkaninfo"         usr/bin/vulkaninfo
compare "Turnip ICD"         usr/share/vulkan/icd.d/freedreno_icd.json
compare "tas2557 fw"         lib/firmware/tas2557_uCDSP.bin
compare "ADSP in sysinit"    etc/systemd/system/sysinit.target.wants/adsp-start.service

echo
echo "===== 大小对比 ====="
printf '  发布版: %s\n' "$(sudo -n du -sh "$MNT" 2>/dev/null | cut -f1)"
printf '  本地:   %s\n' "$(sudo -n du -sh "$LOCAL" 2>/dev/null | cut -f1)"

sudo -n umount "$MNT"
rmdir "$MNT" 2>/dev/null || true

echo
echo "===== 汇总: 一致 $pass，不一致 $diff ====="
[ "$diff" -eq 0 ] && echo "  发布版与本地一致" || echo "  发布版缺少 $diff 项，检查脚本是否遗漏"
exit "$diff"
