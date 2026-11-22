#!/bin/bash
# =============================================================================
# Install the firmware daemons the SDM845 WiFi chain needs, then rebuild the
# rootfs image.
#
# WiFi on this SoC does not come up from ath10k alone. The chain is:
#
#   modem (MSS) -> GLINK/QRTR -> service discovery -> rmtfs/EFS
#   -> PDR msm/modem/wlan_pd -> TQFTP serves wlanmdsp.mbn to the modem
#   -> WLFW QMI service registers -> ath10k_snoc -> wlan0
#
# Every one of those is userspace. Nothing here needs a kernel driver, and the
# modem's "provider: kernel / service: elf_loader" entry in modemuw.jsn is a
# servreg description rather than an instruction to write one.
#
# The one non-obvious detail: tqftpserv must be >= 1.3. Version 1.1 (Debian
# trixie) only accepts /readonly/firmware/image/, while this modem asks for
# /readonly/vendor/firmware_mnt/image/. Version 1.3 (Debian sid) accepts both.
# With 1.1 the log shows "invalid path ... rejecting" and WiFi never appears.
#
# Environment:
#   ROOT   rootfs directory  (default: $HOME/rootfs-arm64)
#
# usage: scripts/install-firmware-daemons.sh
# =============================================================================
set -euo pipefail

MIRROR=${MIRROR:-http://deb.debian.org/debian}
ROOT=${ROOT:-$HOME/rootfs-arm64}
WORK=${WORK:-$(mktemp -d)}
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sudo -n true 2>/dev/null || die "this script needs passwordless sudo"
[ -d "$ROOT" ] || die "rootfs not found: $ROOT"

mkdir -p "$WORK"
cd "$WORK"

fetch_index() {
    curl -s --max-time 180 "$MIRROR/dists/$1/main/binary-arm64/Packages.gz" -o "$1.gz" \
        || die "cannot fetch $1 package index"
    gzip -t "$1.gz" 2>/dev/null || die "invalid package index for $1"
}

fetch_pkg() {
    local suite=$1 pkg=$2
    local fn
    fn=$(gzip -dc "$suite.gz" | awk -v p="$pkg" '$0=="Package: "p{f=1} f&&/^Filename:/{print $2; exit}')
    [ -n "$fn" ] || { echo "  not in $suite: $pkg"; return 1; }
    echo "  $pkg ($suite) -> $fn"
    [ -f "$pkg.deb" ] || curl -s --max-time 300 -o "$pkg.deb" "$MIRROR/$fn"
    sudo -n dpkg-deb -x "$pkg.deb" "$ROOT"
}

say "fetching package indexes"
fetch_index trixie
fetch_index sid

say "installing rmtfs and pd-mapper (trixie)"
fetch_pkg trixie rmtfs
fetch_pkg trixie pd-mapper
fetch_pkg trixie libqrtr1

# tqftpserv 1.3 from sid is required: 1.1 rejects the vendor firmware paths this
# modem actually requests. libzstd is needed by 1.3.
say "installing tqftpserv 1.3 (sid) and its dependencies"
fetch_pkg sid tqftpserv
fetch_pkg trixie libzstd1

say "installing WiFi userspace tools"
fetch_pkg trixie iw
fetch_pkg trixie wpasupplicant
fetch_pkg trixie libnl-3-200
fetch_pkg trixie libnl-genl-3-200
fetch_pkg trixie libnl-route-3-200
fetch_pkg trixie rfkill

# -----------------------------------------------------------------------------
say "enabling services"
W="$ROOT/etc/systemd/system/multi-user.target.wants"
sudo -n mkdir -p "$W"
for u in rmtfs.service pd-mapper.service tqftpserv.service; do
    sudo -n ln -sf "/usr/lib/systemd/system/$u" "$W/$u"
    echo "  enabled: $u"
done

# The modem asks for files under /readonly/vendor/firmware_mnt/image/ and
# /readonly/firmware/image/, which tqftpserv maps onto /lib/firmware/. Put the
# images where it can reach them.
say "staging firmware images for tqftpserv"
SRC="$ROOT/lib/firmware/qcom/sdm845/mi8"
DEST="$ROOT/lib/firmware/image"
if [ -d "$SRC" ]; then
    sudo -n mkdir -p "$DEST"
    for f in "$SRC"/*; do
        [ -f "$f" ] || continue
        sudo -n cp -f "$f" "$DEST/"
    done
    echo "  $(sudo -n ls -1 "$DEST" | wc -l) files staged in /lib/firmware/image"
else
    echo "  warning: $SRC not found - install the modem firmware first"
fi

# -----------------------------------------------------------------------------
say "verifying tqftpserv knows the vendor paths"
if strings -a "$ROOT/usr/bin/tqftpserv" | grep -q '/readonly/vendor/firmware_mnt/image/'; then
    echo "  OK - tqftpserv accepts /readonly/vendor/firmware_mnt/image/"
else
    die "tqftpserv does not know the vendor firmware path; WiFi will not come up"
fi

say "rebuilding the ext4 image"
sudo -n mkdir -p "$ROOT/lib/systemd/system" 2>/dev/null || true
echo "  rootfs updated; run your image build to produce a flashable image"
