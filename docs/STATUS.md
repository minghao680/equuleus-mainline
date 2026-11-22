# Bring-up status

Last verified: 2026-11-22, kernel `7.1.0-rc1-sdm845`, built with clang 19.1.7.

## What works

Evidence taken straight from the running device over the USB console:

```
$ uname -a
Linux (none) 7.1.0-rc1-sdm845 #5 SMP PREEMPT Sun Nov 22 11:19:53 CST 2026 aarch64 GNU/Linux

$ head -1 /proc/meminfo
MemTotal:        7796552 kB

$ grep -c processor /proc/cpuinfo
8

$ ls /sys/class/udc
a600000.usb  a800000.usb
```

| Component | State | Notes |
|---|---|---|
| Kernel boot | working | reaches `Run /init as init process` |
| SMP | working | 8 cores online |
| Memory | working | 7.8 GB of the 8 GB board detected |
| USB gadget (CDC-ACM) | working | host sees a serial port ~15 s after reboot |
| USB DWC3 | working | both controllers probe |
| UART `ttyMSM0` | working | `a84000.serial` probes, needs 1.8 V pads |
| configfs | working | mounted by init |

## What does not work yet

| Component | State | Notes |
|---|---|---|
| UFS | not up | `qnoc-sdm845 ...: sync_state() pending due to 1d84000.ufshc` |
| Root filesystem | absent | initramfs only |
| Display | not enabled | panel is physically broken on this unit |
| Touch | not enabled | `stmfts` node exists but regulators untested |
| WiFi / modem / DSPs | disabled in DT | not needed for headless bring-up |

## Boot timing

Roughly 15 seconds from `fastboot reboot` to the USB serial port appearing.
Most of that is the ABL (decompress + DTB match takes ~2.5 s) plus kernel init.

## Notes on the device tree

`dts/sdm845-xiaomi-equuleus.dts` keeps:

* `&tlmm { gpio-reserved-ranges = <0 4>, <81 4>; }` — required. Xiaomi's
  TrustZone locks the SPI controllers used by the fingerprint sensor and the
  embedded secure element on GPIO 0-3 and 81-84. When `pinctrl-msm` registers
  the GPIO chip it reads direction/config for every unreserved pin; touching
  those triggers an XPU access violation and halts the CPU before any I/O comes
  up. This is the single most important line in the file.
* USB in peripheral mode (`dr_mode = "peripheral"`) on `usb_1` (`a600000.usb`),
  which is the controller wired to the Type-C connector.
* UART9 (`a84000.serial`) on GPIO 4/5, which is the debug UART if you ever wire
  it up.

The remote processors, WiFi and UFS are enabled in the DT but UFS does not
finish probing yet.

## Next steps

1. **UFS.** `1d84000.ufshc` never completes probe, which blocks `qnoc-sdm845`
   from reaching `sync_state()`. Check the UFS PHY supplies
   (`vdda-phy-supply`, `vdda-pll-supply`) and the reset GPIO against the
   downstream device tree.
2. **Root filesystem.** Once UFS enumerates, a minimal Debian or Alpine rootfs
   can be placed on `userdata` (this unit's `userdata` is 113 GB and was wiped).
3. **Persistence.** For a real install the kernel would move from `boot` to a
   proper rootfs on UFS; the initramfs would then only mount the root.

## How this was debugged without a UART

The method follows Mechres' dipper bring-up: use the presence of a USB device as
the progress signal, since there is no other output on a phone with a dead
screen. Two things made that possible here:

1. Fixing the ABL DTB placement rule (see README) so images actually boot.
2. Fixing the initramfs so it mounts configfs before creating the USB gadget.
   Before that fix every image looked like "the kernel is dead".
