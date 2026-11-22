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
