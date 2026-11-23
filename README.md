# Mainline Linux on the Xiaomi Mi 8 Pro (equuleus)

This port runs Debian 13 arm64 with systemd on the Xiaomi Mi 8 Pro (`equuleus`,
Snapdragon 845). A USB CDC-ACM console gives access to a phone with a broken
panel. CI builds Linux `v7.1-rc1` with the equuleus device tree, board patches
and Samsung EA8074 panel driver in this repository.

## Status

| Feature | Hardware evidence |
|---|---|
| Boot and storage | Debian on userdata, eight CPU cores and six UFS LUNs |
| USB access | Serial console on `ttyGS0`, with automatic root login |
| Wi-Fi | The factory address is read from `persist`. A 5 GHz test reached about 66 Mb/s and its short pings had zero loss. |
| Bluetooth | UART6 uses RTS/CTS. Configuring the factory address brought up `hci0` and a scan found nearby devices. |
| CPU | `qcom-cpufreq-hw` reached 1.77 GHz on the little cores and 2.65 GHz on the big cores |
| GPU | Mesa Freedreno FD630 ran glmark2, and Turnip exposed Vulkan 1.3 |
| Audio | ALSA enumerated playback and capture PCMs. The TAS2557 speaker amplifier loaded its firmware. |
| Battery and clock | PMI8998 reports charge and voltage. `systemd-timesyncd` synchronizes the system clock once networking is up. |

The bring-up notes include measured values and failure logs. [Hardware status](docs/STATUS.md)

## Install a release

Get `boot.img` and `rootfs.ext4.gz` for the same version. [GitHub releases](https://github.com/minghao680/equuleus-mainline/releases)

Flashing requires an unlocked `equuleus` bootloader and **erases userdata**.
Back up anything you need from the phone, including saved NetworkManager
profiles. Enter fastboot with Volume Down + Power, check the product, and
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

Open the USB serial port on the host at 115200 baud. The initramfs creates the
CDC-ACM gadget, mounts `/dev/sda21` and switches to systemd. If the root mount
fails, it exposes a shell over USB.

The release image has a 4 GiB ext4 filesystem for transport. On first boot,
`x-systemd.growfs` in `fstab` expands it to fill the existing userdata partition.
Check the new capacity with `df -h /`. On an older install, confirm that `/` is
ext4 on userdata with `findmnt -no SOURCE,FSTYPE /` before growing it with
`resize2fs /dev/sda21`.

## After installing

Run `nmtui` on the USB console to select a Wi-Fi network and save its profile.
NetworkManager uses saved profiles on the phone and automatically connects to
an available one with autoconnect enabled. For multiple networks, use
`connection.autoconnect-priority` to express a preference. A new image comes
with an empty set of Wi-Fi profiles.

```bash
nmtui
nmcli device status
# Optional. Replace PROFILE with the saved profile name.
nmcli connection modify PROFILE connection.autoconnect yes connection.autoconnect-priority 10
```

SSH is available once the phone has a routable IP and your public key is in
`authorized_keys` for the login account. Install your key from the USB console.

The rootfs uses Debian's standard package set and preinstalls `sudo`, `lspci`,
`lsusb`, `man`, `vim`, `curl`, `tcpdump`, `iperf3`, BlueZ, ALSA utilities,
Docker and the Mesa Vulkan stack. The image generates `zh_CN.UTF-8` and selects
it in `/etc/locale.conf`. Use `locale` to check the settings for your session.

Use `bluetoothctl show` and `bluetoothctl --timeout 12 scan on` to check the
Bluetooth controller. The boot service reads the factory address on the phone
and supplies it through the kernel management interface before BlueZ starts.
More detail is available in the [Bluetooth bring-up notes](docs/bluetooth-complete.md).

## Build locally

Use a Linux host with `mmdebstrap`, `arch-test`, registered `qemu-aarch64-static`,
`e2fsprogs`, `simg2img`, `cpio`, `gzip`, `python3`, a working `mkbootimg` and the
`aarch64-linux-gnu-` toolchain. The package installer and loop mounts need root
or passwordless sudo. CI uses an isolated APT source configuration to install
Debian packages and permits only `tqftpserv` from sid to resolve the modem's
vendor firmware path.

```bash
export ROOT="$HOME/rootfs-arm64"
export ROM_DIR=/path/to/extracted/fastboot-rom/images

BUILD_IMAGE=0 scripts/build-rootfs.sh
scripts/prepare-firmware.sh
scripts/make-rootfs-image.sh
scripts/verify-rootfs-image.sh
```

`ROM_DIR` should contain `modem.img`, `vendor.img` and `bluetooth.img` from the
stock firmware. Run `scripts/build-rootfs.sh` without `BUILD_IMAGE=0` to build
an ext4 image directly from the staged userspace. Both paths reuse `ROOT` when
it already exists. Use a fresh directory for a clean image.

To build `out/boot.img`, prepare a Linux `v7.1-rc1` tree and a static arm64
BusyBox. Point `GPU_FW_DIR` at the staged Qualcomm firmware and replace the
stock SQE file with a recent linux-firmware copy as described below.
[Adreno firmware](docs/gpu-firmware.md)

```bash
export KERNEL_SRC="$HOME/linux-sdm845"
export BUSYBOX=/path/to/static/arm64/busybox
export GPU_FW_DIR="$ROOT/lib/firmware/qcom"
scripts/build.sh
python3 scripts/verify-image.py out/boot.img
```

The ABL expects the DTB directly after the kernel gzip stream. The boot image
also contains firmware needed before systemd starts. The GitHub Actions jobs
check the boot layout and inspect the packed ext4 image, including installed
packages, shared libraries, firmware and the generated locale. A `v*` tag
publishes the compressed rootfs, boot image and firmware provenance.
[Build workflow](.github/workflows/build.yml)

## Credits

The approach follows Mechres' mainline work on the Xiaomi Mi 8 (`dipper`) and
builds on the SDM845 mainline community's drivers and device trees.
[Mechres' repository](https://github.com/Mechres/xiaomi-mi8-dipper)

## License

GPL-2.0. [License](LICENSE)
