# 小米 8 Pro（equuleus）主线 Linux 移植

[English](README.md) · **简体中文**

在小米 8 Pro（`equuleus`，M1807E8A，骁龙 845）上运行 Debian 13（trixie）
arm64 与 systemd。测试机的 AMOLED 屏幕物理损坏，因此这个移植从一开始就按
「无屏可用」来做：USB CDC-ACM 串口控制台加自动 root 登录，再配合 USB NCM
网络，就足以安装、调试和日常使用。

CI 用原版 Linux `v7.1-rc1` 内核树、`dts/` 里的板级设备树、
`kernel/tree-delta/` 中主线缺失的源码，以及三星 EA8074 面板驱动，构建启动
镜像和根文件系统镜像。推送 `v*` 标签会把两个产物发布到 release。

## 当前状态一览

下表除特别说明外，均在测试真机上验证过。完整日志、测量数据与失败模式见
[状态文档](docs/STATUS.md)。

| 子系统 | 状态 | 依据 |
|---|---|---|
| 启动、存储、CPU | 可用 | 8 核、6 个 UFS LUN、Debian 装在 `userdata`；已稳定运行，不再出现早期每 27 秒重启 |
| USB 控制台 | 可用 | `ttyGS0` CDC-ACM，自动 root 登录 |
| USB 网络 | 可用 | 开机自动配置 NCM `192.168.42.1/24`，主机可经 IPv6 访问 |
| USB-C 主机（OTG） | 可用 | 5 V 供电、限流 500 mA；U 盘三次插入均以高速枚举 |
| Wi-Fi | 可用 | 5 GHz 约 66 Mb/s，短 ping 零丢包 |
| Wi-Fi 热点 | 可用，默认不启动 | `hotspot start wifi` 或 `hotspot start mobile` |
| 蓝牙 | 可用 | `hci0` 正常出现并能扫描到周边设备 |
| 蜂窝基带 | 部分可用 | 短信与 IPv4 数据可用；IPv6 数据需要主线尚未实现的 IPA 路由规则；通话未测试 |
| GPU | 可用（有条件） | Freedreno FD630 与 Turnip Vulkan 1.3，需放宽一处 SQE 固件校验 |
| 视频编解码（Venus） | 节点已验证 | 编码/解码节点与格式符合预期；未做吞吐量基准 |
| 音频 | 可用 | TAS2557 扬声器与 AMIC3 麦克风 |
| 振动 | 可用 | PMI8998 触觉驱动，支持力度反馈 |
| 电池、充电、时钟 | 可用 | PMI8998 电量计与 SMB2 充电器；联网后由 `systemd-timesyncd` 校时 |
| 白色通知灯 | 可用 | PMIC 硬件呼吸灯图案 |
| 后摄手电筒 | 实验性 | 有亮度接口，但 PMIC 报灯路故障，实测未见出光 |
| NFC | 部分可用 | PN553 可绑定并应答 NCI；读卡与用户态协议栈仍缺 |
| 触摸屏 | 未启用 | 节点存在，供电未验证 |
| 显示面板 | 本机不可用 | DSI PLL 无法锁定，且 AMOLED 已损坏 |
| 后置主摄 | 不可用 | IMX363 在 CCI 总线上探测超时，仍在排查 |
| GNSS | 进行中，未合并 | 独立 Broadcom BCM47755 方案位于 `bcm47755-gnss` 分支 |

## 安装 release

