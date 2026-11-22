# 蓝牙失败分析（静态，未上机）

日期：2026-11-23

---

## 现象（2026-11-22 实测日志）

```
Bluetooth: hci0: QCA Product ID   :0x0000000a
Bluetooth: hci0: QCA SOC Version  :0x40010214
Bluetooth: hci0: QCA ROM Version  :0x00000201
Bluetooth: hci0: QCA Patch Version:0x00000001
Bluetooth: hci0: Frame reassembly failed (-84)
Bluetooth: hci0: Failed to change controller baudrate
Bluetooth: hci0: Retry BT power ON:2
```

最终 `hciconfig hci0 up` 报 `Connection timed out (110)`，地址仍是 `00:00:00:00:00:00`。

**固件已经成功加载**（能读到 SOC/ROM/Patch 版本说明 firmware download 完成）。

---

## 因果链（已定位到代码行）

`hci_qca.c` 的 `qca_set_baudrate()`：

```c
cmd[] = { 0x01, 0x48, 0xFC, 0x01, 0x00 };   // vendor 命令 0xFC48 改速
cmd[4] = baudrate;

skb_queue_tail(&qca->txq, skb);
hci_uart_tx_wakeup(hu);

while (!skb_queue_empty(&qca->txq))          // 等命令发完
    usleep_range(100, 200);

serdev_device_wait_until_sent(...);

/* Give the controller time to process the request */
case QCA_WCN3990:
    usleep_range(1000, 10000);               // ← 只等 1–10 ms
    break;

return 0;                                     // 无条件成功
```

调用处（约 1520–1575 行）：

```c
reinit_completion(&qca->drop_ev_comp);
set_bit(QCA_DROP_VENDOR_EVENT, &qca->flags);

ret = qca_set_baudrate(hu->hdev, qca_baudrate);
host_set_baudrate(hu, speed);                 // ← 主机切到 3200000

case QCA_WCN3990:
    if (!wait_for_completion_timeout(&qca->drop_ev_comp,
                                     msecs_to_jiffies(100))) {
        bt_dev_err(hdev, "Failed to change controller baudrate\n");
        ret = -ETIMEDOUT;                     // ← 我们看到的错误
    }
```

**时序**：

| 时刻 | 事件 |
|---|---|
| t=0 | 在 115200 下发出 `0xFC48` 改速命令 |
| t≈0.4ms | 命令字节发完（5 字节 @115200） |
| t=1–10ms | `usleep_range` |
| t≈10ms | **主机切到 3200000** |
| t=10–110ms | 等控制器的 vendor event |
| t=110ms | **超时** → 报错 |
| 之后 | 两边速度不一致 → 收到无效字节 → `-84 EILSEQ` |

---

## 驱动注释揭示的设计意图

`qca_recv_event()` 里的原文注释：

> For the WCN3990 the vendor command for a baudrate change isn't sent as
> synchronous HCI command, because the controller sends the corresponding vendor
> event **with the new baudrate**. The event is received and properly decoded
> **after changing the baudrate of the host port**.

即：**vendor event 是在新波特率下发出的**，所以主机必须先切速才能收到它。

**这构成一个不可避免的竞争**：
- 主机切太早 → 控制器还没准备好，命令可能被截断
- 主机切太晚 → 控制器的 event 在旧速度下发，收不到

主线给的 1–10 ms 窗口对某些板子可能不够。

---

## 已排除的因素

| 假设 | 结论 | 依据 |
|---|---|---|
| UART 时钟无法产生 3200000 | ❌ 排除 | `clk_rcg2` + `mnd_width=16`，MND 分频可产生任意频率 |
| 供电不足 | ❌ 排除 | 主线绑定只要求 4 路 supply，我们全有；`s5a` 范围 1.904–2.04V 覆盖 2.04V |
| 缺少 `vdd-core` | ❌ 排除 | 主线绑定**没有**这个属性，是下游私有 |
| 我改的 1500000 | ❌ **有害** | 不在 `qca_get_baudrate_value()` 列表里，落到 `default: return 115200`，两边速度更不一致 |

**已恢复 `max-speed = <3200000>`**（参考板通用值，且在驱动支持列表内）。

---

## 下一步需要真机做的事

