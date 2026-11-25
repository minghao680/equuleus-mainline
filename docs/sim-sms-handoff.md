# SIM / SMS 交接文档：modem 不扫描 SIM 卡

范围：单一问题。目标是在小米 8 Pro（`equuleus`）的主线 Linux 上让 SIM 被识别，进而实现短信
收发（以及后续的移动数据与通话）。CPU、Wi-Fi、蓝牙、显示、音频不在范围内。

状态：**卡住**。用户侧硬件与插法已排除，AP 侧（内核/设备树/EFS/稳压器/服务）全部正常，
但 modem 从不扫描 SIM 接口。**本地已无法进一步区分「卡座硬件故障」与「主线下的 modem UIM
未初始化」**，需要社区信息或另一台可对照的设备。

> **2026-11-25 复核：先读第 12-14 节。** `no-atr-received` 是“卡片上电后没有返回 ATR”的
> **卡错误码**，不是“UIM 从未扫描”。物理存在要查 `--uim-get-slot-status`（第 12 节）。
> 槽 2 已能读 ICCID，当前卡在 USIM 应用未激活/无 GW 主会话；`qmicli` 已有
> `--uim-switch-slot` 和 `--uim-change-provisioning-session`，不需要写代码（第 14 节）。

---

## 1. 设备与当前系统状态

| 项 | 值 |
|---|---|
| 设备 | Xiaomi Mi 8 Pro（`equuleus`，SDM845，8 GB，**屏幕已损坏**） |
| 内核 | `7.1.0-rc1-sdm845`（本地构建 `#31`，含 IPA 启用） |
| 根文件系统 | Debian 13 arm64 + systemd，位于 `userdata`（`/dev/sda21`，112 GB，已自动扩容） |
| 访问方式 | USB CDC-ACM 串口（`/dev/ttyGS0`，115200，root 自动登录）+ Wi-Fi SSH（常掉线需重试） |
| boot 分区 | 由系统内 `dd` 写入，回读 sha256 与镜像一致；备份在同目录 `boot-backup-before-ipa.img.gz` |
| 已装相关包 | `libqmi-utils` `qrtr-tools` `modemmanager`（含 `polkitd`） |

## 2. 已经确认可用的部分（都有实测证据）

### 2.1 modem 与 QMI 传输完全正常

`qrtr-lookup` 列出 **56 个服务**，与短信/通话相关的都在：

| QMI 服务 | 编号 | 端口 |
|---|---|---|
| **Wireless Messaging Service (WMS)** | **5** | **65** |
| User Identity Module (UIM) | 11 | 60 |
| Network Access Service (NAS) | 3 | 48 |
| Voice service | 9 | 47 |
| IMS settings / IMS application | 18 / 33 | 80 / 79 |

QMI 客户端可正常访问：

```
$ qmicli -d qrtr://0 --dms-get-manufacturer
  Manufacturer: 'QUALCOMM INCORPORATED'
$ qmicli -d qrtr://0 --dms-get-revision
  Revision: 'AT4.0.c2.6-00335-0220_1946_40a1464  1  [Jan 27 2020 10:00:00]'
```

### 2.2 IPA / rmnet 已启用（ModemManager 能创建 modem 的前提）

```
ipa 1e40000.ipa: IPA driver initialized
ipa 1e40000.ipa: IPA driver setup completed successfully
ipa 1e40000.ipa: received modem starting event
ipa 1e40000.ipa: received modem running event

$ ip -br link | grep rmnet
rmnet_ipa0       DOWN     <>
```

### 2.3 ModemManager 已识别 modem

```
$ mmcli -L
    /org/freedesktop/ModemManager1/Modem/0 [QUALCOMM INCORPORATED] 0

$ mmcli -m 0
  Hardware | manufacturer: QUALCOMM INCORPORATED
           |    drivers: rpmsg_ctrl, ipa, qrtr
  Status   |    state: failed
           |    failed reason: sim-missing
  SIM      |    sim slot paths: slot 1: none
```

## 3. 问题：SIM 从未被扫描

### 3.1 决定性对照实验

一张**正在使用、确认正常**的中国移动 nano-SIM，插入槽 1 与槽 2 分别测试；再用**空托盘**做对照：

| 托盘状态 | `qmicli -d qrtr://0 --uim-get-card-status` |
|---|---|
| **空托盘（无卡）** | `Slot [1]/[2]: error: no-atr-received (3)` |
| 正常 SIM 在槽 1 | 同上 |
| 正常 SIM 在槽 2 | 同上 |

