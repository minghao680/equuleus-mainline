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
| Root filesystem | **working** | Debian 13 arm64 on `sda21` |
| **systemd as PID 1** | **working** | `systemctl is-system-running` → `running`, no failed units |
| Serial console login | **working** | `serial-getty@ttyGS0` with automatic root login |
| Touch | not enabled | `stmfts` node exists, regulators untested |
| ADSP | **working** | needs a post-boot `remoteproc start`; see below |
| WiFi | **blocked** | driver binds, firmware never loaded; see below |
| Panel backlight | **not controllable** | DSI PLL never locks, so no DCS commands get through |

Verified from inside the system:

```
root@equuleus:~# cat /proc/1/comm
systemd
root@equuleus:~# systemctl is-system-running
running
root@equuleus:~# nproc; free -m | head -2
8
               total        used        free      shared  buff/cache   available
Mem:            7608         257        7406          10          78        7351
root@equuleus:~# df -h / | tail -1
/dev/sda21      3.9G  214M  3.6G   6% /
```

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

## ADSP: firmware must be reachable at probe time

`remoteproc` is a built-in driver, so it probes while the initramfs is still the
root filesystem — before `switch_root`. Firmware placed only in `/lib/firmware`
on the real rootfs is therefore invisible to it:

```
remoteproc remoteproc1: Direct firmware load for qcom/sdm845/mi8/adsp.mbn failed with error -2
```

The firmware itself is fine (`adsp.mbn` plus `adsp.b00..b14`, extracted from the
stock `modem` partition), and starting the remoteproc again once the rootfs is
mounted works:

```
remoteproc remoteproc1: Booting fw image qcom/sdm845/mi8/adsp.mbn, size 7516
remoteproc remoteproc1: remote processor adsp is now up
```

A one-shot systemd unit that writes `start` to
`/sys/class/remoteproc/remoteproc1/state` makes this persistent. The cleaner
alternative is to put the firmware into the initramfs, which is what
distributions do for exactly this reason.

## WiFi: the firmware is never loaded

The drivers are now compiled in and `ath10k_snoc` binds:

```
ath10k_snoc 18800000.wifi: supply vdd-3.3-ch1 not found, using dummy regulator
```

and then nothing — no `wlan0`, no error, at any debug level.

The reason is in the code: `ath10k` **never loads the WCN3990 firmware**. `qmi.c`
registers for a QMI service and waits for a `WLFW_FW_READY_IND` indication; the
only `qcom_mdt_load` call in the wireless tree is in `ath12k`. `snoc.c` decides
between two worlds:

```c
node = of_get_child_by_name(host_dev->of_node, "wifi-firmware");
if (!node) {
        ar_snoc->use_tz = true;
        return 0;
}
```

With no `wifi-firmware` subnode the driver assumes **TrustZone already booted the
firmware** — true when the stock bootloader boots Android, not when it boots our
kernel. Neither the ADSP nor `pwrseq-qcom-wcn` (a power-sequencing driver for
newer WCN PMUs, compatibles `qcom,wcn3950-pmu` / `qcom,wcn3988-pmu`) loads it.

Fixing this needs a real firmware loader — the `qcom_mdt_load` +
`qcom_scm_pas_auth_and_reset` sequence that `ath12k` performs, applied to
WCN3990 — not a configuration change. The firmware blobs and the device tree node
are already in place, so the remaining work is code.

## Panel backlight: not controllable on a dead panel

`/sys/class/backlight/ae94000.dsi.0/` exists and reports `max_brightness = 1023`,
but every write fails:

```
# echo 50 > /sys/class/backlight/ae94000.dsi.0/brightness
-bash: echo: write error: Connection timed out
```

because the DSI PLL never locks:

```
msm_dsi_phy ae94400.phy: [drm:dsi_pll_10nm_vco_prepare] *ERROR* DSI PLL(0) lock failed
```

An AMOLED panel has no separate backlight LED — brightness *is* a DCS command
(0x51) over the same DSI link, so when the link is down there is nothing to
adjust. The corollary matters too: the panel is not emitting, so the power being
drawn is the DSI/DPU controller, not the screen.

## Next steps

1. **Grow the root filesystem.** The image is 4 GB inside a 113 GB partition;
   `resize2fs /dev/sda21` (or `systemd-growfs`, enabled by the `x-systemd.growfs`
   mount option) reclaims the rest.
2. **Networking.** `systemd-networkd` is enabled but there is no link yet. USB
   NCM/RNDIS in the initramfs would give the phone an IP over the same cable that
   already carries the console, which is the natural way to get `ssh` access.
3. **Touch.** The ST FTS5 node and its `avdd`/`vdd` rails are not enabled yet.
4. **Charging / fuel gauge.** PMI8998 is present but not configured.

## How this was debugged without a UART

The method follows Mechres' dipper bring-up: use the presence of a USB device as
the progress signal, since there is no other output on a phone with a dead
screen. Three things made that possible here:

1. Fixing the ABL DTB placement rule (see README) so images actually boot.
2. Fixing the initramfs so it mounts configfs before creating the USB gadget.
   Before that fix every image looked like "the kernel is dead".
3. Reading `cat /proc/kmsg` over the console to see that the machine went silent
   with no panic — the signature of a bus deadlock rather than a kernel crash.
