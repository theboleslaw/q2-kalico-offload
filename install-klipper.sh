#!/usr/bin/env bash
# Self-contained Qidi Q2 "mainline Klipper" installer.
#
# Based on the upstream Qidi Q2 external-host project
# (https://github.com/cedbossneo/q2-offload), vendored under ./q2-klipper:
#   - Klipper host stack (Klipper, Moonraker, Happy Hare, Mainsail, Spoolman)
#   - serial proxies and all three MCU flashes: mainboard, toolhead (THR), Qidi Box (MMU)
#   - stock printer camera (crowsnest + nginx) enabled and verified
#
# AutoPA and PrintGuard are intentionally not included.
# Every path, host username and home directory is taken from the machine running this
# script; the printer user defaults to the stock Qidi user "mks" but can be changed.
#
# Usage:
#   ./install-klipper.sh
#   ./install-klipper.sh --components mainsail,spoolman
#   ./install-klipper.sh --printer <ip>
#   ./install-klipper.sh --host-only
#   ./install-klipper.sh --dry-run
#
# The printer address is discovered from this machine's existing Q2 Klipper/Moonraker
# configuration. It is never asked for and --printer is only an override.
#
# The first run converts the printer board from Qidi's stock firmware: it replaces the
# bootloader with Katapult and flashes the three MCUs. Read README.md first. Flashing
# always asks you to type FLASH (and INSTALL KATAPULT on the first conversion).
set -Eeuo pipefail

on_error() {
    local rc=$?
    printf '\nERROR: installer failed at line %s (exit %s).\n' "${BASH_LINENO[0]}" "$rc" >&2
    printf 'If this happened during flashing, stop and read q2-klipper/docs/recovery.md.\n' >&2
    exit "$rc"
}
trap on_error ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
Q2_ROOT="${BUNDLE_DIR}/q2-klipper"
VENDOR_DIR="${BUNDLE_DIR}/vendor"

# The invoking user, never a hardcoded name. HOME/USER are exported so every sourced
# routine renders the same paths.
HOST_USER="${USER:-$(id -un)}"
HOST_HOME="${HOME:-$(getent passwd "$HOST_USER" | cut -d: -f6)}"
[ -n "$HOST_HOME" ] || { echo "ERROR: cannot determine home directory for ${HOST_USER}" >&2; exit 1; }
HOME="$HOST_HOME"
USER="$HOST_USER"
export HOME USER
SETTINGS_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/q2-klipper-bundle"
SETTINGS="${SETTINGS_DIR}/settings.env"

# Bundle metadata: pinned release, firmware ID and deployer build.
if [ -f "${BUNDLE_DIR}/BUNDLE_INFO" ]; then
    # shellcheck source=/dev/null
    . "${BUNDLE_DIR}/BUNDLE_INFO"
fi

# Default to no printer address: it is discovered from this machine's existing
# q2-klipper/Moonraker configuration. --printer only overrides that discovery.
PRINTER_IP=""
PRINTER_SOURCE=""
PRINTER_IS_PLACEHOLDER=0
HOST_IP=""
HOST_IS_PLACEHOLDER=0
PRINTER_USER="mks"
PRINTER_HOME=""
COMPONENTS="__unset__"
ASSUME_YES=0
DRY_RUN=0
HOST_ONLY=0
NO_FLASH=0
FLASH_ONLY=0
NO_CAMERA=0
SKIP_CALIBRATION=0
BUILD_FIRMWARE=0
Q2_CI=0

OPT_PRINTER=""
OPT_HOST_IP=""
OPT_COMPONENTS=""

# Installed unit inspected during address discovery. Overridable for tests/nonstandard
# systemd prefixes; the default is the path Q2 Klipper installs.
SERIAL_BRIDGE_UNIT="${Q2_SERIAL_BRIDGE_UNIT:-/etc/systemd/system/q2-serial-bridge@.service}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say()  { printf '==> %s\n' "$*"; }

