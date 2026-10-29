# Vendored Q2 Klipper source

This directory is the vendored Q2 Klipper source bundled with Q2-Kalico-Offload.
The host Klipper is Kalico (KalicoCrew/kalico, `bleeding-edge-v2` at
`e0a57a0b55c65d8b9112c812a01bd32f88476618`) plus the Q2 patch series in
`patches/klipper/` (from n3oney/qidi-q2-klipper).

Use the installer in the parent directory:

```bash
cd .. && ./install-klipper.sh
```

Local changes relative to the upstream Q2-Mainline bundle:

- Klipper source is Kalico instead of upstream Klipper.
- The `gcode_shell_command` extension is not fetched (Kalico ships it).
- Firmware and Katapult deployers are read from `../vendor/` instead of being downloaded.
- The printer script derives the printer user's home from its own location.

The top-level [`../README.md`](../README.md) is the authoritative documentation for this
bundle. Upstream docs under `docs/` are kept for recovery and calibration reference.
