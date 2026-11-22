# 交接文档 · WiFi 追查进展（2026-11-22 15:45 追加）

> 本节接在 `docs/HANDOFF.md` 第 5 节之后。上一位接手者把方向纠正为「WLAN 固件跑在 modem 上」，**这个方向是对的，已经验证**。下面是按那条路线执行到哪一步、以及下一刀该切在哪。

---

## 已验证成立的部分

### 1. modem 固件安装（对方路线 ①，已做）

从 `stock-rom/.../images/modem.img`（FAT16，可 `mount -o loop,ro`）提取到
`/lib/firmware/qcom/sdm845/mi8/`：

- `mba.mbn`
- `modem.mbn`（`modem.mdt` 复制改名，驱动只换末 3 个字符）
- `modem.b00`~`modem.b28`，共 **27 个**分段
- `modemr.jsn`、`modemuw.jsn`

**注意**：`modem.b14` 和 `modem.b19` 不存在，但**源镜像里本来就没有**，不是提取遗漏。

### 2. modem 启动（对方路线 ②，已做）

`remoteproc0` 是 modem（`4080000.remoteproc`，`compatible = "qcom,sdm845-mss-pil"`）。
它的 `name` 是平台设备名，**不包含 "mss"/"modem" 字样**，所以按名字匹配会漏掉。已改为同时匹配
`device/of_node/compatible` 里的 `mss-pil`。

启动日志：

```
qcom-q6v5-mss 4080000.remoteproc: MBA booted without debug policy, loading mpss
remoteproc remoteproc0: remote processor 4080000.remoteproc is now up
```

### 3. ath10k 与 modem 的耦合（对方路线 ③，已确认）

```
ath10k_snoc 18800000.wifi: received modem running event
ath10k_snoc 18800000.wifi: received modem crashed event
ath10k_snoc 18800000.wifi: received modem offline event
```

ath10k 完全跟随 modem 状态。**「WLAN 固件跑在 modem 上」这个判断被证实了。**

### 4. 崩溃循环已消除

modem 启动后原本每 **43 秒**崩溃一次（`fatal error without message`，共崩了 14 次）。
装上 `rmtfs` 和 `pd-mapper` 之后 **崩溃计数归零**。

---

## 新发现的阻塞点

### rmtfs 不认识 modem 请求的分区名

`rmtfs` 正常运行，并且**确实收到了 modem 的请求**——整条链路是通的：

```
rmtfs[410]: [RMTFS storage] request for unknown partition '/boot/modem_fsg_oem_1', rejecting
rmtfs[410]: [RMTFS storage] request for unknown partition '/boot/modem_fsg_oem_2', rejecting
```

问题在于 `rmtfs` 里有一张**编译进去的已知分区表**，只有这些名字会被解析：

```
/boot/modem_fs1     /boot/modem_fs2
/boot/modem_fsc     /boot/modem_fsg
/boot/modem_tunning /boot/modem_tng
/boot               ← 默认目录
```

modem 请求的是 `modem_fsg_oem_1` / `modem_fsg_oem_2`——**不在表里，直接拒绝**。
建符号链接没用，拒绝发生在名字查表阶段，不是文件存在性检查。

（Deiban 的 `rmtfs` 是 `pool/main/r/rmtfs/rmtfs_1.1-4_arm64.deb`，依赖 `libqrtr1`。）

---

## 下一刀该切在哪

1. **查清 `modem_fsg_oem_1` / `_2` 到底是什么。** 可能的方向：
   - 看原厂 Android 上这些名字对应哪个分区（`/vendor/etc/init/hw/init.qcom.rc` 里可能有线索）
   - 或者它们其实是 `fsg`/`fsc` 的别名，需要给 rmtfs 补上映射
   - 反汇编 `rmtfs` 或找带 OEM 分区的 rmtfs 版本
2. **可能需要 patch rmtfs** 加两张映射。源码：<https://github.com/linux-msm/rmtfs>
3. rmtfs 表里已有的名字，可以先把 `/boot` 下的符号链接建好（已经建了，但当前没有请求用到它们）：
   ```
   /boot/modem_fsg -> /dev/disk/by-partlabel/fsg
   /boot/modem_fsc -> /dev/disk/by-partlabel/fsc
   /boot/modem_fs1 -> /dev/disk/by-partlabel/modemst1
   /boot/modem_fs2 -> /dev/disk/by-partlabel/modemst2
   ```
4. rmtfs 通了之后，再看 ath10k 能否收到 WLFW QMI 服务。

---

## 当前系统状态（2026-11-22 15:45）

| 组件 | 状态 |
|---|---|
| systemd / Debian 13 | ✅ running |
| UFS、显示控制器、USB 串口 | ✅ |
| ADSP | ✅ running（`adsp-start.service`） |
| **modem** | ✅ running，**不再崩溃**（`modem-start.service`） |
| rmtfs / pd-mapper | ✅ active（`rmtfs.service`、`pd-mapper.service`） |
| **WiFi** | ❌ 无 `wlan0`，ath10k 静默等 WLFW |

已启用的服务清单：

```
adsp-start.service    modem-start.service
rmtfs.service         pd-mapper.service
serial-getty@ttyGS0   systemd-networkd
```

---

## 操作备忘

### 从 Linux 进 fastboot（已验证）

```sh
reboot bootloader      # 约 4 秒后主机出现 Android Bootloader Interface
```

### 刷完 rootfs 后必须重启 modem 才会重新发起 rmtfs 请求

```sh
echo stop  > /sys/class/remoteproc/remoteproc0/state
echo start > /sys/class/remoteproc/remoteproc0/state
```

### 注意内核 lockdown

`CONFIG_SECURITY_LOCKDOWN_LSM` 处于启用状态，**debugfs 读不了**：

```
Lockdown: cat: debugfs access is restricted; see man kernel_lockdown.7
```

所以 `/sys/kernel/debug/remoteproc/*/crash` 之类拿不到内容。如果后续要用 debugfs 诊断，需要先关掉 lockdown。

### 设备上的分区标签（可用）

```
fsg      -> sde36      fsc      -> sdf1
modem    -> sde46      modemst1 -> sdf6      modemst2 -> sdf7
```