**三种情况完全相同** → 这个返回值不反映「有没有卡」，而是 modem 根本没有去扫描 SIM 接口。
因此**卡片、触点、插槽方向、槽位选择全部可以排除**。

### 3.2 已排除的软件动作

| 动作 | 结果 |
|---|---|
| `--uim-sim-power-off=1` + `--uim-sim-power-on=1` | 命令成功，状态不变 |
| 对槽 2 做同样的断电/上电 | 命令成功，状态不变 |
| **整机重启**（modem 从零初始化 UIM） | 状态不变 |
| `mmcli -m 0` | `failed reason: sim-missing`，`sim slot paths: slot 1: none` |
| `--nas-get-serving-system` | `not-registered-searching`，`selected network: unknown` |

## 4. 已经查清并排除的 AP 侧因素

### 4.1 EFS 分区正常

```
fsg       14 00 00 00 03 00 00 00 d8 01 00 00 ...   （结构化头部，非全零）
fsc       00 00 00 00 ...                            （全零，正常）
modemst1  10 00 00 00 03 00 00 00 d8 01 00 00 ...
modemst2  11 00 00 00 03 00 00 00 d8 01 00 00 ...
```

分区都存在：`fsg`=`/dev/sde36`、`modemst1`=`/dev/sdf6`、`modemst2`=`/dev/sdf7`（各 8 MB）。

### 4.2 rmtfs 的 `modem_fsg_oem_1/2` 拒绝**不是**根因

启动日志里有：

```
[RMTFS storage] request for unknown partition '/boot/modem_fsg_oem_1', rejecting
[RMTFS storage] request for unknown partition '/boot/modem_fsg_oem_2', rejecting
```

追查结果：

| 检查 | 结果 |
|---|---|
| 名字从哪来 | 在 **`modem.b16`（modem 固件本体）** 里：`/boot/modem_fsg`、`/boot/modem_fsc`、`/boot/modem_fsg_oem_1`、`/boot/modem_fsg_oem_2`，对应 `OEM_1`/`OEM_2` |
| Android 怎么映射 | `vendor/bin/rmt_storage` 只认 **`modem_fs1`/`modem_fs2`/`modem_fsc`/`modem_fsg`** → `by-name/{fs1,fs2,fsc,fsg}`；**完全不认识 `modem_fsg_oem_1/2`** |
| 设备分区表 | 无 `modem_fsg_oem_*`（只有 `fsg`/`fsc`/`modemst1/2`） |
| `/persist` | 无 fsg/oem 文件 |

**关键推理**：原厂 Android 上 SIM 可用，而 Android 自己的 `rmt_storage` 也不认识这两个名字
→ 这两个请求是非致命的兼容性回退，**不是 SIM 不识别的根因**。

### 4.3 稳压器配置与下游一致

| 稳压器 | 下游（原厂 DTB） | 主线 |
|---|---|---|
| `pm8998_l2` | 1.2 V，`always-on` | 1.2 V，`always-on` ✅ |
| `pm8998_lvs2` | 1.8 V，非 always-on | 1.8 V，非 always-on ✅ |
| always-on 集合 | `fp_vdd_vreg`、`pm8998_l2` | 一致（多一个 `s4a_1p8` 供 WiFi/BT） |

### 4.4 不存在 SIM 检测 GPIO

- `/sys/kernel/debug/gpio`（190 行）里没有名字含 `sim`/`uim`/`card` 的线
- 下游 DTB 反编译结果里也没有 `sim`/`uim` 命名的 pinctrl 节点

即：SIM 插拔检测**在 modem 内部**，AP 侧无从观察。

### 4.5 其他 SDM845 板也没做任何 AP 侧 SIM 配置

`OnePlus 6`（enchilada/oneplus-common）、`Poco F1`（beryllium）的主线 DTS 里都没有
SIM/UIM 相关配置，而 OnePlus 6 在 postmarketOS 上实测 SIM 可用（见第 6 节）。说明 SIM 本应
完全由 modem 固件驱动。

## 5. 剩余假设（按可能性排序）

1. **modem 的 UIM 在这条主线链路下没有真正上电/初始化**。可能原因：SIM 供电由 modem 通过
   SPMI 控制，而主线 `spmi-pmic-arb` 重新配置 arbiter 时可能影响 modem master 的通道权限。
   验证方向：对比 OnePlus 6 的 `spmi` 配置与 `dmesg`，或抓 modem 侧日志。
