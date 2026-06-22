#!/bin/bash
set -uo pipefail

# CI environments run `npm install` only to fetch deps — skip post-install entirely.
if [[ "${CI:-}" == "true" || -n "${CI_PIPELINE_ID:-}" ]]; then
    exit 0
fi

_post_install_has_tty() {
    ( : > /dev/tty ) 2>/dev/null
}

_post_install_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -d "${_post_install_dir}/../.git" || -d "${_post_install_dir}/../../.git" ]]; then
    exit 0
fi

# Only run when installed globally via `npm install -g jishushell`.
# (Legacy 'jishushell-cli' / 'jishushell-gui' install paths are kept for
# backward compatibility on existing systems but no new package by those
# names is published.)
# Local installs (npm install, npm run build) skip post-install entirely.
# npm 9+ also sets npm_config_location=global. Keep a filesystem fallback
# because npm's lifecycle env varies between npm versions and package managers.
_is_global_install() {
    [[ "${npm_config_global:-false}" == "true" ]] && return 0
    [[ "${npm_config_location:-}" == "global" ]] && return 0
    local global_root
    global_root="$(npm root -g 2>/dev/null)" || return 1
    [[ "${_post_install_dir}" == "${global_root}/"* ]] && return 0
    return 1
}
if [[ -n "${npm_lifecycle_event:-}" ]] && ! _is_global_install; then
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# JishuShell Post-Install Script
#
# Executed automatically via `npm postinstall` after installing the CLI-only or
# Core+Panel GUI package globally.
# This hook is intentionally package-scoped: it refreshes user-owned wrappers
# and tells the operator to run the user-owned wrapper with sudo for system service
# restart, host repair, and instance migration. Full environment installation
# belongs to install/jishu-install.sh, not npm postinstall.
#
# Skips:
#   • Node.js                    — already installed (npm is running on it)
#   • npm install -g current package — npm just installed the package itself
#
# Sources jishu-install.sh for all shared functions.
# ═══════════════════════════════════════════════════════════════════════════════

backup_postinstall_scripts() {
    local backup_dir="${REAL_HOME}/.jishushell/install"
    mkdir -p "$backup_dir" 2>/dev/null || true
    cp -f "${JISHU_SCRIPT_DIR}/jishu-install.sh"   "${backup_dir}/jishu-install.sh"   2>/dev/null || true
    cp -f "${JISHU_SCRIPT_DIR}/jishu-uninstall.sh" "${backup_dir}/jishu-uninstall.sh" 2>/dev/null || true
    cp -f "${JISHU_SCRIPT_DIR}/post-uninstall.sh"  "${backup_dir}/post-uninstall.sh"  2>/dev/null || true
    chmod +x "${backup_dir}/jishu-uninstall.sh" "${backup_dir}/post-uninstall.sh" 2>/dev/null || true
}

refresh_postinstall_wrappers() {
    local previous_skip="${JISHUSHELL_SKIP_NPM_INSTALL:-}"
    local previous_panel_manage_default="${JISHUSHELL_PANEL_MANAGE_CORE_DEFAULT:-}"
    local refresh_status=0
    export JISHUSHELL_SKIP_NPM_INSTALL=1
    # Legacy single-service upgrades need the refreshed Panel wrapper to recover
    # core until a later privileged system reload installs the split services.
    export JISHUSHELL_PANEL_MANAGE_CORE_DEFAULT=1

    if ! install_jishushell; then
        echo "  [post-install] Warning: could not refresh JishuShell startup wrappers" >&2
        refresh_status=1
    fi

    if [[ -n "$previous_skip" ]]; then
        export JISHUSHELL_SKIP_NPM_INSTALL="$previous_skip"
    else
        unset JISHUSHELL_SKIP_NPM_INSTALL
    fi
    if [[ -n "$previous_panel_manage_default" ]]; then
        export JISHUSHELL_PANEL_MANAGE_CORE_DEFAULT="$previous_panel_manage_default"
    else
        unset JISHUSHELL_PANEL_MANAGE_CORE_DEFAULT
    fi
    return "$refresh_status"
}

refresh_postinstall_wrappers_quiet() {
    refresh_postinstall_wrappers >/dev/null 2>&1
}

write_package_update_pending_marker() {
    local marker="${JISHUSHELL_HOME}/package-update-pending.json"
    mkdir -p "${JISHUSHELL_HOME}" 2>/dev/null || true
    cat > "$marker" <<EOF 2>/dev/null || true
{
  "schemaVersion": 1,
  "reason": "npm-postinstall",
  "createdAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
}
EOF
    if [[ -n "${REAL_USER:-}" ]]; then
        chown "${REAL_USER}:${REAL_GID:-${REAL_USER}}" "$marker" 2>/dev/null || true
    fi
    chmod 644 "$marker" 2>/dev/null || true
}