# Accept an IPv4 address or a hostname and return a resolved IPv4 address. Used only
# for addresses discovered from this machine's configuration; nothing is hardcoded.
normalize_printer_address() {
    local addr="$1" resolved
    [ -n "$addr" ] || return 1
    case "$addr" in
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    if [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        printf '%s\n' "$addr"
        return 0
    fi
    command -v getent >/dev/null || return 1
    resolved="$(getent ahostsv4 "$addr" 2>/dev/null | awk 'NR==1{print $1}')"
    [ -n "$resolved" ] || return 1
    printf '%s\n' "$resolved"
}

use_printer_address() {
    local candidate="$1" source="$2" resolved
    resolved="$(normalize_printer_address "$candidate" || true)"
    [ -n "$resolved" ] || return 1
    PRINTER_IP="$resolved"
    PRINTER_SOURCE="$source"
    return 0
}

# Find the printer this machine already talks to. Checked in order:
#   1. existing q2-klipper settings (~/.config/q2-klipper/settings.env)
#   2. Moonraker's [webcam q2] snapshot/stream URL
#   3. the installed q2-serial-bridge unit (TCP:<printer>:<port>)
#   4. the q2-printer SSH alias's HostName
# No question is asked; if nothing is found the caller decides what to do.
detect_printer_address() {
    local candidate conf unit host ssh_config
    conf="${HOME}/.config/q2-klipper/settings.env"
    if [ -r "$conf" ]; then
        # shellcheck disable=SC1090
        candidate="$( ( . "$conf" >/dev/null 2>&1; printf '%s' "${PRINTER_IP:-}" ) 2>/dev/null || true)"
        use_printer_address "$candidate" "existing Q2 Klipper settings" && return 0
    fi

    conf="${HOME}/printer_data/config/moonraker.conf"
    if [ -r "$conf" ]; then
        candidate="$(awk '
            /^\[webcam q2\]/ { section=1; next }
            /^\[/ { section=0 }
            section && /^(snapshot_url|stream_url):/ {
                line=$0
                sub(/^[^:]*:[[:space:]]*http:\/\//, "", line)
                sub(/\/webcam\/.*$/, "", line)
                print line
                exit
            }' "$conf")"
        candidate="${candidate%%:*}"
        use_printer_address "$candidate" "Moonraker webcam config" && return 0
    fi

    unit="$SERIAL_BRIDGE_UNIT"
    if [ -r "$unit" ]; then
        candidate="$(sed -n "s/.*TCP:\([^:'\"]*\):.*/\1/p" "$unit" | head -1)"
        use_printer_address "$candidate" "installed serial bridge unit" && return 0
    fi

    if command -v ssh >/dev/null; then
        # Honor the home directory this installer runs with (HOME) rather than the
        # passwd entry, so tests/custom homes resolve the same SSH alias.
        ssh_config="${HOME}/.ssh/config"
        [ -r "$ssh_config" ] || ssh_config=/dev/null
        host="$(ssh -F "$ssh_config" -G q2-printer 2>/dev/null \
            | awk '$1=="hostname"{print $2; exit}')"
        if [ -n "$host" ] && [ "$host" != "q2-printer" ]; then
            use_printer_address "$host" "SSH alias q2-printer" && return 0
        fi
    fi
    return 1
}

usage() {
    cat <<EOF
Self-contained Qidi Q2 mainline-Klipper installer (host + MCU flash + camera).

Usage:
  ./install-klipper.sh [options]

Options:
  --printer <ip>          Qidi Q2 IP address (override; normally discovered)
  --host-ip <ip>          this host's IP on the printer network (normally auto-detected)
  --components <list>     mainsail,spoolman (default: mainsail)
                          "none": only Klipper + Moonraker + Happy Hare
                          AutoPA and PrintGuard are rejected on purpose
  --host-only             install only the host side; never touch or flash the printer
  --no-flash              configure proxies/camera but skip the MCU flash
  --flash-only            only flash the MCUs with the bundled firmware (after an install)
  --skip-camera           do not enable/check the printer camera
  --skip-calibration      do not offer PID/input-shaper calibration at the end
  --build-firmware        build the MCU firmware locally instead of using vendor/
  --yes, -y               answer plain yes/no questions with yes (flashing still asks)
  --dry-run               validate the bundle and show the plan; install/flash nothing
  --ci                    test mode: host software only, no systemd/nginx/docker/printer
  -h, --help              show this help

Examples:
  ./install-klipper.sh
  ./install-klipper.sh --dry-run
  ./install-klipper.sh --components mainsail,spoolman
  ./install-klipper.sh --components none
  ./install-klipper.sh --host-only
  ./install-klipper.sh --flash-only

The printer address comes from --printer if given, otherwise this bundle's saved settings,
otherwise this machine's existing setup, in this order: saved Q2 Klipper settings,
Moonraker's [webcam q2] config, the q2-serial-bridge unit, then the q2-printer SSH alias.
Nothing is hardcoded and you are never asked for it. The first conversion replaces Qidi's
bootloader with Katapult and flashes mainboard, toolhead (THR) and Box (MMU). Flashing
always asks you to type FLASH; the first conversion also asks you to type INSTALL
KATAPULT. Read README.md before starting.
EOF
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --printer)        OPT_PRINTER="${2:?--printer needs an IP}"; shift 2 ;;
        --host-ip)        OPT_HOST_IP="${2:?--host-ip needs an IP}"; shift 2 ;;
        --components)     OPT_COMPONENTS="${2:?--components needs a list}"; shift 2 ;;
        --host-only)      HOST_ONLY=1; shift ;;
        --no-flash)       NO_FLASH=1; shift ;;
        --flash-only)     FLASH_ONLY=1; shift ;;
        --skip-camera)    NO_CAMERA=1; shift ;;
        --skip-calibration) SKIP_CALIBRATION=1; shift ;;
        --build-firmware) BUILD_FIRMWARE=1; shift ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --ci)             Q2_CI=1; HOST_ONLY=1; shift ;;
        -h|--help)        usage 0 ;;
        *)                fail "unknown option '$1' (try --help)" ;;
    esac