从同一个 [GitHub release](https://github.com/minghao680/equuleus-mainline/releases)
下载 `boot.img` 与 `rootfs.ext4.gz`。

刷机需要已解锁的 `equuleus` bootloader，并且会**清空 userdata**。请先备份
手机上需要的数据，包括已保存的 NetworkManager 配置。用「音量减 + 电源」
进入 fastboot，确认型号后再操作，并把下面的 `SERIAL` 换成你自己的序列号。

```bash
gunzip -k rootfs.ext4.gz
fastboot devices
fastboot -s SERIAL getvar product
# 确认 product 是 equuleus 再继续刷写。
fastboot -s SERIAL flash boot boot.img
fastboot -s SERIAL flash userdata rootfs.ext4
fastboot -s SERIAL reboot
```

在主机上以 115200 波特率打开 USB 串口。initramfs 会准备好 CDC-ACM 串口，
挂载 UFS 的 `userdata` 分区并切换到 systemd。启动镜像可以在内核命令行用
`root=UUID=<uuid>` 指定 UFS 上某个 ext4 文件系统；不指定时，initramfs 会
回退到 UFS 中名为 `userdata` 的分区。若在 USB 从模式下根文件系统挂载失败，
initramfs 会通过 USB 提供一个 shell。

发布镜像内是 4 GiB 的 ext4 文件系统，首次启动时由 `fstab` 里的
`x-systemd.growfs` 扩展到整个 userdata 分区。用 `df -h /` 确认结果。对于
较早安装的系统，先用 `findmnt -no SOURCE,FSTYPE /` 确认 `/` 是 userdata 上
的 ext4，再用 `resize2fs /dev/sda21` 扩容。

## 安装之后

在 USB 控制台运行 `nmtui` 选择 Wi-Fi 并保存配置。NetworkManager 会自动连接
已保存且启用 autoconnect 的网络。有多个网络时，用
`connection.autoconnect-priority` 指定优先级。新镜像默认没有任何 Wi-Fi 配置。

```bash
nmtui
nmcli device status
# 可选。把 PROFILE 换成已保存的配置名。
nmcli connection modify PROFILE connection.autoconnect yes connection.autoconnect-priority 10
```

手机拿到可路由 IP 后即可使用 SSH。镜像允许 root 密码登录，因为 USB 控制台是
唯一的另一种进入方式。可以在控制台用 `passwd` 设置密码，或把公钥写入
`/root/.ssh/authorized_keys`。SSH 首次启动时会生成手机自己的主机密钥。

音频需要一个混音开关，`audio-defaults.service` 在开机时已自动设置：

```bash
amixer -c 0 sget 'QUAT_MI2S_RX Audio Mixer MultiMedia1'   # 播放
aplay -D plughw:0,0 /path/to/file.wav
```

这会把 MultiMedia 前端接到 TAS2557 功放。SLIMBUS 播放后端保持关闭：启用它会让
prepare 阶段返回 `-EINVAL`，扬声器通路反而没有声音。

录音由同一个服务启用，但走**另一个**前端，因为一个前端不能同时承担两个方向：

```bash
arecord -D hw:0,1 -f S16_LE -r 48000 -c 2 -d 5 rec.wav   # AMIC3 麦克风
```

麦克风是 **ADC3** 上的模拟输入（`AMIC3 -> ADC3 -> DEC0 -> CDC_IF TX0 ->
AIF1_CAP`）；DMIC 通路录到的是静音，ADC1/ADC2 是悬空输入。有两处混音陷阱会
让配置错误看起来像硬件损坏，详见[状态文档](docs/STATUS.md)。

PMI8998 的触觉模块驱动振动马达并支持力度反馈，无需用户态配置。

白色通知灯支持硬件呼吸灯图案。后摄手电筒有实验性亮度控制，默认关闭。具体命令
与当前测试边界见[灯控说明](docs/LEDS.md)。

用 `bluetoothctl show` 和 `bluetoothctl --timeout 12 scan on` 检查蓝牙控制器。
开机服务会从手机读取出厂地址，并在 BlueZ 启动前通过内核管理接口写入。细节见
[蓝牙调试记录](docs/bluetooth-complete.md)。

### Wi-Fi 热点（可选，默认关闭）

镜像包含 `hostapd`、`dnsmasq` 和辅助脚本，但开机不会启动热点：

```bash
hotspot start wifi     # 共享手机当前使用的 Wi-Fi
hotspot start mobile   # 共享基带的 IPv4 数据
hotspot status
hotspot stop
```

客户端连接 `Equuleus-AP`，密码 `equuleus1234`，从 `192.168.50.10-100` 获取
地址。修改 `/etc/equuleus/hotspot.conf` 可以改 SSID 和密码。

使用前需要知道的几点：

* AP 建在第二个接口（`ap0`）上，且必须与 Wi-Fi 客户端连接处于**同一信道**。
  WCN3990 固件只允许同信道 STA+AP 并发，5 GHz 下还需要在 hostapd 配置里加
  `ieee80211ac=1`；辅助脚本两者都已处理。
* 因为 AP 与上行共用射频，开热点时吞吐大约减半。
* `hotspot start mobile` 需要已激活的 IPv4 承载。它会安装一条策略路由
  （`192.168.50.0/24` 走表 200），让客户端流量从基带而不是 Wi-Fi 上行出去，
  并补上基带网关的直连路由；缺了这条，内核会认为默认路由不可达。
* `hotspot stop` 会再次移除接口、策略路由、NAT 规则和 dnsmasq 片段，保证
  热点关闭时 `dnsmasq` 仍正常工作。

### 根文件系统内容

根文件系统使用 Debian 标准软件集，参考 Debian 13 Live standard 与 ARM64
generic 镜像清单。
[Live standard 软件包](https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-13.8.0-amd64-standard.iso.packages)
· [ARM64 generic 软件包](https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.json)

| 用途 | 包含的命令 |
|---|---|
| 硬件与进程 | `lsusb`、`lspci`、`lshw`、`htop`、`lsof`、`strace`、`iostat`、`pidstat`、`inotifywait` |
| 网络 | `nmtui`、`ssh`、`curl`、`wget`、`dig`、`nc`、`socat`、`arping`、`tracepath`、`traceroute`、`mtr`、`tcpdump`、`iperf3` |
| 存储与传输 | `lsblk`、`findmnt`、`fdisk`、`parted`、`gdisk`、`ncdu`、`rsync`、`mkfs.vfat`、`mkfs.exfat`、`mdir` |
| 压缩与归档 | `tar`、`gzip`、`bzip2`、`xz`、`zip`、`unzip`、`lz4`、`zstd`、`pv` |
| 终端与脚本 | `sudo`、`vim`、`git`、`rg`、`fdfind`、`screen`、`tmux`、`bc`、`gawk`、`jq`、`python3 -m venv` |

镜像还包含 BlueZ、ALSA 工具、Docker 和 Mesa Vulkan 栈。已生成
`zh_CN.UTF-8` 并在 `/etc/locale.conf` 中设为默认，Debian 提供中文手册页的
命令也一并包含。可用 `locale` 检查当前会话的设置。

### 运行时调优

以下单元均已安装，表内注明各自的启动方式；可调参数位于 `config/`，安装后放在
`/etc/equuleus/`。

| 单元 | 作用 |
|---|---|
| `cpu-boost.service` | 大核运行在 2.8032 GHz 加速档，服务单线程负载 |
| `perf-tuning.service` | 延迟与存储相关调优 |
| `zram-swap.service` | zstd 压缩的 zram 交换 |
| `wifi-bdf.service` | 从手机自身 modem 分区提取板级数据文件 |
| `usb-ncm.service` | 开机及每次 UDC 事件后自动配置 NCM；由 udev 规则拉起，单元本身是 static 而非 enable |
| `venus-fw.service` | 从手机提取签名的 Venus 固件并重新探测编解码器 |
| `audio-defaults.service` | 应用播放与录音所需的混音路由 |

TCP 拥塞控制使用 BBR，队列规则为 `fq`。细节与实测数据见
[状态文档](docs/STATUS.md)。

## 本地构建

### 启动镜像

准备一棵 Linux `v7.1-rc1` 内核树、一个静态 arm64 BusyBox，以及带有
`gcc-aarch64-linux-gnu`、`mkbootimg`、`cpio`、`python3` 的主机。把
`GPU_FW_DIR` 指向已准备好的高通固件。SQE 需要较新的 linux-firmware 版本，
2021 年的原厂固件对主线来说太旧。详见
[Adreno 固件](docs/gpu-firmware.md)。

```bash
export KERNEL_SRC="$HOME/linux-sdm845"
export BUSYBOX=/path/to/static/arm64/busybox
export GPU_FW_DIR="$ROOT/lib/firmware/qcom"
scripts/build.sh
python3 scripts/verify-image.py out/boot.img
```

ABL 要求 DTB 紧接在内核 gzip 流之后；否则 `pack-bootimg.sh` 会拒绝产出镜像。
启动镜像还携带必须在 systemd 启动前就绪的固件：GPU 固件、
`tas2557_uCDSP.bin`、蓝牙补丁与 NVM，以及 IPA 固件。

### 根文件系统

准备一台装有 `mmdebstrap`、`arch-test`、已注册的 `qemu-aarch64-static`、
`e2fsprogs`、`simg2img`、`cpio`、`gzip`、`python3` 的 Linux 主机。安装软件包
和 loop 挂载需要 root 或免密 sudo。

```bash
export ROOT="$HOME/rootfs-arm64"
export ROM_DIR=/path/to/extracted/fastboot-rom/images

BUILD_IMAGE=0 scripts/build-rootfs.sh
scripts/prepare-firmware.sh
scripts/make-rootfs-image.sh
scripts/verify-rootfs-image.sh
```

`ROM_DIR` 中应包含原厂固件里的 `modem.img`、`vendor.img` 和
`bluetooth.img`。不加 `BUILD_IMAGE=0` 运行 `scripts/build-rootfs.sh` 会直接
从已准备的用户空间生成 ext4 镜像。两条路径在 `ROOT` 已存在时都会复用，因此
需要干净镜像时请使用新目录。

### CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) 在每次推送时构建
`boot.img` 与 `rootfs.ext4`，检查启动镜像布局，并检查打包后的 ext4 中的已安装
软件包、共享库、固件和生成的 locale。固件在构建时从小米自己的 CDN 提取，不存放
在本仓库中。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `dts/` | 板级设备树 `sdm845-xiaomi-equuleus.dts` |
| `config/` | 该设备使用的内核配置 |
| `kernel/tree-delta/` | 主线缺失、构建时覆盖进去的源码 |
| `kernel/panel-samsung-ea8074.c` | 面板驱动 |
| `kernel/patches/` | 可小范围重基于内核树之上的补丁 |
| `initramfs/` | initramfs 的 `init` 脚本 |
| `systemd/` | 安装进根文件系统的单元、udev 规则和辅助脚本 |
| `scripts/` | 构建、固件、校验与调试脚本 |
| `docs/` | 调试记录与状态 |
| `out/` | 构建输出（Git 忽略） |

## 文档

| 文档 | 主题 |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | 完整调试记录，含测量数据与失败模式 |
| [docs/LEDS.md](docs/LEDS.md) | 白色通知灯与实验性后摄手电筒 |
| [docs/gpu-firmware.md](docs/gpu-firmware.md) | 为何不能使用原厂 SQE 固件 |
| [docs/bluetooth-complete.md](docs/bluetooth-complete.md) | 蓝牙地址与固件处理 |
| [docs/reboot-bootloader-analysis.md](docs/reboot-bootloader-analysis.md) | `reboot bootloader` 如何进入 fastboot |
| [docs/HANDOFF.md](docs/HANDOFF.md) | 移植交接说明 |

## 致谢

思路参考 Mechres 在小米 8（`dipper`）上的主线移植，并建立在 SDM845 主线社区
的驱动与设备树之上。
[Mechres 的仓库](https://github.com/Mechres/xiaomi-mi8-dipper)

## 许可

GPL-2.0。[许可证](LICENSE)
