# 短信收发的可行性计划

结论先行：**可行，而且不需要改内核或设备树，也不需要刷机。** 缺的只有一张 SIM 卡，
以及一点点用户态工具/脚本。本文是计划，未在真机上执行发送/接收测试（无卡）。

---

## 1. 现状：该有的都在

设备的 QMI 服务表（`qrtr-lookup`，56 个服务）里与短信相关的都在：

| QMI 服务 | 编号 | 端口 | 用途 |
|---|---|---|---|
| **Wireless Messaging Service (WMS)** | **5** | **65** | **短信收发** |
| User Identity Module (UIM) | 11 | 60 | SIM 卡 / SMSC / 短信存储 |
| Network Access Service (NAS) | 3 | 48 | 注册状态 |
| Voice service | 9 | 47 | 通话（后续） |
| IMS settings / IMS application | 18 / 33 | 80 / 79 | 若运营商走 IMS 短信 |
| Phonebook (PBM) | 12 | 49 | SIM 电话簿 |

用户态栈也已经就位（都在镜像里、开机自启）：

```
ModemManager 1.24   → /ModemManager1/Modem/0 [QUALCOMM INCORPORATED]
qrtr-ns             → QIPCRTR 名字服务
libqmi-utils 1.36   → qmicli
IPA / rmnet_ipa0    → ModemManager 能创建 modem 的前提
```

当前唯一阻塞：`mmcli -m 0` 报 `failed reason: sim-missing`，两个卡槽都是
`error: no-atr-received`。

## 2. 别人做过（重要，避免走弯路）

**OnePlus 6（同为 SDM845）在 postmarketOS 主线内核上的实际使用记录**：

> "I bought a SIM ... put it in, and restarted the phone. It detected the SIM card
> automatically on reboot. **SMS arrived immediately.** Lots of them. I enabled
> mobile data ... and it Just Worked. I can make a phone call, and I can receive a
> phone call ... However, the stack is not particular stable: sometimes I can make
> and receive calls, and sometimes I cannot."
>
> — <https://neilzone.co.uk/2025/10/notes-on-running-postmarketos-on-a-oneplus-6/>

postmarketOS 的 SDM845 设备也没有专门为短信加内核补丁，`modemmanager.conf` 里只有
一行 `--test-quick-suspend-resume`（与我们无关）。也就是说：**短信完全走标准
ModemManager + QMI WMS 路径，不需要任何私有驱动。**

## 3. 一条必须注意的技术限制

`qmicli` **不能发短信**。libqmi 1.36 的 WMS 命令只有：

```
--wms-get-supported-messages, --wms-get-routes, --wms-set-routes,
--wms-reset, --wms-noop
```

没有 list/send。所以**短信功能的实现路径只能是 ModemManager**（它内部用 libqmi 的
WMS 客户端），命令行工具用 `mmcli`。这一点决定了不要把时间花在 qmicli 上。

## 3.5 阶段 0 实测：SIM 未被识别（2026-11-25）——这是当前真正的阻塞

已经插着两张位置都试过一张正在使用的正常 nano-SIM（移动），并做了对照实验：

| 托盘状态 | `qmicli --uim-get-card-status` |
|---|---|
| **空托盘**（无卡） | `Slot [1]/[2]: error: no-atr-received (3)` |
| 正常 SIM 在槽 1 | 同上 |
| 正常 SIM 在槽 2 | 同上 |

**三种情况完全一致**，说明这个状态不反映「有没有卡」，而是 modem **根本没有去扫描 SIM 接口**。
因此不是卡片、触点或插槽的问题，用户侧的卡与插法都可以排除。

已排除的软件动作：

- `--uim-sim-power-off=N` / `--uim-sim-power-on=N`（槽 1、槽 2 各一轮）：命令成功，状态不变
- 整机重启（modem 从零初始化 UIM）：状态不变
- `mmcli -m 0`：`state: failed`、`failed reason: sim-missing`

同时观察到 modem 在启动时向 rmtfs 请求**不存在的分区**：

```
[RMTFS storage] request for unknown partition '/boot/modem_fsg_oem_1', rejecting
[RMTFS storage] request for unknown partition '/boot/modem_fsg_oem_2', rejecting
```

分区表里确实没有 `modem_fsg_oem_1/2`（只有 `fsg`、`modemst1`、`modemst2`）。这是
「双卡各一份 FSG」的请求，可能与该机型 UIM 初始化有关，也可能是非致命的兼容性回退。

