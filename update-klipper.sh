#!/usr/bin/env bash
# Update this Klipper machine from the Q2 Klipper bundle. Run it on the Klipper host.
#
# With a bundle repo set, the newest bundle is fetched from it first. Then
# install-klipper.sh update runs: host software and configs are updated, and the printer
# boards are compiled and flashed only when the pinned Klipper changed (it asks first).
#
# Usage:
#   ./update-klipper.sh                    update from the saved bundle repo, or this folder
#   ./update-klipper.sh --repo <git-url>   save the bundle repo for later runs, then update
#   ./update-klipper.sh --local            update from this folder, no download
#   any other option is passed to install-klipper.sh update (e.g. --yes, --printer <ip>)
set -Eeuo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/q2-klipper-bundle"
UPDATE_CONF="${CONF_DIR}/update.env"
CLONE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/q2-klipper-bundle/src"

die() { echo "ERROR: $*" >&2; exit 1; }

repo=""; local_only=0; passthrough=()
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="${2:?--repo needs a git URL}"; shift 2 ;;
        --local) local_only=1; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) passthrough+=("$1"); shift ;;
    esac
done

Q2_BUNDLE_REPO=""; Q2_BUNDLE_BRANCH=main
# shellcheck disable=SC1090
[ -f "$UPDATE_CONF" ] && . "$UPDATE_CONF"
if [ -n "$repo" ]; then
    mkdir -p "$CONF_DIR"
    printf 'Q2_BUNDLE_REPO=%s\nQ2_BUNDLE_BRANCH=%s\n' "$repo" "$Q2_BUNDLE_BRANCH" > "$UPDATE_CONF"
    Q2_BUNDLE_REPO="$repo"
    echo "bundle repo saved: ${repo}"
fi

target="$BUNDLE_DIR"
if [ "$local_only" = 0 ] && [ -n "$Q2_BUNDLE_REPO" ]; then
    command -v git >/dev/null || die "git is needed to fetch the bundle"
    if [ -d "${CLONE_DIR}/.git" ]; then
        git -C "$CLONE_DIR" remote set-url origin "$Q2_BUNDLE_REPO"
        git -C "$CLONE_DIR" fetch -q origin "$Q2_BUNDLE_BRANCH"
    else
        mkdir -p "$(dirname "$CLONE_DIR")"
        git clone -q --branch "$Q2_BUNDLE_BRANCH" "$Q2_BUNDLE_REPO" "$CLONE_DIR"
    fi
    # The clone is managed by this script: it is never edited by hand
    git -C "$CLONE_DIR" reset -q --hard "origin/${Q2_BUNDLE_BRANCH}"
    target="$CLONE_DIR"
    echo "bundle: ${Q2_BUNDLE_REPO} @ $(git -C "$CLONE_DIR" rev-parse --short HEAD)"
else
    echo "bundle: ${BUNDLE_DIR} (local)"
fi

[ -f "${target}/install-klipper.sh" ] || die "no install-klipper.sh in ${target}"
exec bash "${target}/install-klipper.sh" update ${passthrough[@]+"${passthrough[@]}"}
