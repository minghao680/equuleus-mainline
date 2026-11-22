#!/bin/bash
# Report the enable state of the device tree nodes that matter, matched by the
# node name in the compiled DTB.
#
# Two earlier attempts were wrong and both produced misleading output:
#   - treating every <0x...> value as a phandle, so reg = <0x1000> looked dangling
#   - matching on compatible, which picks the first geni-i2c or geni-uart node,
#     not the one at the address we care about
#
# dtc already reports genuine phandle problems at compile time, so what is worth
# checking here is simply that the nodes we depend on are enabled.
set -u
DTB=${DTB:-$(cd "$(dirname "$0")/.." && pwd)/out/sdm845-xiaomi-equuleus.dtb}
[ -f "$DTB" ] || DTB=/home/claude/sdm845-mainline/arch/arm64/boot/dts/qcom/sdm845-xiaomi-equuleus.dtb
[ -f "$DTB" ] || { echo "找不到 DTB"; exit 1; }

# dtc is not necessarily on PATH: the kernel builds its own at scripts/dtc/dtc, and
# that is the one guaranteed to understand this DTB. Fall back to a system dtc, and
# fail with a clear message rather than a bare exit.
DTC=${DTC:-}
if [ -z "$DTC" ]; then
    for cand in \
        "$(dirname "$DTB")/../../../../../scripts/dtc/dtc" \
        /home/claude/sdm845-mainline/scripts/dtc/dtc \
        "$(command -v dtc 2>/dev/null)"
    do
        [ -n "$cand" ] && [ -x "$cand" ] && DTC=$cand && break
    done
fi
[ -n "$DTC" ] || { echo "找不到 dtc：设置 DTC=<路径> 指向内核的 scripts/dtc/dtc"; exit 1; }

DTS_OUT=$(mktemp)
"$DTC" -I dtb -O dts "$DTB" > "$DTS_OUT" 2>/dev/null || { echo "反编译失败 ($DTC)"; exit 1; }

pass=0; fail=0

# $1 = node name as it appears in the DTB, $2 = what it is for
report() {
    local node=$1 desc=$2
    local block st
    block=$(awk -v n="$node" '
        $0 ~ "^[ \t]*" n "[ \t]*\\{" { found = 1 }
        found { print; if (/^\t+\};/) exit }
    ' "$DTS_OUT")
    if [ -z "$block" ]; then
        printf '  [缺失]   %-28s %s\n' "$node" "$desc"
        fail=$((fail + 1))
        return
    fi
    st=$(echo "$block" | grep -oE 'status = "[a-z]+"' | head -1 | grep -oE '"[a-z]+"' | tr -d '"')
    st=${st:-okay}
    if [ "$st" = "okay" ]; then
        printf '  [%-8s] %-28s %s\n' "$st" "$node" "$desc"
        pass=$((pass + 1))
    else
        printf '  [%-8s] %-28s %s\n' "$st" "$node" "$desc"
        fail=$((fail + 1))
    fi
}

echo "===== 设备树关键节点 ====="
report "dma-controller@800000"  "gpi_dma0, i2c5 的 DMA 来源"
report "geniqup@8c0000"         "qupv3_id_0, uart6 的父节点"
report "i2c@894000"             "i2c5, TAS2557 功放"
report "serial@898000"          "uart6, 蓝牙"
report "sound"                  "声卡"
report "display-controller@ae01000" "MDSS 显示"
report "gpu@5000000"            "Adreno 630"
report "wifi@18800000"          "ath10k"
report "battery"                "电量计"
report "charger@1000"           "PMI8998 充电器"

echo
echo "===== 汇总: 启用 $pass，问题 $fail ====="
rm -f "$DTS_OUT"