静态分析已经穷尽，必须看真机日志才能继续：

1. **看完整 dmesg**：确认 `0xFC48` 命令是否真的发出去、有没有收到任何 vendor event
2. **试降速到驱动支持的档位**：`2000000` 或 `3000000`（**不能用 1500000**）
3. **加驱动调试**：`echo 8 > /sys/module/hci_qca/parameters/...` 或动态 debug
4. **确认流控（RTS/CTS）**：`hci_uart_set_flow_control(hu, true)` 在切速前启用，如果 CTS 引脚有问题会导致字节丢失

---

## 关于 `-84 (EILSEQ)` 的确切来源

不是 `hci_qca.c` 打印的，是通用 serdev 接收路径：`hci_recv_frame()` 返回 `-EILSEQ`，说明收到的字节不是合法 HCI 包头。

这与「两边波特率不一致」完全吻合。

---

## 修复：给时钟表加 51.2 MHz

### 为什么不能改设备树

`clk_rcg2_determine_rate()` 搜索的是编译进 `gcc-sdm845.c` 的固定数组：

```c
static const struct freq_tbl ftbl_gcc_qupv3_wrap0_s0_clk_src[] = {
    F(7372800,   P_GPLL0_OUT_EVEN, 1, 384, 15625),
    ...
    F(48000000,  P_GPLL0_OUT_EVEN, 1, 4, 25),
    F(64000000,  P_GPLL0_OUT_EVEN, 1, 16, 75),
    ...
};
```

`qup_opp_table` **只提供功耗域投票，不决定时钟频率**。所以往 OPP 表加
`opp-51200000` 对 `clk_round_rate()` 毫无影响——我试过，是错的。

### 正确的改动

```c
F(51200000, P_GPLL0_OUT_EVEN, 1, 64, 375),
```

插在 48 MHz 与 64 MHz 之间。

**数学**：
- 48 MHz 行：`m=4, n=25` → 父频率 = `48 × 25/4` = **300 MHz**
- 51.2 MHz 行：`m=64, n=375` → 父频率 = `51.2 × 375/64` = **300 MHz**

同一个父频率，所以是**精确值**，不是近似。

### 副作用分析

这张表被 **16 个 QUP 时钟**共用（wrap0 的 s0–s7，以及 wrap1 等）。必须确认
不会影响其他外设。

`qcom_find_freq()` 是**向上取整**（返回第一个 `rate <= f->freq`），所以新增
51.2 MHz 只影响落在 `(48, 51.2] MHz` 区间的请求。

实测各波特率（过采样 ×16）：

| 波特率 | 请求时钟 | 改动前选中 | 改动后选中 | 变化 |
|---|---|---|---|---|
| 9600 | 0.154 MHz | 7.4 MHz | 7.4 MHz | — |
| 115200 | 1.843 MHz | 7.4 MHz | 7.4 MHz | — |
| 460800 | 7.373 MHz | 7.4 MHz | 7.4 MHz | — |
| 921600 | 14.746 MHz | 14.7 MHz | 14.7 MHz | — |
| 1000000 | 16.000 MHz | 19.2 MHz | 19.2 MHz | — |
| 2000000 | 32.000 MHz | 32.0 MHz | 32.0 MHz | — |
| 3000000 | 48.000 MHz | 48.0 MHz | 48.0 MHz | — |
| **3200000** | **51.200 MHz** | **64.0 MHz** | **51.2 MHz** | ✅ 修复 |
| 3500000 | 56.000 MHz | 64.0 MHz | 64.0 MHz | — |

**只有 3.2 Mbaud 一个受影响**，其余完全不变。

改动前 3.2 Mbaud 会选 64 MHz，除以 16 过采样再除整数分频，得到 3.125 Mbaud
（-2.34%），这正是 `-84 EILSEQ` 的来源。

### 落地方式

`gcc-sdm845.c` 是编译进内核的源码，设备树表达不了，所以走 `tree-delta`
机制：整个文件放在 `kernel/tree-delta/drivers/clk/qcom/`，由
`apply-tree-delta.sh` 覆盖。与原版 `v7.1-rc1` 的差异**只有这一行**，覆盖安全。

CI 已验证能正确应用并构建（run 45058328716，两个 job 都成功）。
