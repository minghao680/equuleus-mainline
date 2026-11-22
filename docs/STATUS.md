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
| ADSP | **working** | needs a post-boot `remoteproc start` |
| **WiFi** | **working** | `wlan0` + `phy0`, scans real networks |
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

## WiFi: works, and it needs no kernel driver

This took far longer than it should have because it looks like a kernel problem
and is not. The chain on SDM845 is entirely in userspace:

```
modem (MSS) -> GLINK/QRTR -> service discovery -> rmtfs/EFS
            -> PDR msm/modem/wlan_pd
            -> TQFTP serves wlanmdsp.mbn to the modem
            -> WLFW QMI service (service 69) registers
            -> ath10k_snoc -> wlan0
```

ath10k never loads the WCN3990 firmware: it registers a QMI lookup and waits for
the modem to publish the WLFW service. `modemuw.jsn` declares `wlan_pd` with
`{ "provider": "kernel", "service": "elf_loader" }`, but that is a servreg
description, not an instruction to write a kernel driver - the loader role is
filled by the userspace TFTP server.

What is required:

| Piece | Note |
|---|---|
| `modem-start` | `qcom_q6v5_mss` sets `auto_boot = false`, so nothing starts the modem |
| `rmtfs` | serves modem EFS requests |
| `pd-mapper` | publishes the protection-domain mapping for `wlan_pd` |
| **`tqftpserv` >= 1.3** | **the one that actually bites**: 1.1 only accepts `/readonly/firmware/image/`, this modem asks for `/readonly/vendor/firmware_mnt/image/` |
| firmware in `/lib/firmware/image/` | where tqftpserv maps the modem's request path onto |

With tqftpserv 1.1 the log reads

```
tqftpserv: invalid path /readonly/vendor/firmware_mnt/image/wlanmdsp.mbn, rejecting
```

and WiFi never appears. With 1.3 the rejections stop and a few seconds later:

```
ath10k_snoc 18800000.wifi: qmi chip_id 0x30214 chip_family 0x4001
ath10k_snoc 18800000.wifi: wcn3990 hw1.0 target 0x00000008
ath10k_snoc 18800000.wifi: htt-ver 3.73 wmi-op 4 htt-op 3 hwcrypto 1
```

```
$ ip -brief link
wlan0            UP   2e:0c:c3:8f:a5:ab  <BROADCAST,MULTICAST,UP>

$ iw dev wlan0 scan
BSS 50:33:f0:9c:8d:66  signal: -32.00 dBm  SSID: ...
```

Two harmless leftovers: `invalid MAC address; choosing random` because
`wlan_mac.bin` is not installed, and `ota_firewall/ruleset` write failures from
tqftpserv, which are unrelated to WiFi.

`scripts/install-firmware-daemons.sh` does all of the above, including pulling
tqftpserv from sid rather than trixie.

## Measured on hardware

WiFi, with the factory MAC applied from persist:

```
Connected to 52:33:f0:9c:8d:66 (on wlan0)
        SSID: (5 GHz AP)
        freq: 5180.0
        signal: -25 dBm
        RX: 5592 bytes (47 packets)

curl 13.2 MB in 1.61 s   -> 8.2 MB/s, about 66 Mbps
ping gateway 10x         -> 0% loss, 16.0 ms avg
ping 223.5.5.5 10x       -> 0% loss, 29.4 ms avg
apt-get update           -> 16.1 MB in 3 s, then installed curl and iperf3
```

Battery, once `pmi8998.dtsi`'s charger and gauge are set to okay:

```
qcom-battery     capacity 1   status Charging  voltage 3.22 V  current -360 mA
pmi8998-charger  status Charging  voltage 4.79 V  current  442 mA
```

CPU scaling, measured under load:

```
scaling_driver  qcom-cpufreq-hw      governor schedutil
cpu0 idle 1.13 GHz -> load 1.77 GHz  (max 1.77 GHz)
cpu4 idle 1.69 GHz -> load 2.65 GHz  (max 2.65 GHz)
cpu7 idle 1.69 GHz -> load 2.65 GHz  (max 2.65 GHz)
sha256 of 512 MiB single-threaded: 0.559 s
```

## The clock is a prerequisite, not a nicety

