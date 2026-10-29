#!/usr/bin/env bash
# Install the optional offload-host half of the reliability fixes.
# Run on the offload host (the SBC that runs Klipper for offload mode) as root.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printer_ip=192.168.2.210
klipper_user="${SUDO_USER:-cloud}"
restart=1
moonraker_url="${MOONRAKER_URL:-http://127.0.0.1:7125}"

usage() {
    cat <<EOF
usage: $(basename "$0") [PRINTER_IP] [options]

  PRINTER_IP          printer SBC address (default 192.168.2.210)
  --user USER         user that runs Klipper (default \$SUDO_USER or cloud)
  --moonraker URL     Moonraker base URL (default $moonraker_url)
  --no-restart        install files but do not restart bridges or Klipper
EOF
}

while (($#)); do
    case "$1" in
        --user)
            klipper_user="${2:?--user needs a value}"
            shift
            ;;
        --moonraker)
            moonraker_url="${2:?--moonraker needs a value}"
            shift
            ;;
        --no-restart) restart=0 ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            printer_ip="$1"
            ;;
    esac
    shift
done

if [[ ${EUID} -ne 0 ]]; then
    echo "error: run as root" >&2
    exit 1
fi

if ! id "$klipper_user" >/dev/null 2>&1; then
    echo "error: user '$klipper_user' does not exist (use --user)" >&2
    exit 1
fi

home="$(getent passwd "$klipper_user" | cut -d: -f6)"
if [[ -z "$home" || ! -d "$home" ]]; then
    echo "error: cannot resolve home directory for '$klipper_user'" >&2
    exit 1
fi

comms="$home/printer_data/comms"
install -d -o "$klipper_user" -g "$(id -gn "$klipper_user")" "$comms"

install -m 755 "$here/q2-pty-bridge.py" /usr/local/sbin/q2-pty-bridge.py

unit=/etc/systemd/system/q2-serial-bridge@.service
if [[ -f "$unit" && ! -f "$unit.pre-offload-fixes" ]]; then
    cp -a "$unit" "$unit.pre-offload-fixes"
fi
sed -e "s|@USER@|$klipper_user|g" \
    -e "s|@HOME@|$home|g" \
    -e "s|@PRINTER_IP@|$printer_ip|g" \
    "$here/q2-serial-bridge@.service.in" > "$unit"
chmod 644 "$unit"

systemctl daemon-reload 2>/dev/null || true
if ((restart)); then
    for instance in main:7001 thr:7002 mmu:7003; do
        systemctl restart "q2-serial-bridge@$instance" 2>/dev/null || true
    done

    # A bridge swap can leave an MCU in firmware shutdown.  A firmware restart
    # resets the MCUs and reloads the config, which a service restart does not.
    if curl -fsS --max-time 5 "$moonraker_url/printer/info" >/dev/null 2>&1; then
        curl -fsS --max-time 20 -X POST "$moonraker_url/printer/firmware_restart" >/dev/null \
            || echo "warning: firmware restart request failed" >&2
        echo "requested a firmware restart through Moonraker"
    elif systemctl list-unit-files klipper.service >/dev/null 2>&1; then
        systemctl restart klipper || true
        echo "restarted klipper.service"
    else
        echo "restart Klipper on this host to pick up the new bridges" >&2
    fi
fi

echo "offload-host fixes installed"
echo "user: $klipper_user ($home)"
echo "printer: $printer_ip"
echo
echo "next: set MODE=offload in /etc/q2-mode.conf on the printer and reboot it"
