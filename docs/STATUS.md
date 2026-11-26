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
wlan0            UP   <address>  <BROADCAST,MULTICAST,UP>

$ iw dev wlan0 scan
BSS <address>  signal: -32.00 dBm  SSID: ...
```

Two harmless leftovers: `invalid MAC address; choosing random` because
`wlan_mac.bin` is not installed, and `ota_firewall/ruleset` write failures from
tqftpserv, which are unrelated to WiFi.

`scripts/install-firmware-daemons.sh` does all of the above, including pulling
tqftpserv from sid rather than trixie.

## Measured on hardware

WiFi, with the factory MAC applied from persist:

```
Connected to <BSSID> (on wlan0)
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

## Microphone: works on AMIC3

The built-in microphone is analog and sits on **ADC3** (`AMIC MUX0 = ADC3`,
`ADC MUX0 = AMIC`). Two wrong assumptions cost a lot of time here:

* **ADC1 and ADC2 are floating inputs on this board.** They produce a
  suspiciously healthy noise floor (rms ~1000 and ~12000 respectively) which
  looks like a working microphone until you compare it against a real sound
  source. The test that settles it: record while clapping, then look at the
  per-window rms; a real microphone shows sharp peaks, a floating input stays
  flat. A synthetic file with three clap bursts was used to validate the
  analysis itself first.
* **The microphone bias voltages in the board tree were swapped** relative to
  the vendor tree. They are now `micbias1 = 2.7 V`, `2 = 1.8 V`, `3 = 2.7 V`,
  `4 = 2.7 V`, matching Xiaomi's values; an electret microphone at 1.8 V does
  not work.

The vendor tree additionally drives GPIO 62 as an "ADC2 switch"
(`aud_active` = output-high). It is not proven that the built-in microphone
needs it, but the sweep that found ADC3 ran with it high, so `audio-defaults`
sets it too (through `/sys/class/gpio`, `GPIO_SYSFS` is enabled).

Capture still has to run on a **different frontend than playback**: with the
capture switch on MultiMedia1 as well, the DSP refuses playback routing
(`Routing not setup for MultiMedia-1 Session`) and `aplay` fails with EIO. That
is why playback stays on MultiMedia1 and capture uses MultiMedia2:

```sh
aplay   -D hw:0,0 tone.wav        # speaker (QUAT_MI2S_RX -> TAS2557)
arecord -D hw:0,1 rec.wav         # AMIC3 microphone
```

The codec chain is `AMIC3 -> ADC3 -> DEC0 -> CDC_IF TX0 -> AIF1_CAP ->
SLIMBUS_0_TX`; each step is one simple-mixer control, addressed by name because
numids follow registration order and are not stable across kernel changes.

### A capture stream can be wedged by mixer experiments

Chasing the right input meant switching `AMIC MUX0`, `CDC_IF TX0 MUX` and the
SLIMBUS routing by hand over and over. At some point capture started returning
**digital silence - exactly zero on both channels** even though the codec's DAPM
showed `AIF1 Capture`, `AMIC3`, `ADC3` and `SLIM TX0` all powered. `dmesg`
showed nothing. A reboot restored it immediately (`rms ~2200`).

So: changing these routes at runtime can leave the DSP capture path in a dead
state that only a reboot clears. Configure the path once at boot
(`audio-defaults`) and leave it alone; if capture suddenly returns zeros while
every mixer value looks right, reboot before suspecting the hardware.

A second lesson from the same hunt: a floating analog input has a plausible
looking noise floor (~950-1200 rms) and occasional ambient spikes, so raw "rms is
not zero" proves nothing. Compare against a real stimulus, or check the noise
floor collapse when the microphone is covered.

## NFC: the controller works, the userspace stack is the open item

The PN553 sits on `i2c3` at address 0x28; VEN is TLMM GPIO 128, FIRM is GPIO 88
and the interrupt is GPIO 63, which matches the vendor tree for the Equuleus MP
v2.1 variant. With the driver enabled the chip binds:

```
/sys/class/nfc/nfc0
/sys/bus/i2c/devices/3-0028 -> nxp-nci_i2c
```

Two mistakes made this look like dead hardware for a long time, and both are
worth remembering:

* **A read does not prove anything.** The PN553 is a mailbox: it ACKs writes
  always and only answers a read when a packet is queued. Probing it with
  `i2ctransfer r1@0x28` therefore reports `No such device` on a perfectly
  healthy chip. Probe with a write (`i2ctransfer -y 3 w1@0x28 0x00`), or send a
  real NCI command and read the response.
* **CLK_REQ is not a power signal here.** `qcom,nq-clkreq` points at PM8998
  GPIO 21, not at a TLMM pin (the phandle in the vendor DTB resolves to the
  PMIC GPIO controller). It reads low even while the chip answers NCI
  commands, so it says nothing about whether the controller is powered.

The boot hang from the first attempt was the interrupt type: the driver leaves
the IRQ line high in `NXP_NCI_MODE_COLD` and does not acknowledge anything, so a
`IRQ_TYPE_LEVEL_HIGH` interrupt fires forever. OnePlus 6 uses
`IRQ_TYPE_EDGE_RISING`; with that change the driver probes cleanly and the
system boots.

Observed handshake over raw I2C (driver unbound), which shows the chip is
functional:

```
CORE_RESET_CMD 20 00 01 00 -> 40 00 03 00 10 00      (status 0x00, NCI 1.0)
CORE_INIT_CMD  20 01 00    -> 40 01 19 00 03 0e 02 ...
                              RF interfaces 0x80 0x82 0x83 0x84
```

