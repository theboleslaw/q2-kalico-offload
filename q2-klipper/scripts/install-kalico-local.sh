#!/usr/bin/env bash
# Install Kalico (software only, no firmware flash) into the Q2 local-fallback
# tree used by q2-local-klipper.service.
#
# The local fallback lives in ~/q2-host:
#   ~/q2-host/klipper        Kalico source
#   ~/q2-host/klippy-env     Python venv
#   ~/q2-host/printer_data   config, logs, gcodes
#
# This copies the exact Kalico tree and Happy Hare from the offload host
# (default 192.168.2.220), so both hosts run the same version, then rebuilds
# the venv for this machine's architecture.  No firmware is flashed.
#
# The existing local config is kept by default: it is already the Q2 local
# variant (ttyS4, q2-host paths) and may hold newer calibrations than .220.
# Use --sync-config to replace it with the offload host's config (paths are
# rewritten for local mode); the old config is backed up first.
#
# Usage (run on the printer as mks, not root):
#   ./install-kalico-local.sh [OFFLOAD_HOST] [--root DIR] [--sync-config]
#
# Requires SSH access to the offload host (password or key).
set -Eeuo pipefail

HOST="192.168.2.220"
REMOTE_USER="${REMOTE_USER:-cloud}"
ROOT="${Q2_LOCAL_ROOT:-$HOME/q2-host}"
SYNC_CONFIG=0

usage() {
    cat <<'EOF'
Usage: install-kalico-local.sh [OFFLOAD_HOST] [options]

  OFFLOAD_HOST       host to copy Kalico from (default 192.168.2.220)
  --root DIR         local fallback tree (default ~/q2-host)
  --sync-config      also copy printer_data/config from the offload host
  -h, --help         show this help

Environment:
  REMOTE_USER        SSH user on the offload host (default cloud)
  Q2_LOCAL_ROOT      same as --root
EOF
}

info() { printf '==> %s\n' "$*"; }
ok()   { printf ' ok  %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --root)        [ $# -ge 2 ] || die "--root needs a value"; ROOT="$2"; shift 2 ;;
        --root=*)      ROOT="${1#*=}"; shift ;;
        --sync-config) SYNC_CONFIG=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "unknown option: $1 (try --help)" ;;
        *)             HOST="$1"; shift ;;
    esac
done

[ "$(id -u)" != 0 ] || die "run as your normal user (mks), not root"
command -v python3 >/dev/null || die "python3 is required"
command -v tar >/dev/null || die "tar is required"
command -v ssh >/dev/null || die "ssh is required"

REMOTE_HOME="${Q2_REMOTE_HOME:-/home/${REMOTE_USER}}"
ROOT="${ROOT%/}"
STAGE="${ROOT}/.kalico-incoming.$$"
TS="$(date +%Y%m%d-%H%M%S)"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$ROOT" "$STAGE" \
    "$ROOT/printer_data"/{config,logs,comms,gcodes}

