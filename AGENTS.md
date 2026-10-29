# Q2-Kalico-Offload — Agent Orientation

This bundle installs a Qidi Q2 + Qidi Box stack: **Kalico** (not upstream
Klipper) on a dedicated Linux host, with Moonraker, Happy Hare, Mainsail,
Spoolman, serial proxies, MCU flashing, and a stock camera. Based on
`theboleslaw/Q2-Mainline-Klipper`, with Kalico contents from
`n3oney/qidi-q2-klipper`.

## Critical safety rules

- **Never flash firmware to any device.** Flashing is destructive and
  human-only. The agent may build `.bin` files and run `--dry-run`/`--ci`,
  but must never execute `printer_convert`, `cmd_flash`, `flashtool -f`,
  or any write to an MCU. The installer asks the user to type `FLASH` /
  `INSTALL KATAPULT` for a reason.
- **Never flash to the wrong device.** MCU types and offsets must match:
  - main: `stm32f407xx` (GD32F425, 200 MHz), offset `0x8008000`, file `q2-main.bin`
  - thr:  `stm32f103xe` (GD32F303, 120 MHz), offset `0x8002000`, UART `/dev/ttyS4` @ 500000 baud, file `q2-thr.bin`
  - box:  `stm32f401xc` (84 MHz), offset `0x8004000`, file `q2-box.bin`
  - The printer script's `cmd_flash` verifies the dict's `"MCU"` field before writing.
- Keep the Katapult deployers pinned (`DEPLOYER_*` in VERSIONS) — a bad one
  bricks an MCU. They only change by hand.

## Pinned versions (q2-klipper/VERSIONS)

- Klipper source is actually **Kalico**: `KalicoCrew/kalico`, branch
  `bleeding-edge-v2`, ref `e0a57a0b55c65d8b9112c812a01bd32f88476618`
  (v2026.07.00-49). Do not bump without re-verifying the patch series.
- Happy Hare: `moggieuk/Happy-Hare`, release `v4.1.0`, ref
  `1ac0303c6f83c09f4ae8254dbebf8b4128e637c5`.
- HelixScreen: `prestonbrown/helixscreen`, release `v1.0.7`, ref
  `faed4e35010e970ba5612e9b2e109c52a11965a6`.
- Moonraker `9e676eba…`, Mainsail `v2.19.0`, Spoolman `v0.27.0`.
- Arm toolchain `15.3.rel2`, SHA `463df966…`.
- Firmware ID: `e0a57a0b5-e4acb12c`.

## Patch series

- `q2-klipper/patches/klipper/` has a `series` manifest driving order and
  method (`git-apply` vs `patch -p1` with fuzz). 20 patches total. The
  Kalico tree after applying them is byte-identical to n3oney's published
  `kalico-bleeding-edge` branch (except `firmwares/` and `.github/`).
- `q2-klipper/patches/happy-hare/` has 7 patches (4 from Q2-Mainline + 3
  Kalico-specific from n3oney).
- `apply_patches()` in `lib.sh` supports both the `series` manifest and a
  plain `*.patch` glob (used for Happy Hare). Do not break that fallback.

## Key facts about Kalico vs upstream Klipper

- Kalico ships `klippy/extras/gcode_shell_command.py` — do NOT fetch it from
  KIAUH (that pin was removed). `host_extensions()` verifies it exists.
- Kalico's `klippy-requirements.txt` adds `msgspec`.
- `[load_cell_probe]` with `sensor_type: cs1237` is supported by Kalico's
  load-cell implementation; `reference_tare_counts` is added by the
  installer's calibration step.
- Overclocks: GD32F425 @ 200 MHz (`CONFIG_STM32F4_GD32F425_200MHZ=y` +
  USB init workaround), GD32F303 @ 120 MHz (`MACH_GD32F303_Q2`).

## Firmware

- Built firmware lives in `vendor/firmware/` (`q2-main/thr/box` `.bin/.dict/.config`
  + `SHA256SUMS` + `BUILD_INFO`). `.dict` files report `"app": "Kalico"`.
- `firmware_id()` hashes firmware-relevant patches (those touching `src/` or
  `scripts/`) + configs. Host-only patches must not trigger reflash.
- `build-firmware.sh` sets `KALICO_BUILD_VERSION=q2-kalico-${KLIPPER_REF:0:9}`
  and checks offsets. Rebuild with `--build-firmware` if IDs diverge.

## Offload setup (.210 printer / .220 host)

- `optional/offload-fixes/` is byte-identical to the original Q2-Mainline
  bundle: Python serial proxies, `q2-mode`, install scripts. Pure byte
  forwarding — works unchanged with Kalico.
- Standard bridges: `q2-serial-bridge@main:7001`, `@thr:7002`, `@mmu:7003`.
- Heatguards: `chamber_heater_guard.cfg`, `mmu/mmu_box_keep_dry_heat_guard.cfg`
  (both included in `printer.cfg`).
- Box drying page served at `/box/` via nginx alias.

## HelixScreen

- Macros in `helix_macros.cfg` (v2.1.0) are included in `printer.cfg`.
- Settings template at `config/helixscreen/settings.json` (dim/sleep 120 s =
  screen dims/sleeps until touch).
- The app itself is installed separately on the printer touchscreen.

## Automation

- `.github/workflows/update-upstream.yml` runs daily (05:17 UTC) + manual
  trigger. Checks Kalico, Happy Hare, HelixScreen; bumps pins only when all
  patches still apply; auto-commits + pushes. Does NOT rebuild
  `vendor/firmware/` (host builds matching firmware if IDs diverge).
- `bump.sh` bumps Moonraker, Katapult, Timelapse, Mainsail-config, Mainsail,
  Spoolman pins (patch-free components).

## Upstream status (as of last check)

- Kalico bleeding-edge-v2 has moved to `42320b3d` (v2026.07.00-53) but
  patch `0012-motion-queuing-steppersync` no longer applies (ruff reformatting).
  Pin kept at `e0a57a0b` until patch 0012 is re-ported.
- Happy Hare, HelixScreen, Mainsail, Spoolman are at their latest releases.

## Things to remember

- Never flash; never push to the printer. Dry-run and `--ci` only.
- The repo is private: `theboleslaw/q2-kalico-offload` (master branch).
- `printer.cfg` includes `q2_kalico_helpers.cfg` (renamed from
  `q2_mainline_helpers.cfg`).
- `gcode_shell_command` is Kalico built-in — do not re-add KIAUH.
- Config validation (`klippy.py` batch mode) has NOT been run; a real
  `--ci` host install is the next safe verification step.
- Recovery docs: `q2-klipper/docs/recovery.md`. Calibration:
  `q2-klipper/docs/calibration.md`.