2. **本机 SIM 卡座硬件故障**。该机屏幕已损坏，可能经历过拆修；卡座是唯一无法从 AP 侧读到的环节。
3. **modem 固件对该机型变体的 UIM 有额外要求**（例如 OEM FSG 存储），但 4.2 已证明 Android
   自己也不需要它，可能性较低。
4. **该机型在主线上的 SIM 从未被验证过**（pmaports 里 `device-xiaomi-equuleus` 仍在
   `device/testing`，wiki 未记录 SIM 状态）。

## 6. 社区先例

同代 SDM845 的 OnePlus 6 在 postmarketOS（主线内核 + ModemManager）上的实际记录：

> "I bought a SIM ... put it in, and restarted the phone. It detected the SIM card automatically on
> reboot. **SMS arrived immediately.** ... I enabled mobile data ... and it Just Worked. I can make
> a phone call, and I can receive a phone call ... However, the stack is not particular stable:
> sometimes I can make and receive calls, and sometimes I cannot."
>
> — <https://neilzone.co.uk/2025/10/notes-on-running-postmarketos-on-a-oneplus-6/>

结论：在同类硬件上，SIM/短信/数据/通话**都是可行的**，完全走标准 ModemManager + QMI 路径，
不需要私有驱动。equuleus 上失败是机型相关问题，不是方案错误。

## 7. 为什么本地无法一锤定音

要判断「卡座坏」还是「主线 modem UIM 没起来」，最直接的办法是刷回原厂 Android 看它是否识别 SIM。
但：

1. 原厂 Android 会重新初始化 `userdata`，而当前 `userdata` **就是 Debian 的根文件系统**
   （用户已在里面部署了大量内容）；
2. MIUI 的 adb 调试需要**在屏幕上点授权**，本机屏幕已损坏，无法完成。

因此**不要**在没有备份的前提下刷原厂 Android。若要这么做，必须先：
- 把 Debian 根文件系统打包备份（约 4 GB 数据 → 压缩后约 2 GB）到外部存储；
- 准备好恢复脚本（恢复 boot 备份 + 解包 rootfs）。

## 8. 给下一个 agent 的具体实验（按安全/成本排序）

1. **问社区（零成本，最高优先）**：SoMainline / postmarketOS 的 equuleus 维护者
   （历史上是 AlexanderGP / DeltaSporos）是否在主线 kernel 上验证过 SIM；pmaports 的
   `device/testing/device-xiaomi-equuleus` 是谁在维护。一句话就能定性是"没验证过"还是"能用"。
2. **在同一台机器上对照 OnePlus 6 的请求序列**：抓 `journalctl -u rmtfs` 的完整请求列表，
   与 OnePlus 6 的对比，看 equuleus 是否少了某个关键请求（除已知的 `_oem_1/2` 外）。
3. **检查 SPMI arbiter 对 modem master 的通道权限**：读 `spmi-pmic-arb` 驱动的寄存器配置，
   与下游行为对比；注意这是内核改动，需要重新编译并刷 boot（可从系统内 dd，见第 9 节）。
4. **确认 modem 是否真的尝试过 UIM**：在 modem 固件/`diag` 侧不可读的前提下，可尝试
   `qmicli --uim-get-supported-messages`（若返回"卡不存在"而不是"服务不支持"，说明 UIM 客户端
   已建立但没有卡）。

**不要**在没有依据的情况下把 `modem_fsg_oem_1/2` 映射到 `fsg`/`modemst1`：rmtfs 会读写 EFS，
写错会损坏 modem 的 NV。

## 9. 一旦 SIM 被识别，短信实测路径（已准备好）

```sh
# 1) 卡状态与注册
qmicli -d qrtr://0 --uim-get-card-status         # 期望 'present'
qmicli -d qrtr://0 --nas-get-serving-system      # 期望 'registered'
mmcli -m 0                                       # 期望 SIM 段出现 ICCID/IMSI

# 2) 收短信（另一台手机发一条）
mmcli -m 0 --messaging-list-sms
mmcli -s 0                                       # 读内容/发件号码
mmcli -s 0 --create-file-with-data=/root/sms0.txt

# 3) 发短信
mmcli -m 0 --messaging-create-sms="text='test from equuleus',number='+8613xxxxxxxxx'"
mmcli -s 1 --send

# 4) 存储：默认在 MM 内存（重启即失）
mmcli -m 0 --set-default-storage=me              # 或 sm（SIM 容量 20-30 条）
```

