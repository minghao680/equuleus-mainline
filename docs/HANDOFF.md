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
| **WiFi** | ❌ **固件没被加载，见第 5 节** |
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
| 加 `qcom,snoc-host-cap-skip-quirk` | 无影响 |
| 设 `debug_mask` 全开 | 只有上面那三行 |

### 5.3 关键结论：**没有任何代码在加载 WCN3990 固件**

这是查证过的，不是推测：

| 位置 | 有没有 `wlanmdsp` / `subsystem_get("wlan")` / PAS 调用 |
|---|---|
| LineageOS/MIUI 4.9 内核（`~/equuleus-src/kernel`） | **全树没有** |
| Halium 9 内核（`~/halium-kernel`） | **全树没有** |
| 闭源 `qca_cld3_wlan.ko`（9.2 MB，未 strip） | **没有**。未定义符号只有 `request_firmware`，无 PAS/SCM；不内嵌固件 |
| 主线内核 | **没有**。全树唯一的 `qcom_mdt_load` 在 `ath12k` |

主线 `ath10k` 的机制是：

```c
/* snoc.c */
node = of_get_child_by_name(host_dev->of_node, "wifi-firmware");
if (!node) {
        ar_snoc->use_tz = true;      /* 假定 TrustZone 已经把固件起好了 */
        return 0;
}
/* qmi.c */
qmi_add_lookup(&qmi->qmi_hdl, WLFW_SERVICE_ID_V01, ...);   /* 然后就是等 */
```

`qmi_add_lookup` 如果对端不响应，是**静默超时**的，不报错。所以「固件没跑」和「固件在跑但握不上」在日志里长得一样。

### 5.4 下一步建议（按优先级）

1. **确认固件到底有没有在跑。** 目前所有观测都无法区分这两种情况。可以考虑：
   - 抓 ABL 阶段的行为（需要装回工程固件才能用 adb 读 `logfs`，代价较大）
   - 或者用示波器/逻辑分析仪看 WCN3990 的复位和供电时序
2. **如果确认固件没跑**，需要实现一个加载器。参考 `drivers/net/wireless/ath/ath12k/ahb.c` 的做法：
   `request_firmware` → `qcom_mdt_load` → `qcom_scm_pas_auth_and_reset(pasid)`。
   **难点是 PAS ID**——在闭源模块和三个内核树里都没找到 sdm845 WLAN 的 PAS ID，可能需要反汇编或实验探测（`qcom_scm_pas_supported` 试一组 ID）。
3. **如果固件在跑只是握手失败**，重点查 CE 通道和 SMP2P/IRQ，用 `/sys/kernel/debug/ath10k/`（需 `CONFIG_ATH10K_DEBUGFS`）。
4. **降级方案**：给 initramfs 加 USB NCM/RNDIS，通过同一根线拿到 IP 和 `ssh`。慢但确定能成，且不依赖 WiFi。

### 5.5 参考

- Mechres 的 dipper 移植（同 SoC，无 UART 方法）：<https://mechres.dev/post/xiaomi-mi8-dipper-mainline-linux-bringup>
- 他的仓库（含 EA8074 面板驱动补丁，已用于本项目）：<https://github.com/Mechres/xiaomi-mi8-dipper>

---

## 6. 重启到 fastboot（进行中）

`reboot bootloader` 依赖 `qcom-pon` 把重启理由写进 PM8998 的 PON 寄存器，ABL 下一轮启动时读取。

之前失效的原因：**主线 sdm845 设备树从不实例化 PM8998 的 SPMI 节点**，所以 `pon@800` 不存在，`qcom-pon` 绑定不到任何设备。

修法：DTS 里 `#include "pm8998.dtsi"`（该文件不含 regulator，不会和 RPMh 冲突），`pon@800` 自带 `mode-bootloader = <0x2>`。

若仍不生效，兜底方案是 `reboot` 后立刻按住音量减。

---

## 7. 仓库与构建

### 仓库

<https://github.com/minghao680/equuleus-mainline>（公开，GPL-2.0）

| 路径 | 内容 |
|---|---|
| `dts/sdm845-xiaomi-equuleus.dts` | 设备树（TrustZone GPIO 保留、显示管线、面板电源、WiFi 供电） |
| `patches/0001-drm-panel-add-samsung-ea8074.patch` | EA8074 面板驱动 |
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
