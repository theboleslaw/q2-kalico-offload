# shellcheck shell=bash
# Klipper host side of install.sh. Source after lib.sh; expects the settings variables
# (PRINTER_IP, HOST_IP, COMPONENTS...) to be set.

DATA="${HOME}/printer_data"
CFG="${DATA}/config"
# Stock Qidi Box tube, Box shared exit sensor to the toolhead (mm, measured on a Q2)
BOX_BOWDEN_LENGTH=763.2
STATE_DIR="${HOME}/.config/q2-klipper"
MANIFEST="${STATE_DIR}/installed-files.sha256"
KLIPPY_ENV="${HOME}/klippy-env"

has() { [[ ",${COMPONENTS}," == *",$1,"* ]]; }

# The unattended update runs its root phase as root: sudo is then a no-op
# (env keeps "sudo VAR=value cmd" working).
if [ "$(id -u)" = 0 ]; then sudo() { env "$@"; }; fi

# Tell the user in the Mainsail console and in logs/q2-klipper-update.log
notify() {
    echo "Q2 Klipper: $*"
    curl -s -o /dev/null -X POST -G --data-urlencode "script=RESPOND TYPE=command MSG=\"Q2 Klipper: $*\"" \
        localhost:7125/printer/gcode/script 2>/dev/null || true
}

# Same, as a dialog in Mainsail (Klipper prompt protocol): for messages that
# ask the user to do something. One argument per paragraph, without double quotes or ;
notify_dialog() {
    local title="$1" line script
    shift
    echo "Q2 Klipper: ${title}"
    printf '  %s\n' "$@"
    script="RESPOND TYPE=command MSG=\"action:prompt_begin Q2 Klipper: ${title}\""
    for line in "$@"; do
        script+=$'\n'"RESPOND TYPE=command MSG=\"action:prompt_text ${line}\""
    done
    script+=$'\n'"RESPOND TYPE=command MSG=\"action:prompt_footer_button Close|RESPOND TYPE=command MSG=action:prompt_end\""
    script+=$'\n'"RESPOND TYPE=command MSG=\"action:prompt_show\""
    script+=$'\n'"RESPOND TYPE=command MSG=\"Q2 Klipper: ${title} (details: logs/q2-klipper-update.log)\""
    curl -s -o /dev/null -X POST -G --data-urlencode "script=${script}" \
        localhost:7125/printer/gcode/script 2>/dev/null || true
}

# Systemd/nginx/docker are skipped in CI containers
in_ci() { [ "${Q2_CI:-0}" = 1 ]; }

svc() { in_ci || sudo systemctl "$@"; }

# Moonraker's name for the update channel: "latest" follows its beta tags
moonraker_channel() { if [ "${UPDATE_CHANNEL:-stable}" = latest ]; then echo beta; else echo stable; fi; }

render() {
    sed -e "s#@HOME@#${HOME}#g" \
        -e "s#@USER@#${USER}#g" \
        -e "s#@PRINTER_IP@#${PRINTER_IP}#g" \
        -e "s#@HOST_IP@#${HOST_IP}#g" \
        -e "s#@Q2_ROOT@#${Q2_ROOT}#g" \
        -e "s#@Q2_ORIGIN@#${Q2_ORIGIN}#g" \
        -e "s#@MAINSAIL_PORT@#${MAINSAIL_PORT}#g" \
        -e "s#@Q2_CHANNEL@#$(moonraker_channel)#g" \
        "$1"
}

# Uncomment "#@NAME@" lines when component NAME is selected, drop them otherwise.
toggle() {
    local name
    local args=()
    # AutoPA and PrintGuard are intentionally not part of this bundle.
    for name in MAINSAIL SPOOLMAN; do
        if has "${name,,}"; then args+=(-e "s/^#@${name}@//"); else args+=(-e "/^#@${name}@/d"); fi
    done
    sed "${args[@]}"
}