补充：`qmicli` **不能**收发短信（libqmi 1.36 的 WMS 命令只有 get-supported/get-routes/
set-routes/reset/noop），必须走 ModemManager。详细计划见 `docs/plans-sms.md`。

## 10. 相关文件与命令

| 路径 | 作用 |
|---|---|
| `dts/sdm845-xiaomi-equuleus.dts` | 板级 DTS；`&ipa` 已启用（`gsi-loader = "self"`），SIM 相关无任何配置 |
| `scripts/prepare-firmware.sh` | 从原厂 ROM 提取固件（含 `ipa_fws.*`） |
| `scripts/build-initramfs.sh` | 把 IPA 固件放进 initramfs |
| `scripts/install-firmware-daemons.sh` | 安装 `libqmi-utils`/`qrtr-tools`/`modemmanager` |
| `systemd/ModemManager-10-equuleus.conf` | 让 ModemManager 排在 `qrtr-ns` 之后启动 |
| `docs/plans-sms.md` | 短信功能计划（含本次阻塞的完整记录） |
| `docs/STATUS.md` | 全机状态，modem 章节记录了 IPA 的实测结果 |

常用只读检查：

```sh
qrtr-lookup                                     # 服务表（确认 WMS=5 在不在）
qmicli -d qrtr://0 --uim-get-card-status
qmicli -d qrtr://0 --nas-get-serving-system
mmcli -m 0
journalctl -u rmtfs --no-pager | tail -20
systemctl status ModemManager qrtr-ns --no-pager
```

## 11. 验收标准（修好的定义）

| 项目 | 通过标准 |
|---|---|
| SIM 识别 | 空托盘显示 `absent`，插卡显示 `present`（当前两者相同，这是最关键的判据） |
| 注册 | `--nas-get-serving-system` → `registered` |
| 短信收 | 对端发送后能 `--messaging-list-sms` 列出且正文正确（含中文 UCS2） |
| 短信发 | `--messaging-create-sms` + `--send` 后对端收到 |
| 稳定性 | 连续收发各 10 条无失败 |

**当前状态：第 1 项即失败**，后续全部无法开始。

---

## 12. 复核（2026-11-25）：先查物理槽状态，再谈硬件或内核

复核者：另一路 agent，只做源码/社区信息复核，未改设备。

### 12.1 `no-atr-received` 的语义被误读了

libqmi 1.36 源码中，`no-atr-received` 属于 **Card error**，不是服务未运行、也不是插槽未扫描：

```c
/* src/libqmi-glib/qmi-enums-uim.h:250-274 */
QmiUimCardError:
    POWER_DOWN       = 1
    POLL             = 2
    NO_ATR_RECEIVED  = 3
    VOLTAGE_MISMATCH = 4
    ...
```

`--uim-get-card-status` 报告的是“卡片激活过程出了什么错”。空托盘、接触不良、SIM 供电
异常、卡座数据线损坏都会得到同一个 `NO_ATR_RECEIVED`。因此第 3.1 节“三种情况相同 →
modem 根本没有扫描”的推理不成立；更准确的描述是：

> UIM 服务可用，modem 对槽上电并等待 ATR，但卡片（或卡座路径）没有应答。

这也意味着“用户侧硬件与插法已排除”过强：排除了卡片本身和明显的插反，但**没有排除卡座
/触点/供电路径硬件故障**。

### 12.2 未使用的关键命令：`--uim-get-slot-status`

libqmi/qmicli 1.36 有独立的物理槽状态接口，与 `--uim-get-card-status` 不同：

```c
/* qmi-enums-uim.h:485-512 */
QmiUimPhysicalCardState: UNKNOWN / ABSENT / PRESENT
QmiUimSlotState:         INACTIVE / ACTIVE
```

`qmicli-uim.c:1180-1194` 的输出逻辑是：

```text
Physical slot N:
   Card status: absent | present | unknown
   Slot status: inactive | active
   Logical slot: ...
   ICCID: ...    (只有 present 才打印)
```

设备上已安装的 qmicli 确认支持以下命令（`qmicli --help-uim`）：