print_package_only_update_notice() {
    local repair_cmd="$1"
    local wrappers_refreshed="${2:-1}"
    local core_wrapper="${JISHUSHELL_BIN_DIR}/jishushell"
    local legacy_core_wrapper="${JISHUSHELL_BIN_DIR}/jishushell-core-start"
    local panel_wrapper="${JISHUSHELL_BIN_DIR}/jishushell-panel-start"

    postinstall_print ""
    postinstall_print "JishuShell package update"
    postinstall_print "-------------------------"
    postinstall_print "✓ Package files updated"
    if [[ "$wrappers_refreshed" == "1" && ( -x "$core_wrapper" || -x "$legacy_core_wrapper" ) ]]; then
        postinstall_print "✓ CLI wrapper updated"
    fi
    if [[ "$wrappers_refreshed" == "1" && -x "$panel_wrapper" ]]; then
        postinstall_print "✓ Panel wrapper updated"
    fi
    postinstall_print ""
    postinstall_print_yellow "════════════════════════════════════════════════════════════════════"
    postinstall_print_yellow "  ⚠  ACTION REQUIRED — Local repair was NOT run"
    postinstall_print_yellow "     (npm install only updates package files and wrappers)."
    postinstall_print_yellow ""
    postinstall_print_yellow "  1. Run this command to finish the upgrade:"
    postinstall_print ""
    postinstall_print_white_bold "       ${repair_cmd}"
    postinstall_print ""
    if [[ "$wrappers_refreshed" == "1" && -x "$panel_wrapper" ]]; then
        postinstall_print_yellow "  2. After the command above finishes, refresh any open"
        postinstall_print_yellow "     JishuShell browser tab to load the updated UI."
        postinstall_print_yellow ""
    fi
    postinstall_print_yellow "════════════════════════════════════════════════════════════════════"
    postinstall_print ""
}

# When npm's postinstall hook runs inside the outer jishu-install.sh flow, the
# parent installer owns wrapper creation and service start order. This hook only
# preserves uninstall helpers, then exits so services are not started twice.
if [[ "${JISHU_RUNNING_IN_INSTALLER:-0}" == "1" ]]; then
    echo "  [post-install] Detected parent jishu-install.sh — deferring service setup to parent installer"
    JISHU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    source "${JISHU_SCRIPT_DIR}/jishu-install.sh"
    # Web updates from old single-service installs cannot rewrite systemd units
    # without sudo, but they can refresh the user-owned wrappers that those units
    # execute. Service restart is intentionally left to the sudo repair command
    # printed below; use the wrapper path because sudo may not include
    # ~/.jishushell/bin in PATH yet.
    refresh_postinstall_wrappers
    backup_postinstall_scripts
    if [[ "${JISHUSHELL_PACKAGE_UPDATE:-0}" == "1" ]]; then
        write_package_update_pending_marker
        print_package_only_update_notice "sudo ${JISHUSHELL_BIN_DIR}/jishushell repair" "1"
    fi
    exit 0
fi

JISHU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
JISHU_INSTALL_SH="${JISHU_SCRIPT_DIR}/jishu-install.sh"

if [[ ! -f "$JISHU_INSTALL_SH" ]]; then
    echo "ERROR: cannot find jishu-install.sh at ${JISHU_INSTALL_SH}" >&2
    exit 1
fi

# Source shared functions (double-source guard is built in)
# shellcheck disable=SC1090
source "$JISHU_INSTALL_SH"

