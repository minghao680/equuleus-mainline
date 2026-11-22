# equuleus 主线 Linux —— 交接文档

> 写给接手的 agent：你没有之前的上下文，这份文档是自包含的。
> 更新时间：2026-11-22 15:00
> 工作目录：`G:\equuleus-linux`　仓库：<https://github.com/minghao680/equuleus-mainline>

---

## 0. 一句话现状

**已经是一台能用的 Debian 13 手机**：主线内核 7.1.0-rc1 启动到 systemd（PID 1），8 核 7.8 GB 内存，UFS 全部可用，通过 USB 串口 root 自动登录。

**唯一卡住的重大问题是 WiFi**，详见第 5 节——那是留给你的主要任务。

---

## 1. 设备与连接

### 设备

- 小米 8 屏幕指纹版 / Mi 8 Pro，代号 **equuleus**，M1807E8A，SDM845，8 GB，MP 硬件
- **屏幕物理损坏**，无法从屏幕获取任何信息
- Bootloader 已解锁（`boot state ORANGE`），**已刷回原厂 MIUI 12.5.2 的 bootloader**（`product: equuleus`）

### ⚠️ 必须指定序列号

机器上同时存在另一个 adb 设备 `127.0.0.1:16384`（不是本机），所有命令都要带 `-s`。

| 通道 | 序列号 | 说明 |
|---|---|---|
| fastboot | `764e4f55` | 原厂 ABL |
| 串口 | Windows 上枚举为 COM 口（当前 COM16） | 主线内核的 USB CDC-ACM |

### 进入 fastboot

设备跑主线时 USB 上只有串口，**没有 fastboot**。当前只能人工操作：

> 长按电源 10 秒强制断电，然后**音量减 + 电源**

`reboot bootloader` 理论上可用（见第 6 节），2026-11-22 正在补 PM8998 PON 节点。

---

## 2. 已经确认的事实（都有证据，不要重复验证）

### 2.1 启动链

- ABL 会接受我们打包的镜像并跳转。判据是 logfs 里的 **`Shutting Down UEFI Boot Services`**，不是有没有报错
- `BootLinux: GetImage failed!DTB offset is incorrect` **只是警告**，不致命
- 但 **DTB 必须紧贴 gzip 流结尾（delta = 0）**，否则行为不可靠。`scripts/pack-bootimg.sh` 强制校验这一点
- `fastboot boot`（临时启动）**不可靠**，同一镜像两次结果可能不同。只用 `flash boot` + `reboot`

### 2.2 曾经导致误判的坑

| 坑 | 后果 |
|---|---|
| initramfs 没挂 `configfs` 就建 USB gadget | gadget 静默失败，主机永远看不到设备，**健康的内核看起来完全死了** |
| `logfs` 是写满的环形缓冲区 | 「数启动记录条数」的方法失效，只能比内容 |
| Android 的 `sh` 是 32 位算术 | `$((0x80000000/4096))` 溢出成负数 |
| `od -t x1z` 在 toybox 里不支持 | 用 `od -A x -t x1` |
| PowerShell 会吃掉内联 `bash -c` 里的 `$var` | **设备侧脚本必须写成文件再执行** |
| `/dev/mem` 读不了 System RAM | 返回 EFAULT；`/dev/kmem` ENXIO；无 `/proc/kcore` |

### 2.3 UFS 和显示

- **UFS**：之前完全不 probe，原因是 `CONFIG_SCSI_UFSHCD` / `CONFIG_SCSI_UFS_QCOM` / `CONFIG_BLK_DEV_SD` 没开。设备树一直是对的。开启后 6 个 LUN 全部枚举，`userdata` 在 `sda21`（113 GB）
- **27 秒重启循环**：bootloader 点亮的 MDSS 无人接管，UFS probe 完成后 `qnoc-sdm845` 进入 `sync_state()` 释放互联带宽，孤儿 DMA 走无投票路径 → NoC 死锁 → 看门狗复位。修法是给 MDSS 一个真驱动（`dispcc` + `mdss` + DSI + EA8074 面板），**不是**关 cpuidle 或 cluster-sleep
- **背光调不了**：`dsi_pll_10nm_vco_prepare: PLL(0) lock failed`，DSI 链路没通，而 AMOLED 的亮度就是这条链路上的 DCS 命令。链路断了就没有「亮度」这个对象

