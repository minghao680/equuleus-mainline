#!/bin/bash
# Audit every objective item against concrete evidence.
#
# Three checks in the first version were wrong, and the corrections matter:
#
#   * 00:00:00:00:00:00 is not a hardcoded address, it is the value the
#     controller reports when it has none. Only a real address would be a leak.
#   * systemd-timesyncd is a unit inside the systemd package, not its own dpkg
#     entry, so check the unit and its enablement instead.
#   * bluetooth-addr.service is enabled via a symlink in a .wants directory,
#     which test -f does not follow the way the check assumed.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
R=${ROOT:-$HOME/rootfs-arm64}
DTS=$REPO/dts/sdm845-xiaomi-equuleus.dts

pass=0; fail=0; warn=0
ok()   { printf '  [OK]   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
maybe(){ printf '  [ ?? ] %s\n' "$*"; warn=$((warn+1)); }

echo "===== 1. 随机 MAC ====="
grep -q 'wlan_bt/bt.mac\|wlan_mac.bin' "$REPO/systemd/wifi-mac.sh" "$REPO/systemd/bluetooth-addr.sh" 2>/dev/null \
    && ok "addresses are read from persist at runtime" \
    || bad "no persist lookup found"

# A real address would be six non-zero octets. 00:00:00:00:00:00 is the
# controller's "I have none" value and must be allowed.
leak=$(grep -rhoE '([0-9a-f]{2}:){5}[0-9a-f]{2}' "$REPO"/systemd/*.sh 2>/dev/null \
       | grep -v '^00:00:00:00:00:00$' || true)
if [ -z "$leak" ]; then
    ok "no real MAC address hardcoded in the repo"
else
    bad "hardcoded address(es): $(echo "$leak" | tr '\n' ' ')"
fi

echo
echo "===== 2. 时钟 ====="
if sudo -n test -f "$R/usr/lib/systemd/system/systemd-timesyncd.service"; then
    ok "systemd-timesyncd unit present"
    if sudo -n find "$R/etc/systemd/system" -path '*wants*' -name 'systemd-timesyncd.service' 2>/dev/null | grep -q .; then
        ok "systemd-timesyncd enabled"
    else
        bad "systemd-timesyncd not enabled"
    fi
else
    bad "systemd-timesyncd unit missing"
fi

echo
echo "===== 3. 蓝牙 ====="
grep -q '&qupv3_id_0 {' "$DTS" && ok "qupv3_id_0 enabled (uart6 parent)" || bad "qupv3_id_0 not enabled"
grep -q 'max-speed = <1500000>' "$DTS" && ok "max-speed lowered to 1500000" || maybe "max-speed unexpected"
if gzip -dc "$REPO/out/initramfs.cpio.gz" 2>/dev/null | cpio -t 2>/dev/null | grep -q 'qca/crbtfw21.tlv'; then
    ok "Bluetooth firmware in initramfs"
else
    bad "Bluetooth firmware missing from initramfs"
fi
sudo -n test -x "$R/usr/local/sbin/bluetooth-addr.sh" && ok "bluetooth-addr.sh installed" || bad "bluetooth-addr.sh missing"
if sudo -n find "$R/etc/systemd/system" -path '*wants*' -name 'bluetooth-addr.service' 2>/dev/null | grep -q .; then
    ok "bluetooth-addr.service enabled"
else
    bad "bluetooth-addr.service not enabled"
fi

echo
echo "===== 4. GPU ====="
for f in a630_sqe.fw a630_gmu.bin a630_zap.mdt; do
    gzip -dc "$REPO/out/initramfs.cpio.gz" 2>/dev/null | cpio -t 2>/dev/null | grep -q "qcom/$f" \
        && ok "$f in initramfs" || bad "$f missing"
done

echo
echo "===== 5. 电池 ====="
grep -q 'simple-battery' "$DTS" && ok "simple-battery present" || bad "simple-battery missing"
grep -q 'monitored-battery' "$DTS" && ok "monitored-battery wired" || maybe "not referenced"

echo
echo "===== 6. 音频 ====="
grep -q '&gpi_dma0 {' "$DTS" && ok "gpi_dma0 enabled" || bad "gpi_dma0 not enabled"
grep -q 'tas2557' "$DTS" && ok "TAS2557 node present" || bad "TAS2557 missing"
grep -q 'spkr-dai-link' "$DTS" && ok "speaker DAI link present" || bad "speaker link missing"
gzip -dc "$REPO/out/initramfs.cpio.gz" 2>/dev/null | cpio -t 2>/dev/null | grep -q 'tas2557_uCDSP.bin' \
    && ok "amplifier firmware in initramfs" || bad "amplifier firmware missing"

echo
echo "===== 7. rmtfs 去重 ====="
sudo -n grep -q 'rmtfs -r -P -s' "$R/usr/lib/systemd/system/rmtfs.service" 2>/dev/null \
    && ok "rmtfs runs with -s" || bad "rmtfs -s missing"
if sudo -n find "$R/etc/systemd/system" -path '*wants*' -name 'modem-start.service' 2>/dev/null | grep -q .; then
    bad "modem-start.service enabled (duplicates rmtfs -s)"
else
    ok "modem-start.service not enabled"
fi

echo
echo "===== 8. 可移植性 ====="
n=$(find "$REPO/kernel/tree-delta" -type f 2>/dev/null | wc -l)
[ "$n" -gt 0 ] && ok "tree-delta holds $n files" || bad "tree-delta missing"
grep -q 'qcom,q6voice.h' "$DTS" && bad "DTS still includes a non-mainline header" \
    || ok "DTS has no non-mainline includes"

echo
echo "===== 9. CI 与 release ====="
grep -q 'simg2img' "$REPO/.github/workflows/build.yml" && ok "simg2img used" || bad "simg2img missing"
grep -q 'Compress the rootfs image' "$REPO/.github/workflows/build.yml" && ok "compression step present" || bad "compression step missing"
grep -q 'rootfs.ext4.gz' "$REPO/.github/workflows/build.yml" && ok "release ships the gzipped rootfs" || bad "release ships raw rootfs"

echo
echo "===== 汇总 ====="
printf '  通过 %d，失败 %d，待确认 %d\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ] && echo "  全部通过" || echo "  有 $fail 项失败"
