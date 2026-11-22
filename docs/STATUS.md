# Bring-up status

Last verified: 2026-11-22, kernel `7.1.0-rc1-sdm845`, built with clang 19.1.7.

## What works

Evidence taken from the running device over the USB console:

```
$ uname -a
Linux (none) 7.1.0-rc1-sdm845 #7 SMP PREEMPT aarch64 GNU/Linux

$ head -1 /proc/meminfo
MemTotal:        7797064 kB

$ grep -c processor /proc/cpuinfo
8

$ cat /proc/uptime
132.80 1058.06        <- stays up now; it used to reset every 27 s

$ ls /dev/sd*
/dev/sda /dev/sda1 ... /dev/sda21     <- UFS, 123 GB

$ ls /dev/dri/
card0  renderD128
```

| Component | State | Notes |
|---|---|---|
| Kernel boot | working | reaches `Run /init as init process` |
| SMP | working | 8 cores online |
| Memory | working | 7.8 GB of the 8 GB board detected |
| USB gadget (CDC-ACM) | working | host sees a serial port ~5 s after reboot |
| UFS | **working** | `SAMSUNG KLUDG4U1EA-B0C1`, 6 LUNs, 123 GB + 4.5 GB |
| Display controller (MDSS/DPU) | **working** | `msm 1.13.0`, `card0-DSI-1` reports `connected` |
| Stable operation | **working** | >130 s uptime instead of a 27 s reboot loop |
| Root filesystem | absent | initramfs only |
| Touch | not enabled | `stmfts` node exists, regulators untested |
| WiFi / modem / DSPs | disabled in DT | not needed for headless bring-up |

## Two bugs that had to be fixed for this to work at all

### 1. UFS drivers were never compiled in

`1d84000.ufshc` registered as a platform device but produced no probe messages
and no block devices. The device tree was always correct; the kernel simply had
`CONFIG_SCSI_UFSHCD`, `CONFIG_SCSI_UFS_QCOM` and `CONFIG_BLK_DEV_SD` disabled.
Enabling them made all six LUNs enumerate on the first try.

### 2. The bootloader's splash kept MDSS alive with no owner

This is the one that took longest to understand, and it is the reason the device
used to reboot every ~27 seconds.

The Xiaomi bootloader turns on MDSS to scan out the "Mi" splash from DDR and
leaves it running. The kernel had `&mdss` disabled and `&dispcc` disabled, so no
driver ever claimed the controller. Meanwhile UFS finishing probe lets
`qnoc-sdm845` reach `sync_state()`, which releases the boot-time interconnect
bandwidth floors. The orphaned MDSS DMA read then hits a path that nobody votes
for, the NoC deadlocks, and the watchdog resets the SoC roughly a dozen seconds
into boot — with no panic message, because the bus is gone, not the kernel.

The fix is to give MDSS a driver: enable `dispcc`, `mdss`, DSI0 and the panel,
so the DPU holds the `mdp0-mem` / `mdp1-mem` votes while it is active and shuts
its DMA engines down when blanked. This adds the display as a working component
rather than trading something else away.

Things that were tried and rejected because they only move the symptom:

* `cpuidle.off=1`
* disabling `cluster-sleep-0` in the device tree

Both hide the deadlock by removing idle states, which costs real functionality.

## Remaining display caveat

`dsi_pll_10nm_vco_prepare` logs a PLL lock failure at boot:

```
msm_dsi_phy ae94400.phy: [drm:dsi_pll_10nm_vco_prepare] *ERROR* DSI PLL(0) lock failed
```

DRM still reports `card0-DSI-1` as `connected`, and the controller is owned and
voting, which is what matters for stability. Whether the panel actually lights up
cannot be confirmed on this unit: its AMOLED is physically broken. If you have a
working panel, check the DSI PHY supply rails (`vdda-phy`, `vdda-pll`) against the
downstream device tree.

## Next steps

1. **Root filesystem with systemd.** `userdata` (`/dev/sda21`, 113 GB, empty) is
   the natural target. The initramfs would mount it and `switch_root`.
2. **Touch.** The ST FTS5 node and its `avdd`/`vdd` rails are not enabled yet.
3. **Charging / fuel gauge.** PMI8998 is present but not configured.

## How this was debugged without a UART

The method follows Mechres' dipper bring-up: use the presence of a USB device as
the progress signal, since there is no other output on a phone with a dead
screen. Three things made that possible here:

1. Fixing the ABL DTB placement rule (see README) so images actually boot.
2. Fixing the initramfs so it mounts configfs before creating the USB gadget.
   Before that fix every image looked like "the kernel is dead".
3. Reading `cat /proc/kmsg` over the console to see that the machine went silent
   with no panic — the signature of a bus deadlock rather than a kernel crash.
