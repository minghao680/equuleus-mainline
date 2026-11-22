# Mainline Linux on the Xiaomi Mi 8 Pro (equuleus)

Getting a **stock mainline Linux kernel** to boot on the Xiaomi Mi 8 Pro
(`equuleus`, Qualcomm SDM845) and give you a usable shell over USB — on a phone
whose display is dead.

The kernel is **not patched**. The whole change is:

* one new device tree, `dts/sdm845-xiaomi-equuleus.dts`
* one line added to `arch/arm64/boot/dts/qcom/Makefile`
* a config, an initramfs, and a packaging script that respects what the Xiaomi
  bootloader actually validates

---

## Status

| | |
|---|---|
| Boots to userspace | **yes** — `Run /init as init process` |
| Symmetric multiprocessing | **yes** — all 8 cores online |
| RAM | **yes** — 7,797,064 kB detected (8 GB board) |
| USB CDC-ACM console | **yes** — appears as a serial port on the host |
| UART `ttyMSM0` | **yes** — `a84000.serial` probes |
| UFS storage | no — `sync_state() pending due to 1d84000.ufshc` |
| Root filesystem | no — initramfs only |
| Display / touch | not enabled (the panel is physically broken anyway) |

Tested kernel: `7.1.0-rc1` (`linux-sdm845-7.1-rc1-r0`, the postmarketOS package),
built with clang 19.1.7 / LLD 19.1.7.

---

## Requirements

* A kernel tree. This was developed against `7.1.0-rc1`; other versions may need
  device tree adjustments.

  ```bash
  git clone --depth 1 https://github.com/SoMainline/linux.git "$HOME/linux-sdm845"
  ```

* `aarch64-linux-gnu-` cross compiler, `mkbootimg`, `cpio`, `gzip`, `python3`
* A **statically linked aarch64 busybox** (the build script explains how to get
  one if you don't have it)
* An unlocked bootloader on the phone

---

## Build

```bash
export KERNEL_SRC="$HOME/linux-sdm845"
export BUSYBOX=/path/to/static/aarch64/busybox

scripts/build.sh
```

Output: `out/boot.img` (64 MiB, ready to flash).

The script copies the device tree into the kernel tree, installs
`config/equuleus.config`, builds `Image.gz` + the DTB, builds the initramfs and
packs the boot image. Run `scripts/verify-image.py out/boot.img` afterwards if
you want to see what it checks.

## Flash

```bash
fastboot -s <serial> flash boot out/boot.img
fastboot -s <serial> reboot
```

The phone then shows up on the host as a **USB serial port** (CDC-ACM). Open it
at 115200 8N1 and you get a busybox shell.

There is no on-device output: `console=ttyMSM0` only works if you have a 1.8 V
UART wired to the board, which is why the initramfs brings up USB instead.

---

## Three details that cost the most time

### 1. The ABL requires the DTB immediately after the gzip stream

The bootloader computes where the compressed kernel ends and expects the FDT
magic right there. Any padding — including page alignment — makes it log:

```
BootLinux: GetImage failed! DTB offset is incorrect,
          kernel image does not have appended DTB
```

So the kernel blob must be exactly `cat Image.gz dtb`. `pack-bootimg.sh`
verifies `delta == 0` and refuses to continue otherwise. Both the stock MIUI
image and the engineering firmware image have `delta == 0`; every image that was
page-aligned failed.

### 2. `configfs` must be mounted before creating the gadget

`/sys/kernel/config` is only a **mountpoint**. If configfs is not mounted there,
`mkdir /sys/kernel/config/usb_gadget/g1` silently fails inside sysfs, the gadget
never binds, and the host never sees a USB device — even though DWC3, the PHY
and the UDC all probed correctly.

This one bug made the kernel look completely dead for a long time: no USB, no
output, device unresponsive. `scripts/verify-image.py` now checks that the
packed `/init` mounts configfs.

### 3. "Device disappeared from USB" is normal

When the ABL hands control to the kernel it tears down its own fastboot USB
interface. The device vanishing from the host tells you **nothing** about whether
the kernel is alive. The only reliable signal is the USB gadget appearing a few
seconds later.

---

## Repository layout

```
dts/        the device tree
initramfs/  the init script that brings up USB
config/     the exact kernel config that was tested
scripts/    build, initramfs, packaging, verification
docs/       bring-up notes
```

---

## Credits

The approach — and the method of debugging a headless SDM845 device without a
UART — follows Mechres' work on the Xiaomi Mi 8 (`dipper`), which is the same
SoC:

* <https://mechres.dev/post/xiaomi-mi8-dipper-mainline-linux-bringup>
* <https://github.com/Mechres/xiaomi-mi8-dipper>

Upstream kernel work comes from the sdm845 mainline community.

## License

GPL-2.0, matching the kernel. See `LICENSE`.
