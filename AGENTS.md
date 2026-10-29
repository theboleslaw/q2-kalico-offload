# Q2-Kalico-Offload — Agent Notes

## Safety (never do these)
- **Never flash firmware to any device.** Build `.bin` files and run `--dry-run`/`--ci` only. Flashing is human-only.
- **Never flash to the wrong device.** MCUs must match:
  - main: `stm32f407xx` GD32F425 200 MHz, offset `0x8008000`, file `q2-main.bin`
  - thr:  `stm32f103xe` GD32F303 120 MHz, offset `0x8002000`, UART `/dev/ttyS4` @ 500000, file `q2-thr.bin`
  - box:  `stm32f401xc` 84 MHz, offset `0x8004000`, file `q2-box.bin`
- Keep Katapult deployers pinned (`DEPLOYER_*` in VERSIONS) — bad ones brick MCUs.

## What this is
Qidi Q2 + Box offload bundle. Host runs **Kalico** (not upstream Klipper) on a Linux machine (.220), printer is .210. Includes Moonraker, Happy Hare, Mainsail, Spoolman, serial proxies, MCU flashing, camera, box drying page, heatguards, offload fixes (Python serial proxies), HelixScreen macros + settings template.

## Key pins (q2-klipper/VERSIONS)
- Kalico: `KalicoCrew/kalico` `bleeding-edge-v2` @ `e0a57a0b` (v2026.07.00-49)
- Happy Hare: `v4.1.0` @ `1ac0303c`
- HelixScreen: `prestonbrown/helixscreen` `v1.0.7` @ `faed4e35`
- Moonraker `9e676eb`, Mainsail `v2.19.0`, Spoolman `v0.27.0`
- Arm toolchain `15.3.rel2`
- Firmware ID: `e0a57a0b5-e4acb12c`

## Patches
- `patches/klipper/` — 20 Kalico patches + `series` manifest (order + method). Reproduces n3oney's published tree.
- `patches/happy-hare/` — 7 patches (4 Q2-Mainline + 3 Kalico-specific).
- `apply_patches()` and `firmware_id()` in `lib.sh` support the `series` manifest.
- Kalico has moved to `42320b3d` but patch 0012 breaks; pin kept.

## Firmware (vendor/firmware/)
- `q2-main/thr/box` `.bin/.dict/.config` + `SHA256SUMS` + `BUILD_INFO`. `.dict` says `"app": "Kalico"`.
- Overclocks: GD32F425 @ 200 MHz, GD32F303 @ 120 MHz.
- `gcode_shell_command` is Kalico built-in — do not fetch from KIAUH.

## Offload (.210 printer / .220 host)
- `optional/offload-fixes/` is byte-identical to original repo. Pure serial forwarding — works unchanged with Kalico.
- Bridges: `q2-serial-bridge@main:7001`, `@thr:7002`, `@mmu:7003`.
- Heatguards + box drying page (`/box/`) included.

## HelixScreen
- Macros in `helix_macros.cfg` (included in `printer.cfg`).
- Settings template at `config/helixscreen/settings.json` (dim/sleep 120s = disable until touch).
- App installed separately on the printer touchscreen.

## Automation
- `.github/workflows/update-upstream.yml`: daily check of Kalico, Happy Hare, HelixScreen. Auto-commits/pushes if safe. Does not rebuild firmware.
- `bump.sh` bumps Moonraker, Katapult, Timelapse, Mainsail-config, Mainsail, Spoolman.

## Not verified
- No end-to-end host install run. No Klipper batch config validation. Treat as "likely works, verify on real hardware."

## Repo
- Private: `theboleslaw/q2-kalico-offload` (master). Commit: "n3oneys Kalico, offload".
- Docs: `q2-klipper/docs/recovery.md`, `docs/calibration.md`, `docs/offload.md`.
