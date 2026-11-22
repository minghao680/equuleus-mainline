# 为什么 `reboot bootloader` 不生效（静态分析结论）

日期：2026-11-23
方法：纯代码分析，未上机。

---

## 结论

**ABL 读取的是 IMEM 里的 `restart_reason`（魔数 `0x77665500`），而不是 PMIC 的 `PON_SOFT_RB_SPARE` 寄存器。**

主线 `qcom-pon` 写的是后者，所以这颗 bootloader 完全看不到，只会当作普通重启。

---

## 两条机制的完整对比

### 主线：`drivers/power/reset/qcom-pon.c`

```
reboot bootloader
  → kernel/reboot.c: kernel_restart("bootloader")
  → atomic_notifier_call_chain(&restart_handler_list, ...)
  → reboot_mode_notify()                       [drivers/power/reset/reboot-mode.c]
  → get_reboot_mode_magic(reboot, "bootloader")
      → 匹配 DT 里 mode-bootloader = <0x2>
  → qcom_pon_reboot_mode_write(magic = 0x2)
  → regmap_update_bits(
        baseaddr + PON_SOFT_RB_SPARE (= 0x8f),
        GENMASK(7, 1),                          [pm8998 → GEN2_REASON_SHIFT = 1]
        0x2 << 1 = 0x4)
```

写入成功，寄存器也确实变了——**但 ABL 不读它**。

### 下游：`drivers/power/reset/msm-poweroff.c`

```c
if (!strncmp(cmd, "bootloader", 10)) {
    qpnp_pon_set_restart_reason(PON_RESTART_REASON_BOOTLOADER);   // 写 PON spare
    __raw_writel(0x77665500, restart_reason);                     // ← 关键：写 IMEM
}
```

**两者都写**。`restart_reason` 指向 IMEM 中的固定偏移，ABL 读那里。

| 命令 | IMEM 值 | PON spare |
|---|---|---|
| `bootloader` | **0x77665500** | PON_RESTART_REASON_BOOTLOADER |
| `recovery` | 0x77665502 | PON_RESTART_REASON_RECOVERY |
| `rtc` | 0x77665503 | PON_RESTART_REASON_RTC |
| 普通重启 | 0x77665501 | PON_RESTART_REASON_NORMAL |

---

## 主线缺什么

| 项目 | 状态 |
|---|---|
| IMEM 设备树节点 | ✅ 有：`sram@14680000 { compatible = "qcom,sdm845-imem", "syscon", "simple-mfd"; }` |
| 写 `restart_reason` 的驱动 | ❌ **没有** |
| `0x77665500` 魔数 | ❌ 主线里只在 **HiSilicon** 的板子上出现（那是另一套机制） |

所以主线没有任何代码把重启理由写进 IMEM。

---

## 为什么那次「看起来成功了」

2026-11-22 早先记录过一次 `reboot bootloader` 之后进入 fastboot。后续五次全部失败。

**最可能的解释**：那次同期的镜像启动失败，ABL 自己回落到 fastboot，与 PON 无关。这和「`reboot bootloader` 生效」在观测上无法区分，因为两者都是「重启后进 fastboot」。

---

## 如果要修，方向是什么

需要写一个驱动（或小改动），在重启时把魔数写进 IMEM：

1. 拿到 IMEM 的物理地址（DT 里有 `sram@14680000`）
2. 找到 `restart_reason` 的偏移（下游代码里是一个全局指针，初始化位置需要查）
3. 注册 `restart_handler`，在 `reboot bootloader` 时写 `0x77665500`

**这不是配置能解决的**，需要新代码。考虑到手动按音量减+电源完全够用，优先级不高。

---

## 附带发现

`PON_SOFT_RB_SPARE` 的位定义在驱动里写的是 `GENMASK(7, reason_shift)`，即 pm8998 用位 `[7:1]`。下游注释提到「Bit-2 to bit-7 of SOFT_RB_SPARE for hard reset reason」，即 `[7:2]`——**位范围有出入**，可能是另一个不一致点，但对本问题不关键，因为 ABL 根本不读这个寄存器。