`apt-get update` failed with

```
Not live until 2026-11-21T08:46:20Z
W: OpenPGP signature verification failed
E: The repository is not signed.
```

because the RTC sits at April 2026 - seven months behind - so Debian's signature
check rejects a valid certificate as not yet in effect. Setting the time once
fixes it instantly, and the same update then succeeds. systemd-timesyncd is
installed and enabled, but it needs WiFi up first, which is a circular
dependency on a fresh boot.

## GPU: the stock firmware is too old for mainline

The initramfs now carries the a630 blobs and they load:

```
msm_dpu: [drm:adreno_request_fw] loaded qcom/a630_sqe.fw from new location
msm_dpu: [drm:adreno_request_fw] loaded qcom/a630_gmu.bin from new location
```

but then

```
adreno 5000000.gpu: [drm:a6xx_ucode_load] *ERROR* a630 SQE ucode is too old.
Have version 187 need at least 190
```

The 2021 stock ROM ships SQE ucode version 187; mainline requires 190 or newer.
That blob has to come from somewhere other than this device's firmware, so the
GPU stays unaccelerated until then. Display works either way.


## GPU acceleration works

The Adreno 630 initialises with the freedreno driver, at full resolution:

```
$ eglinfo | grep "EGL driver name"
EGL driver name: msm

$ glmark2-es2-drm -b build
    GL_VENDOR:      freedreno
    GL_RENDERER:    FD630
    GL_VERSION:     OpenGL ES 3.2 Mesa 25.0.7-2+deb13u1
    Surface Size:   1080x2248 fullscreen
    FPS: 1039 FrameTime: 0.963 ms
    glmark2 Score: 1038
```

Full benchmark suite scores **780**, with per-scene results from 118 FPS (buffer
map update) to 1076 FPS (bump normals). The heaviest scenes are terrain (72 FPS)
and refract (58 FPS), both geometry-bound at 1080x2248.

Three things were needed, none of them a kernel change:

  1. `a630_sqe.fw` from linux-firmware, because the 2021 stock ROM ships ucode
     version 0x187 and mainline requires 0x190. See docs/gpu-firmware.md.
  2. `a630_zap.mdt`, not just `a630_zap.mbn`. The driver asks for the .mdt name.
  3. All of it inside the initramfs, because msm is built in and loads the
     firmware during probe, before the root filesystem exists.

GPU frequency scaling also works:

```
$ cat /sys/class/devfreq/5000000.gpu/available_frequencies
257000000 342000000 414000000 520000000 596000000 675000000 710000000
$ cat /sys/class/devfreq/5000000.gpu/governor
simple_ondemand
```

## Bluetooth

`hci0` comes up and the controller is identified:

```
Bluetooth: hci0: QCA SOC Version  :0x40010214
Bluetooth: hci0: QCA ROM Version  :0x00000201
```

The controller downloads its firmware from the host, so `qca/crbtfw21.tlv` and
`qca/crnv21.bin` have to be present - they come from the stock bluetooth
partition.

Getting this far needed `&qupv3_id_0` enabled: uart6 sits under that QUP wrapper,
and only the wrapper holding the console was enabled, so serial@898000 was never
instantiated at all.

## Audio

The card registers and both codecs are present:

```
$ cat /proc/asound/cards
 0 [Pro            ]: sdm845 - Xiaomi Mi 8 Pro
                      Xiaomi Mi 8 Pro

$ cat /proc/asound/pcm
00-00: MultiMedia1  playback 1 : capture 1
00-01: MultiMedia2  playback 1 : capture 1
00-02: MultiMedia3  playback 1 : capture 1
00-03: MultiMedia4  playback 1 : capture 1

tas2557 5-004c: PG2.1 Silicon found
tas2557 5-004c: Firmware driver: 0x400
```

The root cause of the long-standing failure was one disabled node: `gpi_dma0` is
`status = "disabled"` in sdm845.dtsi, so i2c5 could not acquire DMA channels, the
TAS2557 was never instantiated, and the dangling `&tas2557` reference aborted the
whole sound card - earpiece and headset included.

The amplifier firmware loads at 0.56 s, before the root filesystem is mounted, so
it has to be in the initramfs like the GPU blobs.

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