manifest_set() {
    grep -v "  $2\$" "$MANIFEST" > "${MANIFEST}.tmp" || true
    echo "$1  $2" >> "${MANIFEST}.tmp"
    mv "${MANIFEST}.tmp" "$MANIFEST"
}

# install_config <rendered-content-file> <dest>: write a file we own, without clobbering
# local edits. A file changed since we installed it gets the new version as <dest>.new.
install_config() {
    local src="$1" dest="$2" old_sum cur_sum new_sum
    mkdir -p "$(dirname "$dest")" "$STATE_DIR"
    touch "$MANIFEST"
    new_sum="$(sha256sum < "$src" | cut -d' ' -f1)"
    if [ -e "$dest" ]; then
        cur_sum="$(sha256sum < "$dest" | cut -d' ' -f1)"
        old_sum="$(awk -v f="$dest" '$2 == f {print $1}' "$MANIFEST")"
        if [ "$cur_sum" = "$new_sum" ]; then
            manifest_set "$new_sum" "$dest"
            return 0
        fi
        if [ -n "$old_sum" ] && [ "$cur_sum" != "$old_sum" ]; then
            cp "$src" "${dest}.new"
            warn "kept your edited ${dest#"${HOME}"/}; new version saved as ${dest#"${HOME}"/}.new"
            return 0
        fi
        if [ -z "$old_sum" ]; then
            cp "$dest" "${dest}.pre-q2-klipper"
            warn "existing ${dest#"${HOME}"/} saved as .pre-q2-klipper"
        fi
    fi
    cp "$src" "$dest"
    manifest_set "$new_sum" "$dest"
}

host_packages() {
    local pkgs=(git curl unzip socat python3 python3-venv python3-dev build-essential libffi-dev
                libncurses-dev zlib1g-dev)
    has mainsail && pkgs+=(nginx)
    info "Installing system packages"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null
    if has spoolman && ! command -v docker >/dev/null; then
        info "Installing Docker (Spoolman)"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null
        svc enable --now docker
    fi
}

host_dirs() {
    mkdir -p "${DATA}"/{config,logs,gcodes,systemd,comms,scripts/plr}
}

host_klipper() {
    "${Q2_ROOT}/scripts/prepare-klipper.sh" "${HOME}/klipper"
    if [ ! -x "${KLIPPY_ENV}/bin/python" ]; then
        info "Creating the Klipper Python environment"
        python3 -m venv "$KLIPPY_ENV"
    fi
    "${KLIPPY_ENV}/bin/pip" install -q --upgrade pip
    # numpy: input shaper; scipy: load cell continuous tare filter
    "${KLIPPY_ENV}/bin/pip" install -q -r "${HOME}/klipper/scripts/klippy-requirements.txt" numpy scipy
    # The C helper is normally built on first start; build it now so errors show up here
    "${KLIPPY_ENV}/bin/python" -c "import sys; sys.path.insert(0, '${HOME}/klipper/klippy'); import chelper; chelper.get_ffi()"
    ok "Klipper $(git -C "${HOME}/klipper" describe --tags --always)"
}

host_extensions() {
    local tmp
    checkout_ref "$TIMELAPSE_REPO" "$TIMELAPSE_REF" "${HOME}/moonraker-timelapse"
    checkout_ref "$MAINSAIL_CONFIG_REPO" "$MAINSAIL_CONFIG_REF" "${HOME}/mainsail-config"
    ln -sfn "${HOME}/moonraker-timelapse/component/timelapse.py" "${HOME}/moonraker/moonraker/components/timelapse.py"
    ln -sfn "${HOME}/moonraker-timelapse/klipper_macro/timelapse.cfg" "${CFG}/timelapse.cfg"
    ln -sfn "${HOME}/mainsail-config/mainsail.cfg" "${CFG}/mainsail.cfg"
    # Kalico already ships klippy/extras/gcode_shell_command.py; nothing to fetch here
    [ -s "${HOME}/klipper/klippy/extras/gcode_shell_command.py" ] \
        || die "Kalico is missing klippy/extras/gcode_shell_command.py"
    ok "timelapse, mainsail-config, gcode_shell_command (Kalico built-in)"
}

