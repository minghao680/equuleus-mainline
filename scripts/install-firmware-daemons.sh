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

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/sudo.sh"

MIRROR=${MIRROR:-http://deb.debian.org/debian}
ROOT=${ROOT:-$HOME/rootfs-arm64}
WORK=${WORK:-$(mktemp -d)}
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -d "$ROOT" ] || die "rootfs not found: $ROOT"

mkdir -p "$WORK"
cd "$WORK"

# -f and -L both matter here. Without -f curl writes the error page into the
# output file and still exits 0; without -L it does not follow deb.debian.org's
# redirect to an actual mirror. Together those produced a silent failure that
# then looked like a corrupt index.
fetch_index() {
    curl -fsSL --retry 3 --retry-delay 2 --max-time 900 \
        "$MIRROR/dists/$1/main/binary-arm64/Packages.gz" -o "$1.gz" \
        || die "cannot fetch $1 package index from $MIRROR"
    gzip -t "$1.gz" 2>/dev/null \
        || die "invalid package index for $1 (mirror did not return gzip)"
}

fetch_pkg() {
    local suite=$1 pkg=$2
    local fn
    # awk exits as soon as it finds the entry, which closes the pipe and makes
    # gzip die of SIGPIPE. Under pipefail that turns the whole pipeline into a
    # failure and, because this runs in a command substitution under set -e,
    # the script exits with no message at all. Hence the || true.
    fn=$( { gzip -dc "$suite.gz" 2>/dev/null \
            | awk -v p="$pkg" '$0=="Package: "p{f=1} f&&/^Filename:/{print $2; exit}'; } || true )
    [ -n "$fn" ] || { echo "  not in $suite: $pkg"; return 1; }
    echo "  $pkg ($suite) -> $fn"
    [ -f "$pkg.deb" ] || curl -fsSL --retry 3 --max-time 600 -o "$pkg.deb" "$MIRROR/$fn" \
        || { echo "  download failed: $pkg"; return 1; }
    $SUDO dpkg-deb -x "$pkg.deb" "$ROOT" || { echo "  extract failed: $pkg"; return 1; }
}

say "fetching package indexes"
fetch_index trixie
fetch_index sid

say "installing rmtfs and pd-mapper (trixie)"
fetch_pkg trixie rmtfs
fetch_pkg trixie protection-domain-mapper
fetch_pkg trixie libqrtr1

# tqftpserv 1.3 from sid is required: 1.1 rejects the vendor firmware paths this
# modem actually requests. libzstd is needed by 1.3.
say "installing tqftpserv 1.3 (sid) and its dependencies"
fetch_pkg sid tqftpserv
fetch_pkg trixie libzstd1

# bluez provides bluetoothd, bluetoothctl and btmgmt. Without it the controller
# probes and hci0 appears, but nothing can drive it and bluetooth-addr.sh has no
# btmgmt to set the address with. It is not pulled in by anything else here.
say "installing bluez"
fetch_pkg trixie bluez

# NetworkManager provides nmtui and nmcli. systemd-networkd was the previous
# default but has no interactive interface, and nmtui is how the network gets
# configured on a device with no working display.
say "installing NetworkManager and nmtui"
fetch_pkg trixie network-manager

# Docker, NetworkManager and the Vulkan stack each pull in a dependency tree, and
# fetch_pkg only extracts a single .deb without recording it - docker.io is a
# metapackage whose /usr/bin/docker lives in docker-cli, so extracting it alone
# produced an image with dockerd but no CLI. apt resolves the tree and records the
# packages, which also makes dpkg -l work for later diagnosis.
say "installing Docker, NetworkManager and Vulkan with apt"
apt_install() {
    $SUDO chroot "$ROOT" /bin/sh -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq $* 2>&1 | tail -3
    " || echo "  apt install failed: $*"
}

# apt needs a working sources.list and a resolv.conf inside the rootfs.
$SUDO mkdir -p "$ROOT/etc/apt/sources.list.d"
$SUDO tee "$ROOT/etc/apt/sources.list.d/debian.list" >/dev/null <<EOF
deb $MIRROR trixie main
EOF
$SUDO cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
$SUDO mount --bind /dev "$ROOT/dev" 2>/dev/null || true
$SUDO mount -t proc proc "$ROOT/proc" 2>/dev/null || true
$SUDO mount -t sysfs sys "$ROOT/sys" 2>/dev/null || true

$SUDO chroot "$ROOT" /bin/sh -c 'apt-get update -qq 2>&1 | tail -2' || true

apt_install docker.io containerd runc
apt_install network-manager
apt_install libvulkan1 mesa-vulkan-drivers vulkan-tools

$SUDO umount "$ROOT/sys" "$ROOT/proc" "$ROOT/dev" 2>/dev/null || true

say "installing WiFi userspace tools"
fetch_pkg trixie iw
fetch_pkg trixie wpasupplicant
fetch_pkg trixie libnl-3-200
fetch_pkg trixie libnl-genl-3-200
fetch_pkg trixie libnl-route-3-200
fetch_pkg trixie rfkill

# The PMIC RTC reports 1970 and the kernel fabricates a wall clock from it, so
# nothing that depends on real time works until NTP has run once.
say "installing time synchronisation"
fetch_pkg trixie systemd-timesyncd
fetch_pkg trixie util-linux-extra

# -----------------------------------------------------------------------------
say "enabling services"
W="$ROOT/etc/systemd/system/multi-user.target.wants"
$SUDO mkdir -p "$W"
for u in rmtfs.service pd-mapper.service tqftpserv.service systemd-timesyncd.service; do
    $SUDO ln -sf "/usr/lib/systemd/system/$u" "$W/$u"
    echo "  enabled: $u"
done

# The modem asks for files under /readonly/vendor/firmware_mnt/image/ and
# /readonly/firmware/image/, which tqftpserv maps onto /lib/firmware/. Put the
# images where it can reach them.
say "staging firmware images for tqftpserv"
SRC="$ROOT/lib/firmware/qcom/sdm845/mi8"
DEST="$ROOT/lib/firmware/image"
if [ -d "$SRC" ]; then
    $SUDO mkdir -p "$DEST"
    for f in "$SRC"/*; do
        [ -f "$f" ] || continue
        $SUDO cp -f "$f" "$DEST/"
    done
    echo "  $($SUDO ls -1 "$DEST" | wc -l) files staged in /lib/firmware/image"
else
    echo "  warning: $SRC not found - install the modem firmware first"
fi

# -----------------------------------------------------------------------------
say "verifying tqftpserv knows the vendor paths"
# grep -a rather than strings: strings lives in binutils, which a rootfs-only
# build host has no reason to have installed.
if grep -aq '/readonly/vendor/firmware_mnt/image/' "$ROOT/usr/bin/tqftpserv"; then
    echo "  OK - tqftpserv accepts /readonly/vendor/firmware_mnt/image/"
else
    die "tqftpserv does not know the vendor firmware path; WiFi will not come up"
fi

say "rebuilding the ext4 image"
$SUDO mkdir -p "$ROOT/lib/systemd/system" 2>/dev/null || true
echo "  rootfs updated; run your image build to produce a flashable image"
