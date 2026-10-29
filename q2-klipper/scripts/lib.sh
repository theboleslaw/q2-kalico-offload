# shellcheck shell=bash
# Shared helpers for install.sh, the build scripts and CI. Source, do not execute.

Q2_ROOT="${Q2_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../VERSIONS
. "${Q2_ROOT}/VERSIONS"

if [ -t 1 ]; then
    C_INFO=$'\e[36m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_OFF=$'\e[0m'
else
    C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_OFF=''
fi

info() { printf '%s==>%s %s\n' "${C_INFO}" "${C_OFF}" "$*"; }
ok()   { printf '%s ok%s %s\n' "${C_OK}" "${C_OFF}" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "${C_WARN}" "${C_OFF}" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "${C_ERR}" "${C_OFF}" "$*" >&2; exit 1; }

# Ask a yes/no question; default answer in $2 (y|n). ASSUME_YES=1 answers yes.
confirm() {
    local prompt="$1" default="${2:-n}" reply
    if [ "${ASSUME_YES:-0}" = 1 ]; then return 0; fi
    [ -t 0 ] || die "'${prompt}' needs an answer: run in a terminal or pass --yes"
    read -r -p "${prompt} [$( [ "$default" = y ] && echo Y/n || echo y/N )] " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# Ask the user to type an exact phrase (used before anything that can brick an MCU).
confirm_phrase() {
    local phrase="$1" reply
    [ -t 0 ] || die "Interactive confirmation required for: ${phrase}"
    read -r -p "Type '${phrase}' to continue: " reply
    [ "$reply" = "$phrase" ] || die "Confirmation did not match, nothing was done"
}

# checkout_ref <repo-url> <ref> <dir>: clone if needed, then detach at <ref>.
# A clone left by another install (a fork, a single-branch or shallow clone) may not have
# <ref> ("fatal: unable to read tree"): its origin is pointed at <repo-url> and <ref> is
# fetched by itself when the branches did not bring it.
checkout_ref() {
    local url="$1" ref="$2" dir="$3" origin
    if [ ! -d "${dir}/.git" ]; then
        git clone --quiet --filter=blob:none "$url" "$dir"
    fi
    origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    if [ "${origin%.git}" != "${url%.git}" ]; then
        warn "${dir} comes from ${origin:-no origin}, switching it to ${url}"
        git -C "$dir" remote set-url origin "$url" 2>/dev/null || git -C "$dir" remote add origin "$url"
    fi
    git -C "$dir" fetch --quiet origin
    git -C "$dir" cat-file -e "${ref}^{commit}" 2>/dev/null || git -C "$dir" fetch --quiet origin "$ref"
    git -C "$dir" checkout --quiet --force --detach "$ref"
}

# apply_patches <git-dir> <patch-dir> <branch>: build <branch> = HEAD + every patch.
# A patch that no longer applies but reverse-applies is already upstream: skipped.
# If <patch-dir>/series exists, it drives the order and the application method
# (git-apply vs. patch -p1, for patches that need fuzz); otherwise *.patch in
# lexical order are applied with git-apply.
apply_patches() {
    local dir="$1" pdir="$2" branch="$3" p name method
    git -C "$dir" checkout --quiet -B "$branch"
    if [ -f "${pdir}/series" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            # strip comments and blanks
            line="${line%%#*}"
            [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
            method="$(printf '%s' "$line" | awk '{print $1}')"
            name="$(printf '%s' "$line" | awk '{print $2}')"
            [ -n "$name" ] || die "malformed series line: ${line}"
            p="${pdir}/${name}"
            [ -e "$p" ] || die "missing patch ${p}"
            apply_one_patch "$dir" "$p" "$name" "$method"
        done < "${pdir}/series"
    else
        for p in "${pdir}"/*.patch; do
            [ -e "$p" ] || continue
            name="$(basename "$p")"
            apply_one_patch "$dir" "$p" "$name" git-apply
        done
    fi
}

# Apply a single patch; commit it on success. <method> is git-apply or patch.
apply_one_patch() {
    local dir="$1" p="$2" name="$3" method="$4"
    local short="${name%.patch}"
    if [ "$method" = patch ]; then
        if patch -p1 -R --dry-run -f -s --no-backup-if-mismatch -d "$dir" < "$p" >/dev/null 2>&1; then
            ok "patch ${name} (already applied, skipped)"
            return 0
        fi
        if patch -p1 --forward --batch --no-backup-if-mismatch -d "$dir" < "$p" >/dev/null 2>&1; then
            git -C "$dir" add -A
            git -C "$dir" -c user.name=q2-klipper -c user.email=q2-klipper@users.noreply.github.com \
                commit --quiet -m "q2-klipper: ${short}"
            ok "patch ${name}"
            return 0
        else
            die "patch ${name} does not apply to $(git -C "$dir" rev-parse --short HEAD)"
        fi
    fi
    if git -C "$dir" apply --check "$p" 2>/dev/null; then
        if head -1 "$p" | grep -q '^From '; then
            git -C "$dir" -c user.name=q2-klipper -c user.email=q2-klipper@users.noreply.github.com \
                am --quiet --committer-date-is-author-date "$p"
        else
            git -C "$dir" apply "$p"
            git -C "$dir" add -A
            git -C "$dir" -c user.name=q2-klipper -c user.email=q2-klipper@users.noreply.github.com \
                commit --quiet -m "q2-klipper: ${short}"
        fi
        ok "patch ${name}"
    elif git -C "$dir" apply --reverse --check "$p" 2>/dev/null; then
        ok "patch ${name} (already upstream, skipped)"
    else
        die "patch ${name} does not apply to $(git -C "$dir" rev-parse --short HEAD)"
    fi
}

# Identifier of a firmware build: Klipper ref + hash of the build configs and of the patches
# that reach the MCU build. A host-only patch (klippy/ only) must not ask users to reflash.
# When a series manifest is present, only the listed patches are considered.
firmware_id() {
    local sum p fw_patches=() series="${Q2_ROOT}/patches/klipper/series"
    if [ -f "$series" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
            p="${Q2_ROOT}/patches/klipper/$(printf '%s' "$line" | awk '{print $2}')"
            [ -e "$p" ] || continue
            if grep -Eq '^diff --git a/(src|scripts)/' "$p"; then
                fw_patches+=("$p")
            fi
        done < "$series"
    else
        for p in "${Q2_ROOT}"/patches/klipper/*.patch; do
            [ -e "$p" ] || continue
            grep -Eq '^diff --git a/(src|scripts)/' "$p" && fw_patches+=("$p")
        done
    fi
    if [ "${#fw_patches[@]}" -eq 0 ]; then
        sum="$(cat "${Q2_ROOT}"/firmware/configs/*.config | sha256sum | cut -c1-8)"
    else
        sum="$(cat "${fw_patches[@]}" "${Q2_ROOT}"/firmware/configs/*.config \
            | sha256sum | cut -c1-8)"
    fi
    printf '%s-%s\n' "${KLIPPER_REF:0:9}" "$sum"
}
