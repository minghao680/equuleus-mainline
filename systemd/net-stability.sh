#!/bin/sh
# Longer-running network stability check.
#
# The existing measurement is a single curl and two short pings, which shows the
# link works but says nothing about whether it stays up. This runs for a while and
# reports the things that actually indicate instability: latency spread, loss
# over time, and whether the link ever drops and reconnects.
#
# usage: net-stability.sh [minutes]   (default 5)

DURATION_MIN=${1:-5}
PING_TARGET=${PING_TARGET:-223.5.5.5}
GATEWAY=$(ip route | awk '/^default/ {print $3; exit}')

echo "=== 网络稳定性测试 ${DURATION_MIN} 分钟 ==="
echo "  接口:   $(ip -brief addr show wlan0 | awk '{print $1, $3}')"
echo "  网关:   ${GATEWAY:-unknown}"
echo "  目标:   $PING_TARGET"
echo

# Baseline link state.
iw dev wlan0 link 2>/dev/null | head -4
echo

PINGS=$((DURATION_MIN * 60))
echo "=== 连续 $PINGS 次 ping（1 秒间隔）==="
# -i 1 keeps it gentle; -D prints timestamps so a gap is visible.
ping -i 1 -c "$PINGS" "$PING_TARGET" 2>&1 | tail -4

echo
echo "=== 网关延迟分布 ==="
if [ -n "$GATEWAY" ]; then
    ping -c 30 -i 0.3 "$GATEWAY" 2>&1 | tail -2
fi

echo
echo "=== 关联状态（测试后）==="
iw dev wlan0 link 2>/dev/null | head -6

echo
echo "=== 重连次数（dmesg 里的断开记录）==="
dmesg 2>/dev/null | grep -ciE 'wlan0.*(disconnect|deauth|link is not ready)' || echo 0

echo
echo "=== 吞吐复测 ==="
if command -v curl >/dev/null 2>&1; then
    curl -o /dev/null -s -w '  下载 13 MB: %{speed_download} B/s (%{time_total} s)\n' \
        --max-time 60 https://mirrors.ustc.edu.cn/debian/ls-lR.gz 2>/dev/null \
        || echo "  curl 失败"
fi