done

# Saved answers from a previous run; command-line options win.
if [ -f "$SETTINGS" ]; then
    # shellcheck disable=SC1090
    . "$SETTINGS"
    [ -n "$PRINTER_IP" ] && PRINTER_SOURCE="saved settings"
fi
if [ -n "$OPT_PRINTER" ]; then
    [ "$OPT_PRINTER" = "$PRINTER_IP" ] || HOST_IP=""
    PRINTER_IP="$OPT_PRINTER"
    PRINTER_SOURCE="command line"
fi
[ -n "$OPT_HOST_IP" ] && HOST_IP="$OPT_HOST_IP"
[ -n "$OPT_COMPONENTS" ] && COMPONENTS="$OPT_COMPONENTS"

# Canonical component list. Empty or "none" means Klipper + Moonraker + Happy Hare only.
[ "$COMPONENTS" = "__unset__" ] && COMPONENTS="mainsail"
[ "$COMPONENTS" = "none" ] && COMPONENTS=""
COMPONENTS="${COMPONENTS//[[:space:]]/}"
if [ -n "$COMPONENTS" ]; then
    for c in ${COMPONENTS//,/ }; do
        if [[ " mainsail spoolman " != *" $c "* ]]; then
            fail "component '$c' is not supported here (allowed: mainsail,spoolman; autopa and printguard are excluded)"
        fi
    done
    canonical=""
    for c in mainsail spoolman; do
        [[ ",${COMPONENTS}," == *",${c},"* ]] && canonical="${canonical:+${canonical},}${c}"
    done
    COMPONENTS="$canonical"
fi

case "$PRINTER_USER" in
    ""|*[!A-Za-z0-9._-]*) fail "invalid printer user '$PRINTER_USER'" ;;
esac