The reference clock is now modelled: PM8998 exposes three clock dividers at
`0x5b00` (`qcom,spmi-clkdiv`, `CONFIG_SPMI_PMIC_CLKDIV`), and divider 3 is
BBCLK3 at 19.2 MHz - `clk_summary` shows `div_clk3 19.2 MHz enabled` once a
consumer exists. Nothing in mainline consumes it, so locally the divider was
forced on with `CLK_IS_CRITICAL` in `clk-spmi-pmic-div.c`; the clean fix is to
have the NFC driver request it (`clocks = <&pm8998_clkdiv 2>`,
`clock-names = "ref_clk"`).

Even with the clock running, holding cards against the back of the phone for
several minutes produced no `RF_DISCOVER_NTF` while discovery was active
(`RF_DISCOVER_RSP status=0x00`, protocols A/B/F/V). That points at the RF path
itself - the antenna coil or its connector - rather than the controller, which
answers NCI, reports its RF interfaces and accepts discovery. The unit has a
dead panel, so it may well have been opened and the antenna flex left
disconnected.

What is still missing: **userspace**. Mainline NFC talks generic netlink only,
so there is no `/dev/nfcN`, and Debian trixie does not ship `neard`. Driving
`RF_DISCOVER` by hand over raw I2C still returns status `0x05`, i.e. the command
payload needs the exact NCI encoding - tag detection is therefore not
demonstrated yet.

## Rear camera: the sensor node is in place, the CCI bus is not answering

The main camera is a Sony IMX363 on CCI master 0 (I2C address 0x10). Wiring taken
from the vendor tree for the Equuleus MP v2.1 variant:

| Signal | Where |
| --- | --- |
| reset | TLMM GPIO 80, active low |
| MCLK | CAMCC `CAM_CC_MCLK0_CLK`, 24 MHz, on GPIO 13 |
| VANA | PM8998 L22 (2.85 V) switched by TLMM GPIO 102 |
| VDIG | 1.35 V on TLMM GPIO 99, then a second switch on PM8998 GPIO 11 |
| VIO | TLMM GPIO 75 (**2.8 V** in the vendor tree, not 1.8 V) |

With `CONFIG_MEDIA_SUPPORT`, `MEDIA_CONTROLLER`, `V4L_PLATFORM_DRIVERS`,
`VIDEO_QCOM_CAMSS` and `VIDEO_IMX363` enabled, CAMSS and CCI come up (`/dev/media0`,
`/dev/video0..11`, `i2c-16`/`i2c-17`) and the sensor binds to the i2c bus as
`16-0010`, but probe fails:

```
imx363: 4 lanes
i2c-qcom-cci ac4a000.cci: master 0 queue 0 timeout
imx363 16-0010: Error reading reg 0x0016: -110
imx363 16-0010: probe with driver imx363 failed with error -110
```

What was tried and ruled out:

* a longer power-on wait in the driver (10 ms instead of 400-600 us) - no change;
* every plausible address on **both** CCI buses times out, including the camera
  EEPROM at 0x50. A missing device would NACK quickly; a timeout on everything
  means the bus itself is not electrically alive, which points at the camera I/O
  rail that feeds the pull-ups;
* driving the enable pins by hand to keep the sensor powered is impossible: the
  fixed regulators claim those GPIOs at probe.

### Two things that hang the boot - do not retry these

1. Marking `cam0_vana` `regulator-always-on` while its `vin-supply` is PM8998
   L22. That rail is an RPMh regulator, and enabling one during early boot
   deadlocks the device.