host_moonraker() {
    local tmp
    checkout_ref "$MOONRAKER_REPO" "$MOONRAKER_REF" "${HOME}/moonraker"
    tmp="$(mktemp)"
    render "${Q2_ROOT}/host/moonraker.conf" | toggle > "$tmp"
    # moonraker.conf is the user's after the first install: never overwritten
    [ -e "${CFG}/moonraker.conf" ] || cp "$tmp" "${CFG}/moonraker.conf"
    rm -f "$tmp"
    # A component selected after the first install still needs its Moonraker section
    if has spoolman && ! grep -q '^\[spoolman\]' "${CFG}/moonraker.conf"; then
        printf '\n[spoolman]\nserver: http://localhost:7912\nsync_rate: 5\n' >> "${CFG}/moonraker.conf"
    fi
    moonraker_conf_migrate
    info "Installing Moonraker"
    local args=(-f -s)
    in_ci && args+=(-z -x)
    "${HOME}/moonraker/scripts/install-moonraker.sh" "${args[@]}" >/dev/null
    moonraker_asvc
    ok "Moonraker $(git -C "${HOME}/moonraker" describe --tags --always)"
}

# Unattended update, user phase: no sudo available, so only the checkout and Python deps
# (system packages are handled by moonraker_sysdeps in the root phase)
host_moonraker_update() {
    local before after
    before="$(git -C "${HOME}/moonraker" rev-parse HEAD 2>/dev/null || true)"
    checkout_ref "$MOONRAKER_REPO" "$MOONRAKER_REF" "${HOME}/moonraker"
    after="$(git -C "${HOME}/moonraker" rev-parse HEAD)"
    if [ "$before" != "$after" ]; then
        "${HOME}/moonraker-env/bin/pip" install -q -r "${HOME}/moonraker/scripts/moonraker-requirements.txt" \
            -r "${HOME}/moonraker/scripts/moonraker-speedups.txt"
        touch "${STATE_DIR}/moonraker-changed"
    fi
    moonraker_conf_migrate
    moonraker_asvc
    ok "Moonraker $(git -C "${HOME}/moonraker" describe --tags --always)"
}

moonraker_sysdeps() {
    local pkgs
    pkgs="$(python3 -c 'import json,sys; print(" ".join(p for p in json.load(open(sys.argv[1]))["debian"] if ";" not in p))' \
        "${HOME}/moonraker/scripts/system-dependencies.json")"
    # shellcheck disable=SC2086
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null
}

# Older moonraker.conf files point Moonraker at /tmp/klippy_uds. Keep the socket path in
# sync. This bundle is updated by re-running install-klipper.sh, not by Moonraker.
moonraker_conf_migrate() {
    python3 - "${CFG}/moonraker.conf" "${DATA}/comms/klippy.sock" <<'EOF'
import re, sys
path, klippy_sock = sys.argv[1:3]
s = open(path).read()
srv = re.search(r'^\[server\]\n', s, re.M)
if srv and not re.search(r'^klippy_uds_address\s*:', s, re.M):
    s = s[:srv.end()] + 'klippy_uds_address: %s\n' % klippy_sock + s[srv.end():]
open(path, 'w').write(s)
EOF
}

moonraker_asvc() {
    local asvc="${DATA}/moonraker.asvc"
    # Moonraker creates it from this default list on first start; do the same.
    [ -f "$asvc" ] || cp "${HOME}/moonraker/moonraker/assets/default_allowed_services" "$asvc"
    # This bundle has no self-updater service.
    if [ -f "$asvc" ]; then
        grep -vx q2-klipper "$asvc" > "${asvc}.tmp" || true
        mv "${asvc}.tmp" "$asvc"
    fi
}

