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

> ⚠️ **2026-11-22 复核纠正**：第二节的判断有误——`modem_fsg_oem_1/2` 的拒绝在本机原厂 Android 上也同样发生，**不是 WiFi 的断点**。真正的下一步是先确认 WLFW 服务有没有注册。详见文末「八、复核结论」。

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

---

## 八、复核结论（2026-11-22）：rmtfs 的 OEM 拒绝不是断点

复核者：另一路 agent。结论：**不要 patch rmtfs，先回答「WLFW 服务有没有注册」**。证据如下。

### 8.1 `modem_fsg_oem_1/2` 在原厂 Android 上同样被拒绝

从本机原厂 vendor 分区（`miui-adb-vendor.raw`）提取了真正的守护进程——名字叫 **`rmt_storage`**，不是 `rmtfs`（之前搜不到是因为名字搜错了）。它位于 `/vendor/bin/rmt_storage`，由 `etc/init/hw/init.qcom.rc:574` 启动。

对该二进制做 `strings` 后，它认识的路径**只有四条**：

```
/boot/modem_fs1   /boot/modem_fs2   /boot/modem_fsc   /boot/modem_fsg
（经 /dev/block/bootdevice/by-name/%s 解析）
```

**没有 `modem_fsg_oem_1`，没有 `modem_fsg_oem_2`。**

也就是说：在原厂 MIUI + 原厂 rmt_storage 上，modem 的这两个请求同样得不到服务。它们不是 WiFi 不工作的必要条件。

旁证：FSG 的含义是 *golden file system*（EFS 的金身备份分区）；`_oem_1/2` 是 OEM 变体备份。同 SoC（OnePlus 6 / SDM845）的 NixOS 移植记录里出现**一模一样**的两条拒绝日志，作者核实过社区结论 "modem_fsg_oem_1 is optional"，且该机器 WiFi 最终正常工作。

### 8.2 上游 rmtfs 的正确姿势（rmtfs.c / storage.c，linux-msm/rmtfs master）

- 分区表是编译期静态数组：`/boot/modem_fs1→partlabel modemst1`、`fs2→modemst2`、`fsc→fsc`、`fsg→fsg`，另有 OnePlus 的 `oem_stanvbk` 等。**上游也没有** `modem_fsg_oem_*`。
- 命令行：`-P` = 按 GPT partlabel 读真实分区（`/dev/disk/by-partlabel/`）；`-r` = 只读（整分区读入 shadow buffer，拒绝写）；**`-s` = 由 rmtfs 自己启动 modem**（`rproc_init()` + `rproc_start()`，Buildroot 对上游的提交注释也写明 "`-s` to let rmtfs start the modem"）。
- 因此注意一个潜在问题：**Debian 的 rmtfs.service 带 `-s`，它自己会 start modem，与现在的 `modem-start.service` 职责重叠**。二选一，别让两边都启动（建议由 rmtfs -s 独占启动，去掉 modem-start.service；rmtfs 先起好再拉 modem 的时序本来就是上游设计）。

### 8.3 真正的下一步：确认 WLFW 有没有注册

ath10k probe 后的静默只说明 `qmi_add_lookup(WLFW)` 的对端没出现。直接验证（不需要 debugfs，绕过 lockdown）：

```sh
apt install qrtr-tools
qrtr-lookup          # 看有没有 WLFW 服务（service id 69, "wlan firmware"）
```

- 内核 7.1 的 QRTR 名字服务器在**内核里**（`net/qrtr/ns.o` 编进 qrtr.o，`qrtr_ns_init()` 见 `af_qrtr.c:1299`），不需要用户态 qrtr-ns。
- 有 WLFW → 问题在 ath10k 握手/board 文件（见 4.2 的 board-2.bin 变体问题）；没有 → WLAN 子系统在 modem 侧没起来。

### 8.4 如果 WLFW 没注册，按序查

1. **确认 base EFS 请求真的成功了**（不是只有 rmtfs active）：给 rmtfs.service 临时加 `-v`（所有 open 都会打印，成功也打），重启 modem（6.2 的步骤），看 `/boot/modem_fs1|fs2|fsc|fsg` 是否都成功打开、没有 `failed to open`。注意：当前是 `-P` 分区模式，之前 2.4 在 `/boot` 下建的符号链接在 `-P` 下**根本不会被使用**——那步等于没做；分区模式直接读 `/dev/disk/by-partlabel/{modemst1,modemst2,fsc,fsg}`。
2. **复查"重启 modem 没有新请求"这条记录**：正常重启 modem 后 rmtfs 至少会重新收到 `_oem_` 拒绝。完全没有新日志说明重启没真正发生或观测方式有误，用 `journalctl -u rmtfs -f` + `dmesg | grep remoteproc` 同步盯。
3. 检查 `cat /sys/class/remoteproc/remoteproc0/state` 必须是 `running`。
4. pd-mapper 只服务 ADSP/CDSP 域，与 WLAN 无关；tqftpserv 同理，SDM845 的 WLAN 不需要它。

