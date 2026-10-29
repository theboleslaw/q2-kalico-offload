# shellcheck shell=bash
# Printer-board side of install-klipper.sh, driven over SSH.
# Source after lib.sh and host.sh.

PRINTER_USER="${PRINTER_USER:-mks}"
# Stock Qidi OS uses /home/mks. Keep the default for compatibility, but resolve the real
# home from the printer before copying anything, so a renamed printer user works too.
PRINTER_HOME="${PRINTER_HOME:-/home/${PRINTER_USER}}"
PRINTER_WORK="${PRINTER_HOME}/q2-klipper"
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=15)
# Unattended update: never wait for a password
[ "${UNATTENDED:-0}" = 1 ] && SSH_OPTS+=(-o BatchMode=yes)

pssh() { ssh "${SSH_OPTS[@]}" "${PRINTER_USER}@${PRINTER_IP}" "$@"; }
# Root commands. After "setup", a sudoers rule allows exactly this command without a
# password; before that, -tt lets sudo ask for it (stock Qidi image: "makerbase").
proot() { ssh -tt "${SSH_OPTS[@]}" "${PRINTER_USER}@${PRINTER_IP}" sudo /bin/bash "${PRINTER_WORK}/q2-printer.sh" "$@"; }

printer_ssh_key() {
    if ssh -o BatchMode=yes "${SSH_OPTS[@]}" "${PRINTER_USER}@${PRINTER_IP}" true 2>/dev/null; then
        return 0
    fi
    info "Setting up SSH key access to ${PRINTER_USER}@${PRINTER_IP} (stock password: makerbase)"
    [ -f "${HOME}/.ssh/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519"
    ssh-copy-id -i "${HOME}/.ssh/id_ed25519.pub" "${PRINTER_USER}@${PRINTER_IP}" >/dev/null
    ssh -o BatchMode=yes "${SSH_OPTS[@]}" "${PRINTER_USER}@${PRINTER_IP}" true \
        || die "SSH key login to the printer failed"
}

# Ask the printer for the real home directory of PRINTER_USER. Nothing is hardcoded to
# /home/mks: the stock user happens to be "mks", but a different image or user works.
printer_resolve_home() {
    local home
    case "${PRINTER_USER}" in
        ""|*[!A-Za-z0-9._-]*) die "invalid printer user '${PRINTER_USER}'" ;;
    esac
    home="$(pssh "getent passwd ${PRINTER_USER} | cut -d: -f6" 2>/dev/null || true)"
    if [ -n "$home" ]; then
        PRINTER_HOME="$home"
    else
        warn "could not read the home directory of ${PRINTER_USER}; using ${PRINTER_HOME}"
    fi
    PRINTER_WORK="${PRINTER_HOME}/q2-klipper"
    export PRINTER_USER PRINTER_HOME PRINTER_WORK
}

