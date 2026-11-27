# Mainline Linux on the Xiaomi Mi 8 Pro (equuleus)

**English** · [简体中文](README.zh-CN.md)

Debian 13 (trixie) arm64 with systemd on the Xiaomi Mi 8 Pro (`equuleus`,
M1807E8A, Snapdragon 845). The test handset has a physically broken AMOLED
panel, so the port is built to be usable headless: a USB CDC-ACM console with
automatic root login, plus USB NCM networking, is enough to install, debug and
run it.

CI builds the boot image and the root filesystem from a stock Linux
`v7.1-rc1` tree, the board device tree in `dts/`, the sources under
`kernel/tree-delta/` that vanilla mainline lacks, and the Samsung EA8074 panel
driver. Pushing a `v*` tag publishes both artifacts.

## Status at a glance

Everything below was verified on the test handset unless the row says
otherwise. Logs, measurements and failure modes are in
[docs/STATUS.md](docs/STATUS.md).

| Area | State | Evidence |
|---|---|---|
| Boot, storage, CPU | Works | 8 cores, 6 UFS LUNs, Debian on `userdata`; stable uptime instead of the early 27 s reset loop |
| USB console | Works | `ttyGS0` CDC-ACM with automatic root login |
| USB networking | Works | NCM at `192.168.42.1/24` comes up by itself at boot; IPv6 reachable from the host |
| USB-C host (OTG) | Works | 5 V at a 500 mA limit; a USB drive enumerated at High-Speed on three insertions |
| Wi-Fi | Works | 5 GHz, about 66 Mb/s, zero-loss pings |
| Wi-Fi hotspot | Works, off by default | `hotspot start wifi` or `hotspot start mobile` |
| Bluetooth | Works | `hci0` comes up and scans nearby devices |
| Cellular modem | Partial | SMS and IPv4 data work; IPv6 data needs upstream IPA routing rules; calls untested |
| GPU | Works with a caveat | Freedreno FD630 and Turnip Vulkan 1.3, with one SQE firmware gate relaxed |
| Video codec (Venus) | Nodes verified | Encoder and decoder nodes with the expected formats; throughput not benchmarked |
| Audio | Works | TAS2557 speaker and AMIC3 microphone |
| Vibration | Works | PMI8998 haptics with force feedback |
| Battery, charger, clock | Works | PMI8998 gauge and SMB2 charger; `systemd-timesyncd` once networking is up |
| White status LED | Works | PMIC hardware breathing patterns |
| Rear torch | Experimental | Brightness control exists, but the PMIC reports a fault and no light was observed |
| NFC | Partial | PN553 binds and answers NCI; tag reading and a userspace stack are missing |
| Touchscreen | Not enabled | Node exists; regulators untested |
| Display panel | Not usable on this unit | DSI PLL never locks and the AMOLED is broken |
| Rear camera | Not working | IMX363 probe times out on the CCI bus; investigation ongoing |
| GNSS | In progress, not merged | Independent Broadcom BCM47755 path on branch `bcm47755-gnss` |

## Install a release