---

## 3. 系统当前状态

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

| 组件 | 状态 |
|---|---|
| 内核 / SMP / 内存 | ✅ 7.1.0-rc1，8 核，7.8 GB |
| USB CDC-ACM 控制台 | ✅ 开机约 5 秒出现 |
| UFS | ✅ `SAMSUNG KLUDG4U1EA-B0C1`，6 个 LUN |
| 显示控制器 | ✅ `msm 1.13.0`，`card0-DSI-1` = `connected`（但 PLL 不锁，面板不亮） |
| Debian 13 + systemd | ✅ `serial-getty@ttyGS0` root 自动登录 |
| ADSP | ✅ 需要开机后手动 `start`（见 4.1） |
| **WiFi** | ❌ **modem（MPSS）从未启动，WLFW QMI 服务永远不出现；根因与路线见第 5 节** |
| 触摸 / 音频 / 基带 | 未启用 |

---

## 4. 两个已知的实现细节

### 4.1 ADSP 固件必须在 probe 时可见

`remoteproc` 是内建驱动，在 **initramfs 阶段**就 probe 了，那时根文件系统还没挂载。放在 `/lib/firmware` 里的固件它**看不到**：

```
remoteproc remoteproc1: Direct firmware load for qcom/sdm845/mi8/adsp.mbn failed with error -2
```

根挂好后再触发一次就成功：

```
echo start > /sys/class/remoteproc/remoteproc1/state
→ remoteproc remoteproc1: remote processor adsp is now up
```

已用 `systemd/adsp-start.service` 固化。

**固件来源**：原厂 `modem` 分区（vfat，挂在 `/vendor/firmware_mnt`）的 `image/` 目录，含 `adsp.b00`~`adsp.b14`、`adsp.mdt`、`adspr.jsn`。安装到 `/lib/firmware/qcom/sdm845/mi8/`（DT 里 `firmware-name` 要求的位置），`adsp.mdt` 复制一份命名为 `adsp.mbn`。

### 4.2 增量维护根文件系统

rootfs 目录在 WSL 的 `/home/claude/rootfs-trixie-arm64`，镜像是 `G:\equuleus-linux\rootfs.ext4`（4 GB ext4，UUID `b04fd122-…`）。改动 rootfs 后重跑 `make_rootfs_image.sh`（会复用已有 UUID，不会失配），再 `fastboot flash userdata`。

---

## 5. WiFi —— 主要待解问题

> **⚠️ 本节已被后续工作推翻，请以 `HANDOFF-wifi-progress.md` 为准。**
>
> 关键更正：WLAN 固件**跑在 modem（MPSS）上**，不是由 Linux 加载。ath10k 只是等 WLFW QMI 服务出现。
> 所以「需要自己写加载器、找 PAS ID」是错的方向——`qcom_q6v5_mss` 的 `auto_boot = false` 才是原因。
>
> 后续进展：modem 已能启动并稳定运行，ath10k 已确认跟随 modem 状态，当前卡在 `rmtfs` 的分区名映射上。
> 详见 **`HANDOFF-wifi-progress.md`**。

### 5.1 现象

驱动全部就位后，`ath10k_snoc` **完整走完 probe**，然后就没了：

```
ath10k_snoc 18800000.wifi: snoc xo-cal-data return -22
ath10k_snoc 18800000.wifi: qmi msa.paddr: 0x8e300000 , msa.vaddr: 0xd629f3b8
ath10k_snoc 18800000.wifi: snoc probe          ← probe 成功结束
（之后永远静默，没有 wlan0，没有任何错误）
```

即使 `debug_mask=0xffffffff` 且 `CONFIG_ATH10K_DEBUG` 已编译进去，也没有更多输出。

### 5.2 已经做过并且确认无效的