# Copy the printer-side script, the pinned Katapult flashtool and the bundled firmware.
# No download happens here: everything needed for flashing is in vendor/.
printer_push() {
    local bundle m stage flashtool firmware
    bundle="${Q2_BUNDLE_DIR:-$(dirname "$Q2_ROOT")}"
    flashtool="${bundle}/vendor/katapult/flashtool.py"
    firmware="${FIRMWARE_DIR:-${bundle}/vendor/firmware}"
    [ -s "$flashtool" ] || die "missing bundled flashtool: ${flashtool}"
    [ -s "${firmware}/q2-main.bin" ] || die "missing bundled firmware: ${firmware}"
    pssh "mkdir -p ${PRINTER_WORK}/firmware ${PRINTER_WORK}/deployer"
    scp -q "${SSH_OPTS[@]}" "${Q2_ROOT}/printer/q2-printer.sh" \
        "${Q2_ROOT}/printer/q2-serial-proxy@.service" "${flashtool}" \
        "${PRINTER_USER}@${PRINTER_IP}:${PRINTER_WORK}/"
    # One directory per MCU with klipper.bin + klipper.dict: flashtool then also checks
    # that the image was built for the MCU it is writing to
    stage="$(mktemp -d)"
    for m in main thr box; do
        mkdir -p "${stage}/${m}"
        cp "${firmware}/q2-${m}.bin" "${stage}/${m}/klipper.bin"
        cp "${firmware}/q2-${m}.dict" "${stage}/${m}/klipper.dict"
    done
    (cd "$stage" && sha256sum ./*/klipper.bin ./*/klipper.dict > SHA256SUMS)
    pssh "rm -rf ${PRINTER_WORK}/firmware && mkdir -p ${PRINTER_WORK}/firmware"
    scp -q -r "${SSH_OPTS[@]}" "$stage"/* "${PRINTER_USER}@${PRINTER_IP}:${PRINTER_WORK}/firmware/"
    rm -rf "$stage"
    pssh "cd ${PRINTER_WORK}/firmware && sha256sum -c --quiet SHA256SUMS" \
        || die "firmware copy on the printer is corrupted"
}

# SSH key, current scripts on the printer, then the sudo rule for q2-printer.sh: the
# printer's sudo password is asked once here, every later step runs without it.
printer_prepare() {
    printer_ssh_key
    printer_resolve_home
    printer_push
    if ! pssh "sudo -n /bin/bash ${PRINTER_WORK}/q2-printer.sh status" >/dev/null 2>&1; then
        info "Allowing ${PRINTER_USER} to run q2-printer.sh as root (printer sudo password, asked once)"
        proot sudoers
    fi
}

# First conversion only: verify the bundled Katapult deployers and copy them over.
printer_fetch_deployers() {
    local bundle src f
    bundle="${Q2_BUNDLE_DIR:-$(dirname "$Q2_ROOT")}"
    src="${bundle}/vendor/deployer"
    for f in mcu thr mmu; do
        [ -s "${src}/${f}-deployer.bin" ] || die "missing bundled deployer: ${src}/${f}-deployer.bin"
    done
    printf '%s  %s\n' \
        "${DEPLOYER_MCU_SHA256}" "${src}/mcu-deployer.bin" \
        "${DEPLOYER_THR_SHA256}" "${src}/thr-deployer.bin" \
        "${DEPLOYER_MMU_SHA256}" "${src}/mmu-deployer.bin" \
        | sha256sum -c --quiet || die "bundled deployer checksum mismatch"
    pssh "rm -f ${PRINTER_WORK}/deployer/*-deployer.bin"
    scp -q "${SSH_OPTS[@]}" "$src"/*-deployer.bin "${PRINTER_USER}@${PRINTER_IP}:${PRINTER_WORK}/deployer/"
}

# Firmware phase: optional Katapult deploy (first conversion), then Klipper on all three
# MCUs, in a single root session on the printer (one sudo password prompt).
printer_convert() {
    local deploy="${1:-}"
    if [ "$deploy" = deploy ]; then
        cat <<EOF

${C_WARN}First conversion: Katapult bootloader on the three MCUs${C_OFF}
Qidi's own update scripts flash a Katapult "deployer" (n3oney/qidi-q2-klipper) while the
stock firmware still runs. Afterwards Katapult replaces Qidi's bootloader: Qidi's firmware
can still be flashed back through Katapult (docs/recovery.md), but recovering from a power
cut during THIS step needs an ST-Link.
  - keep the printer powered and connected the whole time
  - one MCU at a time; each one is checked before the next
EOF
        confirm_phrase "INSTALL KATAPULT"
    fi
    cat <<EOF

${C_WARN}Flashing Klipper ($(firmware_id)) on mainboard, toolhead and Qidi Box${C_OFF}
Each MCU is put into Katapult and its application offset is checked before writing.
EOF
    # Never skipped, not even with --yes
    confirm_phrase "FLASH"
    if [ -n "$(systemctl list-unit-files klipper.service --no-legend 2>/dev/null)" ]; then
        sudo systemctl stop klipper q2-serial-bridge@main:7001 q2-serial-bridge@thr:7002 q2-serial-bridge@mmu:7003 2>/dev/null || true
    fi
    # shellcheck disable=SC2086  # $deploy is empty or one word
    proot convert "$(firmware_id)" $deploy || die "firmware phase failed; see docs/recovery.md"
    ok "all MCUs on firmware $(firmware_id)"
}

printer_firmware_id() { pssh "cat ${PRINTER_WORK}/firmware-id 2>/dev/null" || true; }

# True once the Katapult bootloader was installed by an earlier conversion (the marker is
# written after the deployers; firmware-id covers printers converted before the marker).
# Also true when an MCU is already running Klipper firmware: that can only happen after
# Katapult was installed and used to flash, so the deployers must not be re-run.
printer_katapult_installed() {
    pssh "test -e ${PRINTER_WORK}/katapult-installed || test -s ${PRINTER_WORK}/firmware-id || ls /dev/serial/by-id/usb-Klipper_stm32f407xx_*-if00 /dev/serial/by-id/usb-Klipper_stm32f401xc_*-if00 >/dev/null 2>&1"
}

printer_proxies() {
    proot setup "$HOST_IP"
}

# The Q2 camera is the stock USB camera on the printer board, served by the stock
# crowsnest + nginx services. Never replace them: after the conversion only Klipper,
# Moonraker and the stock UI are stopped, the camera stack stays untouched.
printer_camera() {
    info "Configuring the printer camera (stock crowsnest + nginx)"
    proot camera-enable || die "camera setup failed; check crowsnest/nginx on the printer"
}

printer_camera_status() {
    proot camera-status
}