```sh
qmicli -d qrtr://0 --uim-get-supported-messages
qmicli -d qrtr://0 --uim-get-slot-status
qmicli -d qrtr://0 --uim-monitor-slot-status
qmicli -d qrtr://0 --uim-switch-slot=1
qmicli -d qrtr://0 --uim-get-configuration
qmicli -d qrtr://0 --uim-reset
```

#### 最小实验（零风险）

分别在空托盘、卡在槽 1、卡在槽 2 时执行：

```sh
qmicli -d qrtr://0 --uim-get-slot-status
```

再开一个监视进程，然后插拔卡片：

```sh
timeout 60 qmicli -d qrtr://0 --uim-monitor-slot-status
```

判读表：

| `Card status` / 事件 | 结论 |
|---|---|
| 插卡 `present`，空托盘 `absent`，插拔有事件 | UIM 检测和供电正常，问题在 ATR/数据线或卡通信，硬件故障概率高 |
| 插卡仍 `absent`，无插拔事件 | modem 看不到物理卡，强烈指向卡座/检测路径硬件，或该固件不支持物理槽状态上报 |
| 插卡和空托盘都是 `unknown`，命令失败 | 先看 `--uim-get-supported-messages` 是否支持 GET_SLOT_STATUS；不支持时该判据失效，再考虑 DIAG |
| `present` 但 `--uim-get-card-status` 仍 `NO_ATR_RECEIVED` | 供电/接触/IO 问题，不是“未扫描” |

如果 `Slot status` 显示 inactive，可以再试一次 `--uim-switch-slot=1` 后重新查询；但不要
在没有先看 slot status 的情况下盲切。

### 12.3 社区状态已核实

- pmaports 当前 `device/testing/device-xiaomi-equuleus/APKBUILD`：
  `maintainer="Sporos <alexandergp@pm.me>"`，`pkgver=4`，依赖
  `linux-postmarketos-qcom-sdm845`、`postmarketos-base`、`soc-qcom`。
- 该目录的提交历史（GitLab API，共 12 条）：2021-07 初始包由 Sporos 加入；之后的提交全部
  是 deviceinfo 元数据、维护者字段、依赖和重建，**没有 SIM/modem/UIM 相关功能提交**。
- postmarketOS wiki 的 Mi 8/Mi 8 Pro/Mi 8 Explorer 页面中：
  `status_calls`、`status_sms`、`status_mobiledata` 均为空（未验证），页面还标注设备
  “当前只在过时的 pmaports/linux 5.12.8 上工作，等待 sdm845-mainline MR 102 移植到 6.11”。

所以第 8.1 节的问题已经有了答案：**没有公开证据表明 equuleus 的 SIM 在主线内核上被验证过。**
OnePlus 6 的成功先例只能证明同 SoC/标准 QMI 路径可行，不能证明 equuleus 的卡座或固件
配置没问题。

### 12.4 修正后的假设排序

1. **卡座/触点/供电路径硬件故障**（升到第一）：`NO_ATR_RECEIVED` 的直接含义就是卡片
   无应答，而这台机器有物理损坏和拆修风险。
2. **UIM 供电或物理槽状态配置问题**：只有 `--uim-get-slot-status` 显示 `present` 但无
   ATR 时才值得继续查。
3. **该机型固件变体问题**：如果 slot status 命令本身不被支持，再考虑 DIAG/固件侧。
4. **SPMI arbiter 权限**：目前没有任何直接证据，降到最后；不要先改内核。

### 12.5 给落地者的顺序

1. `--uim-get-supported-messages`（确认 GET_SLOT_STATUS 是否支持）
2. 三种托盘状态下 `--uim-get-slot-status`
3. 插拔时 `--uim-monitor-slot-status`
4. 根据判读表分支：
   - `present + NO_ATR` → 查触点/供电/换卡座，AP 侧 DTS 大概率无关
   - `absent` → 硬件故障结论基本成立
   - 命令不支持 → 用 DIAG 或社区对照
5. 只有上述结果指向软件时，才回到 SPMI/rmtfs/固件假设。仍然不要把
   `modem_fsg_oem_1/2` 盲目映射到真实 EFS 分区。

---

## 13. 2026-11-25 下午的关键进展：卡在槽 2 被识别，但 USIM 应用未激活

### 13.1 之前的判据是错的

第 3 节用 `--uim-get-card-status` 做“插没插卡”的判据是错的：该命令在**空托盘**时也返回
`error: no-atr-received (3)`。正确的物理存在判据是 **`--uim-get-slot-status`**，它给出
`Card status: absent | present`。用错 API 导致“modem 从不扫描”的错误结论。