info "Copying Kalico, Happy Hare and config from ${REMOTE_USER}@${HOST} ..."
# One ssh connection, one tar stream.  No rsync is needed on either side.
# Happy Hare, ShakeTune and moonraker-timelapse are optional; include them when
# present so the local config's [mmu], [shaketune] and [timelapse] still load.
ITEMS="klipper"
[ "$SYNC_CONFIG" = 1 ] && ITEMS="$ITEMS printer_data/config"
if ! ssh "${REMOTE_USER}@${HOST}" "
        cd '${REMOTE_HOME}' || exit 1
        items='${ITEMS}'
        for d in Happy-Hare klippain_shaketune moonraker-timelapse; do
            [ -d \"\$d\" ] && items=\"\$items \$d\"
        done
        tar czf - --exclude=.git --exclude='*.pyc' --exclude=__pycache__ --exclude=out \$items
    " | tar xzf - -C "$STAGE"; then
    die "transfer from ${HOST} failed (check SSH access and free space)"
fi

[ -f "${STAGE}/klipper/pyproject.toml" ] \
    || die "${HOST}:~/klipper is not a Kalico checkout (no pyproject.toml)"
grep -qi 'kalico' "${STAGE}/klipper/pyproject.toml" \
    || die "${HOST}:~/klipper is not Kalico (pyproject.toml does not mention Kalico)"
ok "Kalico source received"

# ---------------------------------------------------------------- Kalico source
if [ -e "${ROOT}/klipper" ]; then
    info "Backing up existing klipper -> klipper.pre-kalico-${TS}"
    mv "${ROOT}/klipper" "${ROOT}/klipper.pre-kalico-${TS}"
fi
mv "${STAGE}/klipper" "${ROOT}/klipper"
ok "Kalico installed in ${ROOT}/klipper"

# ---------------------------------------------------------------- Happy Hare
if [ -d "${STAGE}/Happy-Hare" ]; then
    if [ -e "${ROOT}/Happy-Hare" ]; then
        info "Backing up existing Happy-Hare -> Happy-Hare.pre-kalico-${TS}"
        mv "${ROOT}/Happy-Hare" "${ROOT}/Happy-Hare.pre-kalico-${TS}"
    fi
    mv "${STAGE}/Happy-Hare" "${ROOT}/Happy-Hare"
    ok "Happy Hare installed in ${ROOT}/Happy-Hare"
else
    warn "${HOST}:~/Happy-Hare not found; keeping any existing local copy"
fi

# ShakeTune is referenced by the local printer.cfg ([shaketune]) and by the
# local Moonraker update manager.
if [ -d "${STAGE}/klippain_shaketune" ]; then
    if [ -e "${HOME}/klippain_shaketune" ]; then
        info "Backing up existing klippain_shaketune"
        mv "${HOME}/klippain_shaketune" "${HOME}/klippain_shaketune.pre-kalico-${TS}"
    fi
    mv "${STAGE}/klippain_shaketune" "${HOME}/klippain_shaketune"
    ok "ShakeTune installed in ${HOME}/klippain_shaketune"
fi

# Moonraker's [timelapse] component is a symlink into moonraker-timelapse.
if [ -d "${STAGE}/moonraker-timelapse" ]; then
    if [ -e "${ROOT}/moonraker-timelapse" ]; then
        info "Backing up existing moonraker-timelapse"
        mv "${ROOT}/moonraker-timelapse" "${ROOT}/moonraker-timelapse.pre-kalico-${TS}"
    fi
    mv "${STAGE}/moonraker-timelapse" "${ROOT}/moonraker-timelapse"
    if [ -d "${ROOT}/moonraker/moonraker/components" ]; then
        ln -sfn "${ROOT}/moonraker-timelapse/component/timelapse.py" \
            "${ROOT}/moonraker/moonraker/components/timelapse.py"
    fi
    ok "moonraker-timelapse installed"
fi

# Happy Hare v4 links every module into klipper/moonraker.  The copied links
# still point at the offload host's home, so rewrite them to the local tree.
if [ -d "${ROOT}/Happy-Hare" ]; then
    while IFS= read -r link; do
        target="$(readlink "$link" 2>/dev/null || true)"
        case "$target" in
            "${REMOTE_HOME}/Happy-Hare/"*)
                rel="${target#"${REMOTE_HOME}/Happy-Hare/"}"
                new="${ROOT}/Happy-Hare/${rel}"
                [ -e "$new" ] && ln -sfn "$new" "$link"
                ;;
        esac
    done < <(find "${ROOT}/klipper" "${ROOT}/moonraker" -type l 2>/dev/null)

    # Moonraker component used by Mainsail's MMU/spool panel.
    if [ -f "${ROOT}/Happy-Hare/components/mmu_server.py" ] \
            && [ -d "${ROOT}/moonraker/moonraker/components" ]; then
        ln -sfn "${ROOT}/Happy-Hare/components/mmu_server.py" \
            "${ROOT}/moonraker/moonraker/components/mmu_server.py"
    fi
fi

# The local config may use ShakeTune; its module lives outside Happy Hare and
# must be linked into the new Kalico tree.
if [ -d "${HOME}/klippain_shaketune/shaketune" ]; then
    ln -sfn "${HOME}/klippain_shaketune/shaketune" \
        "${ROOT}/klipper/klippy/extras/shaketune"
    ok "ShakeTune module linked"
fi

# A missing Happy Hare package would only show up as a Klipper config error.
if [ ! -e "${ROOT}/klipper/klippy/extras/mmu/__init__.py" ]; then
    die "Happy Hare mmu package is missing after the copy (${ROOT}/klipper/klippy/extras/mmu)"
fi

# ---------------------------------------------------------------- Config
if [ "$SYNC_CONFIG" = 1 ]; then
    [ -d "${STAGE}/printer_data/config" ] \
        || die "${HOST}:~/printer_data/config not found"
    info "Syncing config from ${HOST} (paths rewritten for local mode)"
    mkdir -p "${ROOT}/printer_data"
    if [ -d "${ROOT}/printer_data/config" ]; then
        tar czf "${ROOT}/printer_data/config.pre-kalico-${TS}.tgz" \
            -C "${ROOT}/printer_data" config
        ok "old config saved as ${ROOT}/printer_data/config.pre-kalico-${TS}.tgz"
    fi
    rm -rf "${ROOT}/printer_data/config.new"
    cp -a "${STAGE}/printer_data/config" "${ROOT}/printer_data/config.new"
    # Offload host paths -> local fallback paths.  The THR serial is a bridge
    # pty on the offload host but the real UART on the printer.
    find "${ROOT}/printer_data/config.new" -type f \
        \( -name '*.cfg' -o -name '*.conf' -o -name '*.json' \) -print0 \
        | xargs -0 -r sed -i \
            -e "s|${REMOTE_HOME}|${ROOT}|g" \
            -e "s|@HOME@|${ROOT}|g" \
            -e "s|~/printer_data|${ROOT}/printer_data|g" \
            -e "s|${ROOT}/printer_data/comms/q2-thr|/dev/ttyS4|g"
    rm -rf "${ROOT}/printer_data/config"
    mv "${ROOT}/printer_data/config.new" "${ROOT}/printer_data/config"
    ok "config synced"
