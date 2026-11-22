# GPU firmware

`a630_sqe.fw` from this device's stock ROM is too old for mainline:

```
adreno 5000000.gpu: [drm:a6xx_ucode_load] *ERROR* a630 SQE ucode is too old.
Have version 187 need at least 190
```

The version is the low 12 bits of the first dword *after the first four bytes*,
because `adreno_fw_create_bo()` copies from `fw->data[4]`:

| source | buf[0] | version | usable |
|---|---|---|---|
| stock ROM (2021) | 0x016ee187 | 0x187 | no |
| linux-firmware   | 0x016ee207 | 0x207 | yes |

Take the newer one from linux-firmware:

    curl -fsSL -o a630_sqe.fw \
      https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/qcom/a630_sqe.fw

Put it where `build.sh` picks it up for the initramfs (`GPU_FW_DIR`, which
defaults to `~/rootfs-trixie-arm64/lib/firmware/qcom`), because msm is built in
and loads it before the root filesystem is mounted.

`a630_gmu.bin` and `a630_zap.mbn` can stay as they are: the GMU blob carries no
version gate, and the zap shader is signed per-device by Xiaomi.