2. **Driving TLMM GPIO 40.** Two separate images that touched that pin (once
   from the sensor driver's power-on, once as `regulator-boot-on`) both failed
   to boot; every image that leaves it alone boots. The vendor sensor node shows
   why this pin is special - its power table is

   ```
   CAMIF_MCLK0 = TLMM 13
   CAM_RESET0  = TLMM 80
   CAM_VANA0   = TLMM 102
   CAM_VDIG0   = PM8998 GPIO 11
   CAM_CUSTOM0 = TLMM 40     <- not a supply, an auxiliary/unknown signal
   ```

   GPIO 40 is `CAM_CUSTOM0`, not the 2.8 V analog rail. An earlier pass
   (including a subagent report) read it as "avdd 2.8" from a differently named
   pinctrl group and wired VANA to it; the board then failed to boot twice.

### Where it stands

The camera sensor is correctly wired in the device tree as far as the vendor
data goes (VANA = TLMM 102, VDIG = TLMM 99 behind PM8998 GPIO 11, VIO = TLMM
75, reset = TLMM 80, MCLK0 = 24 MHz, address 0x10 on CCI master 0), CAMSS and
CCI come up and the sensor binds, but every transfer on both CCI buses times
out rather than NACKs, with SDA held low by something on the bus.

Camera work is parked here. The remaining suspects are physical - the camera
flex or connector on a unit whose panel has been replaced - rather than
something the device tree can express.

## CPU: 2.8 GHz for single-thread work

The big cluster's cpufreq hardware LUT contains a **2.8032 GHz** entry. Mainline's
`qcom-cpufreq-hw` marks that entry `CPUFREQ_BOOST_FREQ` and leaves boost off, so
the default ceiling is 2.6496 GHz.

Turning boost on is not enough by itself. `schedutil` derives its next request
from the frequency the CPU is already running at, so it never asks for more than
the current frequency and the boost OPP is never selected - measured under both
a single-threaded and an eight-threaded load, the frequency stayed at 2.6496 GHz
with boost enabled. What does reach it is a governor that requests the policy
maximum:

| Configuration | Highest observed | Single-thread | Idle temperature |
| --- | --- | --- | --- |
| `schedutil`, boost off (default) | 2.6496 GHz | 228,479 | 50 C |
| `schedutil`, boost on | 2.6496 GHz | unchanged | 50 C |
| `ondemand`, boost on | 2.8032 GHz | 233,787 (+2.3%) | - |
| `performance`, boost on | 2.8032 GHz | 235,561 (**+3.1%**) | 48-50 C |

`cpu-boost.service` applies `BOOST=1` plus `GOVERNOR=performance` from
`/etc/equuleus/cpu-boost.conf`, and verifies after reboot that both clusters sit
at their maximum. Set `POLICIES=big` in that file to pin only the gold cores and
leave the little ones on `schedutil`.

The voltage for the boost OPP comes from the hardware LUT, so this is a fused
operating point, not an overclock. Anything above 2.8032 GHz would mean writing
the cpufreq LUT registers and inventing voltages; the GPU is already at its
highest OPP (710 MHz), and climbing beyond that needs an RPMh level above
`TURBO_L1`, which this board may not have fused.

## Buttons: power key as shipped, volume keys usable as hotkeys

The power key was already working and is left alone: `pm8998_pwrkey` reports
`KEY_POWER` and `systemd-logind` keeps its default poweroff action.

The two volume keys were not registered at all until they were added to the
board device tree. Their wiring comes from the vendor tree, and the split is
easy to get wrong because only one of them is a real GPIO:

| Key | Hardware | Device tree |
| --- | --- | --- |
| Volume up | PM8998 GPIO 6, active low | `gpio-keys` entry `key-vol-up`, `KEY_VOLUMEUP` |
| Volume down | PMIC PON "resin" (`pon_2`) | `&pm8998_resin` enabled with `linux,code = <KEY_VOLUMEDOWN>` |

Volume down is not on a GPIO at all - the vendor PON node reports `pon_2` with
keycode 0x72, which is `KEY_VOLUMEDOWN`. Mainline ships `pm8998_resin` disabled,
so enabling it plus a keycode is enough; the driver already reads `linux,code`
and reports it like any other key.

Both now appear as ordinary input devices, which is all a hotkey daemon needs:

```
/dev/input/event2  pm8941_resin   KEY_VOLUMEDOWN  (press/release)
/dev/input/event3  Volume keys    KEY_VOLUMEUP    (press/release/autorepeat)
```

The `gpio-keys` entry carries `autorepeat`, so holding volume up repeats like a
real key. Assigning actions to these events (`keyd`, `triggerhappy`, or a small
systemd unit reading the event device) is left to the user.

Note that volume down doubles as the bootloader's recovery entry when held
during boot; that is firmware behaviour and is unaffected by the click at
runtime.

### WLAN board data: the phone carries its own calibration

linux-firmware's `board-2.bin` for WCN3990 is built from Qualcomm reference
boards. For this phone that meant the DB845C calibration was used, even though
Xiaomi ships a BDF tuned for its own RF front end.

Which file the vendor driver picks is decided by the board id from the WLAN
firmware capability message - both mainline and Xiaomi read the same QMI field,
and both default to `0xFF` when it is absent:

```
board_id == 0xFF  ->  bdwlan.bin
otherwise         ->  bdwlan.b<board_id>
```

This unit reports `board_id 0xff` (and `chip_id 0x30214`, which matches the
`qmi-chip-id=30214` used in the firmware's own entry names, so the parsing is
sound). The phone stores the result on its `modem` partition: `image/bdwlan.bin`
is 26328 bytes, and 28 more `image/bdwlan.bXX` files at 19152 bytes each belong
to other board ids sharing the same modem image.

Mainline asks the firmware for the entry named
`bus=snoc,qmi-board-id=ff,qmi-chip-id=30214`, and linux-firmware answers with a
**19152-byte** blob. Xiaomi's `bdwlan.bin` is **26328 bytes** with the same header
and 28% of its bytes differing, spread evenly through the RF parameter region -
the same format, calibrated for this antenna and front end.

`wifi-bdf.service` closes that gap without redistributing anything: it finds the
partition by name (never a hardcoded device node), mounts it read-only, copies
`image/bdwlan.bin` into both matching entries of `board-2.bin`, keeps the
original as `board-2.bin.equuleus-orig`, and re-probes the platform device so the
new data is used. It is idempotent - the entry data is compared by hash and an
already current file leaves the device untouched - and it runs `Before=
NetworkManager.service` so the link comes up once, already correct.

Measured on a 5 GHz link a few metres from the AP, before and after:

| | reference BDF | device BDF |
| --- | --- | --- |
| signal | -32 dBm | -32 dBm |
| PHY rate | 866.7 Mbit/s | 866.7 Mbit/s |
| ping loss / avg | 0% / 2.19 ms | 0% / 1.78 ms |
| TCP down (median of 3) | 509.5 Mbit/s | 528.3 Mbit/s |

At this distance the link already runs at its maximum PHY rate, so the
difference is inside the noise - the change is about using the right
calibration rather than about a measured speed-up. Rolling back is a `cp`:
restoring `board-2.bin.equuleus-orig` returns the image to the exact stock file
and re-running the unit re-applies the device data deterministically.

### MSA permissions cannot be skipped on this board

When the WLAN occasionally fails to come up, the failing call is
`qcom_scm_assign_mem()` moving the MSA region to the WLAN subsystem, so the
obvious idea is `qcom,msa-fixed-perm`: with that property ath10k skips the SCM
permission dance entirely and the bring-up stops depending on TZ state.

It does not work here. Tested on the live device, the firmware dies immediately:

```
ath10k_snoc 18800000.wifi: board_file api 2 bmi_id N/A crc32 00000000
ath10k_snoc 18800000.wifi: qmi chip_id 0x30214 ... board_id 0xff
ath10k_snoc 18800000.wifi: firmware crashed! (guid f27e5c8e-...)
ath10k_snoc 18800000.wifi: (null) target 0x00000000 chip_id 0x00000000
```

No `wlan0` appears at all. The property is only correct on platforms whose
bootloader pre-grants the region to the WLAN subsystem; on this one it does not,
so the host's assignment is mandatory. The property was reverted.

That closes the "fix it at the root" route for the rare failure: the assignment
cannot be removed, and TZ/XPU state is not something Linux controls. What is left
is recovery after the fact - the platform device can be re-probed from userspace
(`/sys/bus/platform/drivers/ath10k_snoc/{unbind,bind}`), which was measured
bringing `wlan0` back in about four seconds after an unbind.

Automating that was considered and dropped. WLAN bring-up here is slow and does
not finish at a predictable moment, and an absent `wlan0` does not mean failure:
the interface may simply not be wanted yet. A boot-time watchdog cannot tell
those apart, so it would risk re-probing a perfectly healthy device - or worse,
rebooting a device whose owner deliberately kept it offline. Recovery stays
manual: if `wlan0` never shows up, unbind and bind the platform device by hand.

### Latency and storage tuning (`perf-tuning.service`)

Two runtime settings, both measured on this unit:

| Setting | Measurement |
| --- | --- |
| Disable `cpu-sleep` (885 us exit latency) on the four gold cores | ping average 1.94/1.90/2.26 ms -> **1.19/1.16/1.17 ms**; jitter (mdev) 1.01/1.13/2.22 ms -> **0.58/0.10/0.12 ms** |
| Hold UFS at its top gear, `scheduler=none`, `nr_requests=32`, `read_ahead=512K` | raw 200 MiB direct read 1079 -> **1335 MiB/s** |

The silver cores keep their deep idle state, so this does not turn the box into
an idle-power hog. Everything is re-applied at boot and is safe on any equuleus.

### zram swap (`zram-swap.service`)

The kernel already carries zram with zstd, but nothing configured the device, so
the machine ran with **no swap at all** - a memory spike would have killed it
rather than slowed it down. The unit sets a 3.7 GB area (50% of RAM, priority
100, swappiness 150).

**A trap worth remembering:** zram swap together with transparent huge pages set
to `always` wedges this kernel. `khugepaged` ends up blocked on I/O and drags
kworkers - and eventually pid 1 - into uninterruptible sleep; the box then shows
a load of exactly 4.00 with no CPU use and stops answering. That was reproduced
here once. The unit therefore forces `THP=madvise` and `khugepaged/defrag=0`
before enabling swap, which is why THP is no longer `always`.

### TCP: BBR and fq

`CONFIG_TCP_CONG_BBR` and `CONFIG_NET_SCH_FQ` were not built; both are now
enabled and `/etc/sysctl.d/90-equuleus-network.conf` sets
`tcp_congestion_control=bbr` with `default_qdisc=fq`. BBR is the right choice for
a Wi-Fi link with variable bandwidth and loss; on a short-range 5 GHz link it
measured no faster than westwood, which is expected - its benefit shows up with
real loss and distance, not at 866 Mbit/s a few metres from the AP.

### Display: suspended on a dead panel (per-unit, not in the image)

This unit's AMOLED is broken, so the DPU kept scanning out to nothing and the
three display devices stayed runtime-active. Unbinding them once and letting them
re-bind leaves the stack `suspended`, which measured about 3 C cooler on the gold
cluster (52.1 -> ~48-49 C) with DRM still functional.

That is deliberately **not** part of the shared image: other equuleus units have
working panels and must keep their display. `display-off.service` is installed by
hand on units that want it, and can be disabled through
`/etc/equuleus/display-off.conf`.

## GPU: works, but only with one firmware gate relaxed

The Adreno 630 needs two separate things fixed, and they were confused at first.

**1. The SQE firmware version gate is real.** `a6xx_ucode_check_version()` demands
`buf[0] & 0xfff >= 0x190` (or the patched-firmware signature) and refuses to
continue otherwise. The only a630 SQE firmware that exists for this device
reports version 0 there, and it is byte-identical in Xiaomi's own `modem` and
`vendor` partitions and in linux-firmware, with the newest upstream revision no
better - so there is nothing newer to install.

The failure is easy to misread, because the device node still appears:

| | upstream check | check relaxed |
| --- | --- | --- |
| `/dev/dri/card0` + `renderD128` | **present** | present |
| GPU devfreq | **0 Hz** | **257 MHz** (scales to 710) |
| Vulkan | `could not get GPU ID` | **`Turnip Adreno (TM) 630`** |

So "`/dev/dri` exists" does not mean the GPU works. The kernel tree carries
`kernel/tree-delta/drivers/gpu/drm/msm/adreno/a6xx_gpu.c`, which accepts the
firmware while **leaving `has_whereami` off** - the check only gates crash
diagnostics, not rendering, so this buys a working GPU without pretending the
blob can report faulting instructions.

**2. Never unbind the display stack.** The GPU is bound *through* `msm_dpu`, and
the DSI output is part of the DRM device. An experiment that unbound the display
stack to save power on this dead-panel unit took DRM and the GPU down with it:

```
unbind DSI  ->  /dev/dri empty, GPU devfreq gone, Vulkan gone
```

That experiment was dropped permanently. It looked harmless at the time only
because the GPU was not initialising anyway.

## Video codec (Venus): works, with the phone's own signed firmware

The hardware video block was not built at all: `CONFIG_VIDEO_QCOM_VENUS` and its
`V4L_MEM2MEM_DRIVERS` parent were missing, and the node was disabled. Enabling
both is not enough on this handset, because it boots with
`androidboot.secureboot=1`: Venus authenticates its firmware through PAS in
TrustZone, and the generic `qcom/venus-5.2/venus.mbn` from linux-firmware is not
signed for this device, so the load fails with `-EINVAL` and the codec never
probes. Xiaomi's signed image lives on the `modem` partition.

There is a second trap in how the firmware is loaded. `qcom_mdt_load()` treats the
file the driver names as an ELF header and then reads each segment from a sibling
file whose name is that path with the last three characters replaced:

```c
sprintf(seg_name + strlen(fw_name) - 3, "b%02d", segment);
/* qcom/venus-5.2/venus.mbn -> qcom/venus-5.2/venus.b02, .b03, ... */
```

So a single merged blob does not work, and neither does a lone `.mdt`. What works
is the vendor layout with the header renamed:

```
/lib/firmware/qcom/venus-5.2/venus.mbn   <- venus.mdt from the modem partition
/lib/firmware/qcom/venus-5.2/venus.b02   <- exactly p_filesz bytes
/lib/firmware/qcom/venus-5.2/venus.b03
/lib/firmware/qcom/venus-5.2/venus.b04
```

`venus-fw.service` does that extraction from the phone itself, so no vendor
firmware is redistributed, and it re-probes the device so the codec works without
a reboot. It is idempotent and skips itself once `/dev/video12` exists.

Result:

| Node | Role | Formats |
| --- | --- | --- |
| `/dev/video12` | encoder | NV12 in, H.264/HEVC out |
| `/dev/video13` | decoder | **H.264, VP8, VP9, HEVC, MPEG-2** |

## Wi-Fi hotspot: works, off unless started by hand

`scripts/hotspot.sh` (installed as `/usr/local/sbin/hotspot`) turns the phone into
an access point, sharing either the Wi-Fi uplink or the modem's IPv4 data. It is
not started at boot; there is no unit or hook for it on purpose.

Measured on hardware: a laptop connected to `Equuleus-AP`, received
`192.168.50.38` from dnsmasq, resolved names and browsed with the wired NIC
disabled. Both uplinks were exercised with the same client.

Two details are easy to get wrong and are handled by the helper:

* the AP must be created as a second interface (`ap0`) and left **down** before
  `hostapd` starts - starting it while the interface is up gives
  `Could not connect to kernel driver`;
* it must use the **same channel as the STA connection**, and on 5 GHz the
  hostapd config needs `ieee80211ac=1`, otherwise it fails with
  `Failed to set beacon parameters`. That is a firmware limitation of the
  WCN3990, not a configuration choice.

For `hotspot start mobile` the helper adds a policy route and, importantly, the
on-link route for the modem gateway inside that table; without it forwarding
fails with `Network is unreachable` even though the default route looks fine.
`hotspot stop` removes the interface, policy route, NAT rules and the dnsmasq
snippet again.

## Vibration motor: works

The PMI8998 haptics block is enabled in the board tree exactly like the sibling
Xiaomi boards do it:

```dts
&pmi8998_haptics {
	qcom,wave-play-rate-us = <4878>;

	status = "okay";
};
```

The driver registers an input device and the motor responds to force feedback:

```
input: spmi_haptics as .../pmic@3:haptics@c000/input/input0
$ evdev dump: FF_RUMBLE, FF_PERIODIC (sine/square/triangle), FF_GAIN
```

A rumble effect and a 100 Hz sine effect both upload and play without errors.
The actuator type is left at the pmi8998.dtsi default, which is the linear
resonant actuator this phone uses.

## Wi-Fi hotspot: works, off unless started by hand

`scripts/hotspot.sh` (installed as `/usr/local/sbin/hotspot`) turns the phone into
an access point, sharing either the Wi-Fi uplink or the modem's IPv4 data. It is
not started at boot; there is no unit or hook for it on purpose.

Measured on hardware: a laptop connected to `Equuleus-AP`, received
`192.168.50.38` from dnsmasq, resolved names and browsed with the wired NIC
disabled. Both uplinks were exercised with the same client.

Two details are easy to get wrong and are handled by the helper:

* the AP must be created as a second interface (`ap0`) and left **down** before
  `hostapd` starts - starting it while the interface is up gives
  `Could not connect to kernel driver`;
* it must use the **same channel as the STA connection**, and on 5 GHz the
  hostapd config needs `ieee80211ac=1`, otherwise it fails with
  `Failed to set beacon parameters`. That is a firmware limitation of the
  WCN3990, not a configuration choice.

For `hotspot start mobile` the helper adds a policy route and, importantly, the
on-link route for the modem gateway inside that table; without it forwarding
fails with `Network is unreachable` even though the default route looks fine.
`hotspot stop` removes the interface, policy route, NAT rules and the dnsmasq
snippet again.

## Vibration motor: works

The PMI8998 haptics block is enabled in the board tree exactly like the sibling
Xiaomi boards do it:

```dts
&pmi8998_haptics {
	qcom,wave-play-rate-us = <4878>;

	status = "okay";
};
```

The driver registers an input device and the motor responds to force feedback:

```
input: spmi_haptics as .../pmic@3:haptics@c000/input/input0
$ evdev dump: FF_RUMBLE, FF_PERIODIC (sine/square/triangle), FF_GAIN
```

A rumble effect and a 100 Hz sine effect both upload and play without errors.
The actuator type is left at the pmi8998.dtsi default, which is the linear
resonant actuator this phone uses.

## Microphone: works, but only on a second frontend

Recording is analog: the DMIC path records digital silence, while `AMIC1`
carries the signal (`rms ~750` against `0`). The codec chain is

```
AMIC1 -> ADC1 -> DEC0 -> CDC_IF TX0 -> AIF1_CAP -> SLIMBUS_0_TX
```

and `audio-defaults.sh` sets every step plus the q6routing switch. Two traps
cost time here:

* **The capture switch must be on before opening the PCM.** Without
  `MultiMediaN Mixer SLIMBUS_0_TX` the open succeeds and the first read fails
  with EIO.
* **A frontend cannot carry both directions.** With the capture switch on
  MultiMedia1 as well, the DSP refuses playback routing
  (`Routing not setup for MultiMedia-1 Session`) and `aplay` fails with EIO.
  Playback therefore stays on MultiMedia1 and capture uses MultiMedia2:

```sh
aplay   -D hw:0,0 tone.wav        # speaker (QUAT_MI2S_RX -> TAS2557)
arecord -D hw:0,1 rec.wav         # AMIC1 microphone
```

Controls are addressed by name, not by numid: numids follow registration order
and are not stable across kernel changes.

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


## Release: built and published by CI

Tagging `v*` runs the whole pipeline and publishes the artifacts:

    https://github.com/minghao680/equuleus-mainline/releases/tag/v0.1.0

    boot.img          64 MiB
    rootfs.ext4.gz   162 MiB
    FIRMWARE.txt

The rootfs ships gzipped because the raw ext4 image is 4 GiB and GitHub rejects
release assets of 2 GiB or more:

    Validation Failed: {"resource":"ReleaseAsset","field":"size",
                        "message":"size must be less than 2147483648"}

Only about 240 MB of the image is in use, so gzip takes it to a fraction of the
limit. Unzip before flashing.

Both build jobs run against stock torvalds/linux v7.1-rc1, so the device tree is
portable: everything it needs that vanilla lacks lives in kernel/tree-delta/ and
is overlaid by scripts/apply-tree-delta.sh.

## The modem is started by rmtfs, not by a separate unit

`rmtfs -s` starts the modem service itself, so a second unit doing the same thing
would race with it. `modem-start.service` is kept in the tree for reference but
is deliberately not enabled; only `rmtfs.service` is in
`multi-user.target.wants/`.

The packaged unit is used unmodified:

    ExecStart=/usr/bin/rmtfs -r -P -s

`-r` keeps it read-only so nothing is written back to the EFS partitions, and
`-P` serves the persist partition. A verbose drop-in was used during bring-up and
has been removed.

## Field notes from the v0.6.x images

These were all measured on the device, and each one changed the image.

**Wi-Fi power save makes an interactive session feel broken.** The WCN3990
associates with power save enabled, so every packet waits for a wake-up. Ping from
the host averaged about 25 ms with regular spikes over 100 ms, and typing over SSH
felt sluggish in both directions. The link itself was fine (-38 dBm, 866.7 Mbit/s
PHY). Turning it off collapses the latency:

```
before (power save on)    p50 ~25 ms, frequent spikes >100 ms
after  (power save off)   min 2  p50 5  p90 5  max 7 ms, 0 samples >50 ms
```

`systemd/NetworkManager-90-wifi-powersave` is a NetworkManager dispatcher script
that clears power save on every `up`/`dhcp*-change`, so it also covers profiles
added later with `nmtui` and re-applies after a re-association.

**The root filesystem grows itself.** The shipped image is 4 GiB because it has to
be downloadable, but `userdata` is 113 GB. The `fstab` entry carries
`x-systemd.growfs`, so `systemd-growfs-root.service` runs on first boot:

```
$ findmnt -no SOURCE,FSTYPE,SIZE,AVAIL /
/dev/sda21 ext4 111.2G 109.8G
```

**The factory MAC needs the persist partition, and persist can appear late.**
`/dev/disk/by-partlabel/persist` is created by udev, and one boot skipped the
address unit outright:

```
wifi-mac.service - skipped, unmet condition check
  ConditionPathExists=/dev/disk/by-partlabel/persist
```

The controller then used a random address. `systemd/persist-part.sh` now waits a
bounded time for the symlink and falls back to reading the partition table with
`lsblk`, which does not depend on udev.

**The Bluetooth controller is unconfigured for minutes, not seconds.** `hci0`
appears within a second and the QCA firmware finishes at 1.9 s, but `btmgmt`
only accepts a public address much later: a call that still failed at 464 s of
uptime returned "complete" at 586 s, 616 s and 983 s. Two things matter more than
the clock:

* bluetoothd must not hold the controller. With it active the call blocks, and
  stopping it makes the next call succeed immediately.
* retrying in a loop keeps the controller from ever becoming ready. A loop that
  attempted every few seconds failed for 900–1000 s straight, while the first
  attempt after a quiet pause succeeded at once.

So `bluetooth-addr.service` makes exactly one attempt per invocation, and
`bluetooth-addr.timer` invokes it again ten minutes after boot and every ten
minutes after that. Nothing is ordered before the boot, so a slow controller can
never delay it. Measured result once configured: `hci0 UP RUNNING`, factory
address, and a scan finding 28 devices.

**Audio needs one mixer switch.** Opening `MultiMedia1` failed with
`Audio open error: Invalid argument` because no backend was enabled:

```
MultiMedia1: ASoC: no backend DAIs enabled for MultiMedia1,
  possibly missing ALSA mixer-based routing or UCM profile
```

Turning on `QUAT_MI2S_RX Audio Mixer MultiMedia1` routes playback to the TAS2557
speaker amplifier. `audio-defaults.service` does that at boot, and it has to wait
for the *control* to exist rather than for the card: setting a switch that q6routing
has not registered yet is a silent no-op. The SLIMBUS backend must stay off;
enabling it makes prepare fail with `-EINVAL` and silences the speaker path.

```
$ aplay -D plughw:0,0 tone.wav
Playing WAVE: Signed 16 bit Little Endian, Rate 48000 Hz, Stereo
tas2557: Enable: 1 -> load startup sequence -> load unmute sequence
```

**Charging depends on the cable, not on the driver.** With the phone plugged into
a PC's USB-A port the charger reports `online=1` and the pack charges. A wall
charger that presents a Type-C source reported `online=0` and `VOLTAGE_NOW=0`,
with no USB event in `dmesg` at all: there is no Type-C/PD negotiation in this
kernel (`/sys/class/typec` does not exist), so a C-to-C PD charger never enables
VBUS. `usb_type` reports `[Unknown] SDP DCP CDP`, which is BC1.2 only. Use a
USB-A charger with an A-to-C cable.

**`reboot bootloader` still does not reach fastboot.** The IMEM driver loads and
writes `0x77665500` to IMEM +0x65c, and the phone does reboot — but ABL boots Linux
again. The vendor implementation uses `PON_POWER_OFF_WARM_RESET` for a bootloader
command, while mainline `reboot` performs a hard reset, so a warm reset is the
likely missing piece. Until that is implemented, fastboot needs Volume Down +
Power.

## Cellular modem: IPA enabled, and the only blocker is a SIM

The modem has been running for a while (`rmtfs -s` starts it, QMI is reachable over
QRTR), but ModemManager refused to create a modem object:

```
[qrtr0/probe] probe step: QMI ... done
[device qcom-soc] creating modem with plugin 'qcom-soc' and '1' ports
<wrn> couldn't create modem for device 'qcom-soc': Failed to find a net port in the QMI modem
```

The missing net port is **IPA** (IP Accelerator), the pipe the modem uses for data.
`CONFIG_QCOM_IPA=y` was already set, but the `ipa@1e40000` node in `sdm845.dtsi` is
`status = "disabled"` and the board tree never enabled it.

Enabling it is a small device-tree change. The reserved regions `ipa_fw_mem`
(64 KiB) and `ipa_gsi_mem` (20 KiB) are already in `sdm845.dtsi`, and the Xiaomi
boards in mainline (`sdm845-xiaomi-perseus.dts`, `sdm845-xiaomi-polaris.dts`) show
the exact shape:

```dts
&ipa {
	memory-region = <&ipa_fw_mem>;
	firmware-name = "qcom/sdm845/mi8/ipa_fws.mdt";
	qcom,gsi-loader = "self";

	status = "okay";
};
```

The firmware is proprietary and lives in the stock ROM's **vendor.img**
`/firmware/` directory as `ipa_fws.mdt` plus `.b00..b04` segments — not in the
modem partition, and there is no separate `ipa_fws` partition on this device.
`scripts/prepare-firmware.sh` extracts it and `scripts/build-initramfs.sh` puts it
in the initramfs, because IPA is built in and probes before the real root exists.

Measured after flashing the new boot image:

```
ipa 1e40000.ipa: IPA driver initialized
ipa 1e40000.ipa: IPA driver setup completed successfully
ipa 1e40000.ipa: received modem starting event
ipa 1e40000.ipa: received modem running event

$ ip -br link | grep rmnet
rmnet_ipa0       DOWN     <>

$ mmcli -L
    /org/freedesktop/ModemManager1/Modem/0 [QUALCOMM INCORPORATED] 0

$ mmcli -m 0
  Hardware | manufacturer: QUALCOMM INCORPORATED
           |    drivers: rpmsg_ctrl, ipa, qrtr
  Status   |    state: failed
           |    failed reason: sim-missing
```

So the chain now reaches "modem created by ModemManager" and stops only at
`sim-missing`: the card slots report `error: no-atr-received`, no network is
registered and the signal is -128 dBm.

### The SIM is only usable once a UIM session exists

Two things were wrong, and neither was the card:

1. **Slot 1 detection is broken on this unit.** `--uim-get-slot-status` is the
   reliable presence check (`--uim-get-card-status` reports an error state even
   with an empty tray). The card reads as `present` in slot 2 only.
2. **The modem never activates the USIM application by itself.** It stays at
   `Application state: 'detected'`, no primary GW provisioning session exists, and
   ModemManager fails with `Couldn't check unlock status: QMI operation failed:
   GW primary session index unknown`.

`systemd/modem-bringup.service` fixes it with three plain `qmicli` calls: bring the
radio online (the modem boots in `shutting-down` mode), switch the card's physical
slot onto logical slot 1, then activate the primary session **with the
application AID**. Without `aid=` qmicli powers the card off first and the modem
rejects that with `QMI error (3) 'Internal'`; with the AID it succeeds and the
application goes `detected -> ready`.

Measured:

```
$ mmcli -m 0
  state: registered          operator: 46000 / CHINA MOBILE
  signal quality: 76%        packet service state: attached
  own number: 8617868189616

$ mmcli -m 0 --messaging-list-sms
  SMS/4 (received)  equuleus sms test 1
  SMS/6 (received)  ä¸­æ...  (see below)
```

Sending and receiving both work, including Chinese text: the received PDU decodes
to the exact UTF-8 bytes of "中文测试：equuleus 发送正常" with zero replacement
characters.

### Mobile data: the bearer comes up, the data path does not

With `CONFIG_RMNET` (plus its `ETHERNET`/`NET_VENDOR_QUALCOMM` parents, which a
minimal config drops silently) the modem creates a QMAP mux link and the bearer
negotiates a real address:

```
qmapmux0.0@rmnet_ipa0   IPv4 10.136.56.157/30  gateway 10.136.56.158
                        DNS 221.179.38.7, 120.196.165.7, MTU 1410
```

**IPv4 data works** once the bearer is connected as IPv4-only and its addresses
are applied by hand - ModemManager negotiates them but nothing configures a QRTR
modem's netdev, and NetworkManager does not manage this modem. Measured:

```
qmapmux0.0  10.210.154.78/30  via 10.210.154.77  mtu 1410
            dns 221.179.38.7, 120.196.165.7

download  16,137,272 bytes in 4.33 s   ≈ 3.73 MB/s  (29.8 Mbit/s)
upload     8,585,216 bytes in 12.0 s   ≈ 0.72 MB/s  ( 5.7 Mbit/s)
latency    30/30 replies, min/avg/max 29.9/36.4/57.2 ms, 0% loss
```

Additional attempts to make IPv6 usable all failed in the same way - the modem
accepts the call and returns addresses but forwards nothing:

| Attempt | Result |
|---|---|
| `ipv4v6` bearer, IPv4 configured first | no ingress at all |
| `ipv6` bearer as the first call after boot | no ingress at all |
| DAD and ND disabled (`arp off`, `addrgenmode none`) | no change |
| rmnet links for mux ids 0-7 created and watched | no link ever received a frame |
| Two separate PDN calls (v4 + v6) | modem rejects: `InvalidOperation` / `Internal` |
| Default data profile set to `cmnet` + `IPV4V6` | call still delivers no downlink |

So IPv6 is not a configuration problem that a helper script can fix: the modem's
IPA downlink for a non-IPv4 flow is never set up. The downstream kernel shows what
is missing: `ipa_v3/ipa_rt.c`, `ipa_flt.c` and `ipa_hdr.c` program per-family
routing, filter and header tables, a userspace daemon (`ipacm`) drives them
through `IPA_IOCTL_ADD_RT_RULE` / `IPA_IOC_COPY_HDR`, and `ipa_qmi_service.c`
answers the modem's IPA requests - `ipacm` even installs dedicated "dummy" v6
header and filter handles. Upstream's driver has none of that.

**Practical way to get IPv6 on this device:** tunnel it over the working IPv4
link. A WireGuard link to a VPS provides public IPv4 *and* IPv6 plus inbound
reachability, which native dual-stack would not give anyway: China Mobile hands
out a CGNAT IPv4 address, so there is nothing to port-forward. Android does that from
userspace through `ipacm`, which installs IPA routing and filter rules; mainline
has neither the interface nor a rule-provisioning client, so this needs platform
work rather than a device tree or ModemManager change. BAM-DMUX is not an
alternative here: `CONFIG_QCOM_BAM_DMUX` exists in the tree but SDM845 has no
`qcom,bam-dmux` node (this SoC carries its data path over IPA).

Two behaviours of this modem firmware shape the design:

* **A dual-stack or IPv6-only bearer delivers no downlink at all.** With
  `ip-type=ipv4v6` or `ipv6` the modem hands out addresses (including a real
  `2409:...` IPv6 address) but the parent interface never receives a usable
  frame; even the IPv4 half stops working. `ip-type=ipv4` works. See the table
  above for the attempts that ruled out a mux id or DAD/ND explanation.
* **A bearer cannot be torn down and re-created within one boot.** Reconnecting
  leaves the rmnet mux link with a working uplink but a dead downlink; only a
  modem restart (a reboot) restores it. The `data-bringup` helper consequently
  connects exactly one bearer, only if none is up, and never disconnects.

`systemd/data-bringup.service` runs after registration, connects
`apn=cmnet,ip-type=ipv4` (the APN can be overridden in `/etc/equuleus/data-apn`)
and applies the address, gateway, MTU and DNS. Verified on hardware after a cold
boot: the bearer comes up on its own and `ping` succeeds with 0% loss.

Both units come from the Debian packages (`qrtr-ns.service` from `qrtr-tools`,
`ModemManager.service` from `modemmanager`, which pulls `polkitd`);
`systemd/ModemManager-10-equuleus.conf` only adds the `Wants=`/`After=` ordering
after `qrtr-ns`, since the shipped unit orders after polkit alone.

## Next steps

1. **Touch.** The ST FTS5 node and its `avdd`/`vdd` rails are not enabled yet.
2. **Warm reset for `reboot bootloader`.** Implementing the PON warm-reset path may
   be what makes the IMEM reason stick.
3. **Type-C/PD detection.** Until a Type-C driver exists, document the USB-A
   requirement rather than implying any charger works.

## How this was debugged without a UART

The method follows Mechres' dipper bring-up: use the presence of a USB device as
the progress signal, since there is no other output on a phone with a dead
screen. Three things made that possible here:

1. Fixing the ABL DTB placement rule (see README) so images actually boot.
2. Fixing the initramfs so it mounts configfs before creating the USB gadget.
   Before that fix every image looked like "the kernel is dead".
3. Reading `cat /proc/kmsg` over the console to see that the machine went silent
   with no panic — the signature of a bus deadlock rather than a kernel crash.