| 尝试 | 结果 |
|---|---|
| 启用 `CONFIG_WLAN` / `CFG80211` / `MAC80211` / `ATH10K` / `ATH10K_SNOC` | ✅ 必须——`CONFIG_WLAN` 是隐藏总开关，不开它 `ATH10K` 会被 `olddefconfig` 丢弃 |
| 安装 `firmware-5.bin` / `board-2.bin` / `wlanmdsp.mbn`（来自 Debian `firmware-atheros`） | ✅ 已就位 |
| 补齐 `vdd-3.3-ch1-supply` | ✅ 警告消失，但对现象无影响 |
| 修好 ADSP 并启动 | ✅ ADSP up，但对 ath10k 无影响 |
| **启动 modem（MPSS）** | **从未做过**——这才是缺失的环节，见 5.3 |
| 加 `qcom,snoc-host-cap-skip-quirk` | 无影响 |
| 设 `debug_mask` 全开 | 只有上面那三行 |

### 5.3 根因（2026-11-22 复核）：WLAN 固件由 modem 加载，而 modem 从未启动

原结论「没有任何代码在加载 WCN3990 固件」的**事实部分正确**（下表仍成立），但推出的方向——自己写 PAS 加载器、找 WLAN PAS ID——**是错的**。加载者不是缺失的代码，而是 **modem（MPSS）子系统**：SDM845 上 WCN3990 的 WLAN 固件跑在 modem 上，由 TZ/modem 侧负责加载；Linux 侧 ath10k 只负责等 WLFW QMI 服务出现。

| 位置 | 有没有 `wlanmdsp` / `subsystem_get("wlan")` / PAS 调用 |
|---|---|
| LineageOS/MIUI 4.9 内核（`~/equuleus-src/kernel`） | **全树没有** |
| Halium 9 内核（`~/halium-kernel`） | **全树没有** |
| 闭源 `qca_cld3_wlan.ko`（9.2 MB，未 strip） | **没有**。未定义符号只有 `request_firmware`，无 PAS/SCM；不内嵌固件 |
| 主线内核 | **没有**。全树唯一的 `qcom_mdt_load` 在 `ath12k` |

**源码证据**（内核树 `/home/claude/sdm845-mainline`，均已逐行核对）：

| 证据 | 位置 | 含义 |
|---|---|---|
| `rproc->auto_boot = false;` | `drivers/remoteproc/qcom_q6v5_mss.c:2098` | **modem remoteproc 永不自动启动**。对比：ADSP 是 `auto_boot = true`（`qcom_q6v5_pas.c:903`），所以 ADSP 开机会尝试加载并报 `-ENOENT`；modem 连尝试都没有，一行日志都不出 |
| `qcom_register_sSR_notifier("mpss", ...)` | `ath10k/snoc.c:1556`（`ath10k_modem_init()`，probe 末尾调用，见 snoc.c:1864） | ath10k 显式订阅 modem 的上/下线事件——WLAN 固件随 modem 存亡 |
| `qcom_add_ssr_subdev(rproc, ..., "mpss")` | `qcom_q6v5_mss.c:2193` | modem 的 SSR 通知名正是 `"mpss"`，与 ath10k 的订阅严格对应 |
| 无 `wifi-firmware` 子节点 → `use_tz = true` | `ath10k/snoc.c:1624-1627`；且全部上游 sdm845 DTS（db845c、crosshatch、beryllium）都没有该节点 | WLAN 固件由 TZ 侧加载是 SDM845 的**正常设计**，不是本项目缺陷 |
| `qmi_add_lookup(WLFW_SERVICE_ID_V01, ...)` 后无超时告警 | `ath10k/qmi.c:1115` | probe 结束后 ath10k 只是注册服务查找，对端不出现就永久静默——与「三行日志后再无输出」完全吻合 |

**同 SoC 旁证**：

- Mechres dipper 笔记 §0 原文：*"On SDM845 the WCN3990 Wi-Fi firmware runs on the modem"*——他的机器 modem RF 损坏，因此整机放弃 WiFi。
- 上游 `sdm845-db845c.dts`、`sdm845-google-crosshatch.dts`（Pixel 3）都是 `&mss_pil` + `&wifi` 同时启用且 WiFi 正常。

**当前系统 modem 没跑的两个具体原因**：