### 13.2 槽 1 坏、槽 2 好

| 卡的位置 | `--uim-get-slot-status` |
|---|---|
| 槽 1 | `Card status: absent`（即使卡在槽 1） |
| 槽 2 | **`Card status: present`，能读出 ICCID `89860000192397706169`** |

监视器（`--uim-monitor-slot-status`）也捕获到了槽 2 的 `absent → present` 事件。

**结论：检测链路、ATR、ICCID 读取全部正常；出问题的是槽 1 的检测（硬件嫌疑最大），
槽 2 完全可用。** 之前所有失败测试都是卡插在槽 1。

### 13.3 新的真正瓶颈：USIM 应用停在 `detected`

卡插在槽 2 时的完整 `--uim-get-card-status`：

```
Provisioning applications:
	Primary GW:   session doesn't exist
	Primary 1X:   session doesn't exist
	Secondary GW: session doesn't exist
	Secondary 1X: session doesn't exist
Slot [1]:
	Card state: 'error: no-atr-received (3)'
Slot [2]:
	Card state: 'present'
	Application [1]:
		Application type:  'usim (2)'
		Application state: 'detected'      <-- 不是 ready
		Personalization state: 'unknown'
		PIN1 state: 'not-initialized'   retries: '0'
```

QMI 里应用状态是 `detected → pin1-verified → ready`。停在 **`detected`** 意味着
**USIM 应用没有激活**，因此没有 provisioning session，modem 拿不到 IMSI，无法附着。

ModemManager 的报错正好对应这一点：

```
[modem0] modem couldn't be initialized:
  Couldn't check unlock status: QMI operation failed: GW primary session index unknown
[device qcom-soc] error initializing: Modem in failed state: sim-missing
```

MM 需要“GW 主会话索引”才能检查 PIN 锁；没有会话 → 初始化失败 → `sim-missing`。

### 13.4 已尝试但无效的动作

| 动作 | 结果 |
|---|---|
| 把主槽切到 2（`mmcli --set-primary-sim-slot=2`） | 命令返回成功，**射频起来过**（`Selected network: '3gpp'`，**LTE −53 dBm**），但 `Primary GW: session doesn't exist` 依旧 |
| `--uim-reset` | 成功，会话仍不存在 |
| 对槽 2 `--uim-sim-power-off/on` | 成功，会话仍不存在 |
| 整机重启（带着槽 2 的卡冷启动） | 槽 2 仍 `present`，会话仍不存在 |
| **`echo stop > /sys/class/remoteproc/remoteproc0/state`** | **危险：整机卡死/复位**，串口打不开、Wi‑Fi 不通，最后需长按电源强制重启。**不要再用这条路径。** |

另外每次冷启动后 `--dms-get-operating-mode` 都显示 **`shutting-down`**，需要用
`--dms-set-operating-mode=online` 才能打开射频；这本身也是个待查点（谁在把 modem 关掉？

### 13.5 当前的核心矛盾

```
槽 1 无卡（硬件检测坏）  →  modem 的主 provisioning 槽（slot 1）没有卡
槽 2 有卡且能读 ICCID    →  但只是「副槽」，modem 不把它当作 GW 主会话
```

也就是说：**要么让槽 1 重新能认卡（硬件），要么把槽 2 变成 modem 的主槽**。后者需要
QMI UIM 的 “Switch Slot” 在 modem 侧真正生效，而 MM 的 `--set-primary-sim-slot` 虽然返回
成功，却没有建立主会话——很可能因为 MM 处于 `failed` 状态，它没法在 modem 侧完成后续初始化。

### 13.6 下一步实验（按顺序，全部安全）

1. **让槽 2 成为主槽后再冷启动**：先 `--dms-set-operating-mode=online`，再
   `mmcli -m N --set-primary-sim-slot=2`，确认 `--uim-get-card-status` 里
   `Primary GW` 是否变成有会话；若仍是 `session doesn't exist`，说明 MM 的切换在 failed
   状态下无效。
2. **绕开 MM 直接验证会话**：用 libqmi 的库接口（不是 CLI）发 QMI UIM “Switch Slot”，
   或在 `qmicli` 里找等价命令（1.36 的 CLI 里没有，需要写小程序或等上游加）。
