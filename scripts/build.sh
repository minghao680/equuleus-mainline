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
