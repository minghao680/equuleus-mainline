#!/bin/bash
# =============================================================================
# Overlay the source files this device tree needs that vanilla mainline lacks.
#
# The kernel was brought up against postmarketOS's linux-sdm845-7.1-rc1-r0,
# which reports 7.1.0-rc1 but carries patches. Building against stock
# torvalds/linux v7.1-rc1 fails on things that only exist in the patched tree:
#
#   pmi8998_fg      fuel gauge node + driver
#   qcom,q6voice.h  voice DAI bindings
#   q6voice         (dropped - not needed for playback or capture)
#
# Rather than fork the kernel, the five files that matter are kept in
# kernel/tree-delta/ and copied over a stock checkout. That keeps the patch set
# reviewable and makes CI build exactly what the device was tested with.
#
# Environment:
#   KERNEL_SRC  kernel tree to modify (required)
#
# usage: scripts/apply-tree-delta.sh
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
KERNEL_SRC=${KERNEL_SRC:?set KERNEL_SRC to the kernel tree to patch}
DELTA=$REPO/kernel/tree-delta

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -d "$KERNEL_SRC" ] || die "kernel tree not found: $KERNEL_SRC"
[ -d "$DELTA" ] || die "tree delta not found: $DELTA"

say "overlaying $(find "$DELTA" -type f | wc -l) files"
cd "$DELTA"
find . -type f | while read -r f; do
    rel=${f#./}
    dest="$KERNEL_SRC/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -f "$f" "$dest"
    echo "  $rel"
done

# The fuel gauge driver and the charger need to be reachable from the build.
say "wiring the added drivers into Kconfig and Makefile"
PS=$KERNEL_SRC/drivers/power/supply

if ! grep -q 'BATTERY_PMI8998_FG' "$PS/Kconfig" 2>/dev/null; then
    cat >> "$PS/Kconfig" <<'EOF'

config BATTERY_PMI8998_FG
	tristate "Qualcomm PMI8998 fuel gauge"
	depends on MFD_SPMI_PMIC
	help
	  Say Y to enable the PMI8998 battery fuel gauge found on SDM845
	  boards such as the Xiaomi Mi 8 and Mi 8 Pro.
EOF
    echo "  added BATTERY_PMI8998_FG to Kconfig"
fi

if ! grep -q 'pmi8998_fg' "$PS/Makefile" 2>/dev/null; then
    printf 'obj-$(CONFIG_BATTERY_PMI8998_FG)\t+= pmi8998_fg.o\n' >> "$PS/Makefile"
    echo "  added pmi8998_fg to Makefile"
fi

if ! grep -q 'CHARGER_QCOM_SMB2' "$PS/Kconfig" 2>/dev/null; then
    cat >> "$PS/Kconfig" <<'EOF'

config CHARGER_QCOM_SMB2
	tristate "Qualcomm PMI8998 PMIC charger driver"
	depends on MFD_SPMI_PMIC
	depends on IIO
	help
	  Say Y to enable the SMB2 switch mode battery charger found in the
	  PMI8998 and related Qualcomm PMICs.
EOF
    echo "  added CHARGER_QCOM_SMB2 to Kconfig"
fi

if ! grep -q 'qcom_smbx' "$PS/Makefile" 2>/dev/null; then
    printf 'obj-$(CONFIG_CHARGER_QCOM_SMB2)\t+= qcom_smbx.o\n' >> "$PS/Makefile"
    echo "  added qcom_smbx to Makefile"
fi

say "done"