Download `boot.img` and `rootfs.ext4.gz` from the same
[GitHub release](https://github.com/minghao680/equuleus-mainline/releases).

Flashing requires an unlocked `equuleus` bootloader and **erases userdata**.
Back up anything you need from the phone, including saved NetworkManager
profiles. Enter fastboot with Volume Down + Power, confirm the product, and
substitute your device's serial throughout.

```bash
gunzip -k rootfs.ext4.gz
fastboot devices
fastboot -s SERIAL getvar product
# Confirm the product is equuleus before flashing.
fastboot -s SERIAL flash boot boot.img
fastboot -s SERIAL flash userdata rootfs.ext4
fastboot -s SERIAL reboot
```

Open the USB serial port on the host at 115200 baud. The initramfs prepares the
CDC-ACM gadget, mounts the UFS `userdata` partition and switches to systemd. A
boot image can select a specific ext4 filesystem on UFS with `root=UUID=<uuid>`
in its kernel command line; without it the initramfs falls back to the UFS
partition named `userdata`. If the root mount fails in USB peripheral mode, the
initramfs exposes a shell over USB.

The release image ships a 4 GiB ext4 filesystem for transport. On first boot,
`x-systemd.growfs` in `fstab` expands it to fill the existing userdata
partition. Check the result with `df -h /`. On an older install, confirm that
`/` is ext4 on userdata with `findmnt -no SOURCE,FSTYPE /` before growing it
with `resize2fs /dev/sda21`.

## After installing

Run `nmtui` on the USB console to select a Wi-Fi network and save its profile.
NetworkManager connects automatically to a saved profile with autoconnect
enabled. For several networks, use `connection.autoconnect-priority` to express
a preference. A new image starts with no Wi-Fi profiles.

```bash
nmtui
nmcli device status
# Optional. Replace PROFILE with the saved profile name.
nmcli connection modify PROFILE connection.autoconnect yes connection.autoconnect-priority 10
```

SSH is available once the phone has a routable IP. The image permits root
password authentication because the USB console is the only other way in. Set a
password from that console with `passwd`, or install your public key in
`/root/.ssh/authorized_keys`. The first SSH start generates the phone's own host
keys.

Audio needs one mixer switch, which `audio-defaults.service` sets at boot:

```bash
amixer -c 0 sget 'QUAT_MI2S_RX Audio Mixer MultiMedia1'   # playback
aplay -D plughw:0,0 /path/to/file.wav
```

That routes the MultiMedia frontends to the TAS2557 speaker amplifier. The
SLIMBUS playback backend stays off: enabling it makes prepare fail with
`-EINVAL` and silences the speaker path.

Capture is enabled by the same service on a **different** frontend, because a
frontend cannot carry both directions:

```bash
arecord -D hw:0,1 -f S16_LE -r 48000 -c 2 -d 5 rec.wav   # AMIC3 microphone
```

The microphone is analog on **ADC3** (`AMIC3 -> ADC3 -> DEC0 -> CDC_IF TX0 ->
AIF1_CAP`); the DMIC path records silence and ADC1/ADC2 are floating inputs.
Two mixer traps that make a wrong setup look like broken hardware are described
in the [status notes](docs/STATUS.md).

The PMI8998 haptics block drives the vibration motor and accepts force-feedback
effects; no userspace setup is needed.

The white status LED supports hardware breathing patterns. The rear torch has an
experimental brightness control and stays off by default. Commands and current
test limits: [LED controls](docs/LEDS.md).

Use `bluetoothctl show` and `bluetoothctl --timeout 12 scan on` to check the
controller. A boot service reads the factory address on the phone and supplies
it through the kernel management interface before BlueZ starts. Details:
[Bluetooth bring-up notes](docs/bluetooth-complete.md).

### Wi-Fi hotspot (optional, off by default)

The image ships `hostapd`, `dnsmasq` and a helper, but nothing starts the
hotspot on boot:

```bash
hotspot start wifi     # share the Wi-Fi connection the phone is using
hotspot start mobile   # share the modem's IPv4 data
hotspot status
hotspot stop
```

Clients connect to `Equuleus-AP` with the password `equuleus1234` and get an
address from `192.168.50.10-100`. Edit `/etc/equuleus/hotspot.conf` to change
the SSID and password.

Things worth knowing before using it:

* The AP runs on a second interface (`ap0`) that must sit on the **same channel
  as the Wi-Fi client connection**. The WCN3990 firmware only allows concurrent
  STA+AP on one channel, and on 5 GHz it also needs `ieee80211ac=1` in the
  hostapd config; the helper sets both.
* Because the AP shares the radio with the uplink, throughput is roughly halved
  while the hotspot runs.
* `hotspot start mobile` needs an active IPv4 bearer. It installs a policy
  route (`192.168.50.0/24` to table 200) so client traffic leaves over the modem
  rather than the Wi-Fi uplink, and adds the on-link route for the modem's
  gateway; without that the kernel calls the default route unreachable.
* `hotspot stop` removes the interface, policy route, NAT rules and the DHCP
  snippet again, so `dnsmasq` stays healthy while the hotspot is off.

### Root filesystem contents

The rootfs uses Debian's standard package set, drawn from the Debian 13 Live
standard and ARM64 generic image manifests.
[Live standard packages](https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-13.8.0-amd64-standard.iso.packages)
· [ARM64 generic packages](https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.json)

| Task | Commands included |
|---|---|
| Hardware and processes | `lsusb`, `lspci`, `lshw`, `htop`, `lsof`, `strace`, `iostat`, `pidstat`, `inotifywait` |
| Networking | `nmtui`, `ssh`, `curl`, `wget`, `dig`, `nc`, `socat`, `arping`, `tracepath`, `traceroute`, `mtr`, `tcpdump`, `iperf3` |
| Storage and transfers | `lsblk`, `findmnt`, `fdisk`, `parted`, `gdisk`, `ncdu`, `rsync`, `mkfs.vfat`, `mkfs.exfat`, `mdir` |
| Archives | `tar`, `gzip`, `bzip2`, `xz`, `zip`, `unzip`, `lz4`, `zstd`, `pv` |
| Terminal and scripting | `sudo`, `vim`, `git`, `rg`, `fdfind`, `screen`, `tmux`, `bc`, `gawk`, `jq`, `python3 -m venv` |

The image also includes BlueZ, ALSA utilities, Docker and the Mesa Vulkan stack.
It generates `zh_CN.UTF-8`, selects it in `/etc/locale.conf` and includes Chinese
man pages where Debian provides them. Use `locale` to check the settings for your
session.

### Runtime tuning

These units are installed. The table notes how each one starts; tunable values
live in `config/` and are installed under `/etc/equuleus/`.

| Unit | Effect |
|---|---|
| `cpu-boost.service` | Big cluster at the 2.8032 GHz boost OPP for single-thread work |
| `perf-tuning.service` | Latency and storage tuning |
| `zram-swap.service` | zram swap with zstd |
| `wifi-bdf.service` | Extracts the board data file from the phone's own modem partition |
| `usb-ncm.service` | Brings NCM up automatically at boot and after every UDC event; a udev rule starts it, so the unit itself stays static rather than enabled |
| `venus-fw.service` | Extracts the signed Venus firmware from the phone and re-probes the codec |
| `audio-defaults.service` | Applies the mixer routing needed by playback and capture |

The TCP congestion control is BBR with the `fq` qdisc. Details and measured
numbers: [status notes](docs/STATUS.md).

## Build locally

### Boot image

Prepare a Linux `v7.1-rc1` tree, a static arm64 BusyBox, and a host with
`gcc-aarch64-linux-gnu`, `mkbootimg`, `cpio` and `python3`. Point `GPU_FW_DIR`
at staged Qualcomm firmware. The SQE blob needs a recent linux-firmware copy;
the 2021 stock one is too old for mainline. See
[Adreno firmware](docs/gpu-firmware.md).

```bash
export KERNEL_SRC="$HOME/linux-sdm845"
export BUSYBOX=/path/to/static/arm64/busybox
export GPU_FW_DIR="$ROOT/lib/firmware/qcom"
scripts/build.sh
python3 scripts/verify-image.py out/boot.img
```

The ABL expects the DTB directly after the kernel gzip stream; `pack-bootimg.sh`
refuses to produce an image otherwise. The boot image also carries firmware that
must be available before systemd starts: the GPU blobs, `tas2557_uCDSP.bin`, the
Bluetooth patch and NVM, and the IPA firmware.

### Root filesystem

Use a Linux host with `mmdebstrap`, `arch-test`, registered `qemu-aarch64-static`,
`e2fsprogs`, `simg2img`, `cpio`, `gzip` and `python3`. The package installer and
loop mounts need root or passwordless sudo.

```bash
export ROOT="$HOME/rootfs-arm64"
export ROM_DIR=/path/to/extracted/fastboot-rom/images

BUILD_IMAGE=0 scripts/build-rootfs.sh
scripts/prepare-firmware.sh
scripts/make-rootfs-image.sh
scripts/verify-rootfs-image.sh
```

`ROM_DIR` should contain `modem.img`, `vendor.img` and `bluetooth.img` from the
stock firmware. Run `scripts/build-rootfs.sh` without `BUILD_IMAGE=0` to build an
ext4 image directly from the staged userspace. Both paths reuse `ROOT` when it
already exists, so use a fresh directory for a clean image.

### CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds `boot.img`
and `rootfs.ext4` on every push, checks the boot layout, and inspects the packed
ext4 image for installed packages, shared libraries, firmware and the generated
locale. Firmware is extracted from Xiaomi's own CDN at build time and is not
stored in this repository.

## Repository layout

| Path | Contents |
|---|---|
| `dts/` | The board device tree, `sdm845-xiaomi-equuleus.dts` |
| `config/` | The kernel configuration used for the device |
| `kernel/tree-delta/` | Sources that vanilla mainline lacks, overlaid at build time |
| `kernel/panel-samsung-ea8074.c` | The panel driver |
| `kernel/patches/` | Small rebasable patches applied to the kernel tree |
| `initramfs/` | The initramfs `init` script |
| `systemd/` | Units, udev rules and helper scripts installed into the rootfs |
| `scripts/` | Build, firmware, verification and bring-up helpers |
| `docs/` | Bring-up notes and status |
| `out/` | Build output (ignored by Git) |

## Documentation

| Document | Topic |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | Full bring-up log with measurements and failure modes |
| [docs/LEDS.md](docs/LEDS.md) | White status LED and the experimental rear torch |
| [docs/gpu-firmware.md](docs/gpu-firmware.md) | Why the stock SQE blob cannot be used |
| [docs/bluetooth-complete.md](docs/bluetooth-complete.md) | Bluetooth address and firmware handling |
| [docs/reboot-bootloader-analysis.md](docs/reboot-bootloader-analysis.md) | How `reboot bootloader` reaches fastboot |
| [docs/HANDOFF.md](docs/HANDOFF.md) | Handoff notes for the port |

## Credits

The approach follows Mechres' mainline work on the Xiaomi Mi 8 (`dipper`) and
builds on the SDM845 mainline community's drivers and device trees.
[Mechres' repository](https://github.com/Mechres/xiaomi-mi8-dipper)

## License

GPL-2.0. [License](LICENSE)