3. **检查槽 1 的物理状态**：换上另一张 SIM、或在槽 1 用薄垫片测试；若槽 1 永远 `absent`，
   就确认硬件故障，只能走“槽 2 做主槽”的软件路线。
4. **问社区/对面**：MM 1.24 的 qcom-soc 插件在“卡在副槽、主槽无卡”时是否有已知处理方式；
   `--set-primary-sim-slot` 需要 modem 处于什么状态才生效。

### 13.7 修订后的判据（给下一个 agent）

| 命令 | 看什么 | 含义 |
|---|---|---|
| `--uim-get-slot-status` | `Card status: absent/present` | **物理存在**的唯一可靠判据 |
| `--uim-get-card-status` | `Application state` | `detected` = 卡被找到但应用未激活；`ready` = 可用 |
| `--uim-get-card-status` | `Provisioning → Primary GW` | `session doesn't exist` = modem 没有可用的主会话 |
| `--dms-get-operating-mode` | `online` / `shutting-down` | `shutting-down` 时射频不起，需先设 online |
| `--nas-get-serving-system` | `Registration state` | `registered` 才算真正入网 |

---

## 14. 复核（2026-11-25 15:20）：用 qmicli 现有的 switch/activate，不用写代码

复核者：另一路 agent。第 13 节定位正确，但其中有一个会把人带偏的结论，下面直接改掉。

### 14.1 第 13.6 节第 2 条「CLI 里没有等价命令」是错的

qmicli 1.36 **有**这两个命令，设备上 `qmicli --help-uim` 已经列出：

```text
--uim-switch-slot=[(slot number)]     Switch active physical slot
--uim-change-provisioning-session=["key=value,..."]
                                      (session-type=..., activate=(yes|no), slot, aid)
```

- `UIM Switch Slot`（消息 0x0046）把**当前 active 的 logical slot 映射到指定 physical slot**
  （`data/qmi-service-uim.json` 0x0046：input = logical slot + physical slot）。
- qmicli 的实现会先查 `get-slot-status` 找 active logical slot，再发 Switch Slot
  （`qmicli-uim.c` 的 `get_active_logical_slot_ready` + `switch_slot_input_create`，
  约 1306-1392 行）。所以 `--uim-switch-slot=2` 正是“让槽 2 当主槽”的直接操作，**不需要
  写 libqmi 小程序**。

### 14.2 第二个未被使用的命令：显式激活 GW 主会话

`UIM Change Provisioning Session`（消息 0x0038）可以显式激活 USIM 应用会话。在
switch-slot 后如果 `Primary GW` 仍是 `session doesn't exist`，再补这一步：

```sh
qmicli -d qrtr://0 --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=2"
```

`aid` 可省略；USIM 已在 `get-card-status` 里被识别为 app [1]，不需要手工给 AID。

### 14.3 建议的顺序（全部零风险，不要冷重启/不要 stop remoteproc）

```sh
# 0) 先确认物理槽与 active logical slot
qmicli -d qrtr://0 --uim-get-slot-status

# 1) 让射频在线（13.4 观察到每次冷启动都是 shutting-down）
qmicli -d qrtr://0 --dms-set-operating-mode=online

# 2) 把 active logical slot 映射到物理槽 2
qmicli -d qrtr://0 --uim-switch-slot=2
sleep 3

# 3) 看 Primary GW 与 USIM application state
qmicli -d qrtr://0 --uim-get-card-status

# 4) 若 Primary GW 仍不存在，显式激活
qmicli -d qrtr://0 --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=2"
sleep 3
qmicli -d qrtr://0 --uim-get-card-status

# 5) 让 MM 丢掉 failed 状态重新探测（MM 会缓存 sim-missing）
systemctl restart ModemManager
mmcli -m 0

# 6) 注册检查
qmicli -d qrtr://0 --nas-get-serving-system
```

判据：`--uim-get-card-status` 里 `Primary GW` 出现 `slot '2', application '1'`，
`Application state` 变成 `ready`，`--nas-get-serving-system` → `registered`，
`mmcli -m 0` 的 `failed reason: sim-missing` 消失。

### 14.4 两个要记住的点

- 第 13.6 第 1 条的 `mmcli --set-primary-sim-slot` 本质是走 MM 的 QMI 路径并触发整机
  re-probe；MM 处于 `failed` 时它可能没有完成 UIM switch。**先用 qmicli 直接做，再重启 MM**
  比反复试 mmcli 更可控。
