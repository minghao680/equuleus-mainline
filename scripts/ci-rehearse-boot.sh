#!/bin/bash
# =============================================================================
# Reproduce the CI boot job locally, against a clean vanilla v7.1-rc1 tree.
#
# The whole point is to catch "works on my machine" failures before pushing.
# The local development tree is postmarketOS's patched build, so validating
# against it proves nothing about whether stock mainline works.
#
# usage: scripts/ci-rehearse-boot.sh [kernel-tag]
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:-v7.1-rc1}
WORK=${WORK:-/tmp/ci-rehearse}
DTS_NAME=sdm845-xiaomi-equuleus

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORK"
cd "$WORK"

# -----------------------------------------------------------------------------
if [ -d kernel/.git ]; then
    say "reusing the clone in $WORK/kernel"
    git -C kernel checkout --quiet FETCH_HEAD 2>/dev/null || true
else
    say "cloning $TAG (this takes a while)"
    rm -rf kernel
    git init --quiet kernel
    git -C kernel remote add origin https://github.com/torvalds/linux.git
    git -C kernel fetch --depth 1 origin "$TAG"
    git -C kernel checkout --quiet FETCH_HEAD
fi
echo "  kernel: $(make -s -C kernel kernelversion)"

# -----------------------------------------------------------------------------
say "applying the tree delta (sources vanilla mainline lacks)"
KERNEL_SRC="$WORK/kernel" "$REPO/scripts/apply-tree-delta.sh"

say "installing the device tree and panel driver"
DTS_DIR=kernel/arch/arm64/boot/dts/qcom
cp "$REPO/dts/$DTS_NAME.dts" "$DTS_DIR/"
grep -q "$DTS_NAME.dtb" "$DTS_DIR/Makefile" \
    || printf 'dtb-$(CONFIG_ARCH_QCOM)\t+= %s.dtb\n' "$DTS_NAME" >> "$DTS_DIR/Makefile"

PANEL_DIR=kernel/drivers/gpu/drm/panel
cp "$REPO/kernel/panel-samsung-ea8074.c" "$PANEL_DIR/"
if ! grep -q DRM_PANEL_SAMSUNG_EA8074 "$PANEL_DIR/Kconfig"; then
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
fi
grep -q panel-samsung-ea8074 "$PANEL_DIR/Makefile" \
    || printf 'obj-$(CONFIG_DRM_PANEL_SAMSUNG_EA8074) += panel-samsung-ea8074.o\n' >> "$PANEL_DIR/Makefile"

# -----------------------------------------------------------------------------
say "configuring"
cp "$REPO/config/equuleus.config" kernel/.config
make -s -C kernel ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# -----------------------------------------------------------------------------
say "building the device tree first (this is where portability breaks show up)"
make -C kernel ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     "qcom/$DTS_NAME.dtb"

say "building the kernel"
make -C kernel ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     KALLSYMS_EXTRA_PASS=1 -j"$(nproc)" Image.gz

# -----------------------------------------------------------------------------
say "packing"
OUT="$WORK/out" INITRD="${INITRD:-$REPO/out/initramfs.cpio.gz}" \
    "$REPO/scripts/pack-bootimg.sh" \
    "$WORK/kernel/arch/arm64/boot/Image.gz" \
    "$WORK/kernel/arch/arm64/boot/dts/qcom/$DTS_NAME.dtb" \
    "$WORK/out/boot.img"

python3 "$REPO/scripts/verify-image.py" "$WORK/out/boot.img"

say "rehearsal passed"
echo "  $WORK/out/boot.img"
