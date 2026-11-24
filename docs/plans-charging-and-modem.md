# 两个计划：充电热插拔、以及移动数据与通话

状态：**仅计划与可行性评估**，本文写作过程中未改动设备、未刷机、未提交任何代码。
所有"已确认"的事实都来自本机已有的日志/源码/镜像检查；"假设"一律标注。

---

## 0. 已有的轮子（避免重复造）

写这两个计划前先查过社区与上游，结论是：**充电驱动已经在用上游代码，PD 已有人在
做但远未就绪，通话音频也有人做过**。以下是可直接引用的项目。

### 0.1 PD / Type-C on PMI8998：有人在做，但**没有就绪**

| 来源 | 内容 | 状态 |
|---|---|---|
| [`samcday/qcom-pmic-typec-smb2`](https://github.com/samcday/qcom-pmic-typec-smb2) | 树外 **TCPM** 驱动，覆盖 PM660 与 PMI8998 SMB2 的 CC 检测、power/data role、VCONN、VBUS 与 **PD PHY（PD 2.0）**；与 `qcom_smbx` 对接 | **仅通过静态验证，没有任何真机运行过**；所有默认 DT profile **禁用 PD**；只有 Crosshatch 有一份"固定 5 V"的诊断 profile；明确拒绝 >5 V、源 >1.5 A、非 PD 2.0；已知 `CURRENT_MAX` 所有权未仲裁。覆盖板：sargo/bonito、enchilada/fajita、crosshatch，**不含 equuleus**（但源码可移植） |
| 上游 `drivers/usb/typec/tcpm/qcom/` | `qcom_pmic_typec.c` + `qcom_pmic_typec_pdphy.c` | 只支持 **`qcom,pm8150b-typec`** 与 **`qcom,pmi632-typec`**，**不含 PMI8998** |
| 2026-05 邮件列表 `[PATCH 0/6] usb: typec: add Qualcomm PMI8998 USB Type-C role-switch support` | 只读角色切换，无 TCPM、无 PD | 未合并；review 建议改用 TCPM 后端 |

**决定：不自行实现 PD 栈。** 现在只把限制写清楚；若将来要 PD，优先以**外部模块**方式
接 `qcom-pmic-typec-smb2`，而不是往本仓库里塞一份新驱动。

### 0.2 tree-delta 的来历与真实状态（结论已修正）

`kernel/tree-delta/` 是 **2026-11-22 的 `5f50a1f`** 引进的，提交标题就写明了用途：
*"Ship the six files vanilla mainline lacks, so CI can build the same tree"*。
原因是：**本地开发用的是 postmarketOS 打过补丁的 `linux-sdm845-7.1-rc1-r0`**，而 **CI 拉的是
stock `torvalds/linux` v7.1-rc1`**，有六个文件上游根本没有，于是 CI 构建失败。为了"不分叉内核"，
仓库把这六个文件连同覆盖脚本一起带上，本地与 CI 构建同一棵树。

之后又加了两个：

| 提交 | 加入的文件 | 用途 | 后来结论 |
|---|---|---|---|
| `5f50a1f` 2026-11-22 | `pmi8998.dtsi`、`pmi8998_fg.c`、`panel-samsung-ea8076.c`、`qcom_smbx.c`、`qcom,spmi-haptics.h`、`qcom,q6voice.h` | 让 CI 能编译 | 仍然必需 |
| `a32048f` 2026-11-23 | `gcc-sdm845.c`（+1 行 `F(51200000, …)`） | 修蓝牙波特率 | **假设已被推翻**（真因是 uart6 四线 pinctrl） |
| `5fe2852` 2026-11-23 | `qcom-imem-restart-reason.c` | 让 `reboot bootloader` 能进 fastboot | **真机验证无效**（ABL 仍回 Linux） |

**权威比对（`vanilla-ref`，HEAD `254f4963` = Linux 7.1-rc1，用 `git cat-file` 逐个核实）：**

| tree-delta 文件 | vanilla | 判断 |
|---|---|---|
| `pmi8998.dtsi` | 有（98 行） | 我们的 125 行，**+19 行**（haptics include、`pmi8998_fg` 节点）→ **delta 必需** |
| `qcom_smbx.c` | 有（1059 行） | 我们的 1130 行，**+297/−246**，含 `enum smb_generation {SMB2, SMB5}` 与 `SMB_REG_OFFSET` → **我们的比上游更新**（Casey 的 smb5 支持当时还没进 v7.1-rc1） |
| `gcc-sdm845.c` | 有（4035 行） | 我们的 4036 行，**仅 +1 行**，就是那个被推翻的波特率假设 → **可删** |
| `panel-samsung-ea8076.c` | **没有** | delta 必需 |
| `pmi8998_fg.c` | **没有** | delta 必需 |
| `qcom-imem-restart-reason.c` | **没有** | 编译必需，但功能无效 |
| `qcom,spmi-haptics.h` | **没有** | delta 必需（`pmi8998.dtsi` 引用） |
| `qcom,q6voice.h` | **没有** | delta 必需（DTS 引用） |

> **更正**：先前一度认为"整个 tree-delta 与上游逐字节相同、可以整目录删除"——那次比对的基准是
> 本地**打过补丁的 pmOS 树**，不是 CI 用的 vanilla，结论无效。以 vanilla 为准，**tree-delta 仍然必需**。

**因此精确的清理动作只有两条**（都不是整目录删除）：

1. 从 tree-delta 移除 `drivers/clk/qcom/gcc-sdm845.c`：它只是给一个已被推翻的蓝牙波特率假设加了一行
   时钟频率，删掉后时钟表回到上游值，行为不变。
2. 决定 `qcom-imem-restart-reason.c` 的去留：真机证明 `reboot bootloader` 仍然回 Linux
   （`IMEM` 魔数没被 ABL 采信，疑似需要 PON 热复位）。若删除，需同时从
   `config/equuleus.config` 去掉 `CONFIG_QCOM_IMEM_RESTART_REASON=y` 并改 `apply-tree-delta.sh`。

### 0.3 通话 / 数据：可参考的既有工作

- postmarketOS **MR !2982 "enable call audio on sdm845 devices"** —— 通话音频的 UCM/路由做法。
- Casey Connolly 的 SDM845 主线进展（2021 起）与 ModemManager 在 sdm845 上的可用性说明 ——
  数据链路的上游经验。
- 本仓库已有：`CONFIG_QRTR=y` / `CONFIG_QRTR_SMD=y`（AP↔modem 传输）、`CONFIG_QCOM_IPA=y`、
  `CONFIG_QCOM_QMI_HELPERS=y`，只差启用 IPA 节点与用户态 QMI 栈。

→ B 节应当**照搬**这些既有的用户态/DT 组合，不自己发明流程。

---

## A. 充电热插拔 —— 实测结论：无需修复

### A.1 结论先行

**热插拔功能是正常的，没有需要修的软件缺陷。** 2026-11-25 在真机上做了两轮受控测试
（只读采样，每 0.5 s 记录一次），A-to-C 与 C-to-C 都能被识别、都能充电。

| 插拔方式 | 识别延迟 | VBUS | 输入限流 | 结果 |
|---|---|---|---|---|
| **A-to-C**（7 个完整周期，含正反插） | `online` 在 **~0.5 s** 内翻转 | 4.88–4.94 V | **1.5 A** | `Charging`，电池 +1.1 A |
| **C-to-C（PD 充电器）** | 同样 ~0.5 s | 4.38–4.96 V | 0.70–1.20 A 反复变化 | `Charging`，但**没有 PD 协商** |

中断计数同步增长，说明事件链完整：

```
usb-plugin       14 → 36      (测试期间 +22)
usbin-icl-change 280 → 607    (+327，输入限流反复重算)
```

### A.2 真实限制：PD 快充不被协商（原厂镜像确认过）

主线没有 PD 驱动，所以 C-to-C 只能拿到 **默认 5 V、≤1.2 A**（约 6 W）。

**原厂固件里确实有这套驱动，而且是 Qualcomm + Xiaomi 私有实现。** 已验证：

| 检查对象 | 结果 |
|---|---|
| `vendor.img` | 只有 12 个 `.ko`（exfat / pinctrl-wcd / qca_cld3_wlan 等），**PD 不在模块里** |
| 原厂内核（`boot.img` 内 gzip，解出 42 MB，`Linux 4.9.186-perf`） | 含 `qpnp-pdphy`、`hvdcp`（14 处）、`qcom,fastchg`、`qcom,thermal-mitigation-pd-base` |
| Xiaomi 私有属性（内核字符串 + 下游 DTS） | `mi,limit_pd_vbus`、`mi,pd_vbus_max_limit = <0x895440>` = **9 000 000 µV（9 V）** |
| 下游 DTS 充电拓扑 | `qcom,qpnp-smb2` + **两颗** `qcom,smb1355`（并联），`qcom,fg-gen3` 电量计 |
| 电荷泵 / 无线充 | **都没有**（`sc85*`/`bq2597*`/wireless 计数为 0） |

也就是说原厂能做到 **PD 9 V + 双路并联充电**，另有 QC3 与 PD 各自的温控降流表
（`qcom,thermal-mitigation-qc3`、`qcom,thermal-mitigation-pd-base`）。

**主线为什么做不到**：`qpnp-pdphy` 是**下游独有驱动**，主线内核里根本没有这个文件；
它也不是标准 TCPC，而是配合 `smb5-lib` 的 PD PHY，无法直接套 `TYPEC_TCPM` 框架。

**可行性判断：短期不做。** 需要移植/重写 `qpnp-pdphy` 并接入主线的 `qcom_smbx`，
工作量以周计，收益只是「C-to-C 从 6 W 变成 18 W 左右」。相比之下，USB-A 已经能到 1.5 A，
A-to-C 体验不受影响。**如实记为功能限制，不声称已支持。**

### A.3 之前那次 `online=0` 如何解释

当时（电量 1–4%、电压 2.7 V）观测到 `online=0`、`VOLTAGE_NOW=0`，而今天同一条 A-to-C 线在
7 个周期里全部正常。两次之间唯一明显的变化是：**今天把 Type-C 头正反各插了多次**。
最可能的原因是当次接触不良（CC 触点只在一个方向导通、或插头未插到底），其次是那个充电器
当时没有输出。**没有证据支持这是驱动缺陷。**

### A.4 只读调查留下的可复用资料

- 从本机原厂 `boot.img`（偏移 14144688 起）解出 **64 个 DTB**，其中 **51 个是 Xiaomi 机型**，
  Equuleus 有 6 个（`model = "Xiaomi Technologies, Inc. Equuleus MP v2.1"`）。
- 设备 `dtbo` 分区（`/dev/sde37`，8 MB，md5 `96995b58d4cbf6aaa9041b4f00c7f6ae`）**全零、无 FDT**，
  说明这台机器不使用独立 dtbo。
- 下游设备树确认：**没有独立 TCPC**（`tcpci`/`tcpm`/`fusb302`/`ptn5110` 计数为 0），
  USB 插入/CC 状态靠 `qcom,usbplug-cc-gpio = <&tlmm 38 0>`；充电器是 `qcom,qpnp-smb2`
  加两颗 `qcom,smb1355`；下游订阅 8 个 usbin 中断，主线只订阅 4 个
  （`usb-plugin`、`bat-ov`、`wdog-bark`、`usbin-icl-change`）。
  **实测表明这 4 个已足够**，不需要补 `type-c-change` / `usbin-src-change`。

### A.5 已发现但不紧急的健壮性问题

手动 `unbind`/`bind` `qcom-smbx-charger` 时，`power_supply_changed_work` 会抛内核栈回溯
（当时是为了强制重探而做的实验）。正常插拔不会触发，列为**低优先级健壮性问题**，
可在有空时修，不影响用户。

### A.6 验收状态

| 项目 | 状态 |
|---|---|
| A-to-C 连续插拔 10 次、2 s 内识别 | ✅ 已超标准完成（7 次，~0.5 s） |
| C-to-C 能充电（非 PD 快充） | ✅ 已实测 |
| C-to-C PD 高压/大电流 | ❌ 不支持（缺 PD PHY 驱动），**如实记录，不声称已修复** |
| 关机充电 | ⏳ 未单独验证（由 ABL 负责） |

### A.7 因此的计划

**不做任何代码改动。** 只把上面的限制如实写进 README / STATUS：
「A-to-C 与 C-to-C 都能充电；C-to-C 只走 5 V 默认档，不支持 PD 快充，原因是主线缺少 PMI8998
PD PHY 驱动。」

## B. 移动数据与通话

### B.1 已经具备的基础

| 层 | 状态 | 证据 |
|---|---|---|
| Modem（MSS） | **已运行** | `remoteproc1 state=running`，加载 `qcom/sdm845/mi8/{mba,modem}.mbn` |
| 固件服务 | **已运行** | `rmtfs` / `pd-mapper` / `tqftpserv` 全 active，`/lib/firmware/image` 65 个文件 |
| QRTR | **内核内建** | `CONFIG_QRTR=y`、`CONFIG_QRTR_SMD=y`（AP↔modem 传输已就绪） |
| QMI helpers | 已编译 | `CONFIG_QCOM_QMI_HELPERS=y` |
| IPA（数据加速） | 驱动已编译，**但未启用** | `CONFIG_QCOM_IPA=y`；`sdm845.dtsi` 里 `ipa@1e40000` 是 `status = "disabled"`，板级 DTS 没有 `&ipa` 覆盖 |
| 用户态 QMI | **完全缺失** | 镜像内 `qmicli`/`qmi-network`/`mmcli`/`ModemManager`/`qrtr-ns` 全部 MISSING |
| 通话音频 DAIs | **未接线** | 板级 DTS 内无 `q6voice`/voice DAI；`kernel/tree-delta` 只有 `qcom,q6voice.h` 头文件 |

### B.2 可行性判断

- **移动数据：高。** 内核侧 IPA+QRTR 都在，缺的是"启用 IPA 节点 + 装用户态 QMI 栈"，属于配置与打包工作，不需要新驱动。
- **通话语音：中低。** QMI 语音命令可以走通（modem 固件是原厂的），但**通话音频**需要 q6voice DAI + SLIMBUS/PCM 路由 + UCM 配置，且我们没有可参考的 equuleus UCM。社区在 sdm845 上做过（postmarketOS MR !2982 "enable call audio on sdm845 devices"），可作为路线参考，但需要实测调。

### B.3 数据链路：分层实施计划

**阶段 0（只读确认，不动设备）**
- 确认 IPA 驱动对 DT 的实际要求：`drivers/net/ipa/` 里查 `memory-region`/`sram`/`qcom,smem` 的使用，确认 sdm845.dtsi 现有节点是否已足够。
- 确认 modem 是否已加载 IPA 固件（`dmesg | grep -i ipa`；IPA FW 由 modem 侧加载，不是 AP）。
- 确认 `ipa_modem_tables` / `ipa_smp2p_*` 节点是否都存在。

**阶段 1（内核：启用 IPA）**
- 板级 DTS 加 `&ipa { status = "okay"; };`（若驱动还要求 `memory-region` 或 `firmware-name`，按阶段 0 的结论补）。
- 重新编译 boot.img 并刷入（**这是唯一需要刷机的步骤**）。
- 验收：`dmesg` 出现 IPA probe 成功、`ip link` 出现 `rmnet_ipa0` 或 IPA 相关设备。

**阶段 2（用户态：QMI 栈）**
- 装包：`libqmi-utils`（`qmicli`、`qmi-network`）、`libqmi-proxy`、`qrtr`、`modemmanager`、`libqrtr-glib`。
- 起服务：`qrtr-ns`（QRTR 名字服务），必要时 `qmi-proxy`。
- 验收：
  ```
  qmicli -d qrtr://0 --dms-get-manufacturer
  qmicli -d qrtr://0 --dms-get-model
  qmicli -d qrtr://0 --uim-get-card-status     # 确认 SIM 可读
  ```
- 这一步就能确认 **SIM 识别**是否正常——这是数据能不能通的前提。

**阶段 3（数据连接）**
- 用 `qmicli` 手动建 PDP：`--wds-start-network="apn=...,ip-type=4"` 拿 IP，再配 `rmnet` 接口/DHCP；或用 `mmcli` 让 ModemManager 全自动。
- 验收：`ping -I <rmnet 接口> 223.5.5.5` 通、`curl` 能出网、断开后能重连。

**阶段 4（集成进镜像）**
- 把上述包装进 `scripts/install-firmware-daemons.sh`，开机自动起 `qrtr-ns` + `ModemManager`，并像 Wi-Fi MAC 那样**不写入任何每机常量**（APN 由用户配置，不进镜像）。
- 验收：冷启动后 `mmcli -m 0` 能看到 modem，插 SIM 后自动注册网络。

### B.4 通话：分层实施计划

**阶段 V0（可行性验证，成本最低）**
- 阶段 2 完成后，直接试 QMI 语音命令：
  ```
  qmicli -d qrtr://0 --voice-list-calls
  qmicli -d qrtr://0 --voice-dial="12345"
  ```
- 目的：确认 modem 固件的 QMI voice 服务存在。若这一步不通，通话在用户态就无解，方案终止（不需要动音频）。

**阶段 V1（通话音频链路）**
- 板级 DTS 增加 q6voice 相关 DAI（`qcom,q6voice.h` 已在 tree-delta，说明之前已为此准备过），把 modem 语音 PCM 接到 WCD9340（听筒/耳机）。
- 需要 **UCM2 配置**：为通话场景定义 `Voice Call` 用例的 mixer 路由（参考 postmarketOS sdm845 的 UCM 与 MR !2982）。
- 验收（**必须能听到/被听到**，只看日志不算）：
  1. `qmicli --voice-dial` 后对端振铃；
  2. 双向语音可懂（不是只看 `dmesg`）；
  3. 挂断后音频通路正确释放（不残留占用）。

**阶段 V2（集成）**
- 用 ModemManager 的 Voice API（`org.freedesktop.ModemManager1.Modem.Voice`）替代手工 `qmicli`，便于长期使用。
- 风险：MM 的 voice 支持在部分固件上不稳定；必要时保留 `qmicli` 脚本作为兜底。

### B.5 验收标准（整体）

| 项目 | 通过标准 |
|---|---|
| SIM 识别 | `--uim-get-card-status` 返回有效 ICCID/IMSI |
| 注册网络 | `--nas-get-serving-system` 显示已注册（LTE） |
| 移动数据 | 通过 rmnet 出网，`curl` 成功，掉线可自动重连 |
| 通话信令 | `--voice-dial` 能建立并挂断 |
| 通话音频 | 双向可懂；挂断后无残留占用 |
| 冷启动 | 全部自动，无手工步骤，且镜像内**不含** SIM/APN 等每机信息 |

### B.6 主要风险与未知

1. **SIM/运营商**：需要一张可用 SIM 与对应 APN；不同运营商 QMI profile 配置不同。
2. **IPA 与 modem 固件版本**：原厂 modem 固件期望的下行数据路径可能与主线 IPA 驱动的假设不一致（社区在 sdm845 上能跑，但不能保证每个固件版本都行）。
3. **通话音频是本项目最大不确定项**：涉及 q6voice、SLIMBUS、UCM 三方配合，且没有 equuleus 的现成配置；可能出现"信令通、声音不通"的中间状态。
4. **电量与热**：调试数据/通话会显著增加功耗，需保证充电通路可用（见 A 节）。
5. **法规/合规**：通话与蜂窝注册涉及运营商网络，仅做本机实验，不涉及任何绕过。

---

## C. 建议的执行顺序

1. **A.4 步骤 1–3**（充电，纯只读，成本极低，可能直接结案）。
2. **B.3 阶段 0 + 阶段 2 的只读部分**（确认 SIM 与 QMI 可用性，仍然不刷机）。
3. 若 1、2 都需要动内核，则**合并成一次刷机**：IPA 启用 + 充电相关 DT 改动一起验证，减少刷机次数。
4. 数据通了之后再评估通话（V0 成本很低，可以先做，不影响别的）。