# WiFi 追查交接（2026-11-22 15:55 定稿）

> 接在 `docs/HANDOFF.md` 第 5 节之后。上一位接手者把方向纠正为「WLAN 固件跑在 modem 上」——**这个方向是对的，已在真机上完整验证**。本文记录执行到哪一步、断点在哪、以及我已经排除的路径，避免重复劳动。

---

## 一句话现状

**modem 已经能启动并稳定运行，ath10k 也确认在跟随 modem 状态**——整条链路打通了。唯一卡住的是 `rmtfs` 拒绝服务 modem 请求的两个分区名：

```
rmtfs: [RMTFS storage] request for unknown partition '/boot/modem_fsg_oem_1', rejecting
rmtfs: [RMTFS storage] request for unknown partition '/boot/modem_fsg_oem_2', rejecting
```

**下一刀就切在这里。**

---

## 一、已验证成立的部分

### 1.1 modem 固件安装

从 `stock-rom/equuleus_images_V12.5.2.0.QECCNXM_.../images/modem.img`（FAT16，可 `sudo mount -o loop,ro`）提取到 `/lib/firmware/qcom/sdm845/mi8/`：

| 文件 | 说明 |
|---|---|
| `mba.mbn` | 238 KB |
| `modem.mbn` | `modem.mdt` 复制改名，驱动只替换文件名末 3 字符 |
| `modem.b00`~`modem.b28` | **27 个**分段 |
| `modemr.jsn` / `modemuw.jsn` | PIL 元数据 |

`modem.b14` 和 `modem.b19` 不存在，但**源镜像里本来就没有**，不是提取遗漏。

### 1.2 modem 启动

`remoteproc0` 就是 modem：`4080000.remoteproc`，`compatible = "qcom,sdm845-mss-pil"`。

启动成功的日志：

```
qcom-q6v5-mss 4080000.remoteproc: MBA booted without debug policy, loading mpss
remoteproc remoteproc0: remote processor 4080000.remoteproc is now up
```

> ⚠️ **坑**：这个 remoteproc 的 `name` 是平台设备名 `4080000.remoteproc`，**不含 "mss"/"modem" 字样**。按名字匹配会漏。`systemd/start-modem.sh` 已改为同时检查 `device/of_node/compatible` 里的 `mss-pil`。

### 1.3 ath10k 与 modem 的耦合 —— 核心判断被证实

```
ath10k_snoc 18800000.wifi: received modem running event
ath10k_snoc 18800000.wifi: received modem crashed event
ath10k_snoc 18800000.wifi: received modem offline event
ath10k_snoc 18800000.wifi: received modem starting event
```

ath10k 完全跟随 modem 的 SSR 状态变化。这只有「WLAN 固件跑在 modem 上」才能解释。

### 1.4 崩溃循环已消除

modem 最初每 **43 秒**崩一次（`fatal error without message`，累计 14 次）。装上 `rmtfs` + `pd-mapper` 之后**崩溃计数归零**，稳定运行。

### 1.5 rmtfs 确实在服务 modem

`journalctl -u rmtfs` 里能看到 modem 发来的真实请求——**证明 QMI 通道是通的**，不是「没连上」。

---

## 二、断点：rmtfs 的分区名映射

### 2.1 机制

Debian 的 `rmtfs`（`pool/main/r/rmtfs/rmtfs_1.1-4_arm64.deb`，依赖 `libqrtr1`）内部有一张**编译进去的已知分区表**。从二进制里提取出来的完整表：

```
/boot/modem_fs1      ← modem_fs1
/boot/modem_fs2      ← modem_fs2
/boot/modem_fsc      ← modem_fsc
/boot/modem_fsg      ← modem_fsg
/boot/modem_tunning  ← modem_tunning
/boot/modem_tng      ← modem_tng
/boot                ← 默认目录
/dev/disk/by-partlabel
```

**名字不在表里就直接拒绝**，发生在查表阶段，**不是文件存在性检查**——所以建符号链接对 `modem_fsg_oem_1` 这种名字无效。