### 8.5 什么时候才需要 patch rmtfs

只有当 8.4 全部排除、且能证明 WLAN 固件因读不到 OEM 金身而拒绝启动时，才值得动 rmtfs。届时照上游表的格式加两行即可（`{ "/boot/modem_fsg_oem_1", "...", "fsg" }`），先备份 fsg/fsc 分区（`dd` 到电脑），`-r` 只读模式可保底。

### 8.6 本节的行动清单（给落地者）

| # | 动作 | 预期产出 |
|---|---|---|
| 1 | `apt install qrtr-tools && qrtr-lookup` | 回答"WLFW 是否注册"，一刀二分问题域 |
| 2 | rmtfs.service 加 `-v` 重启 + 重启 modem，收集完整 open 日志 | 确认 base EFS 四个分区全部打开成功 |
| 3 | rmtfs -s 与 modem-start.service 去重，只留一个启动方 | 消除双启动竞争 |
| 4 | 以上都正常却仍无 wlan0 → 才进入 board-2.bin / CE 通道排查 | 后续阶段 |

---

## 九、执行结果（2026-11-22 16:10）：WLFW 确实没注册

按第八节行动清单第 1 条执行，`qrtr-lookup` 给出了**决定性答案**。

### 9.1 modem 是全功能在线的

```
$ qrtr-lookup
  Service Version Instance Node  Port
       21       1        0    0    23 Modem embedded file system service
        3       1        0    0    45 Network Access Service
        1       1        0    0    49 Wireless Data Service
       26       1        0    0    51 Wireless data administrative service
       24       1        0    0    24 Thermal mitigation device service
        9       2        0    0    44 Voice service
       11       1        0    0    56 User Identity Module service
       18       1        0    0    69 IMS settings service
       ...（共 39 条）
```

modem 的整套 QMI 服务栈都在：数据业务、网络接入、EFS、语音、SIM、热管理、IMS……
**包括 `Service 21 = Modem embedded file system service`**——这从另一个角度证明第十四节那两条 OEM
拒绝确实无关紧要，EFS 通道本身是通的。

### 9.2 但 WLFW（Service 69）不在列表里

完整输出里**没有 Service ID 69 的条目**。注意别被 port 号混淆：列表第 5 列是 QRTR port，
`18 1 0 0 69 IMS settings service` 指的是「服务 18 在 port 69」，不是 WLFW。

WLFW 的服务 ID 是 **69**（`WLFW_SERVICE_ID_V01`），它没有注册。

### 9.3 这就把问题域一刀切开了

| 假设 | 判定 | 依据 |
|---|---|---|
| ath10k 侧有问题 | **排除** | ath10k `snoc probe` 完整成功，包括 `qmi_add_lookup` 注册 |
| modem 没启动 | **排除** | 39 个 QMI 服务在线，`remoteproc0` = running |
| rmtfs 拒绝 OEM 分区是关键 | **排除** | EFS 服务（Service 21）正常注册；且原厂同样拒绝（第八节） |
| **modem 没有把 WLAN 子系统带起来** | **成立** | Service 69 缺失，其余全在 |

**结论：卡点在 modem 固件侧，不是 Linux 侧。** 在 modem 注册 WLFW 服务之前，
ath10k 无论怎么调都不可能拿到 `wlan0`。

### 9.4 下一步该查什么

modem 的主固件（`modem.mbn` + 27 个分段）显然只启动了通信相关子系统，WLAN 部分没有随之启动。
可能的方向：

1. **`wlanmdsp.mbn` 是不是需要作为一个独立的 PD 被加载。**
   它和使用者一起躺在原厂 `modem` 分区的 `image/` 目录里，但我们只安装了 `modem.*` 全家桶，
   **没有把 `wlanmdsp.mbn` 放到 `/lib/firmware/qcom/sdm845/mi8/`**。
   这是当前最可疑的一点——值得先补上再试一次。

2. **`modemr.jsn` / `modemuw.jsn` 里是否声明了 `wlan` 保护域。**
   `pd-mapper` 读取 `/lib/firmware/` 下的 `.jsn`（已从二进制字符串确认它只认这个目录和 `.jsn` 后缀），
   如果 json 里没有 WLAN 域，PDR 机制不会去拉起它。可以直接 `cat` 出来看。

3. **`qcom,mss` 相关设备树是否缺 WLAN 的 smem/glink 通道。**
   主线 `sdm845.dtsi` 里 `&wifi` 只有 SNOC 部分，modem 侧的 glink edge 可能在 `mss_pil` 节点下。

4. 三个都不要先改 rmtfs（第八节已论证）。

### 9.5 已就位的诊断工具

