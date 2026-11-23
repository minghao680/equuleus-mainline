# 蓝牙时钟修复：真机验证未通过（2026-11-23）

## 结论

`F(51200000, P_GPLL0_OUT_EVEN, 1, 64, 375)` 这一行**已确认编入发布内核**，
但真机上 uart6 的时钟仍然是 **7,372,800 Hz**，蓝牙仍然报同样的错误：

```
Bluetooth: hci0: Frame reassembly failed (-84)
Bluetooth: hci0: Failed to change controller baudrate
Bluetooth: hci0: Retry BT power ON:0/1/2
```

## 已排除的可能

| 检查项 | 方法 | 结果 |
|---|---|---|
| tree-delta 是否应用 | CI 日志 `overlaying 8 files` 含 `gcc-sdm845.c` | ✅ |
| 驱动是否编译 | CI 日志 `CC drivers/clk/qcom/gcc-sdm845.o` | ✅ |
| 常量是否在内核 | 解压 boot.img 内核段（57 MB），搜 `51200000` | ✅ 8/4 字节均找到 |
| 频率表排序 | 逐项检查 `ftbl_gcc_qupv3_wrap0_s0_clk_src` | ✅ 16 项严格递增，51.2M 在第 7 位 |
| 父时钟频率 | `/sys/kernel/debug/clk/gpll0_out_even/clk_rate` | ✅ **300 MHz**，与 `51.2 × 375/64` 精确匹配 |
| 时钟驱动配置 | `CONFIG_SDM_GCC_845=y` | ✅ |
| 时钟范围限制 | `clk_min_rate=0`，`clk_max_rate=ULLONG_MAX` | ✅ 无限制 |

## 剩余可疑点

### 1. `geni_se_clk_tbl_get()` 的枚举过程

```c
for (i = 0; i < MAX_CLK_PERF_LEVEL; i++) {
    freq = clk_round_rate(se->clk, freq + 1);
    if (freq <= 0 || (i > 0 && freq == se->clk_perf_tbl[i - 1]))
        break;
    se->clk_perf_tbl[i] = freq;
}
```

从 1 Hz 开始，每次用「上一项 + 1」重新请求。理论上应依次得到
7.37M → 14.7M → ... → 48M → **51.2M** → 64M → ...

**但 `clk_round_rate()` 对 `clk_rcg2` 的实现是 CEIL 策略**，返回第一个 ≥ 请求值的表项。
如果某个中间项被跳过（例如 MND 分频器无法精确产生），枚举会提前终止或漏掉 51.2 MHz。

### 2. `clk_rcg2_determine_rate` 的父时钟校验

即使 `freq_tbl` 有 51.2 MHz，`_freq_tbl_determine_rate()` 还要验证
`clk_hw_get_parent_by_index()` 能找到对应父时钟，并检查父时钟能否产生该频率。
如果 `P_GPLL0_OUT_EVEN` 的索引解析有问题，该项会被跳过。

### 3. 内核 lockdown 阻止诊断

```
Kernel is locked down from Kernel configuration
Lockdown: bash: debugfs access is restricted
```

无法写入 `/sys/kernel/debug/dynamic_debug/control`，因此看不到
`dev_dbg(port->se.dev, "desired_rate = %u, clk_rate = %lu, clk_div = %u, clk_idx = %u\n", ...)`
这条关键日志。

## 下一步

1. **关闭内核 lockdown**（`CONFIG_SECURITY_LOCKDOWN_LSM=n` 或加
   `lockdown=none` 到 cmdline），然后开 dynamic debug 看 `desired_rate`
2. 如果 `desired_rate = 51200000` 但 `clk_rate` 不是 51200000，问题在
   `geni_se_clk_freq_match` 的选择
3. 如果 `desired_rate` 本身不是 51200000，问题在 `sampling_rate` 计算
   （`UART_OVERSAMPLING` 可能不是 16）

## 附带发现的问题

`bluetooth-addr.service` 会卡在 `activating` 状态：
- `btmgmt --index 0 power off` 对 DOWN 状态的控制器**无限阻塞**
- 已修复：先 `hciconfig up`，再用 `timeout 15` 包裹 `btmgmt info` 探活，
  不响应则直接退出

这个问题与时钟问题独立，但同样会让蓝牙不可用。
