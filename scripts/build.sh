#!/bin/bash
# =============================================================================
# Build mainline Linux for the Xiaomi Mi 8 Pro (equuleus, SDM845).
#
# The kernel is NOT patched. The only changes made to the tree are:
#   * one new file: arch/arm64/boot/dts/qcom/sdm845-xiaomi-equuleus.dts
#   * one added line in arch/arm64/boot/dts/qcom/Makefile
#
# Everything else is a stock sdm845 mainline kernel plus the config in config/.
#
# Environment:
#   KERNEL_SRC   path to an existing kernel tree      (default: $HOME/linux-sdm845)
#   OUT          output directory                     (default: ./out)
#   BUSYBOX      static aarch64 busybox binary        (default: auto-detect)
#   JOBS         parallel build jobs                  (default: nproc)
#
# usage: scripts/build.sh [--no-initramfs]
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
KERNEL_SRC=${KERNEL_SRC:-$HOME/linux-sdm845}
OUT=${OUT:-$REPO/out}
JOBS=${JOBS:-$(nproc)}
DTS_NAME=sdm845-xiaomi-equuleus

SKIP_INITRAMFS=0
[ "${1:-}" = "--no-initramfs" ] && SKIP_INITRAMFS=1

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
say "checking the kernel tree"
[ -d "$KERNEL_SRC" ] || die "KERNEL_SRC not found: $KERNEL_SRC
  Get a kernel tree first, for example:
    git clone --depth 1 https://github.com/SoMainline/linux.git \"\$HOME/linux-sdm845\"
  This project was developed and tested against 7.1.0-rc1 (postmarketOS
  linux-sdm845-7.1-rc1-r0). Other versions may need device tree fixups."

KVER=$(make -s -C "$KERNEL_SRC" kernelversion 2>/dev/null || true)
[ -n "$KVER" ] || die "cannot determine kernel version in $KERNEL_SRC"
echo "  kernel: $KERNEL_SRC ($KVER)"

# -----------------------------------------------------------------------------
say "installing device tree"
DTS_DIR=$KERNEL_SRC/arch/arm64/boot/dts/qcom
cp -f "$REPO/dts/$DTS_NAME.dts" "$DTS_DIR/$DTS_NAME.dts"

if ! grep -q "$DTS_NAME.dtb" "$DTS_DIR/Makefile"; then
    printf 'dtb-$(CONFIG_ARCH_QCOM)\t+= %s.dtb\n' "$DTS_NAME" >> "$DTS_DIR/Makefile"
    echo "  added Makefile entry"
else
    echo "  Makefile entry already present"
fi

# -----------------------------------------------------------------------------
say "installing the panel driver"
# Shipped as a plain source file rather than a patch: the patch also touches
# drivers/gpu/drm/panel/Kconfig and Makefile, whose surrounding context differs
# between kernel trees and makes patch(1) fail. The new file has no such
# problem, and the two build hooks are single lines.
PANEL_DIR=$KERNEL_SRC/drivers/gpu/drm/panel
cp -f "$REPO/kernel/panel-samsung-ea8074.c" "$PANEL_DIR/panel-samsung-ea8074.c"

if ! grep -q 'DRM_PANEL_SAMSUNG_EA8074' "$PANEL_DIR/Kconfig"; then
    cat >> "$PANEL_DIR/Kconfig" <<'EOF'

config DRM_PANEL_SAMSUNG_EA8074
	tristate "Samsung EA8074 DSI cmd mode panel"
	depends on OF
	depends on DRM_MIPI_DSI
	depends on BACKLIGHT_CLASS_DEVICE
	help
	  Say Y here to enable the Samsung EA8074 AMOLED command mode panel
	  (1080x2248@60Hz) found in the Xiaomi Mi 8 and Mi 8 Pro.
EOF
    echo "  added Kconfig entry"
fi

if ! grep -q 'panel-samsung-ea8074' "$PANEL_DIR/Makefile"; then
    printf 'obj-$(CONFIG_DRM_PANEL_SAMSUNG_EA8074) += panel-samsung-ea8074.o\n' \
        >> "$PANEL_DIR/Makefile"
    echo "  added Makefile entry"
fi

# -----------------------------------------------------------------------------
say "installing config"
if [ -f "$KERNEL_SRC/.config" ] && cmp -s "$REPO/config/equuleus.config" "$KERNEL_SRC/.config"; then
    echo "  config already up to date"
else
    cp -f "$REPO/config/equuleus.config" "$KERNEL_SRC/.config"
    echo "  config installed"
fi
make -s -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# -----------------------------------------------------------------------------
say "building kernel"
make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     KALLSYMS_EXTRA_PASS=1 -j"$JOBS" \
     Image.gz "qcom/$DTS_NAME.dtb"

KGZ=$KERNEL_SRC/arch/arm64/boot/Image.gz
DTB=$KERNEL_SRC/arch/arm64/boot/dts/qcom/$DTS_NAME.dtb
[ -f "$KGZ" ] || die "Image.gz was not produced"
[ -f "$DTB" ] || die "$DTS_NAME.dtb was not produced"
echo "  Image.gz : $(stat -c%s "$KGZ") bytes"
echo "  dtb      : $(stat -c%s "$DTB") bytes"

# -----------------------------------------------------------------------------
mkdir -p "$OUT"

if [ "$SKIP_INITRAMFS" -eq 0 ]; then
    say "building initramfs"
    # GPU_FW_DIR is what puts a630_sqe.fw into the image. msm is built in and
    # loads it during probe, before the root filesystem is mounted, so without
    # this the GPU never comes up. Point it at wherever prepare-firmware.sh
    # installed the files.
    GPU_FW_DIR=${GPU_FW_DIR:-$HOME/rootfs-trixie-arm64/lib/firmware/qcom} \
    KERNEL_SRC=$KERNEL_SRC OUT=$OUT BUSYBOX=${BUSYBOX:-} \
        "$REPO/scripts/build-initramfs.sh"
    INITRD=$OUT/initramfs.cpio.gz
else
    say "skipping initramfs"
    INITRD=${INITRD:-$OUT/initramfs.cpio.gz}
    [ -f "$INITRD" ] || die "no initramfs at $INITRD (drop --no-initramfs or provide INITRD=...)"
fi

# -----------------------------------------------------------------------------
say "packing boot image"
KERNEL_SRC=$KERNEL_SRC OUT=$OUT INITRD=$INITRD \
    "$REPO/scripts/pack-bootimg.sh" "$KGZ" "$DTB"

# -----------------------------------------------------------------------------
say "verifying"
python3 "$REPO/scripts/verify-image.py" "$OUT/boot.img"

say "done"
echo "  $OUT/boot.img"
echo
echo "  flash with:"
echo "    fastboot -s <serial> flash boot $OUT/boot.img"