- `qrtr-lookup`、`qrtr-ns`、`qrtr-cfg` 已装进 rootfs（`qrtr-tools`，依赖 `libqrtr1`）
- `rmtfs` 已加 `-v`（通过 `/etc/systemd/system/rmtfs.service.d/verbose.conf` 覆盖，
  `-r` 只读不变），日志用 `journalctl -u rmtfs`
- `pd-mapper` 运行中但**没有任何输出**，需要的话可以前台跑 `pd-mapper -v`

### 9.6 去重待办

`rmtfs -r -P -s` 里的 `-s` 表示 rmtfs 自己负责拉起 modem，与手写的
`modem-start.service` 职责重叠。当前两者都在，因为 `start-modem.sh` 幂等（检测到
`state == running` 就跳过），没有实际观察到竞争；但按第八节建议应当只留一个启动方。
**建议保留 `rmtfs -s`**（顺序更正确：rmtfs 就绪后才拉起 modem），删掉 `modem-start.service`。

---

## 十、追到底了（2026-11-22 16:20）：缺的是内核侧的 `wlan_pd` 加载器

第九节的怀疑已经验证并排除，同时找到了**真正的机制**。

### 10.1 `modemuw.jsn` 声明了一个独立的 WLAN 保护域

```json
"sr_domain": {
    "domain": "modem",
    "subdomain": "wlan_pd"          ← 独立的保护域，不是 modem 主域的一部分
},
"sr_service": [
    { "provider": "kernel", "service": "elf_loader" },   ← 要求内核加载固件
    { "provider": "tms",    "service": "servreg" },
    { "provider": "wlan",   "service": "fw" }
]
```

关键在第一条：**`wlan_pd` 需要「内核提供 ELF 加载器」服务**。PDR（保护域重启）框架里，
modem 会向 AP 请求启动 `wlan_pd`，AP 侧必须有人响应该请求并把 WLAN 固件载入。

`qrtr-lookup` 里能看到 PDR 框架本身是活的：

```
64  1  1  1  16388  Service registry locator service
64  1  1  1  16389  Service registry locator service
```

但**没有任何东西为 `wlan_pd` 提供 elf_loader**，所以这个域永远不会被拉起，
`Service 69 (WLFW)` 也就永远不注册。

### 10.2 已排除：`wlanmdsp.mbn` 缺失不是原因

我一度怀疑是固件文件没装。已验证：

- 已从原厂 `modem` 分区安装 `wlanmdsp.mbn`（3.6 MB）和 `bdwlan.bin`（26 KB）
  到 `/lib/firmware/qcom/sdm845/mi8/`
- 重新刷机后 `qrtr-lookup` **仍然没有 Service 69**

所以文件在不在不是关键，**缺的是「谁去加载它」这个角色**。

### 10.3 这解释了我最初那个结论为什么「方向错但事实对」

最初的判断是「没有任何代码加载 WCN3990 固件 → 需要自己写加载器」。
上一轮复核纠正为「固件跑在 modem 上，modem 启动就行」。现在两者统一了：

- **事实确实是没有代码加载它**（我最初对了）
- **但它不该由 ath10k 加载**，而应该由一个响应 `wlan_pd` 的 PDR elf_loader 加载（复核对了）
- modem 起来了、其余 39 个 QMI 服务全在线，**唯独 `wlan_pd` 没人拉起来**

### 10.4 下一步：实现 `wlan_pd` 的 elf_loader

参考实现：`drivers/remoteproc/qcom_q6v5_pas.c` 里对 adsp/cdsp 的 PAS 加载 +
PDR 服务注册。对 WLAN 需要：

1. 一个平台设备（对应 `&wifi` 或新建节点），注册 PDR 服务
   `{ domain: "modem", subdomain: "wlan_pd" }`
2. 收到 PDR 请求时：`request_firmware(".../wlanmdsp.mbn")` →
   `qcom_mdt_load()` / `qcom_scm_pas_auth_and_reset()` → 回报 PDR 状态
3. WLAN 的 PAS ID 需要确认（这次是真的需要它了，之前讨论 PAS ID 是为 ath10k 服务，方向不对）

**或者**：查一下主线有没有现成的 WLAN PDR 支持（`qcom,pas` 的 `wlan` 变体），
`drivers/remoteproc/` 里搜 `wlan_pd` / `WLFW` / PDR 相关。

### 10.5 已是当前最佳状态

不管怎样，现在相比几小时前已经是**完全不同的位置**：

| 项目 | 之前 | 现在 |
|---|---|---|
| modem | 从未启动 | running，39 个 QMI 服务在线，零崩溃 |
| ath10k | 静默，不知道卡在哪 | probe 完整成功，确认在等 WLFW |
| 问题定位 | 「WiFi 不工作」 | 「`wlan_pd` 没有 elf_loader」 |
| 诊断工具 | 无 | `qrtr-lookup` / rmtfs `-v` / ath10k debugfs 全部就位 |
