# 825 mainboard image (archival)

This is the Klipper image running on the Q2 mainboard since 2026-10-29. It is
byte-identical to the image Katapult verified when it was flashed: both the
SHA-256 and the padded SHA-1 match the values recorded at flash time.

| | |
|---|---|
| Source | offload host `192.168.2.220`, `git archive 526d9769c` |
| Config | `q2-klipper/firmware/configs/main.config` |
| MCU | GD32F425, 200 MHz, `CONFIG_STM32F4_GD32_USB_INIT_WORKAROUND=y` |
| Toolchain | Arm GNU Toolchain 15.3.rel2 |
| Size | 47,736 bytes |
| SHA-256 | `1438d959785147487550130310cbd2e8b5b97a8a984e2a7c580141e022406d63` |
| Padded SHA-1 | `23B11CEAED213BD9FE9191381446DB126C8CEA61` |
| Katapult at flash time | `23B11CEAED213BD9FE9191381446DB126C8CEA61` |

The default `vendor/firmware/q2-main.bin` is still the 824 rollback image. This
directory is not used automatically by the installer or the flash scripts.

## Reproduce

```bash
git archive --format=tar 526d9769c | tar -x -C klipper
cp q2-klipper/firmware/configs/main.config klipper/.config
make -C klipper olddefconfig
# The firmware embeds a build timestamp and hostname (scripts/buildcommands.py).
# Pin them to 20261029_033835 and pikapika before building.
make -C klipper -j"$(nproc)"
```

The version string is `?-20261029_033835-pikapika` because the source was
exported without a `.git` directory.

## Flash

Use the normal Katapult flow from `q2-klipper/docs/recovery.md`. Read that page
first; keep the 824 image at `vendor/firmware/q2-main.bin` as the rollback.
