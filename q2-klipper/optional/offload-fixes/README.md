# Optional: offload-mode reliability fixes

These files are **not installed by the default `install-klipper.sh`**. They are
the host-side changes that make repeated offload boots reliable on a Q2:

| File | Installed on | Replaces |
|---|---|---|
| `q2-serial-proxy.py` + `q2-serial-proxy@.service.in` | printer SBC (`192.168.2.210`) | the `socat` serial proxy |
| `q2-pty-bridge.py` + `q2-serial-bridge@.service.in` | offload host (`192.168.2.220`) | the `socat` PTY bridge |
| `q2-mode` | printer SBC | the offload/local boot selector |

`socat` recreates its PTY on every reconnect. Klipper then holds a serial device
that has already disappeared, and the next offload boot fails with
`read failed: device reports readiness to read but returned no data`. The Python
bridge keeps one PTY for the life of the process and reconnects TCP inside it.

The patched `q2-mode` also:

- USB-resets the mainboard and Box MCU before starting offload, which clears the
  intermittent `mcu 'mcu': Unable to connect` hang;
- waits for all three bridge links before restarting the offload Klipper;
- uses `/printer/firmware_restart` instead of a service restart, which also
  clears an MCU left in firmware shutdown.

See `../../docs/offload.md` for the full procedure and verification steps.

Quick start (from a checkout of this repository):

```bash
# on the printer SBC, as root
sudo q2-klipper/optional/offload-fixes/install-printer.sh --with-q2-mode

# on the offload host, as root
sudo q2-klipper/optional/offload-fixes/install-host.sh 192.168.2.210
```

Both installers keep a backup of the file they replace (`*.pre-offload-fixes`).