check_bundle() {
    local f computed bundle_id
    [ -d "$Q2_ROOT" ] || fail "missing vendored Q2 Klipper sources at ${Q2_ROOT}"
    for f in \
        "${Q2_ROOT}/scripts/lib.sh" "${Q2_ROOT}/scripts/host.sh" \
        "${Q2_ROOT}/scripts/remote.sh" "${Q2_ROOT}/scripts/verify.sh" \
        "${Q2_ROOT}/scripts/calibrate.sh" "${Q2_ROOT}/scripts/prepare-klipper.sh" \
        "${Q2_ROOT}/scripts/build-firmware.sh" \
        "${Q2_ROOT}/printer/q2-printer.sh" "${Q2_ROOT}/printer/q2-serial-proxy@.service" \
        "${Q2_ROOT}/host/moonraker.conf" "${Q2_ROOT}/host/nginx/q2-klipper.conf" \
        "${Q2_ROOT}/host/nginx/q2-klipper-common.conf" \
        "${Q2_ROOT}/host/systemd/klipper.service" "${Q2_ROOT}/host/systemd/klipper.env" \
        "${Q2_ROOT}/host/systemd/q2-serial-bridge@.service" \
        "${Q2_ROOT}/config/klipper/printer.cfg" \
        "${VENDOR_DIR}/katapult/flashtool.py" \
        "${VENDOR_DIR}/deployer/mcu-deployer.bin" \
        "${VENDOR_DIR}/deployer/thr-deployer.bin" \
        "${VENDOR_DIR}/deployer/mmu-deployer.bin" \
        "${VENDOR_DIR}/firmware/SHA256SUMS" "${VENDOR_DIR}/firmware/BUILD_INFO" \
        "${VENDOR_DIR}/firmware/q2-main.bin" "${VENDOR_DIR}/firmware/q2-thr.bin" \
        "${VENDOR_DIR}/firmware/q2-box.bin" "${VENDOR_DIR}/firmware/q2-main.dict" \
        "${VENDOR_DIR}/firmware/q2-thr.dict" "${VENDOR_DIR}/firmware/q2-box.dict"; do
        [ -s "$f" ] || fail "bundle is incomplete: missing ${f#"$BUNDLE_DIR"/}"
    done
    (cd "${VENDOR_DIR}/firmware" && sha256sum -c --quiet SHA256SUMS) \
        || fail "bundled firmware checksum mismatch"
    printf '%s  %s\n' \
        "6ca9d065a6317d732589557dcc31f43fc427c36516f08d515832d4c4675290f6" "${VENDOR_DIR}/deployer/mcu-deployer.bin" \
        "890948b73bce0e3ee4a264cf3d0610e5e616279bb554f819e45e9eefac1340c9" "${VENDOR_DIR}/deployer/thr-deployer.bin" \
        "c693875a922322bd57ab9d3bb49a4250da34402dc2e78997f90bf78337f2d8fa" "${VENDOR_DIR}/deployer/mmu-deployer.bin" \
        | sha256sum -c --quiet || fail "bundled Katapult deployer checksum mismatch"
    computed="$(Q2_ROOT="$Q2_ROOT" bash -c '. "$Q2_ROOT/scripts/lib.sh"; firmware_id')"
    bundle_id="$(sed -n 's/^FIRMWARE_ID=//p' "${VENDOR_DIR}/firmware/BUILD_INFO")"
    if [ "$BUILD_FIRMWARE" != 1 ] && [ "$computed" != "$bundle_id" ]; then
        say "WARNING: bundled firmware ${bundle_id:-unknown} is for another Klipper than this bundle pins (${computed}): the matching firmware is built on this host"
    fi
}