1. **固件没装**：DT 要求 `qcom/sdm845/mi8/mba.mbn` + `qcom/sdm845/mi8/modem.mbn`，但 `/lib/firmware/qcom/sdm845/mi8/` 里只有 `adsp.*` 和 `cdsp.*`。`mba.mbn`（238,304 B）、`modem.mdt`、`modem.b00..b28` 都在原厂 `modem.img` 的 `image/` 目录里（FAT16，`stock-rom/equuleus_images_V12.5.2.0.QECCNXM_.../images/modem.img`，`7z x` 即可解出），从未提取。
2. **没人启动它**：`auto_boot = false` 意味着必须有用户态动作，但系统里只有 `adsp-start.service`，没有对应的 modem 启动服务，也没人手动 `echo start` 过。

顺带：Debian `firmware-atheros` 的 `wlanmdsp.mbn`（3,725,044 B）与原厂的（3,645,892 B）不同，且 Linux 本来就不加载它——装不装都不影响，别再在这上面花时间。

### 5.4 修复路线（不需要写任何新驱动，不需要找 PAS ID）

原 5.4 第 2 条（写加载器 / 探测 PAS ID）**作废**：`qcom_q6v5_mss` 就是现成的 modem 加载器，self-authenticating 的认证细节由驱动内部处理。要做的只是把固件摆到它要的路径并 `start`：

1. **提取固件**：从 `modem.img` 解出 `image/mba.mbn`、`image/modem.mdt`、`image/modem.b00..b28`，全部装入 `/lib/firmware/qcom/sdm845/mi8/`，并把 `modem.mdt` 复制一份命名为 `modem.mbn`（与 `adsp.mdt`→`adsp.mbn` 同一招；MSS 驱动在 `qcom_q6v5_mss.c:1554` 只把文件名**末 3 个字符**替换成 `b%02d`，所以段文件按原名摆放即可）。
2. **启动 modem**：`ls /sys/class/remoteproc/` + `cat .../name` 找到 modem 实例（ADSP 是 remoteproc1，modem 大概率是 remoteproc0），`echo start > /sys/class/remoteproc/remoteprocN/state`。成功标志：`remote processor modem is now up`。
3. **观察 WiFi**：无需重新 bind ath10k——`qmi_add_lookup` 持续有效，WLFW 服务上线会自动触发握手。盯 `dmesg | grep -iE "remoteproc|qrtr|ath10k|wlfw"`。保险起见也可 unbind/bind（命令见第 8 节）。
4. **固化**：仿 `adsp-start.service` 加 `modem-start.service`（与 ADSP 互相独立，无先后依赖）。
5. **如果 modem 起了 WiFi 仍沉默**，按序排查：
   - `cat /sys/class/remoteproc/remoteproc*/state`——mss 启动失败（mba load 失败、SCM 拒绝等）在 dmesg 有明确报错，不会静默
   - `ls /sys/kernel/debug/qrtr/`——WLFW 服务（node/service）有没有注册
   - DT 加 `qcom,calibration-variant`（beryllium 用 `"xiaomi_beryllium"`），非首要
   - CE 通道 / SMP2P / IRQ（`ATH10K_DBG_QMI` 已随 debug_mask 全开）
6. **降级方案不变**：USB NCM/RNDIS 走同一根线拿 IP + ssh，与 WiFi 互不影响。

### 5.5 参考

- Mechres 的 dipper 移植（同 SoC，无 UART 方法）：<https://mechres.dev/post/xiaomi-mi8-dipper-mainline-linux-bringup>
- 他的仓库（含 EA8074 面板驱动补丁，已用于本项目）：<https://github.com/Mechres/xiaomi-mi8-dipper>

---

## 6. 重启到 fastboot（已验证可用）

**在系统里执行 `reboot bootloader` 即可进入 fastboot，不需要手动按键。** 2026-11-22 在真机上验证通过：

```
root@equuleus:~# reboot bootloader
（约 4 秒后主机出现 Android Bootloader Interface）
$ fastboot devices
764e4f55	fastboot
```

原理：`qcom-pon` 把重启理由写进 PM8998 的 PON scratch 寄存器，ABL 下一轮启动时读取它决定进 fastboot 还是正常启动。

