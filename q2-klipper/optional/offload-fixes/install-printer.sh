#!/usr/bin/env bash
# Install the optional printer-side half of the offload reliability fixes.
# Run on the printer SBC (192.168.2.210) as root.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
with_mode=0
restart=1

usage() {
    cat <<EOF
usage: $(basename "$0") [--with-q2-mode] [--no-restart]

  --with-q2-mode  also install the patched /usr/local/sbin/q2-mode boot selector
  --no-restart    install files but do not restart the serial proxies
EOF
}

while (($#)); do
    case "$1" in
        --with-q2-mode) with_mode=1 ;;
        --no-restart) restart=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ ${EUID} -ne 0 ]]; then
    echo "error: run as root" >&2
    exit 1
fi

pick_python() {
    local candidate
    for candidate in /home/mks/q2-host/klippy-env/bin/python "$(command -v python3 || true)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" -c 'import serial' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

python="$(pick_python)" || {
    echo "error: no python3 with pyserial found (looked in the Klipper venv and PATH)" >&2
    exit 1
}

install -m 755 "$here/q2-serial-proxy.py" /usr/local/sbin/q2-serial-proxy.py

unit=/etc/systemd/system/q2-serial-proxy@.service
if [[ -f "$unit" && ! -f "$unit.pre-offload-fixes" ]]; then
    cp -a "$unit" "$unit.pre-offload-fixes"
fi
sed "s|@PYTHON@|$python|g" "$here/q2-serial-proxy@.service.in" > "$unit"
chmod 644 "$unit"

if ((with_mode)); then
    if [[ -f /usr/local/sbin/q2-mode && ! -f /usr/local/sbin/q2-mode.pre-offload-fixes ]]; then
        cp -a /usr/local/sbin/q2-mode /usr/local/sbin/q2-mode.pre-offload-fixes
    fi
    install -m 755 "$here/q2-mode" /usr/local/sbin/q2-mode
    echo "installed /usr/local/sbin/q2-mode"
fi

if ! compgen -G '/etc/q2-serial-proxy/*.env' >/dev/null; then
    echo "warning: no /etc/q2-serial-proxy/*.env files; run the main installer first" >&2
fi

systemctl daemon-reload 2>/dev/null || true
if ((restart)); then
    for instance in main thr mmu; do
        systemctl restart "q2-serial-proxy@$instance" 2>/dev/null || true
    done
fi

echo "printer-side offload fixes installed"
echo "python: $python"
echo
echo "next: run install-host.sh on the offload host, then restart its Klipper"
echo "      (curl -X POST http://<host>:7125/printer/firmware_restart)"