else
    info "Keeping the existing local config in ${ROOT}/printer_data/config"
    [ -f "${ROOT}/printer_data/config/printer.cfg" ] \
        || warn "no printer.cfg there; rerun with --sync-config to copy it from ${HOST}"
fi

# Catch missing includes/modules now instead of after a reboot into local mode.
CFG_DIR="${ROOT}/printer_data/config"
if [ -f "${CFG_DIR}/printer.cfg" ]; then
    (
        cd "$CFG_DIR" || exit 0
        while IFS= read -r inc; do
            for p in $inc; do
                compgen -G "$p" >/dev/null || warn "printer.cfg include not found: $p"
            done
        done < <(sed -n 's/^\[include \(.*\)\]$/\1/p' printer.cfg)
    )
fi
if [ -f "${CFG_DIR}/printer.cfg" ] && grep -q '^\[shaketune\]' "${CFG_DIR}/printer.cfg"; then
    [ -e "${ROOT}/klipper/klippy/extras/shaketune" ] \
        || warn "config has [shaketune] but the module is missing"
fi
if [ -f "${CFG_DIR}/moonraker.conf" ]; then
    if grep -q '^\[timelapse\]' "${CFG_DIR}/moonraker.conf" \
            && [ ! -e "${ROOT}/moonraker/moonraker/components/timelapse.py" ]; then
        warn "moonraker.conf has [timelapse] but the component is missing"
    fi
    if grep -q '^\[mmu_server\]' "${CFG_DIR}/moonraker.conf" \
            && [ ! -e "${ROOT}/moonraker/moonraker/components/mmu_server.py" ]; then
        warn "moonraker.conf has [mmu_server] but the component is missing"
    fi
fi

# ---------------------------------------------------------------- Python venv
info "Rebuilding Python venv for $(uname -m) ..."
if [ -e "${ROOT}/klippy-env" ]; then
    info "Backing up existing klippy-env -> klippy-env.pre-kalico-${TS}"
    mv "${ROOT}/klippy-env" "${ROOT}/klippy-env.pre-kalico-${TS}"
fi
python3 -m venv "${ROOT}/klippy-env"
"${ROOT}/klippy-env/bin/pip" install -q --upgrade pip
"${ROOT}/klippy-env/bin/pip" install -q \
    -r "${ROOT}/klipper/scripts/klippy-requirements.txt" numpy scipy
"${ROOT}/klippy-env/bin/python" -c \
    "import sys; sys.path.insert(0, '${ROOT}/klipper/klippy'); import chelper; chelper.get_ffi()" \
    || die "chelper build failed"
if [ -f "${HOME}/klippain_shaketune/requirements.txt" ]; then
    info "Installing ShakeTune Python requirements"
    "${ROOT}/klippy-env/bin/pip" install -q \
        -r "${HOME}/klippain_shaketune/requirements.txt" \
        || warn "ShakeTune requirements failed to install; [shaketune] may not load"
fi
ok "venv ready"

# ---------------------------------------------------------------- Local service
UNIT=/etc/systemd/system/q2-local-klipper.service
if [ -f "$UNIT" ]; then
    changed=0
    if ! grep -q "^WorkingDirectory=${ROOT}/klipper$" "$UNIT"; then
        sudo sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${ROOT}/klipper|" "$UNIT"
        changed=1
    fi
    if ! grep -q "${ROOT}/klippy-env/bin/python" "$UNIT"; then
        sudo sed -i "s|^ExecStart=[^ ]*/python |ExecStart=${ROOT}/klippy-env/bin/python |" "$UNIT"
        changed=1
    fi
    if ! grep -q "${ROOT}/klipper/klippy/klippy.py" "$UNIT"; then
        sudo sed -i "s|[^ ]*/klipper/klippy/klippy.py|${ROOT}/klipper/klippy/klippy.py|" "$UNIT"
        changed=1
    fi
    if [ "$changed" = 1 ]; then
        sudo systemctl daemon-reload
        ok "q2-local-klipper.service updated"
    else
        ok "q2-local-klipper.service already points at ${ROOT}"
    fi
else
    warn "q2-local-klipper.service not found; q2-mode local mode will not use this install"
fi

if systemctl is-enabled --quiet klipper 2>/dev/null; then
    warn "klipper.service is enabled; q2-mode uses q2-local-klipper instead"
fi

echo
echo "Done. Kalico is installed for local mode (nothing was flashed)."
echo "  Source: ${ROOT}/klipper"
echo "  Venv:   ${ROOT}/klippy-env"
echo "  Config: ${ROOT}/printer_data/config"
echo
echo "To test local mode when the printer is idle:"
echo "  sudo q2-mode set local && sudo reboot"
echo "To go back to offload:"
echo "  sudo q2-mode set offload && sudo reboot"
