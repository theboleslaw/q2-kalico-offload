# Q2-Kalico-Offload: Klipper (Kalico) installer for the Qidi Q2

This folder installs a complete Q2 Klipper stack for a Qidi Q2 + Qidi Box, without
AutoPA, PrintGuard, Fluidd or HelixScreen. It is based on
[Q2-Mainline-Klipper](https://github.com/theboleslaw/Q2-Mainline-Klipper), but the
Klipper source is [Kalico](https://github.com/KalicoCrew/kalico) (bleeding-edge-v2)
with the Q2 patch series from [n3oney/qidi-q2-klipper](https://github.com/n3oney/qidi-q2-klipper):

- Klipper host stack: Kalico (Q2 patched), Moonraker, Happy Hare
- Mainsail web interface and Spoolman (selectable)
- Printer-side serial proxies
- MCU flashing for **mainboard**, **toolhead (THR)** and **Qidi Box (MMU)**
- Stock printer **camera** (`crowsnest` + `nginx`) enabled and verified

Every path and host username is derived from the machine running the installer. Nothing
is hardcoded and no network address is needed: the installer finds the printer by itself.

The pinned Kalico is `bleeding-edge-v2` at `e0a57a0b` (`v2026.07.00-49`, with the 17
Q2 patches on top). Moonraker is `9e676eb`, and the Happy Hare release is `v4.1.0` plus
the Q2-Mainline patches and 3 Kalico-specific Happy Hare patches. The firmware in
`vendor/firmware` is built from exactly that tree with the Arm GNU Toolchain 15.3.Rel2.
AutoPA and PrintGuard stay excluded here.

## Quick start

```bash
git clone https://github.com/theboleslaw/q2-kalico-offload.git Q2-Kalico-Offload
cd Q2-Kalico-Offload
./install-klipper.sh
```

The first command creates the `Q2-Kalico-Offload` folder with the whole bundle in it.

The installer reuses this bundle's saved choices from an earlier run. On a first run it
finds the printer by itself and asks nothing about addresses.

The first run is a full conversion: host software, printer serial proxy, Katapult,
and the three MCU flashes. **Read the flashing warning below first.**

```bash
./install-klipper.sh
```

This installs Kalico, Moonraker, Happy Hare and Mainsail. Spoolman (inventory, runs in Docker)
is optional: add it with `./install-klipper.sh --components mainsail,spoolman`.

Other variants:

```bash
# Host side only: do not touch or flash the printer
./install-klipper.sh --host-only

# Already flashed, just repair host/proxies/camera
./install-klipper.sh --no-flash

# Only flash the three MCUs (after an install)
./install-klipper.sh --flash-only

# Check the bundle and print the plan without installing anything
./install-klipper.sh --dry-run
```

`install-klipper-host.sh` is kept as a compatibility wrapper for `--host-only`.

## What is bundled here

| Path | Contents |
|---|---|
| `install-klipper.sh` | The installer and all orchestration |
| `q2-klipper/` | Vendored Q2 Klipper source: host scripts, printer script, Kalico patches, configs, nginx/systemd units |
| `vendor/firmware/` | Firmware `q2-main.bin`, `q2-thr.bin`, `q2-box.bin` for the pinned Kalico (`e0a57a0b` + Q2 patches), with matching `.dict` files, `SHA256SUMS`, `BUILD_INFO`; see [Firmware](#firmware) |
| `vendor/deployer/` | Pinned Katapult deployers for the first conversion: `mcu-deployer.bin`, `thr-deployer.bin`, `mmu-deployer.bin` |
| `vendor/katapult/flashtool.py` | Pinned Katapult flashtool copied to the printer |
| `vendor/n3oney/` | Upstream Nix build from n3oney/qidi-q2-klipper (provenance, not used by the installer) |
| `q2-klipper/config/helixscreen/` | HelixScreen settings template (dim/sleep-until-touch, dark mode, touch calibration) |
| `BUNDLE_INFO` | Upstream commit, firmware ID and deployer build |

The Q2-specific files and every flash artifact are local: the installer never downloads
firmware, deployers or `flashtool.py`. The host software itself (Kalico, Moonraker, Happy
Hare, Mainsail, Spoolman image, timelapse, mainsail-config) is still fetched from the
versions pinned in `q2-klipper/VERSIONS`; the host therefore needs internet access for
those first-time downloads.

## Options

| Option | Meaning |
|---|---|
| `--components <list>` | `mainsail` (default) or `mainsail,spoolman`; Klipper, Moonraker and Happy Hare are always installed. AutoPA/PrintGuard rejected |
| `--host-only` | Host only; no printer changes, no proxies, no flash, no camera setup |
| `--no-flash` | Configure printer proxies/camera but skip the MCU flash |
| `--flash-only` | Only flash the MCUs with the firmware in `vendor/firmware` and rebuild this host's Kalico to match; needs an earlier install; still asks you to type `FLASH` |
| `--skip-camera` | Do not enable/check the printer camera |
| `--skip-calibration` | Do not offer PID/input-shaper calibration at the end |
| `--build-firmware` | Build MCU firmware locally instead of using `vendor/firmware` |
| `--yes`, `-y` | Yes to plain questions; flashing still requires typing `FLASH` |
| `--dry-run` | Validate bundle/checksums/preflight and print the plan; change nothing |
| `--ci` | Host-software test mode; no systemd/nginx/docker/printer |
| `-h`, `--help` | Show help |

## Installation flow

1. Verify the bundled firmware, deployers and flashtool checksums.
2. Install host packages, Kalico, Moonraker, Happy Hare, the Mainsail web interface and Q2 configs.
3. Copy the printer script, flashtool and firmware to the printer.
4. Back up the printer configuration.
5. On the first conversion, flash the Katapult deployers through Qidi's own update
   scripts, then flash Kalico on all three MCUs.
6. Install the printer serial proxies and the sudo rule for `q2-printer.sh`.
7. Enable and verify the stock camera services (`crowsnest`, `nginx`).
8. Start Kalico/Moonraker on the host, apply UI defaults, optionally calibrate.
9. Verify the serial bridges, Kalico, Moonraker, Mainsail, Spoolman and camera.

At the end the installer prints the web addresses of this machine and the camera.
Mainsail is on port 80 of the Klipper machine (open `http://localhost/` there).

## Camera

The Q2 camera is a USB camera on the printer board. Qidi's stock image serves it through
`crowsnest` and `nginx` at the printer's `/webcam/` path, and the installer checks the
snapshot and stream endpoints for you.

The bundle does not install a second camera stack. It keeps the stock `crowsnest` and
`nginx` services enabled, verifies the snapshot endpoint, and configures Moonraker's
`[webcam q2]` section to point at the printer. Use `--skip-camera` if the printer has no
camera; if the stock camera services are missing, restore Qidi's camera packages/config
and re-run the installer.

## Flashing warning

The first conversion replaces Qidi's bootloader with Katapult. A power cut or interrupted
write during the **Katapult deployer** step can leave an MCU needing an ST-Link. Keep the
printer powered and connected for the whole flash. The installer:

- verifies the bundled firmware/deployer SHA-256 checksums
- verifies Katapult's application offset and MCU type before writing
- flashes one MCU at a time
- asks you to type `INSTALL KATAPULT` (first conversion) and `FLASH` (every flash)

If Katapult is already on the printer from an earlier conversion, the installer skips the
deployers and only asks whether to flash the firmware now. It still asks you to type `FLASH`.

Recovery notes: `q2-klipper/docs/recovery.md`.
Calibration notes: `q2-klipper/docs/calibration.md`.

## HelixScreen (touchscreen UI)

The bundle ships the HelixScreen integration macros (`helix_macros.cfg`, included in
`printer.cfg`) and a settings template at `q2-klipper/config/helixscreen/settings.json`
(dim/sleep after 120 s, dark mode, touch calibration, Asia/Manila timezone). The
HelixScreen app itself is installed separately on the printer's touchscreen:

```bash
# on the printer SBC / touchscreen (example for a K1-class device)
curl -fsSL https://github.com/prestonbrown/helixscreen/releases/latest/download/install.sh | bash
# then copy the template over your settings:
cp q2-klipper/config/helixscreen/settings.json ~/printer_data/config/helixscreen/settings.json
```

The macros are already wired into `PRINT_START`/`PRINT_END`/cancel via `gcode_macro_mmu.cfg`,
so once HelixScreen is installed it integrates automatically. The version pin lives in
`q2-klipper/VERSIONS` (`HELIXSCREEN_RELEASE`) and is checked by the daily
`update-upstream.yml` workflow.

## What is not installed

- AutoPA
- PrintGuard
- Fluidd: Mainsail covers the same role, so only one web interface is installed
- HelixScreen (the printer touchscreen app itself — install separately from prestonbrown/helixscreen; the bundle ships the integration macros in `helix_macros.cfg` and a settings template in `q2-klipper/config/helixscreen/settings.json`)
- The upstream Moonraker self-updater (it could run printer-touching steps)

Update the stack with the update script, or by re-running `install-klipper.sh`. Host units installed are
`klipper.service` and `q2-serial-bridge@main:7001`, `@thr:7002`, `@mmu:7003`.

## Updates

Two scripts, one for each side:

- **Upstream check (this folder, or the repo that hosts it):**
  `q2-klipper/scripts/update-upstream.sh` checks Kalico `bleeding-edge-v2` and the latest Happy Hare
  release, then pins them in `q2-klipper/VERSIONS`. A newer version is only taken when all
  Q2 patches still apply to it; otherwise the old pin is kept and a warning says why.
  `--check` only reports, `--commit` commits, `--push` also pushes to the bundle's `origin`.
- **Klipper machine:** `./update-klipper.sh` (run on the Klipper host). With a bundle repo
  set, it fetches the newest bundle from that repo, then runs `install-klipper.sh update`:
  host software and configs are updated, and the printer boards are compiled and flashed
  only when the pinned Klipper changed (it asks first). Set the repo once with
  `./update-klipper.sh --repo <git-url>`; `--local` uses the folder it runs from.

If this folder is pushed to your GitHub repo, `.github/workflows/update-upstream.yml` runs
the upstream check every day and commits the pins automatically when something changed.
A Klipper bump changes the firmware ID. The update check does not rebuild `vendor/firmware`,
so after a bump the firmware must be rebuilt and committed (see [Firmware](#firmware)); until
then the Klipper machine builds the matching firmware itself (about 10 minutes, needs internet).

## Firmware

| Build | Klipper | Toolchain | Where it is used |
|---|---|---|---|
| `vendor/firmware` (shipped) | `e0a57a0b` + Q2 patches, `q2-kalico-e0a57a0b5` | Arm GNU Toolchain 15.3.Rel2 (GCC 15.3) | used when its firmware ID matches the pin; built from the Kalico tree with the Q2 patch series |

The installer compares the firmware ID before flashing. When they differ it warns, then
builds the pinned firmware on the Klipper machine (or downloads a published release of the
same ID). Nothing is flashed without typing `FLASH`.

To see which firmware a printer runs, read the MCU versions from Moonraker:

```bash
curl -s "http://<klipper-machine>:7125/printer/objects/query?mcu&mcu%20unit0&mcu%20THR"
```

`mcu` is the mainboard, `mcu unit0` the Box/MMU and `mcu THR` the toolhead. The
`mcu_version` must match the firmware being installed on all three MCUs.

## Troubleshooting

```bash
# Host services
systemctl status klipper moonraker
systemctl status 'q2-serial-bridge@*'

# Installed state and printer status (the installer checks the printer for you)
./install-klipper.sh status
./install-klipper.sh check
```

The printer user is the stock `mks`, and its home directory is read from the printer, so
nothing in the bundle depends on the host username.