# Drop a whole [section] from an ini-style file (Happy Hare re-adds its update_manager entry)
drop_section() {
    python3 - "$1" "$2" <<'EOF'
import re, sys
path, section = sys.argv[1], sys.argv[2]
out, skip = [], False
for line in open(path).read().split('\n'):
    m = re.match(r'^\[([^\]]+)\]', line)
    if m:
        skip = m.group(1).strip() == section
    if not skip:
        out.append(line)
open(path, 'w').write('\n'.join(out))
EOF
}

host_happy_hare() {
    local hh="${HOME}/Happy-Hare"
    checkout_ref "$HAPPY_HARE_REPO" "$HAPPY_HARE_REF" "$hh"
    apply_patches "$hh" "${Q2_ROOT}/patches/happy-hare" q2-klipper
    # Happy Hare refuses a config made for another major.minor: take the checkout's own version
    local version
    version="$(sed -n 's/^VERSION = "\([^"]*\)".*/\1/p' "${hh}/extras/mmu/mmu_constants.py")"
    [ -n "$version" ] || die "could not read the Happy Hare version from ${hh}/extras/mmu/mmu_constants.py"
    render "${Q2_ROOT}/config/happy-hare/mmu_config" \
        | sed "s#@HAPPY_HARE_VERSION@#${version}#" > "${hh}/.mmu_config"
    info "Installing Happy Hare (Qidi Box profile)"
    (cd "$hh" && ./install.sh -z -s -y) > "${STATE_DIR}/happy-hare-install.log" 2>&1 \
        || { tail -20 "${STATE_DIR}/happy-hare-install.log"; die "Happy Hare install failed (log: ${STATE_DIR}/happy-hare-install.log)"; }
    python3 "${Q2_ROOT}/scripts/apply-overrides.py" "${Q2_ROOT}/config/happy-hare/overrides.cfg" \
        "${CFG}/mmu/base" --home "$HOME"
    drop_section "${CFG}/moonraker.conf" "update_manager happy-hare"
    ok "Happy Hare $(git -C "$hh" describe --tags --always 2>/dev/null || git -C "$hh" rev-parse --short HEAD)"
}

host_config() {
    local f tmp
    tmp="$(mktemp)"
    for f in "${Q2_ROOT}"/config/klipper/*.cfg; do
        render "$f" | toggle > "$tmp"
        if [ "$(basename "$f")" = printer.cfg ]; then
            # printer.cfg carries the SAVE_CONFIG calibrations: only written on first install
            [ -e "${CFG}/printer.cfg" ] && [ -z "$(awk -v f="${CFG}/printer.cfg" '$2 == f' "$MANIFEST" 2>/dev/null)" ] \
                && { warn "keeping your existing printer.cfg"; continue; }
        fi
        install_config "$tmp" "${CFG}/$(basename "$f")"
    done
    for f in "${Q2_ROOT}"/config/plr/*.sh; do
        render "$f" > "$tmp"
        install_config "$tmp" "${DATA}/scripts/plr/$(basename "$f")"
        chmod +x "${DATA}/scripts/plr/$(basename "$f")"
    done
    # Single variables file shared by the Qidi macros and Happy Hare (which checks mmu__revision)
    # Bowden length of the stock Box-to-toolhead tube, so loading works before MMU_CALIBRATE_BOWDEN
    [ -e "${CFG}/saved_variables.cfg" ] || printf '%s\n' '[Variables]' 'mmu__revision = 0' \
        "mmu_unit0_bowden_home = 'mmu_shared_exit'" \
        "mmu_unit0_bowden_lengths = [${BOX_BOWDEN_LENGTH}, ${BOX_BOWDEN_LENGTH}, ${BOX_BOWDEN_LENGTH}, ${BOX_BOWDEN_LENGTH}]" \
        > "${CFG}/saved_variables.cfg"
    if has mainsail; then
        mkdir -p "${CFG}/.theme"
        python3 "${Q2_ROOT}/scripts/navi.py" "$COMPONENTS" "$HOST_IP" "$MAINSAIL_PORT" > "$tmp"
        install_config "$tmp" "${CFG}/.theme/navi.json"
    fi
    rm -f "$tmp"
    ok "Klipper configuration in ${CFG}"
}

web_client() {
    local name="$1" repo="$2" version="$3" tmp
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/${repo}/releases/download/${version}/${name}.zip" -o "${tmp}/${name}.zip"
    rm -rf "${HOME:?}/${name}.new" && mkdir -p "${HOME}/${name}.new"
    unzip -q "${tmp}/${name}.zip" -d "${HOME}/${name}.new"
    # Keep Mainsail's config.json across updates
    [ -f "${HOME}/${name}/config.json" ] && cp "${HOME}/${name}/config.json" "${HOME}/${name}.new/"
    rm -rf "${HOME:?}/${name}" && mv "${HOME}/${name}.new" "${HOME}/${name}"
    rm -rf "$tmp"
    ok "${name} ${version}"
}

host_web_clients() {
    if has mainsail; then web_client mainsail mainsail-crew/mainsail "$MAINSAIL_VERSION"; fi
    host_box_page
}

# Box drying page, served by nginx at /box/ (the copy keeps it working if the repo moves)
host_box_page() {
    has mainsail || return 0
    install -D -m 644 "${Q2_ROOT}/web/box/index.html" "${DATA}/web/box/index.html"
    ok "Box drying page /box/"
}

host_web() {
    host_web_clients
    host_nginx
}

host_nginx() {
    has mainsail || return 0
    in_ci && return 0
    local tmp site
    tmp="$(mktemp)"
    # A previous cedbossneo/q2-offload (or other) install may have left a site
    # that also declares `default_server` on :80, which makes nginx refuse to
    # start. Drop any enabled site that is not ours and that carries default_server.
    for site in /etc/nginx/sites-enabled/*; do
        [ -e "$site" ] || continue
        [ "$(basename "$site")" = "q2-klipper" ] && continue
        if grep -q 'listen .*default_server' "$site" 2>/dev/null; then
            warn "removing conflicting nginx site $(basename "$site") (default_server on :80)"
            sudo rm -f "$site"
        fi
    done
    render "${Q2_ROOT}/host/nginx/q2-klipper.conf" > "$tmp"
    sudo install -m 644 "$tmp" /etc/nginx/sites-available/q2-klipper
    render "${Q2_ROOT}/host/nginx/q2-klipper-common.conf" > "$tmp"
    sudo install -m 644 "$tmp" /etc/nginx/q2-klipper-common.conf
    rm -f "$tmp"
    sudo ln -sfn /etc/nginx/sites-available/q2-klipper /etc/nginx/sites-enabled/q2-klipper
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t -q || die "nginx configuration test failed"
    svc enable nginx
    svc reload nginx || svc restart nginx
    # nginx (www-data) must be able to read the web clients in $HOME
    chmod o+x "$HOME"
    ok "nginx: Mainsail :${MAINSAIL_PORT}"
}

host_spoolman() {
    has spoolman || return 0
    in_ci && return 0
    mkdir -p "${HOME}/spoolman-data"
    # The image runs as uid 1000 unless told otherwise: the data dir belongs to this user.
    # $USER, not id -u: the unattended update runs this as root, and Spoolman refuses PUID 0.
    local want uid gid
    uid="$(id -u "$USER")"; gid="$(id -g "$USER")"
    want="ghcr.io/donkie/spoolman:${SPOOLMAN_VERSION#v} PUID=${uid}"
    if sudo docker inspect spoolman >/dev/null 2>&1; then
        [ "$(sudo docker inspect -f '{{.Config.Image}} {{range .Config.Env}}{{if eq (index (split . "=") 0) "PUID"}}{{.}}{{end}}{{end}}' spoolman)" = "$want" ] \
            && { ok "Spoolman ${SPOOLMAN_VERSION}"; return 0; }
        sudo docker rm -f spoolman >/dev/null
    fi
    sudo docker run -d --name spoolman --restart unless-stopped -p 7912:8000 \
        -e TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)" -e PUID="$uid" -e PGID="$gid" \
        -v "${HOME}/spoolman-data:/home/app/.local/share/spoolman" \
        "ghcr.io/donkie/spoolman:${SPOOLMAN_VERSION#v}" >/dev/null
    ok "Spoolman ${SPOOLMAN_VERSION} on :7912"
}

host_services() {
    in_ci && return 0
    local tmp
    tmp="$(mktemp)"
    render "${Q2_ROOT}/host/systemd/klipper.env" > "${DATA}/systemd/klipper.env"
    [ "$(id -u)" = 0 ] && chown "${USER}:" "${DATA}/systemd/klipper.env"
    render "${Q2_ROOT}/host/systemd/klipper.service" > "$tmp"
    sudo install -m 644 "$tmp" /etc/systemd/system/klipper.service
    render "${Q2_ROOT}/host/systemd/q2-serial-bridge@.service" > "$tmp"
    sudo install -m 644 "$tmp" /etc/systemd/system/q2-serial-bridge@.service
    rm -f "$tmp"
    # This bundle has no self-updater: re-run install-klipper.sh instead.
    sudo systemctl daemon-reload
    sudo systemctl enable -q klipper q2-serial-bridge@main:7001 q2-serial-bridge@thr:7002 q2-serial-bridge@mmu:7003
    ok "systemd units (klipper, q2-serial-bridge@main/thr/mmu)"
}

host_start() {
    info "Starting the serial bridges, Klipper and Moonraker on this host"
    sudo systemctl restart q2-serial-bridge@main:7001 q2-serial-bridge@thr:7002 q2-serial-bridge@mmu:7003
    sleep 2
    sudo systemctl restart klipper moonraker
}

# Arm GNU Toolchain from VERSIONS, downloaded once into the user's home and checked against
# its SHA-256 before it is unpacked. Puts its bin/ first on PATH for the firmware build.
host_arm_toolchain() {
    local root="${HOME}/.local/share/q2-klipper/toolchain" dir tmp
    dir="${root}/${ARM_TOOLCHAIN_VERSION}"
    [ "$(uname -m)" = x86_64 ] || die "the Arm toolchain is downloaded for x86_64 hosts only (this one is $(uname -m))"
    if [ ! -x "${dir}/bin/arm-none-eabi-gcc" ]; then
        tmp="$(mktemp -d)"
        info "Downloading the Arm GNU Toolchain ${ARM_TOOLCHAIN_VERSION}"
        curl -fsSL "$ARM_TOOLCHAIN_URL" -o "${tmp}/toolchain.tar.xz" \
            || { rm -rf "$tmp"; die "could not download the Arm toolchain from ${ARM_TOOLCHAIN_URL}"; }
        echo "${ARM_TOOLCHAIN_SHA256}  ${tmp}/toolchain.tar.xz" | sha256sum -c --quiet \
            || { rm -rf "$tmp"; die "Arm toolchain checksum mismatch: not installed"; }
        tar xJf "${tmp}/toolchain.tar.xz" -C "$tmp"
        rm -rf "$dir" && mkdir -p "$root"
        mv "${tmp}/arm-gnu-toolchain-${ARM_TOOLCHAIN_VERSION}-x86_64-arm-none-eabi" "$dir"
        rm -rf "$tmp"
    fi
    export PATH="${dir}/bin:${PATH}"
    ok "Arm GNU Toolchain ${ARM_TOOLCHAIN_VERSION} ($(arm-none-eabi-gcc --version | head -1))"
}

# Fetch the published release firmware for <id> into <dir>. Fails when it is not published.
host_download_firmware() {
    local id="$1" dir="$2" f
    local base="https://github.com/${Q2_GITHUB_REPO}/releases/download/fw-${id}"
    info "Downloading firmware ${id}"
    for f in SHA256SUMS BUILD_INFO q2-main.bin q2-thr.bin q2-box.bin q2-main.dict q2-thr.dict q2-box.dict; do
        curl -fsSL "${base}/${f}" -o "${dir}/${f}" || return 1
    done
}

# Use the firmware shipped next to this bundle when it matches the patched Klipper tree.
# Otherwise fetch the matching upstream release, or build it locally with --build-firmware.
host_firmware() {
    local id dir bundle_id
    id="$(firmware_id)"
    local bundled="${Q2_BUNDLE_DIR:-$(dirname "$Q2_ROOT")}/vendor/firmware"
    if [ "${BUILD_FIRMWARE:-0}" != 1 ] && [ -s "${bundled}/q2-main.bin" ] && [ -s "${bundled}/SHA256SUMS" ] \
        && (cd "$bundled" && sha256sum -c --quiet SHA256SUMS); then
        bundle_id="$(sed -n 's/^FIRMWARE_ID=//p' "${bundled}/BUILD_INFO" 2>/dev/null || true)"
        if [ "$bundle_id" = "$id" ]; then
            export FIRMWARE_DIR="$bundled"
            ok "bundled firmware ${id}"
            return 0
        fi
        warn "bundled firmware is ${bundle_id:-unknown}, this source tree needs ${id}"
    fi
    dir="${STATE_DIR}/firmware/${id}"
    if [ -s "${dir}/q2-main.bin" ] && (cd "$dir" && sha256sum -c --quiet SHA256SUMS); then
        export FIRMWARE_DIR="$dir"; return 0
    fi
    mkdir -p "$dir"
    if [ "${BUILD_FIRMWARE:-0}" != 1 ] && host_download_firmware "$id" "$dir"; then
        :
    else
        [ "${BUILD_FIRMWARE:-0}" = 1 ] || warn "firmware fw-${id} is not published: building it on this host (about 10 minutes)"
        info "Building firmware ${id} locally"
        host_arm_toolchain
        "${Q2_ROOT}/scripts/prepare-klipper.sh" "${STATE_DIR}/klipper-build"
        "${Q2_ROOT}/scripts/build-firmware.sh" "${STATE_DIR}/klipper-build" "$dir"
    fi
    (cd "$dir" && sha256sum -c --quiet SHA256SUMS) || die "firmware checksum mismatch in ${dir}"
    local m mcu
    for m in main:stm32f407xx thr:stm32f103xe box:stm32f401xc; do
        mcu="${m#*:}"; m="${m%%:*}"
        grep -Eq "\"MCU\": *\"${mcu}\"" "${dir}/q2-${m}.dict" || die "q2-${m} is not built for ${mcu}"
    done
    export FIRMWARE_DIR="$dir"
    ok "firmware ${id}"
}

host_install_all() {
    host_packages
    host_dirs
    if [ "${KEEP_KLIPPER:-0}" = 1 ]; then info "Klipper kept at its current version"; else host_klipper; fi
    host_moonraker
    host_extensions
    host_config
    host_happy_hare
    host_web
    host_spoolman
    host_services
}

# Default title and dashboard layout of Mainsail (config/ui/<client>.json), stored
# in Moonraker's database where the clients keep their settings. Only keys the user has not
# set yet are written, so later changes made in the UI are kept.
host_ui_defaults() {
    in_ci && return 0
    local client=mainsail
    has "$client" || return 0
    python3 - "${Q2_ROOT}/config/ui/${client}.json" "$client" <<'PY' || warn "${client}: default layout not applied"
import json, sys, urllib.error, urllib.request
path, ns = sys.argv[1], sys.argv[2]
base = "http://localhost:7125/server/database/item"
for key, value in json.load(open(path)).items():
    try:
        urllib.request.urlopen("%s?namespace=%s&key=%s" % (base, ns, key), timeout=5)
        continue  # already set by the user
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    body = json.dumps({"namespace": ns, "key": key, "value": value}).encode()
    req = urllib.request.Request(base, data=body, headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=5)
PY
    ok "Mainsail: title Qidi Q2 and dashboard layout (where not set yet)"
}