之前失效的原因：**主线 sdm845 设备树从不实例化 PM8998 的 SPMI 节点**，`pon@800` 不存在，`qcom-pon` 绑定不到设备。修法是在 DTS 里 `#include "pm8998.dtsi"`——该文件不含 regulator（不会和 RPMh 冲突），`pon@800` 自带 `mode-bootloader = <0x02>`。

验证驱动绑定的方法：

```sh
ls /sys/bus/platform/drivers/qcom-pon/
# 应能看到 c440000.spmi:pmic@0:pon@800
```

注意：加了 PM8998 节点后**第一次**刷入时设备可能直接停在 fastboot、不启动。重发一次 `fastboot reboot` 就正常了（2026-11-22 观察到的现象，原因未查明，但不影响后续使用）。

兜底方案：`reboot` 后立刻按住音量减。

---

## 7. 仓库与构建

### 仓库

<https://github.com/minghao680/equuleus-mainline>（公开，GPL-2.0）

| 路径 | 内容 |
|---|---|
| `dts/sdm845-xiaomi-equuleus.dts` | 设备树（TrustZone GPIO 保留、显示管线、面板电源、WiFi 供电） |
| `kernel/panel-samsung-ea8074.c` | EA8074 面板驱动源码 |
| `config/equuleus.config` | 完整内核配置 |
| `initramfs/init` | 挂 configfs → 建 USB 串口 → 挂根分区 → `switch_root` 到 systemd |
| `scripts/build.sh` | 端到端构建 |
| `scripts/pack-bootimg.sh` | 打包，强制校验 `delta == 0` |
| `scripts/verify-image.py` | 刷前自检（DTB 布局、cmdline、`/init` 是否挂 configfs） |
| `scripts/build-rootfs.sh` | 构建 Debian rootfs + ext4 镜像 |
| `systemd/adsp-start.service` | 开机启动 ADSP |

### 内核源码

`/home/claude/sdm845-mainline`（WSL Debian，7.1.0-rc1，来自 postmarketOS 的 `linux-sdm845-7.1-rc1-r0`）

**对内核源码的改动只有两处**：新增 `sdm845-xiaomi-equuleus.dts`，`Makefile` 加一行。其余全部是配置和打包。

### 构建

```bash
cd /mnt/g/equuleus-linux/equuleus-mainline
KERNEL_SRC=/home/claude/sdm845-mainline \
BUSYBOX=/home/claude/busybox-aarch64 \
bash scripts/build.sh
```

产物 `out/boot.img`（64 MB）。rootfs 用 `scripts/build-rootfs.sh`。

### 刷机

```bash
fastboot -s 764e4f55 flash boot     out/boot.img
fastboot -s 764e4f55 flash userdata /mnt/g/equuleus-linux/rootfs.ext4
fastboot -s 764e4f55 reboot
```

---

## 8. 照抄即可的操作

### 连上设备

Windows 上找到新的 COM 口（不是 COM3/COM33），115200 8N1。

**注意**：电源操作后 COM 口名字可能复用（比如一直是 COM16），所以「找新端口」的判断会失效——直接连这个名字也行。

### 常用命令

```sh
# 系统状态
cat /proc/1/comm; systemctl is-system-running; nproc; free -m | head -2

# 启动 ADSP（若 adsp-start.service 没生效）
echo start > /sys/class/remoteproc/remoteproc1/state

# WiFi 调试
echo 0xffffffff > /sys/module/ath10k_core/parameters/debug_mask
echo 18800000.wifi > /sys/bus/platform/drivers/ath10k_snoc/unbind
echo 18800000.wifi > /sys/bus/platform/drivers/ath10k_snoc/bind
dmesg | grep -i ath10k
```

### 串口操作的坑

- 如果提示符变成 `>`，说明有未闭合的引号，发 `Ctrl-C` 两下再回车复位
- 命令要用**单行**，复杂逻辑写到设备上的脚本文件里再执行
- PowerShell 里给串口发命令时，`$`、`"`、`;` 都容易出问题，尽量用单引号包住整条命令
