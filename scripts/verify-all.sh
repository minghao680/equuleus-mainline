#!/bin/bash
# =============================================================================
# Run every verification in one go.
#
# Four checks have accumulated, each catching a different class of problem:
#
#   audit-objective.sh     source, device tree and config (31 checks)
#   check-dtb-nodes.sh     the compiled DTB's key nodes are enabled (10 checks)
#   verify-rootfs-image.sh what is actually inside the shipped image (31 checks)
#   verify-unit-targets.sh every unit reference resolves (58 checks)
#
# They were written after three real bugs that only one of them would have caught:
# a stale image, a missing bluez package, and a unit pointing at a script that is
# not installed. Running them together is the point.
#
# usage: scripts/verify-all.sh [rootfs-dir]
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
ROOT=${1:-${ROOT:-$HOME/rootfs-arm64}}
IMG=${IMG:-$REPO/rootfs.ext4}

total_fail=0

section() { printf '\n\033[1m========== %s ==========\033[0m\n' "$*"; }

section "1/4 目标审计（源码、设备树、配置）"
if ROOT="$ROOT" bash "$REPO/scripts/audit-objective.sh" 2>&1 | tail -4; then
    :
else
    total_fail=$((total_fail + 1))
fi

section "2/4 设备树节点"
if bash "$REPO/scripts/check-dtb-nodes.sh" 2>&1 | tail -4; then
    :
else
    total_fail=$((total_fail + 1))
fi

section "3/4 发布镜像内容"
if [ -f "$IMG" ]; then
    if IMG="$IMG" bash "$REPO/scripts/verify-rootfs-image.sh" 2>&1 | tail -4; then
        :
    else
        total_fail=$((total_fail + 1))
    fi
else
    echo "  跳过：找不到 $IMG"
fi

section "4/4 单元引用完整性"
if [ -f "$IMG" ]; then
    if IMG="$IMG" bash "$REPO/scripts/verify-unit-targets.sh" 2>&1 | tail -3; then
        :
    else
        total_fail=$((total_fail + 1))
    fi
else
    echo "  跳过：找不到 $IMG"
fi

section "汇总"
if [ "$total_fail" -eq 0 ]; then
    echo "  全部检查通过"
else
    echo "  有 $total_fail 组检查失败"
fi

exit "$total_fail"
