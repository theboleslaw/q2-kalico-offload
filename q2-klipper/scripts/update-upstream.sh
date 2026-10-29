#!/usr/bin/env bash
# Check upstream Klipper (branch head) and Happy Hare (latest release) and pin them in
# VERSIONS. A newer version is only taken when every Q2 patch still applies to it, so the
# pin never moves onto a source the firmware and host patches cannot be built from.
# Usage: scripts/update-upstream.sh [--check | --commit | --push]
#   (none)    rewrite VERSIONS
#   --check   report only, change nothing
#   --commit  also commit VERSIONS in the bundle's git repository
#   --push    also push that commit to its origin (used by the scheduled GitHub workflow)
set -Eeuo pipefail
. "$(dirname "$0")/lib.sh"

file="${Q2_ROOT}/VERSIONS"
bundle="$(cd "${Q2_ROOT}/.." && pwd)"
mode="${1:-}"
case "$mode" in
    ""|--check|--commit|--push) ;;
    *) die "usage: $0 [--check | --commit | --push]" ;;
esac

set_var() {
    local key="$1" new="$2" old
    old="$(sed -n "s/^${key}=//p" "$file")"
    [ -n "$new" ] || die "could not resolve ${key}"
    [ "$old" = "$new" ] && return 0
    if [ "$mode" = --check ]; then
        echo "${key}: ${old} -> ${new} (not applied, --check)"
        return 0
    fi
    sed -i "s#^${key}=.*#${key}=${new}#" "$file"
    echo "${key}: ${old} -> ${new}"
}

# Exit status 0 when every patch in <patch-dir> applies to <repo> at <ref>. Run it in a
# subshell: apply_patches exits the shell on the first patch that does not apply.
patches_apply() {
    local repo="$1" ref="$2" patches="$3" tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # $tmp must expand now: it is local to this function
    trap "rm -rf '${tmp}'" EXIT
    git clone -q --filter=blob:none "$repo" "$tmp/src"
    git -C "$tmp/src" checkout -q --detach "$ref"
    apply_patches "$tmp/src" "$patches" q2-check >/dev/null
}

latest_release() {
    curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
        "https://api.github.com/repos/$1/releases/latest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
}

# Commit a tag points to (the peeled line of an annotated tag)
tag_commit() {
    git ls-remote "$1" "refs/tags/$2" "refs/tags/$2^{}" | sort -k2 | tail -1 | cut -f1
}

info "Klipper: checking ${KLIPPER_BRANCH}"
new_klipper="$(git ls-remote "$KLIPPER_REPO" "refs/heads/${KLIPPER_BRANCH}" | cut -f1)"
if [ "$new_klipper" = "$KLIPPER_REF" ]; then
    ok "Klipper ${KLIPPER_REF:0:9} is current"
elif ( patches_apply "$KLIPPER_REPO" "$new_klipper" "${Q2_ROOT}/patches/klipper" ); then
    set_var KLIPPER_REF "$new_klipper"
    warn "Klipper changed: the printer host builds the matching MCU firmware on its next update"
else
    warn "Klipper ${new_klipper:0:9} is newer, but its patches do not apply (or could not be checked): pin kept at ${KLIPPER_REF:0:9}"
fi

info "Happy Hare: checking the latest release"
hh_tag="$(latest_release moggieuk/Happy-Hare)"
if [ "$hh_tag" = "$HAPPY_HARE_RELEASE" ]; then
    ok "Happy Hare ${HAPPY_HARE_RELEASE} is current"
else
    hh_commit="$(tag_commit "$HAPPY_HARE_REPO" "$hh_tag")"
    if ( patches_apply "$HAPPY_HARE_REPO" "$hh_commit" "${Q2_ROOT}/patches/happy-hare" ); then
        set_var HAPPY_HARE_RELEASE "$hh_tag"
        set_var HAPPY_HARE_REF "$hh_commit"
    else
        warn "Happy Hare ${hh_tag} is newer, but a Q2 patch does not apply to it: pin kept at ${HAPPY_HARE_RELEASE}"
    fi
fi

info "HelixScreen: checking the latest release"
hs_tag="$(latest_release prestonbrown/helixscreen)"
if [ "$hs_tag" = "$HELIXSCREEN_RELEASE" ]; then
    ok "HelixScreen ${HELIXSCREEN_RELEASE} is current"
else
    hs_commit="$(tag_commit "$HELIXSCREEN_REPO" "$hs_tag")"
    set_var HELIXSCREEN_RELEASE "$hs_tag"
    set_var HELIXSCREEN_REF "$hs_commit"
    warn "HelixScreen changed: ${HELIXSCREEN_RELEASE} -> ${hs_tag}"
fi

[ "$mode" = --commit ] || [ "$mode" = --push ] || exit 0

git -C "$bundle" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "${bundle} is not a git repository: run git init and add its GitHub origin first"
if git -C "$bundle" diff --quiet -- "$file"; then
    ok "VERSIONS unchanged, nothing to commit"
    exit 0
fi
git -C "$bundle" add -- "$file"
git -C "$bundle" commit -q -m "Update Klipper and Happy Hare pins

$(git -C "$bundle" diff --cached -U0 -- "$file" | sed -n 's/^+\([A-Z_]*=.*\)/\1/p')" -- "$file"
ok "committed VERSIONS"
if [ "$mode" = --push ]; then
    git -C "$bundle" push -q origin HEAD
    ok "pushed to $(git -C "$bundle" remote get-url origin)"
fi