### 2.2 modem 要的是这两个名字

```
/boot/modem_fsg_oem_1
/boot/modem_fsg_oem_2
```

都不在表里。

### 2.3 设备上实际存在的相关分区

```
fsg      -> /dev/sde36     (modem_fsg 的候选)
fsc      -> /dev/sdf1      (modem_fsc 的候选)
modem    -> /dev/sde46
modemst1 -> /dev/sdf6
modemst2 -> /dev/sdf7
```

### 2.4 已经做过但无效的尝试

| 尝试 | 结果 |
|---|---|
| 在 `/boot` 下建 `modem_fsg`/`modem_fsc`/`modem_fs1`/`modem_fs2` 符号链接 | 建好了，但 modem 请求的是 `_oem_1`/`_2`，仍被查表拒绝 |
| 重启 rmtfs | 无新请求（modem 只在启动时请求一次） |
| 重启 modem 触发重新请求 | 没有产生新请求，行为待进一步观察 |
| 在 vendor 镜像里找原厂 rmtfs | **没有** |
| 在 system 镜像（`miui-adb-system.raw`）里找原厂 rmtfs | **也没有** |

**最后两条很重要**：Android 上并不存在一个 rmtfs 可执行文件，说明安卓那边**不是靠这个程序**给 modem 提供 EFS 的。这可能是关键线索。

---

## 三、下一步建议（按可能性排序）

### 3.1 先搞清 `modem_fsg_oem_1` / `_2` 到底是什么

几个方向：

1. **查 `rmtfs` 上游有没有处理 OEM 分区的版本**
   <https://github.com/linux-msm/rmtfs>
   表可能是可配置的，或者是新版本加的。

2. **看安卓侧的 init 脚本怎么提供的**
   `/vendor/etc/init/hw/init.qcom.rc` 和 `init.target.rc` 里提到 wlan/rmtfs 的部分（`miui-adb-vendor.raw` 已确认可 `mount -o loop,ro`）。

3. **反汇编原厂内核模块**
   安卓那边可能是内核态的 `qcom_rmtfs` 或者 `subsystem_ramdump` 直接映射分区，不需要用户态守护进程。下游内核 `~/equuleus-src/kernel` 里搜 `rmtfs`。

4. **确认 `_oem_1`/`_2` 是否就是 `fsg`/`fsc`**
   如果是，patch rmtfs 加两条映射即可。风险：EFS 分区写坏会丢校准数据，**操作前先备份 `fsg` 和 `fsc`**。

### 3.2 如果确认需要 patch rmtfs

`rmtfs` 的分区表在源码里是静态数组，加两行就行。但要注意：

- 编译需要 `libqrtr`（Debian 有 `libqrtr-dev`）
- 交叉编译到 aarch64 后放进 rootfs
- 服务参数是 `rmtfs -r -P -s`（`-r` 可能是只读，值得确认，只读能降低写坏 EFS 的风险）

### 3.3 rmtfs 通了之后

再看 ath10k 是否收到 WLFW QMI 服务：

```sh
dmesg | grep -iE 'ath10k|wlfw'
ip -brief link          # 期望出现 wlan0
```

如果仍然静默，按顺序查：
1. `remoteproc0` 状态是否 `running`
2. `/sys/kernel/debug/qrtr/`（**注意 lockdown，见下**）
3. `qcom,calibration-variant`（`board-2.bin` 里没有 equuleus 的变体，见 4.2）

---

## 四、两个已知的实现细节

### 4.1 内核处于 lockdown，debugfs 读不了

```
Lockdown: cat: debugfs access is restricted; see man kernel_lockdown.7
```

所以 `/sys/kernel/debug/remoteproc/remoteproc0/crash` 之类拿不到。内核配置里有 `CONFIG_SECURITY_LOCKDOWN_LSM`，来源待查（`secureboot=1` 相关）。**如果后续需要 debugfs 诊断，得先解决这个。**

### 4.2 `board-2.bin` 里没有 equuleus 的校准变体

