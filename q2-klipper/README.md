# Vendored Q2 Klipper source

This directory is the vendored [upstream source](https://github.com/cedbossneo/q2-offload)
(commit `b5c8107`, tag `v2026.10.21-beta.1`, the release installed on the live
reference host) bundled with Q2-Mainline-Klipper.

Use the installer in the parent directory:

```bash
cd .. && ./install-klipper.sh
```

Local changes relative to upstream:

- AutoPA and PrintGuard were removed from the install/config/nginx paths.
- The upstream Moonraker self-updater and service were removed.
- Firmware and Katapult deployers are read from `../vendor/` instead of being downloaded.
- The printer script derives the printer user's home from its own location; it is not
  hardcoded to `/home/mks`.
- The printer script has `camera-enable` / `camera-status` for the stock
  `crowsnest` + `nginx` camera.

The top-level [`../README.md`](../README.md) is the authoritative documentation for this
bundle. Upstream docs under `docs/` are kept for recovery and calibration reference.
