#!/bin/bash
# Verify the shipped rootfs image contains what the objective asks for.
#
# The first version used "sudo -n test -e $MNT/path" and reported nearly everything
# missing. That check is unreliable against a loop mount under sudo here - it
# returned false for paths that plainly exist. Using ls on the parent directory is
# dependable, so every check now goes through a listing instead.
set -u
IMG=${IMG:-$(cd "$(dirname "$0")/.." && pwd)/rootfs.ext4}
MNT=$(mktemp -d)

sudo -n umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT"

echo "=== 挂载镜像 ==="
sudo -n mount -o loop,ro "$IMG" "$MNT" 2>/dev/null || { echo "  挂载失败"; exit 1; }
echo "  OK"

pass=0; fail=0

# Check a path by listing its parent and matching the basename.
check() {
    local desc=$1 rel=$2
    local dir base
    dir=$(dirname "$rel")
    base=$(basename "$rel")
    if sudo -n ls "$MNT/$dir" 2>/dev/null | grep -qx "$base"; then
        printf '  [OK]   %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf '  [FAIL] %s  (no %s in /%s)\n' "$desc" "$base" "$dir"
        fail=$((fail + 1))
    fi
}

# A .wants entry is a symlink; -e would follow it out of the image, so just look
# for the name.
check_link() {
    local desc=$1 rel=$2
    local dir base
    dir=$(dirname "$rel")
    base=$(basename "$rel")
    if sudo -n ls "$MNT/$dir" 2>/dev/null | grep -qx "$base"; then
        printf '  [OK]   %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf '  [FAIL] %s  (no %s in /%s)\n' "$desc" "$base" "$dir"
        fail=$((fail + 1))
    fi
}

echo
echo "=== 1. nmtui 与 NetworkManager ==="
check      "nmtui"                    usr/bin/nmtui
check      "nmcli"                    usr/bin/nmcli
check      "NetworkManager daemon"    usr/sbin/NetworkManager
check_link "NetworkManager enabled"   etc/systemd/system/multi-user.target.wants/NetworkManager.service

echo
echo "=== 2. Vulkan ==="
check "vulkaninfo"          usr/bin/vulkaninfo
check "Turnip ICD"          usr/share/vulkan/icd.d/freedreno_icd.json
check "libvulkan"           usr/lib/aarch64-linux-gnu/libvulkan.so.1

echo
echo "=== 3. Docker ==="
check      "docker CLI"           usr/bin/docker
check      "dockerd"              usr/sbin/dockerd
check_link "docker enabled"       etc/systemd/system/multi-user.target.wants/docker.service
check_link "containerd enabled"   etc/systemd/system/multi-user.target.wants/containerd.service

echo
echo "=== 4. 蓝牙 ==="
check      "bluetooth-addr.sh"     usr/local/sbin/bluetooth-addr.sh
check      "bluetooth-addr unit"   etc/systemd/system/bluetooth-addr.service
check_link "bt addr enabled"       etc/systemd/system/multi-user.target.wants/bluetooth-addr.service
check_link "bluetooth enabled"     etc/systemd/system/multi-user.target.wants/bluetooth.service
check      "BT firmware patch"     lib/firmware/qca/crbtfw21.tlv
check      "BT firmware NVM"       lib/firmware/qca/crnv21.bin

echo
echo "=== 4b. bluez 本体 ==="
# Without these the firmware, clock fix and QUP wrapper all go to waste: the
# controller comes up but nothing can drive it, and btmgmt cannot set its address.
check      "bluetooth.service"     usr/lib/systemd/system/bluetooth.service
check      "bluetoothctl"          usr/bin/bluetoothctl
check      "btmgmt"                usr/bin/btmgmt
check      "hciconfig"             usr/bin/hciconfig

echo
echo "=== 5. 音频 ==="
check      "amplifier firmware"    lib/firmware/tas2557_uCDSP.bin
check      "ADSP start unit"       etc/systemd/system/adsp-start.service
check_link "ADSP in sysinit"       etc/systemd/system/sysinit.target.wants/adsp-start.service

echo
echo "=== 6. WiFi 与 rmtfs ==="
check      "wifi-mac.sh"           usr/local/sbin/wifi-mac.sh
check_link "wifi-mac enabled"      etc/systemd/system/multi-user.target.wants/wifi-mac.service
check_link "rmtfs enabled"         etc/systemd/system/multi-user.target.wants/rmtfs.service
check      "tqftpserv"             usr/bin/tqftpserv
check      "pd-mapper"             usr/bin/pd-mapper

echo
echo "=== 7. 不应存在的项 ==="
if sudo -n ls "$MNT/etc/systemd/system/rmtfs.service.d" 2>/dev/null | grep -qx 'verbose.conf'; then
    echo "  [FAIL] 临时调试配置 verbose.conf 还在镜像里"
    fail=$((fail + 1))
else
    echo "  [OK]   临时调试配置已清除"
    pass=$((pass + 1))
fi
if sudo -n ls "$MNT/etc/systemd/system/multi-user.target.wants" 2>/dev/null | grep -qx 'modem-start.service'; then
    echo "  [FAIL] modem-start.service 被启用（与 rmtfs -s 重复）"
    fail=$((fail + 1))
else
    echo "  [OK]   modem-start.service 未启用"
    pass=$((pass + 1))
fi

echo
echo "=== 8. 统计 ==="
echo "  已用空间: $(sudo -n du -sh "$MNT" 2>/dev/null | cut -f1)"

sudo -n umount "$MNT"

echo
echo "=== 汇总: 通过 $pass，失败 $fail ==="