cleanup_postinstall_keepalive() {
    if [[ -n "${_SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "${_SUDO_KEEPALIVE_PID}" 2>/dev/null || true
        _SUDO_KEEPALIVE_PID=""
    fi
}
trap 'cleanup_postinstall_keepalive; cleanup_tmpfiles' EXIT

postinstall_print() {
    if _post_install_has_tty; then
        printf '%s\n' "$*" >/dev/tty
    else
        printf '%s\n' "$*"
    fi
}

# Color helpers (only emit ANSI codes when stdout/tty is a terminal).
_postinstall_color_supported() {
    if _post_install_has_tty; then
        return 0
    fi
    if [[ -t 1 ]]; then
        return 0
    fi
    return 1
}

postinstall_print_yellow() {
    if _postinstall_color_supported; then
        if _post_install_has_tty; then
            printf '\033[1;33m%s\033[0m\n' "$*" >/dev/tty
        else
            printf '\033[1;33m%s\033[0m\n' "$*"
        fi
    else
        postinstall_print "$*"
    fi
}

postinstall_print_white_bold() {
    if _postinstall_color_supported; then
        if _post_install_has_tty; then
            printf '\033[1;37m%s\033[0m\n' "$*" >/dev/tty
        else
            printf '\033[1;37m%s\033[0m\n' "$*"
        fi
    else
        postinstall_print "$*"
    fi
}

_postinstall_path_under() {
    local child="$1"
    local parent="$2"
    [[ -n "$child" && -n "$parent" ]] || return 1
    child="$(cd "$child" 2>/dev/null && pwd -P || printf '%s' "$child")"
    parent="$(cd "$parent" 2>/dev/null && pwd -P || printf '%s' "$parent")"
    [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

assert_user_owned_global_install() {
    local package_root
    package_root="$(cd "${_post_install_dir}/.." 2>/dev/null && pwd -P || true)"
    local global_prefix
    global_prefix="$(npm prefix -g 2>/dev/null || true)"
    local global_root
    global_root="$(npm root -g 2>/dev/null || true)"
    local preferred_prefix="${REAL_HOME}/.jishushell/npm-global"
    local preferred_package="${npm_package_name:-jishushell}"

    if [[ $EUID -eq 0 || "${REAL_USER:-}" == "root" || "${REAL_HOME:-}" == "/root" ]]; then
        postinstall_print ""
        postinstall_print "ERROR: JishuShell must not be installed as root."
        postinstall_print ""
        postinstall_print "Install it into the real user's npm prefix instead:"
        postinstall_print ""
        postinstall_print_white_bold "  npm install -g --prefix \"${preferred_prefix}\" ${preferred_package}"
        postinstall_print "  # For a local tarball, replace ${preferred_package} with ./jishushell-<version>.tgz"
        postinstall_print_white_bold "  sudo env JISHUSHELL_HOME=\"${JISHUSHELL_HOME}\" HOME=\"${REAL_HOME}\" \"${JISHUSHELL_BIN_DIR}/jishushell\" repair"
        postinstall_print ""
        exit 1
    fi

    case "$global_prefix" in
        /usr|/usr/*|/usr/local|/usr/local/*|/opt|/opt/*|/root|/root/*)
            postinstall_print ""
            postinstall_print "ERROR: JishuShell global npm prefix is not user-owned:"
            postinstall_print "  ${global_prefix}"
            postinstall_print ""
            postinstall_print "Install it into the current user's JishuShell npm prefix:"
            postinstall_print ""
            postinstall_print_white_bold "  npm install -g --prefix \"${preferred_prefix}\" ${preferred_package}"
            postinstall_print "  # For a local tarball, replace ${preferred_package} with ./jishushell-<version>.tgz"
            postinstall_print_white_bold "  sudo env JISHUSHELL_HOME=\"${JISHUSHELL_HOME}\" HOME=\"${REAL_HOME}\" \"${JISHUSHELL_BIN_DIR}/jishushell\" repair"
            postinstall_print ""
            exit 1
            ;;
    esac

    if ! _postinstall_path_under "$package_root" "$REAL_HOME" && ! _postinstall_path_under "$global_root" "$REAL_HOME"; then
        postinstall_print ""
        postinstall_print "ERROR: JishuShell package was installed outside the real user's home:"
        postinstall_print "  package: ${package_root:-unknown}"
        postinstall_print "  npm root: ${global_root:-unknown}"
        postinstall_print ""
        postinstall_print "Install it into the current user's JishuShell npm prefix:"
        postinstall_print ""
        postinstall_print_white_bold "  npm install -g --prefix \"${preferred_prefix}\" ${preferred_package}"
        postinstall_print "  # For a local tarball, replace ${preferred_package} with ./jishushell-<version>.tgz"
        postinstall_print_white_bold "  sudo env JISHUSHELL_HOME=\"${JISHUSHELL_HOME}\" HOME=\"${REAL_HOME}\" \"${JISHUSHELL_BIN_DIR}/jishushell\" repair"
        postinstall_print ""
        exit 1
    fi
}

# Skip steps handled by npm
SKIP_NODE=1
export JISHUSHELL_SKIP_NPM_INSTALL=1

# Parse any extra args forwarded via npm (e.g. --dry-run, --yes, --skip-docker)
parse_args "$@"
assert_user_owned_global_install

is_jishushell_service_installed() {
    [[ -f "/etc/systemd/system/jishushell.service" ]] && return 0
    [[ -f "${REAL_HOME:-$HOME}/Library/LaunchAgents/com.jishushell.panel.plist" ]] && return 0
    return 1
}

postinstall_shell_quote() {
    printf '%q' "$1"
}

resolve_postinstall_cli_command() {
    local jishu_bin="${JISHUSHELL_BIN_DIR}/jishushell"
    if [[ ! -x "$jishu_bin" && -x "${JISHUSHELL_BIN_DIR}/jishushell-core-start" ]]; then
        ln -sf "${JISHUSHELL_BIN_DIR}/jishushell-core-start" "$jishu_bin" 2>/dev/null || {
            cp "${JISHUSHELL_BIN_DIR}/jishushell-core-start" "$jishu_bin" 2>/dev/null || true
            chmod +x "$jishu_bin" 2>/dev/null || true
        }
    fi
    if [[ ! -x "$jishu_bin" ]]; then
        jishu_bin="$(command -v jishushell 2>/dev/null || echo "jishushell")"
    fi
    printf '%s\n' "$jishu_bin"
}

build_postinstall_sudo_command() {
    local jishu_bin="$1"
    shift
    printf 'sudo env JISHUSHELL_HOME=%s HOME=%s %s' \
        "$(postinstall_shell_quote "${JISHUSHELL_HOME}")" \
        "$(postinstall_shell_quote "${REAL_HOME}")" \
        "$(postinstall_shell_quote "${jishu_bin}")"
    local arg
    for arg in "$@"; do
        printf ' %s' "$(postinstall_shell_quote "${arg}")"
    done
    printf '\n'
}

resolve_postinstall_repair_command() {
    build_postinstall_sudo_command "$(resolve_postinstall_cli_command)" repair
}

resolve_postinstall_install_command() {
    build_postinstall_sudo_command "$(resolve_postinstall_cli_command)" install
}

print_first_install_notice() {
    local install_cmd="$1"
    postinstall_print ""
    postinstall_print "JishuShell package installed"
    postinstall_print "---------------------------"
    postinstall_print "✓ Package files updated"
    postinstall_print ""
    postinstall_print_yellow "════════════════════════════════════════════════════════════════════"
    postinstall_print_yellow "  ⚠  FIRST INSTALL NOT CONFIGURED"
    postinstall_print_yellow "     npm postinstall does not install Docker/Nomad or system services."
    postinstall_print_yellow ""
    postinstall_print_yellow "  Run the full installer to configure this machine:"
    postinstall_print ""
    postinstall_print_white_bold "       ${install_cmd}"
    postinstall_print ""
    postinstall_print_yellow "════════════════════════════════════════════════════════════════════"
    postinstall_print ""
}

# ── Log setup ─────────────────────────────────────────────────────────────────
# npm captures lifecycle script stdout/stderr and only shows it on error.
# Writing to /dev/tty bypasses that capture so progress is visible in real time.
# The log file is always written regardless of tty availability.
mkdir -p "${REAL_HOME}/.jishushell"
LOG_FILE="${REAL_HOME}/.jishushell/post-install-$(date +%Y-%m-%d-%H-%M-%S)-$$.log"
if _post_install_has_tty; then
    # tee writes to $LOG_FILE; its stdout (>/dev/tty) goes straight to the terminal,
    # bypassing npm's stdout capture entirely.
    exec > >(tee -a "$LOG_FILE" >/dev/tty) 2>&1
else
    # Non-interactive / CI: fall back to npm's stdout (visible with --foreground-scripts)
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

echo ""
ui_info "Log: ${LOG_FILE}"
echo ""

# ── Run install steps ─────────────────────────────────────────────────────────
detect_os
detect_arch

backup_postinstall_scripts
_WRAPPERS_REFRESHED=0
if refresh_postinstall_wrappers_quiet; then
    _WRAPPERS_REFRESHED=1
fi

if is_jishushell_service_installed; then
    write_package_update_pending_marker
    print_package_only_update_notice "$(resolve_postinstall_repair_command)" "$_WRAPPERS_REFRESHED"
else
    print_first_install_notice "$(resolve_postinstall_install_command)"
fi
_rc=0

# ── Persist uninstall scripts for postuninstall lifecycle hook ────────────────
# npm removes package files BEFORE postuninstall runs, so we keep a copy in
# ~/.jishushell/install/ that the postuninstall script can always find.
_jishu_install_backup="${REAL_HOME}/.jishushell/install"
mkdir -p "$_jishu_install_backup"
cp -f "${JISHU_SCRIPT_DIR}/jishu-install.sh"   "${_jishu_install_backup}/jishu-install.sh"   2>/dev/null || true
cp -f "${JISHU_SCRIPT_DIR}/jishu-uninstall.sh" "${_jishu_install_backup}/jishu-uninstall.sh" 2>/dev/null || true
cp -f "${JISHU_SCRIPT_DIR}/post-uninstall.sh"  "${_jishu_install_backup}/post-uninstall.sh"  2>/dev/null || true
chmod +x "${_jishu_install_backup}/jishu-uninstall.sh" "${_jishu_install_backup}/post-uninstall.sh" 2>/dev/null || true

echo ""
ui_info "Full log saved to: ${LOG_FILE}"
exit $_rc
