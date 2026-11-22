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
| UFS storage | **yes** — `SAMSUNG KLUDG4U1EA-B0C1`, 6 LUNs, 123 GB + 4.5 GB |
| Display controller | **yes** — `msm 1.13.0`, `card0-DSI-1` reports `connected` |
| Stable operation | **yes** — no more 27 s reboot loop |
| **Debian + systemd rootfs** | **yes** — `systemctl is-system-running` → `running` |
| Touch / WiFi / modem | not enabled |

The end state is a Debian 13 arm64 userland with systemd as PID 1, reachable over
a USB serial console with automatic root login:

```
Debian GNU/Linux 13 equuleus ttyGS0
equuleus login: root (automatic login)
Linux equuleus 7.1.0-rc1-sdm845 aarch64
root@equuleus:~#
```

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

The script copies the device tree into the kernel tree, applies `patches/`,
installs `config/equuleus.config`, builds `Image.gz` + the DTB, builds the
initramfs and packs the boot image. Run `scripts/verify-image.py out/boot.img`
afterwards if you want to see what it checks.

### Root filesystem

```bash
scripts/build-rootfs.sh
```

Builds a Debian arm64 rootfs with systemd, enables a serial getty on the USB
console with automatic root login, and produces `out/rootfs.ext4`. Needs
`mmdebstrap`, `arch-test`, `qemu-aarch64-static` and passwordless sudo.

## Flash

```bash
fastboot -s <serial> flash userdata out/rootfs.ext4
fastboot -s <serial> flash boot     out/boot.img
fastboot -s <serial> reboot
```

The initramfs mounts the rootfs from the UFS userdata partition and `switch_root`s
into systemd. If anything fails on the way it drops to a shell on the USB console
instead of failing silently — that console is the only way into this device.

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

### 3. The bootloader leaves MDSS running, and nobody owns it

This is the one that makes the phone reboot every ~27 seconds with **no panic
message at all**.

The Xiaomi bootloader turns on the display controller to scan out the "Mi" splash
from DDR and never turns it off. If no Linux driver claims MDSS, nothing votes for
that memory path. As soon as UFS finishes probing, `qnoc-sdm845` reaches
`sync_state()`, releases its boot-time bandwidth floors, the orphaned MDSS DMA
read hits an unvoted path and the NoC deadlocks. The watchdog then resets the
SoC. The kernel looks dead but was never crashing — the bus was gone.

The fix is to give MDSS an owner: enable `dispcc`, `mdss`, DSI0 and the panel so
the DPU holds the `mdp0-mem` / `mdp1-mem` votes and shuts its DMA engines down
when blanked. The panel driver is `patches/0001-drm-panel-add-samsung-ea8074.patch`.

Turning CPU idle off (`cpuidle.off=1`) or disabling `cluster-sleep-0` "fixes" the
symptom too, and both were rejected: they trade away real functionality instead
of fixing the cause.

---

## Repository layout

```
dts/        the device tree
initramfs/  the init script that brings up USB
patches/    kernel patches (the EA8074 panel driver)
config/     the exact kernel config that was tested
scripts/    build, initramfs, packaging, verification
docs/       bring-up notes and a reference device tree
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