preflight() {
    [ "$(id -u)" != 0 ] || fail "run as your normal user, not root (sudo is used where needed)"
    command -v apt-get >/dev/null || fail "only Debian/Ubuntu hosts are supported"
    command -v git >/dev/null || fail "git is required (install it first)"
    if [ "$DRY_RUN" != 1 ] && [ "$Q2_CI" != 1 ]; then
        command -v sudo >/dev/null || fail "sudo is required"
        sudo -v || fail "sudo is required"
        if ! command -v ip >/dev/null; then
            say "Installing iproute2"
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 >/dev/null
        fi
    fi

    if [ -z "$PRINTER_IP" ]; then
        if detect_printer_address; then
            say "Using printer ${PRINTER_IP} (${PRINTER_SOURCE})"
        elif [ "$DRY_RUN" = 1 ] || [ "$Q2_CI" = 1 ]; then
            PRINTER_IP="printer.invalid"
            PRINTER_IS_PLACEHOLDER=1
            PRINTER_SOURCE="dry-run placeholder"
            say "No printer address found on this machine; this dry run uses a placeholder"
        else
            fail "no printer address found (checked saved Q2 Klipper settings, Moonraker webcam config, q2-serial-bridge unit and the q2-printer SSH alias); pass --printer <ip>"
        fi
    fi
    if [ "$PRINTER_IS_PLACEHOLDER" = 0 ]; then
        [[ "$PRINTER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "invalid printer IP '$PRINTER_IP'"
    fi

    if [ -z "$HOST_IP" ] && [ "$PRINTER_IS_PLACEHOLDER" = 0 ] && command -v ip >/dev/null; then
        HOST_IP="$(ip -4 route get "$PRINTER_IP" 2>/dev/null \
            | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1 || true)"
    fi
    if [ -z "$HOST_IP" ]; then
        if [ "$DRY_RUN" = 1 ] || [ "$Q2_CI" = 1 ]; then
            HOST_IP="host.invalid"
            HOST_IS_PLACEHOLDER=1
        else
            fail "cannot determine this host's IP on the printer network; pass --host-ip <ip>"
        fi
    fi
    if [ "$HOST_IS_PLACEHOLDER" = 0 ]; then
        [[ "$HOST_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "invalid host IP '$HOST_IP'"
    fi

    if [ "$DRY_RUN" != 1 ] && [ "$Q2_CI" != 1 ] \
        && [ "$PRINTER_IS_PLACEHOLDER" = 0 ] && [ "$HOST_IS_PLACEHOLDER" = 0 ]; then
        mkdir -p "$SETTINGS_DIR"
        {
            printf 'PRINTER_IP=%q\n' "$PRINTER_IP"
            printf 'HOST_IP=%q\n' "$HOST_IP"
            printf 'PRINTER_USER=%q\n' "$PRINTER_USER"
            printf 'PRINTER_HOME=%q\n' "$PRINTER_HOME"
            printf 'COMPONENTS=%q\n' "${COMPONENTS:-none}"
        } > "$SETTINGS"
    fi
}

check_bundle
preflight

# Upstream release coordinates: only for pinned firmware downloads and provenance.
Q2_ORIGIN="https://github.com/cedbossneo/q2-offload.git"
Q2_GITHUB_REPO="cedbossneo/q2-offload"
UPDATE_CHANNEL=stable
MAINSAIL_PORT=80
FIRMWARE_ID="${FIRMWARE_ID:-$(sed -n 's/^FIRMWARE_ID=//p' "${VENDOR_DIR}/firmware/BUILD_INFO")}"
export Q2_ROOT Q2_BUNDLE_DIR="$BUNDLE_DIR" Q2_ORIGIN Q2_GITHUB_REPO FIRMWARE_ID
export PRINTER_IP HOST_IP PRINTER_USER PRINTER_HOME COMPONENTS
export UPDATE_CHANNEL Q2_CI DRY_RUN BUILD_FIRMWARE NO_CAMERA
export MAINSAIL_PORT

# shellcheck source=/dev/null
. "${Q2_ROOT}/scripts/lib.sh"
# shellcheck source=/dev/null
. "${Q2_ROOT}/scripts/host.sh"
# shellcheck source=/dev/null
. "${Q2_ROOT}/scripts/remote.sh"
# shellcheck source=/dev/null
. "${Q2_ROOT}/scripts/verify.sh"
# shellcheck source=/dev/null
. "${Q2_ROOT}/scripts/calibrate.sh"

for fn in has in_ci svc render host_packages host_dirs host_klipper host_moonraker \
          host_extensions host_config host_happy_hare host_web host_spoolman host_services \
          host_start host_ui_defaults host_firmware host_install_all \
          printer_prepare printer_fetch_deployers printer_convert printer_katapult_installed printer_proxies \
          printer_camera printer_firmware_id \
          verify_install calibrate_load_cell_tare calibrate_offer; do
    declare -F "$fn" >/dev/null || fail "vendored Q2 Klipper source is missing ${fn}(); re-create the bundle"
done

printing() {
    curl -s "localhost:7125/printer/objects/query?print_stats=state" 2>/dev/null \
        | grep -Eq '"state": *"(printing|paused)"'
}

wait_ready() {
    local state
    info "Waiting for Klipper to connect to the three MCUs (up to 2 minutes)"
    for _ in $(seq 1 60); do
        state="$(curl -s localhost:7125/printer/info 2>/dev/null | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')"
        [ "$state" = ready ] && { ok "Klipper is ready"; return 0; }
        sleep 2
    done
    warn "Klipper is not ready (state: ${state:-unknown}); check ${DATA}/logs/klippy.log"
    return 1
}

firmware_id_label() { firmware_id 2>/dev/null || echo unknown; }

banner() {
    local printer_line printer_user_line
    if [ "$PRINTER_IS_PLACEHOLDER" = 1 ]; then
        printer_line="not detected (dry run placeholder)"
        printer_user_line="${PRINTER_USER}@<printer>"
    else
        printer_line="${PRINTER_IP} (${PRINTER_SOURCE})"
        [ "$HOST_ONLY" = 1 ] && printer_line="${printer_line} (not modified)"
        printer_user_line="${PRINTER_USER}@${PRINTER_IP}"
    fi
    cat <<EOF

Q2 Klipper full install (self-contained bundle)
  bundle        ${BUNDLE_DIR}
  upstream      ${Q2_UPSTREAM_TAG:-vendored} ${Q2_UPSTREAM_COMMIT:-}
  host user     ${USER} (${HOME})
  printer       ${printer_line}
  printer user  ${printer_user_line}
  components    ${COMPONENTS:-none (Klipper + Moonraker + Happy Hare only)}
  firmware      $(firmware_id_label) (pinned, not flashed yet)
  camera        stock crowsnest + nginx on the printer
  excluded      AutoPA, PrintGuard
EOF
    if [ "$HOST_ONLY" = 1 ]; then
        echo "  mode          host only: serial bridges expect the printer's serial proxies"
    elif [ "$NO_FLASH" = 1 ]; then
        echo "  mode          full host + printer proxies/camera, but no MCU flash"
    else
        echo "  mode          full host + printer proxy + mainboard/THR/MMU flash + camera"
    fi
}

host_only_summary() {
    local bridge
    printf '\n%sHost-only install finished.%s\n' "${C_OK}" "${C_OFF}"
    if [ "$Q2_CI" != 1 ]; then
        systemctl is-active --quiet moonraker && ok "Moonraker is running" || warn "Moonraker is not running"
        systemctl is-active --quiet klipper && ok "Klipper is running" || warn "Klipper is not running yet"
        for bridge in q2-serial-bridge@main:7001 q2-serial-bridge@thr:7002 q2-serial-bridge@mmu:7003; do
            systemctl is-active --quiet "$bridge" \
                || warn "${bridge} is not connected (is the printer-side serial proxy running?)"
        done
    fi
    echo
    echo "Web interfaces:"
    has mainsail && echo "  Mainsail    http://${HOST_IP}/"
    has spoolman && echo "  Spoolman    http://${HOST_IP}:7912/"
    has mainsail && echo "  Box page    http://${HOST_IP}/box/"
    echo "  Moonraker   http://${HOST_IP}:7125/"
    cat <<EOF

The printer was not modified and no MCU was flashed. Klipper stays disconnected until
the printer exposes TCP 7001-7003 with the printer's serial proxy. Re-run without
--host-only to flash the boards and configure the printer.

Update this host stack by re-running:
  $0
EOF
}

final_notes() {
    local healthy="${1:-0}"
    if [ "$healthy" = 0 ]; then
        printf '\n%sDone.%s\n' "${C_OK}" "${C_OFF}"
    else
        printf '\n%sDone, but some checks failed (see above).%s\n' "${C_WARN}" "${C_OFF}"
    fi
    has mainsail && echo "  Mainsail    http://${HOST_IP}/"
    has spoolman && echo "  Spoolman    http://${HOST_IP}:7912/"
    echo "  Moonraker   http://${HOST_IP}:7125/"
    echo "  Camera      http://${PRINTER_IP}/webcam/?action=stream"
    cat <<EOF

AutoPA, PrintGuard and the upstream Moonraker self-updater are not installed. Update this
stack by re-running:
  $0

Calibration notes: ${Q2_ROOT}/docs/calibration.md
EOF
}

do_install() {
    banner
    if [ "$DRY_RUN" = 1 ]; then
        info "Dry run: bundle, firmware, checksums and preflight are valid."
        info "Nothing was installed, no printer was contacted and no MCU was flashed."
        exit 0
    fi
    cat <<EOF

This will:
  1. install Klipper, Moonraker, Happy Hare and the selected web components on this host
EOF
    if [ "$HOST_ONLY" = 1 ]; then
        cat <<EOF
  2. NOT touch the printer (--host-only)
EOF
    else
        cat <<EOF
  2. convert the printer board into a serial proxy (its own Klipper/Moonraker stop)
  3. flash the mainboard, toolhead (THR) and Qidi Box (MMU) with $(firmware_id_label)
EOF
        [ "$NO_FLASH" = 1 ] && echo "     (skipped: --no-flash)"
        if [ "$NO_CAMERA" = 1 ]; then
            echo "  4. leave the printer camera as it is (--skip-camera)"
        else
            echo "  4. keep the stock crowsnest + nginx camera enabled and verify /webcam/"
        fi
        echo
        echo "A backup of the printer configuration is made before any printer-side change."
    fi
    cat <<EOF

Read README.md (flashing warnings) first.
EOF
    if [ "$ASSUME_YES" != 1 ]; then
        confirm "Continue?" n || exit 0
    fi

    if [ "$HOST_ONLY" != 1 ]; then
        host_firmware
    fi
    host_install_all

    if [ "$HOST_ONLY" = 1 ]; then
        if [ "$Q2_CI" != 1 ]; then
            host_start
            host_ui_defaults || warn "Mainsail default layout was not applied"
        fi
        host_only_summary
        return 0
    fi

    printer_prepare
    proot backup

    if [ "$NO_FLASH" = 1 ]; then
        [ -n "$(printer_firmware_id)" ] \
            || fail "the printer has no Q2 Klipper firmware yet; drop --no-flash to flash it"
        info "Skipping the MCU flash (--no-flash)"
    else
        local on_printer flash_default=y
        on_printer="$(printer_firmware_id)"
        if [ -z "$on_printer" ] && ! printer_katapult_installed; then
            if confirm "Is this the first conversion from Qidi's STOCK firmware?" y; then
                printer_fetch_deployers
                printer_convert deploy
            else
                fail "no Q2 Klipper firmware detected on the printer; nothing was flashed"
            fi
        else
            if [ "$on_printer" = "$(firmware_id)" ]; then
                flash_default=n
                info "The printer already runs firmware $(firmware_id)"
            elif [ -z "$on_printer" ]; then
                info "Katapult is already installed on the printer: no Klipper firmware yet"
            else
                info "The printer runs firmware ${on_printer}, the bundle is $(firmware_id)"
            fi
            if confirm "Flash Klipper firmware $(firmware_id) to the mainboard, toolhead and Box now?" "$flash_default"; then
                printer_convert
            else
                warn "no firmware flashed: the printer keeps its current firmware. Klipper may refuse to start until it is flashed; run this installer again and answer yes"
            fi
        fi
    fi

    printer_proxies
    [ "$NO_CAMERA" = 1 ] || printer_camera
    host_start
    wait_ready || true
    host_ui_defaults || warn "Mainsail default layout was not applied"

    if [ "$SKIP_CALIBRATION" != 1 ] && klipper_ready; then
        calibrate_load_cell_tare || true
        calibrate_offer
    fi

    local healthy=0
    verify_install || healthy=1
    final_notes "$healthy"
}

# Flash only: the printer's three MCUs get the bundled firmware, and this host's Klipper is
# rebuilt to the same version. Host packages, components and config are left alone.
do_flash_only() {
    [ -f "$SETTINGS" ] || fail "nothing is installed yet: run ./install-klipper.sh first"
    [ "$HOST_ONLY" != 1 ] && [ "$NO_FLASH" != 1 ] || fail "--flash-only cannot be combined with --host-only or --no-flash"
    [ "$PRINTER_IS_PLACEHOLDER" = 0 ] || fail "no printer found: pass --printer <ip>"
    banner
    if [ "$DRY_RUN" = 1 ]; then
        info "Dry run: would flash the bundled firmware $(firmware_id_label) to the printer. Nothing was changed."
        exit 0
    fi
    printing && fail "a print is running: flash after it ends"
    host_firmware
    host_klipper
    printer_prepare
    proot backup
    printer_convert
    proot proxies-start
    host_start
    wait_ready || true
    verify_install || warn "some checks failed: see the FAIL lines above"
}

if [ "$FLASH_ONLY" = 1 ]; then do_flash_only; else do_install; fi
