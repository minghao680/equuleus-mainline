#!/bin/bash
# =============================================================================
# Turn a prepared rootfs directory into a flashable ext4 image.
#
# Kept separate from build-rootfs.sh so a caller can add things to the rootfs
# (firmware, daemons) and then build the image once, instead of building it,
# modifying the rootfs and building again.
#
# The filesystem UUID is reused from the rootfs's own /etc/fstab when one is
# already recorded there, so rebuilding never breaks the mount.
#
# Environment:
#   ROOT      rootfs directory  (default: $HOME/rootfs-arm64)
#   OUT       output directory  (default: ./out)
#   IMG       output image      (default: $OUT/rootfs.ext4)
#   SIZE_MB   image size        (default: 4096)
#
# usage: scripts/make-rootfs-image.sh
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$REPO/out}
ROOT=${ROOT:-$HOME/rootfs-arm64}
IMG=${IMG:-$OUT/rootfs.ext4}
SIZE_MB=${SIZE_MB:-4096}

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sudo -n true 2>/dev/null || die "this script needs passwordless sudo"
[ -d "$ROOT" ] || die "rootfs not found: $ROOT"
command -v mke2fs >/dev/null || die "mke2fs not found (e2fsprogs)"

mkdir -p "$OUT"

say "resolving the filesystem UUID"
UUID=$(sudo -n awk -F'[= ]+' '/^UUID=/{print $2; exit}' "$ROOT/etc/fstab" 2>/dev/null || true)
case "${UUID:-}" in
    ''|__ROOT_UUID__)
        UUID=$(cat /proc/sys/kernel/random/uuid)
        sudo -n sed -i "s/UUID=__ROOT_UUID__/UUID=$UUID/" "$ROOT/etc/fstab"
        echo "  generated: $UUID"
        ;;
    *)
        echo "  reusing:   $UUID"
        ;;
esac

say "creating the image"
rm -f "$IMG"
truncate -s "${SIZE_MB}M" "$IMG"
sudo -n mke2fs -t ext4 -F -m 1 -L rootfs -U "$UUID" -d "$ROOT" "$IMG" >/dev/null

os_release=$([ -r "$ROOT/etc/os-release" ] && . "$ROOT/etc/os-release" 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)
say "done"
echo "  image : $IMG"
echo "  size  : $(stat -c%s "$IMG") bytes"
echo "  uuid  : $UUID"
echo "  system: $os_release"