Debian 的 `firmware-atheros` 提供的 `ath10k/WCN3990/hw1.0/board-2.bin` 里只有 `xiaomi_berylliumm`（还带拼写错误），**没有 equuleus**。

如果 WiFi 起来后信号异常或连不上，可能需要：
- 用原厂 `modem` 分区里的 `bdwlan.*`（已确认存在）转成 board 文件
- 或者用 DT 的 `qcom,calibration-variant` 指向一个存在的变体

### 4.3 不要再用 Debian 的 `wlanmdsp.mbn`

Debian 的 `firmware-atheros` 里那个 `wlanmdsp.mbn` 和原厂的不一样，而 **Linux 根本不加载这个文件**（加载在 modem 侧）。别再折腾它。

---

## 五、当前系统状态

| 组件 | 状态 | 服务 |
|---|---|---|
| systemd / Debian 13 | ✅ running | — |
| UFS / 显示控制器 / USB 串口 | ✅ | — |
| ADSP | ✅ running | `adsp-start.service` |
| **modem** | ✅ running，**不崩溃** | `modem-start.service` |
| rmtfs | ✅ active（但拒绝 OEM 分区） | `rmtfs.service` |
| pd-mapper | ✅ active | `pd-mapper.service` |
| **WiFi** | ❌ 无 `wlan0` | — |

已启用的单元：

```
adsp-start.service    modem-start.service
rmtfs.service         pd-mapper.service
serial-getty@ttyGS0   systemd-networkd
ssh.service           networking
```

---

## 六、操作备忘

### 6.1 从 Linux 进 fastboot（已验证可用）

```sh
reboot bootloader      # 约 4 秒后主机出现 Android Bootloader Interface
```

原理：`qcom-pon` 写 PM8998 的 PON scratch 寄存器，ABL 下一轮启动时读取。
**前提是 DTS 里 include 了 `pm8998.dtsi`**（见第 6 节主文档）。

### 6.2 刷完 rootfs 后要让 modem 重新请求

```sh
echo stop  > /sys/class/remoteproc/remoteproc0/state
echo start > /sys/class/remoteproc/remoteproc0/state
```

### 6.3 观察 rmtfs 收到了什么

```sh
journalctl -u rmtfs --no-pager -n 30
```

### 6.4 打开 ath10k 全部调试（已编译进内核）

```sh
echo 0xffffffff > /sys/module/ath10k_core/parameters/debug_mask
echo 18800000.wifi > /sys/bus/platform/drivers/ath10k_snoc/unbind
echo 18800000.wifi > /sys/bus/platform/drivers/ath10k_snoc/bind
dmesg | grep -i ath10k
```

正常应该能看到 `snoc probe`、`qmi msa.paddr: ...` 等。

### 6.5 串口操作的坑

- 提示符变成 `>` 表示有未闭合引号，发 `Ctrl-C` 两下回车复位
- PowerShell 里给串口发命令时，`$`、`"`、`;` 容易被吞，**必须写成脚本文件再执行**

---

## 七、相关路径

| 内容 | 位置 |
|---|---|
| 仓库 | <https://github.com/minghao680/equuleus-mainline> |
| 内核源码 | `/home/claude/sdm845-mainline`（WSL Debian） |
| rootfs 目录 | `/home/claude/rootfs-trixie-arm64` |
| rootfs 镜像 | `G:\equuleus-linux\rootfs.ext4`（4 GB ext4，UUID `b04fd122-…`） |
| 原厂固件 | `G:\equuleus-linux\stock-rom\equuleus_images_V12.5.2.0.QECCNXM_20211118.0000.00_10.0_cn\` |
| 下游内核源码 | `/home/claude/equuleus-src/kernel`、`/home/claude/halium-kernel` |
| 闭源 WLAN 模块 | `/home/claude/wlan-ko/qca_cld3_wlan.ko`（9.2 MB，未 strip） |
| rmtfs 分析产物 | `/home/claude/qcom-helpers/` |