AP 侧稳压器也已比对，**没有漏配**：

| 稳压器 | 下游 | 我们 |
|---|---|---|
| `pm8998_l2` | 1.2 V，`always-on` | 1.2 V，`always-on` ✅ |
| `pm8998_lvs2` | 1.8 V，非 always-on | 1.8 V，非 always-on ✅ |
| 下游 always-on 集合 | `fp_vdd_vreg`、`pm8998_l2` | 一致（多一个 `s4a_1p8`，给 WiFi/BT） |

也就是说：主线里其他 SDM845 板（OnePlus 6、beryllium）也没有任何 AP 侧 SIM 配置，
SIM 完全由 modem 固件驱动；equuleus 上它却没驱动起来。

### 2026-11-25 追加调查结果（全部只读）

| 检查 | 结果 |
|---|---|
| `modem_fsg_oem_1/2` 从哪来 | 出现在 **`modem.b16`（modem 固件本体）** 里：`/boot/modem_fsg`、`/boot/modem_fsc`、`/boot/modem_fsg_oem_1`、`/boot/modem_fsg_oem_2`，对应 `OEM_1`/`OEM_2` 存储 |
| Android 侧怎么映射 | `vendor/bin/rmt_storage` 只认识 **`modem_fs1`、`modem_fs2`、`modem_fsc`、`modem_fsg`**，映射到 `/dev/block/bootdevice/by-name/{fs1,fs2,fsc,fsg}`；**完全不认识 `modem_fsg_oem_1/2`** |
| 设备分区表 | 只有 `fsg`、`fsc`、`modemst1`、`modemst2`，没有 `modem_fsg_oem_*` |
| `/persist` 里 | 没有 fsg/oem 相关文件 |
| EFS 内容 | `fsg`/`modemst1`/`modemst2` 都有结构化头部（非全零），`fsc` 全零（正常） |
| SIM 检测 GPIO | 不存在：`/sys/kernel/debug/gpio` 无线名含 sim/uim/card；下游 DTS 也没有 sim/uim 的 pinctrl |

**结论**：`modem_fsg_oem_1/2` 的拒绝几乎可以确定是**非致命的兼容性回退**——因为连 Android 自己的
`rmt_storage` 都不认识这两个名字，而原厂 Android 上 SIM 是可用的。所以它不是 SIM 不被识别的根因。

至此 AP 侧能查的都查完了：EFS 正常、分区正确、稳压器正确、没有 SIM GPIO、
modem 固件在跑、WMS/UIM 服务已注册。**SIM 依然不被扫描**，原因只在 modem 内部，
AP 侧无法再区分「硬件卡座故障」还是「主线下的 modem UIM 未初始化」。

### 待查方向（按可能性排序）

1. **`modem_fsg_oem_1/2` 到底该指向什么**。查小米同代机型的分区表是否真有这两个分区；
   若确实存在，把它们补进 rmtfs 的映射（注意 rmtfs 当前以 `-r` 只读运行）。
2. **modem 是否有 UIM 相关的 NV/EFS 需求**：`fsg`、`modemst1/2` 分区都在且未被擦除，
   但 modem 可能期望 Xiaomi 私有布局。
3. **对比同 SoC 且 SIM 可用的机型**（OnePlus 6 的 pmOS 实测 SIM 可用）的 modem 固件版本
   与 rmtfs 请求序列，找出 equuleus 独有的请求。
4. **向社区确认**：pmaports 里 `device-xiaomi-equuleus` 仍在 `device/testing`，wiki 未记录
   SIM 状态；直接问 SoMainline / pmOS 的 equuleus 维护者是最快的判定。

在 1–4 有结论前，阶段 1（收短信）和阶段 2（发短信）都无法开始。

## 4. 实施步骤

### 阶段 0：插卡与识别（几分钟）

```bash
# 插入 nano-SIM 后
mmcli -m 0                                  # 应看到 SIM 段：iccid/imsi/operator
qmicli -d qrtr://0 --uim-get-card-status     # Card state: 'present'
qmicli -d qrtr://0 --nas-get-serving-system  # Registration state: 'registered'
```

验收：`state: registered`，且 `mmcli -m 0` 的 `SIM` 段有 ICCID。

### 阶段 1：接收短信（分钟级）

用另一台手机发一条短信过来，然后：