- 除非 `--uim-switch-slot` 报「no active logical slot」，否则先不要把它归因为硬件或写代码；
  那才需要看 `get-slot-status` 里有没有任何 slot 是 active、以及是否要用
  change-provisioning-session 先激活一个 session。

---

## 15. 已解决（2026-11-25 15:49）：短信收发全通

**问题不是硬件、不是驱动、不是内核**，而是 **UIM 会话从未被显式激活**，加上 **槽 1 检测坏、
卡在槽 2**。解决的完整配方如下，全部是 `qmicli` 现成命令，**不需要写代码**。

### 15.1 关键发现：`change-provisioning-session` 必须带 AID

不带 `aid=` 时 qmicli 会先给卡断电，modem 返回 `QMI protocol error (3): 'Internal'`，命令失败。
带上从 `get-card-status` 读到的 AID 后**直接成功**：

```sh
AID=$(qmicli -d qrtr://0 --uim-get-card-status \
       | grep -A2 'Application ID' \
       | grep -oE '([0-9A-F]{2}:){15}[0-9A-F]{2}' | head -1)

qmicli -d qrtr://0 --uim-change-provisioning-session=\
  "session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$AID"
# -> Successfully changed provisioning session
#    Primary GW: slot '1', application '1'
#    Application state: 'ready'          <-- 从 detected 变成 ready
```

### 15.2 完整可用序列（本机实测）

```sh
# 1) 卡在物理槽 2（槽 1 检测坏）
qmicli -d qrtr://0 --uim-get-slot-status          # 确认哪个物理槽 present

# 2) 冷启动后 modem 是 shutting-down，先打开射频
qmicli -d qrtr://0 --dms-set-operating-mode=online

# 3) 把物理槽 2 映射成逻辑主槽 1
qmicli -d qrtr://0 --uim-switch-slot=2
# -> 之后 get-card-status: Slot[1]=present, Slot[2]=absent（逻辑映射 flipped）

# 4) 带 AID 激活主会话（这一步是关键）
qmicli -d qrtr://0 --uim-change-provisioning-session=\
  "session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$AID"

# 5) 重启 ModemManager 让它按新状态重建 modem
systemctl restart ModemManager
```

### 15.3 实测结果

```
Registration state: 'registered'
Selected network:  '3gpp'
Network 'lte':     '-66 dBm'      （信号质量 76%）

mmcli -m 0:
  own:           8617868189616
  state:         registered
  operator:      46000 / CHINA MOBILE
  registration:  home
  packet service state: attached   <-- 数据也已附着
```

短信（收发均已验证）：

```
SMS/3 (sent)      text: equuleus sms test 1
SMS/4 (received)  from +8617868189616  text: equuleus sms test 1      <- 自发自收
SMS/5 (sent)      text: 中文测试：equuleus 发送正常
SMS/6 (received)  text: 中文测试：equuleus 发送正常                  <- 中文回环

SMS/0/1/2  (received)  运营商真实短信（10086900 等），中文正常
```

中文用字节验证（不是终端显示）：正文的原始字节为

```
e4 b8 ad e6 96 87 e6 b5 8b e8 af 95 ef bc 9a 65 71 75 75 6c 65 75 73 20 e5 8f 91 e9 80 81 e6 ad a3 e5 b8 b8
= 中文测试：equuleus 发送正常
```

替换字符 `?` 的个数为 **0**，编码链路完全正确。

### 15.4 仍未解决 / 待办

1. **槽 1 的物理检测坏了**：卡在槽 1 时 `--uim-get-slot-status` 恒为 `absent`。目前靠
   “卡插槽 2 + switch-slot 映射到逻辑槽 1”绕过。若要修槽 1，属于硬件排查。
2. **上述序列目前是手工执行**。需要做成开机自启的脚本/服务，否则每次冷启动都要手动跑一遍。
   脚本逻辑应当是：读 `--uim-get-slot-status` 找有卡的物理槽 → `dms online` → `uim-switch-slot=N`
   → 读 AID → `change-provisioning-session` → `systemctl restart ModemManager`。
3. **冷启动后 modem 处于 `shutting-down`** 这一现象仍未查明原因（谁在关它？），脚本里先当作已知
   条件处理（无条件设 online）。
4. 短信存储仍在 MM 内存，重启即失；要持久化需按 `docs/plans-sms.md` 阶段 3 写接收器。
