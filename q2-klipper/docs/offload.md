# Offload mode (optional)

Offload mode runs Klipper on a second SBC instead of on the printer board:

```
printer SBC (192.168.2.210)                 offload host (192.168.2.220)
  q2-serial-proxy@main  :7001  <-- TCP -->  q2-serial-bridge@main:7001 -> pty
  q2-serial-proxy@thr   :7002  <-- TCP -->  q2-serial-bridge@thr:7002  -> pty
  q2-serial-proxy@mmu   :7003  <-- TCP -->  q2-serial-bridge@mmu:7003  -> pty
                                            klipper + moonraker
```

The default install is **local**: Klipper runs on the printer SBC and no serial
proxies are used. The changes in `optional/offload-fixes/` are for printers that
switch between local and offload, and are not installed by `install-klipper.sh`.

## Why these changes are needed

The stock offload setup uses `socat` on both sides. `socat` recreates its PTY
every time the TCP connection is re-established. Klipper keeps the old serial
device open and the next offload boot fails with:

```
Internal error during connect: read failed: device reports readiness to read
but returned no data
```

The optional package replaces that chain with two small Python programs:

- `q2-serial-proxy.py` opens the MCU serial device once and keeps it open while
  clients reconnect.
- `q2-pty-bridge.py` creates one PTY per MCU and keeps it for the life of the
  process, reconnecting TCP internally. Klipper never sees the PTY disappear.

It also installs a patched `q2-mode` that:

- USB-resets the mainboard and Box MCU before offload start-up (the mainboard
  can otherwise enumerate but never answer `identify`);
- waits until all three bridges are connected before restarting the offload
  Klipper;
- uses `/printer/firmware_restart` rather than a service restart, which also
  clears an MCU left in firmware shutdown (`Can not update MCU 'unit0' config
  as it is shutdown`).

## Install

Prerequisites: the main install is already done, both hosts are reachable over
SSH, and the printer is idle.

1. Copy this repository (or at least `q2-klipper/optional/offload-fixes/`) to
   the printer SBC, then install the printer side as root:

   ```bash
   sudo q2-klipper/optional/offload-fixes/install-printer.sh --with-q2-mode
   ```

   `--with-q2-mode` replaces `/usr/local/sbin/q2-mode`. Omit it if you manage
   the boot selector yourself.

2. On the offload host, install the bridge (run as root):

   ```bash
   sudo q2-klipper/optional/offload-fixes/install-host.sh 192.168.2.210
   ```

   Use `--user USER` if Klipper does not run as `cloud` (the default is
   `$SUDO_USER`, then `cloud`). The installer restarts the three bridges and
   requests a Moonraker firmware restart.

3. Enable offload for the next boot on the printer SBC:

   ```bash
   sudo sed -i 's/^MODE=.*/MODE=offload/' /etc/q2-mode.conf
   sudo reboot
   ```

   Only `offload` and `local` are supported in `/etc/q2-mode.conf`.

## Verify

On the printer SBC:

```bash
systemctl is-active q2-serial-proxy@main q2-serial-proxy@thr q2-serial-proxy@mmu
ss -tn | grep -E ':700[123]'      # three ESTAB links to 192.168.2.220
```

On the offload host:

```bash
systemctl is-active 'q2-serial-bridge@main:7001' \
                    'q2-serial-bridge@thr:7002' \
                    'q2-serial-bridge@mmu:7003'
ls -l ~/printer_data/comms/q2-*
curl -s http://127.0.0.1:7125/printer/info
curl -s 'http://127.0.0.1:7125/printer/objects/query?mcu&mcu%20THR&mcu%20unit0'
```

`printer/info` should report `ready`, and all three objects should return an
`mcu_version`. The Klipper log should contain no `read failed` or
`Lost communication with MCU` lines after the last `Start printer at`.

## Measured result on a Q2

| Check | Before | After |
|---|---|---|
| Local reactor stalls | ~255/min at 0.21 s | ~4/min at 0.14 s, none from `DelayedGcode` |
| Offload reactor stalls | — | 0 in 467 s |
| Offload boot after printer reboot | failed, needed a manual restart | `ready` in about 70 s, all three MCUs |
| Offload host reboot | PTY recreated, Klipper lost the link | `ready` in about 5 s |

## Rollback

Every installer keeps the replaced file next to it as
`*.pre-offload-fixes`:

```bash
sudo mv /etc/systemd/system/q2-serial-proxy@.service{.pre-offload-fixes,}
sudo mv /usr/local/sbin/q2-mode{.pre-offload-fixes,}        # if installed
sudo systemctl daemon-reload
```

On the offload host:

```bash
sudo mv /etc/systemd/system/q2-serial-bridge@.service{.pre-offload-fixes,}
sudo systemctl daemon-reload
sudo systemctl restart 'q2-serial-bridge@main:7001' \
                      'q2-serial-bridge@thr:7002' \
                      'q2-serial-bridge@mmu:7003'
```

Finally set `MODE=local` in `/etc/q2-mode.conf` and reboot the printer. The
original `socat` units are then used again.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `read failed: ... returned no data` after a boot | the `socat` bridge is still installed | check `systemctl cat 'q2-serial-bridge@main:7001'`; re-run `install-host.sh` |
| `mcu 'mcu': Unable to connect` on offload boot | mainboard USB endpoint hung | `q2-mode` should reset it; verify `/usr/local/sbin/q2-reset-mcus` exists and is executable |
| `Can not update MCU 'unit0' config as it is shutdown` | an MCU was left in firmware shutdown | `curl -X POST http://<host>:7125/printer/firmware_restart` |
| links are up but Klipper is not ready | Klipper started before a bridge | restart Klipper; `q2-mode` now waits and retries once |
| `MODE=auto` in the config | unsupported value | use `offload` or `local` |