```bash
mmcli -m 0 --messaging-list-sms              # 列出 /ModemManager1/SMS/N
mmcli -s 0                                   # 读内容、发件号码、时间
mmcli -s 0 --create-file-with-data=/root/sms0.txt   # 导出正文（便于验证编码）
```

验收：能列出并在正文里看到正确文本（中文需确认 UCS2 解码正常）。

### 阶段 2：发送短信（分钟级）

```bash
mmcli -m 0 --messaging-create-sms="text='test from equuleus',number='+8613xxxxxxxxx'"
# 返回 /org/freedesktop/ModemManager1/SMS/1
mmcli -s 1 --send
```

验收：对端收到；若需要送达回执，创建时加 `delivery-report-request=yes`，之后
`mmcli -s 1` 的 state 应变为 `sent`/`delivered`。

### 阶段 3：存储与持久化（小工作量）

ModemManager 收到的短信默认在**内存**里，重启即失。可选做法：

- `mmcli -m 0 --set-default-storage=me`（modem）或 `sm`（SIM），配合 `--store`，
  让短信落在 modem/SIM 存储（SIM 一般只有 20–30 条容量）；
- 或者自己写一个**接收器**：订阅 ModemManager 的 DBus 信号（新短信到达），把正文
  追加到文件/数据库。这是我推荐的方式——不占 SIM 容量，也不需要 MM 的特殊配置。

### 阶段 4：集成进镜像（小工作量）

- 加一个 `sms-recv.service`（oneshot/常驻均可）：监听 DBus，落盘到
  `/var/lib/equuleus/sms/`，并在串口控制台打印一行提示；
- 或者仅提供 `scripts/sms.sh`（list/send/read 的薄封装），不做常驻服务。
- 两者都不需要动内核与 DTS。

## 5. 验收标准

| 项目 | 通过标准 |
|---|---|
| SIM 识别 | `mmcli -m 0` 显示 ICCID/IMSI，`state: registered` |
| 接收 | 另一台手机发的短信能在 `--messaging-list-sms` 中出现，正文正确（含中文） |
| 发送 | `--messaging-create-sms` + `--send` 后对端收到 |
| 回执 | 开启 `delivery-report-request` 后状态能到 `delivered` |
| 持久化 | 重启后仍能读到此前的短信（用阶段 3 的方案） |
| 稳定性 | 连续收发各 10 条无失败 |

## 6. 风险与未知

1. **运营商是否还提供 CS 短信**。WMS 走的是传统 CS/NAS 短信通路；若某地 2G/3G 已退网
   且仅支持 IMS 短信（SMS over IMS），就需要 IMS 栈（设备有 IMS 服务 18/33，但主线没有
   IMS 客户端），届时要换方案。这是**最大的不确定项**，但插卡即可证伪。
2. **SIM 存储容量**小（20–30 条），不要依赖 SIM 存储做长期保存。
3. **中文编码**：UCS2 需要确认 MM 的解码正确（阶段 1 用中文短信验证）。
4. **双卡**：设备有两个卡槽，本计划只针对插一张卡的情况；双卡需要在 MM 里确认
   `--set-primary-sim-slot`。
5. **通话**虽然服务存在（Voice=9），但社区反馈"时好时坏"，与短信是两个独立议题；
   短信通了之后可以单独评估。
6. **本地无法区分硬件与主线**：要判定「卡座坏」还是「主线 modem UIM 没起来」，需要跑一次原厂
   Android 看它是否识别 SIM；但那会重排 userdata（会毁掉当前 Debian 系统），且 MIUI 的 adb
   需要屏幕点授权——本机屏幕已坏，走不通。**因此建议直接问社区**：
   pmaports 的 `device-xiaomi-equuleus` 仍在 `device/testing`，wiki 未记录 SIM 状态，
   问 SoMainline / pmOS 的 equuleus 维护者是最快的判定。

## 7. 工作量估计

| 阶段 | 预计 |
|---|---|
| 0–2（识别 / 收 / 发） | 插卡后 **10 分钟内**可全部验证 |
| 3（持久化接收器） | 半天以内（一个 DBus 监听脚本 + systemd unit） |
| 4（进镜像 + CI 校验） | 半天以内（改 `build-rootfs.sh`、`verify-rootfs-image.sh`） |

**不需要**：内核改动、设备树改动、刷机、新的私有驱动。