#!/usr/bin/env bash
# Install Kalico (software only, no firmware flash) on a Qidi Q2 printer SBC.
# Copies the Kalico source from an offload host so the versions match exactly,
# then rebuilds the Python venv locally (aarch64-safe).
#
# Usage (run on the printer as mks):
#   ./install-kalico-local.sh [offload-host-ip]   (default 192.168.2.220)
#
# Requires SSH access to the offload host (password or key).
set -Eeuo pipefail

HOST="${1:-192.168.2.220}"
USER_REMOTE="${REMOTE_USER:-cloud}"
KALICO_SRC="$HOME/kalico"
VENV="$HOME/klippy-env"
CFG="$HOME/printer_data/config"

info() { printf '==> %s\n' "$*"; }
ok()   { printf ' ok  %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# rsync is preferred but not always installed; fall back to tar over ssh.
command -v python3 >/dev/null || die "python3 is required"
[ "$(id -u)" != 0 ] || die "run as your normal user (mks), not root"

info "Copying Kalico source from $USER_REMOTE@$HOST (version must match)..."
mkdir -p "$KALICO_SRC"
# Prefer rsync; fall back to tar over ssh if rsync is missing on either side.
if command -v rsync >/dev/null && ssh -o BatchMode=yes "$USER_REMOTE@$HOST" 'command -v rsync' >/dev/null 2>&1; then
    rsync -avz --delete --exclude='.git' --exclude='*.pyc' --exclude='__pycache__' \
        "$USER_REMOTE@$HOST:/home/$USER_REMOTE/klipper/" "$KALICO_SRC/" \
        || die "rsync of Kalico source failed (check SSH access to $HOST)"
else
    ssh "$USER_REMOTE@$HOST" 'cd /home/'"$USER_REMOTE"'/klipper && tar czf - --exclude=.git --exclude="*.pyc" --exclude=__pycache__ .' \
        | tar xzf - -C "$KALICO_SRC" \
        || die "tar/ssh transfer of Kalico source failed (check SSH access to $HOST)"
fi

# Verify it's actually Kalico
grep -q 'Kalico' "$KALICO_SRC/pyproject.toml" 2>/dev/null \
    || die "remote ~/klipper is not Kalico (pyproject.toml missing or wrong)"
ok "Kalico source copied ($(git -C "$KALICO_SRC" describe --tags --always 2>/dev/null || echo 'no git'))"

info "Copying printer.cfg from offload host..."
mkdir -p "$CFG"
if command -v rsync >/dev/null && ssh -o BatchMode=yes "$USER_REMOTE@$HOST" 'command -v rsync' >/dev/null 2>&1; then
    rsync -avz "$USER_REMOTE@$HOST:/home/$USER_REMOTE/printer_data/config/printer.cfg" "$CFG/printer.cfg" \
        || die "rsync of printer.cfg failed"
else
    ssh "$USER_REMOTE@$HOST" 'cat /home/'"$USER_REMOTE"'/printer_data/config/printer.cfg' > "$CFG/printer.cfg" \
        || die "transfer of printer.cfg failed"
fi
# Fix serial path for local mode (offload uses the proxy, local uses ttyS4)
sed -i 's|@HOME@/printer_data/comms/q2-thr|/dev/ttyS4|' "$CFG/printer.cfg"
# Fix other @HOME@ paths
sed -i "s|@HOME@|$HOME|g" "$CFG/printer.cfg"
ok "printer.cfg copied and adjusted for local mode"

info "Rebuilding Python venv (aarch64-safe)..."
rm -rf "$VENV"
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -r "$KALICO_SRC/scripts/klippy-requirements.txt" numpy scipy
"$VENV/bin/python" -c "import sys; sys.path.insert(0, '$KALICO_SRC/klippy'); import chelper; chelper.get_ffi()" \
    || die "chelper build failed"
ok "venv ready"

info "Updating Klipper service..."
if [ -f /etc/systemd/system/klipper.service ]; then
    sudo sed -i "s|/home/$USER_REMOTE/klipper|/home/$(id -un)/kalico|g" /etc/systemd/system/klipper.service
    sudo sed -i "s|/home/$USER_REMOTE/klippy-env|/home/$(id -un)/klippy-env|g" /etc/systemd/system/klipper.service
    sudo systemctl daemon-reload
    ok "service updated"
else
    warn "no klipper.service found; create one manually pointing to $KALICO_SRC/klippy/klippy.py"
fi

info "Restarting Klipper..."
sudo systemctl stop klipper 2>/dev/null || true
sudo systemctl start klipper
sleep 2
if systemctl is-active --quiet klipper; then
    ok "Klipper is running (Kalico)"
else
    die "Klipper failed to start; check: journalctl -u klipper -n 30"
fi

echo
echo "Done. Kalico is running locally on this printer."
echo "  Source:  $KALICO_SRC"
echo "  Venv:    $VENV"
echo "  Config:  $CFG/printer.cfg"
echo
echo "To switch back to offload mode later:"
echo "  sudo sh -c 'echo MODE=offload > /etc/q2-mode.conf' && sudo reboot"
