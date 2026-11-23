# 蓝牙：完整解决方案与踩过的坑

日期：2026-11-23
状态：**成功** —— 控制器 UP RUNNING，出厂地址，扫描到真实设备。

---

## 最终结果

```
Controller <factory-BD_ADDR> (public)
        Manufacturer: 0x001d (29)
        Version: 0x09 (9)
        Name: equuleus
        Powered: yes
        PowerState: on

hci0:   Type: Primary  Bus: UART
        BD Address: <factory-BD_ADDR>
        ACL MTU: 1024:7  SCO MTU: 60:8
        UP RUNNING
```

扫描 12 秒找到 11+ 个设备，包括 `Mi Smart Band 5`。

---

## 修复一：uart6 需要四线 pinctrl（真正的根因）

`hci_qca` 在改速前调用 `hci_uart_set_flow_control(hu, true)`，让控制器能用 RTS 拉住主机。
`sdm845.dtsi` 的默认 pinctrl 只有 TX/RX 两线，**RTS/CTS 没有 mux 到 UART**，这个调用
无效，控制器的确认信号丢失：

```
Bluetooth: hci0: Frame reassembly failed (-84)
Bluetooth: hci0: Failed to change controller baudrate
```

修复：

```dts
&uart6 {
	pinctrl-0 = <&qup_uart6_4pin>;   /* 加这一行 */
	status = "okay";
	...
};
```

`qup_uart6_4pin` 包含 gpio45（CTS，pull-down）、gpio46（RTS）、gpio47（TX）、
gpio48（RX，pull-up）。beryllium 和 Mechres 的 Mi 8 DT 都这样写。

修复后：

```
Bluetooth: hci0: QCA Downloading qca/crbtfw21.tlv
Bluetooth: hci0: QCA Downloading qca/crnv21.bin
Bluetooth: hci0: QCA setup on UART is completed
```

**改速错误和 EILSEQ 完全消失。**

---

## 修复二：HCI_UNCONFIGURED 需要先设地址

固件下载成功后，`hciconfig hci0 up` 仍然失败：

```
Can't init device hci0: Operation not supported (95)
```

`bluetoothctl show` 报 `No default controller available`。

### 原因

`hci_qca` 给这个控制器设了 `HCI_QUIRK_INVALID_BDADDR`（地址来自 persist/QMI，
不是控制器自己报的）。`hci_sync.c` 因此打上 `HCI_UNCONFIGURED`：

```c
invalid_bdaddr = hci_test_quirk(hdev, HCI_QUIRK_INVALID_BDADDR) || ...;
if (hci_test_quirk(hdev, HCI_QUIRK_EXTERNAL_CONFIG) || invalid_bdaddr)
        hci_dev_set_flag(hdev, HCI_UNCONFIGURED);
```

而 `hci_dev_open()` 对未配置控制器直接拒绝普通打开：

```c
if (hci_dev_test_flag(hdev, HCI_UNCONFIGURED) &&
    !hci_dev_test_flag(hdev, HCI_USER_CHANNEL)) {
        err = -EOPNOTSUPP;
        goto done;
}
```

### 解决

只有 management 接口能配置它，也就是 `btmgmt`。顺序必须是：

```
btmgmt -i hci0 power off       -> "Invalid Index"（正常，本来就是关的，忽略）
btmgmt -i hci0 public-addr ..  -> "Set Public Address complete"   ← 关键
btmgmt -i hci0 power on        -> "Set Powered complete, powered br/edr"
```

`public-addr` 成功后，mgmt 会清掉 `HCI_UNCONFIGURED`（`mgmt.c:8162`），
反手 `power on` 就能正常启动。

### 必须在 bluetoothd 之前

`btmgmt` 和 `bluetoothd` 争用同一个 management socket。`bluetooth-addr.service`
因此有 `Before=bluetooth.service`。之前在设备上失败就是因为跑的是旧脚本
（用 `--index 0` 且无超时），卡在 `activating`。

---

## 修复三：bluez 缺依赖库

最初 `bluetooth.service` 启动失败，`status=127`：

```
/usr/libexec/bluetooth/bluetoothd: error while loading shared libraries:
  libdw.so.1: cannot open shared object file
```

因为 bluez 是用 `fetch_pkg`（单包解压，不解析依赖）装的。改用 apt。

---

## 顺序总览

1. **initramfs** 提供 `qca/crbtfw21.tlv` 和 `qca/crnv21.bin`（0.75 s 时就要用）
2. **设备树** `pinctrl-0 = <&qup_uart6_4pin>` 让流控生效 → 固件下载成功
3. **bluez 依赖** 装全 → bluetoothd 能启动
4. **bluetooth-addr.service** 在 bluetoothd 之前用 `btmgmt public-addr` 配置控制器
5. **bluetooth.service** 启动，控制器 UP RUNNING

---

## 我走错的路

**时钟分析**：花了两个回合算出 `qup_opp_table` 缺 51.2 MHz、误差 2.34%，并加了
`F(51200000, P_GPLL0_OUT_EVEN, 1, 64, 375)`。数学全对，但**不是根因** —— Mechres 的
`max-speed` 也是 `3200000`，蓝牙正常。真正的原因是流控引脚。

那行时钟表改动保留（无害，让速率精确），但它从来不是阻塞点。

**教训**：对比一个**能工作**的同类设备树，比对着代码推演快得多。应该更早去看
Mechres 的 DTS。