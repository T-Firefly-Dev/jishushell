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
# Installs all runtime dependencies (Docker, Nomad, OpenClaw) and registers the
# JishuShell service.
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

print_package_only_update_notice() {
    local reload_cmd="$1"
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
    postinstall_print_yellow "  ⚠  ACTION REQUIRED — System services were NOT reloaded"
    postinstall_print_yellow "     (sudo is not available from npm postinstall)."
    postinstall_print_yellow ""
    postinstall_print_yellow "  1. Run this command to finish the upgrade:"
    postinstall_print ""
    postinstall_print_white_bold "       ${reload_cmd}"
    postinstall_print ""
    if [[ "$wrappers_refreshed" == "1" && -x "$panel_wrapper" ]]; then
        postinstall_print_yellow "  2. After the command above finishes, refresh any open"
        postinstall_print_yellow "     JishuShell browser tab to load the updated UI."
        postinstall_print_yellow ""
    fi
    postinstall_print_yellow "════════════════════════════════════════════════════════════════════"
    postinstall_print ""
}

schedule_web_update_service_restart() {
    [[ "${JISHUSHELL_WEB_UPDATE:-0}" == "1" ]] || return 0

    # Old web update workers run inside the pre-upgrade systemd sandbox, where
    # sudo cannot refresh system services. Terminating the supervised process lets
    # systemd restart it into the newly installed package without extra privilege.
    local main_pid="${JISHUSHELL_UPDATE_SERVER_PID:-}"
    if ! [[ "$main_pid" =~ ^[0-9]+$ && "$main_pid" -gt 1 ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            main_pid="$(systemctl show jishushell.service -p MainPID --value 2>/dev/null || true)"
        fi
    fi
    [[ "$main_pid" =~ ^[0-9]+$ && "$main_pid" -gt 1 ]] || return 0

    local delay="${JISHUSHELL_WEB_UPDATE_RESTART_DELAY:-5}"
    [[ "$delay" =~ ^[0-9]+$ && "$delay" -gt 0 ]] || delay=5

    (
        sleep "$delay"
        kill -KILL "$main_pid" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
    echo "  [post-install] Scheduled web update service restart for PID ${main_pid}"
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
    # execute. This lets a legacy jishushell.service restart into the bundled
    # Panel, which then manages core until the later sudo/system reload.
    refresh_postinstall_wrappers
    backup_postinstall_scripts
    schedule_web_update_service_restart
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

# Skip steps handled by npm
SKIP_NODE=1
export JISHUSHELL_SKIP_NPM_INSTALL=1

# Parse any extra args forwarded via npm (e.g. --dry-run, --yes, --skip-docker)
parse_args "$@"

# ── Early privilege decision ──────────────────────────────────────────────────
# npm runs postinstall for global installs, but npm 7+ may hide lifecycle stdout
# unless --foreground-scripts is used.  We never attempt interactive sudo prompts
# inside postinstall because npm's output buffering makes them invisible.
#
# Decision tree:
#   - root (sudo npm install -g ...)      → proceed with full system setup
#   - passwordless sudo available         → proceed with full system setup
#   - non-root + service already exists   → package updated; print restart hint
#   - non-root + first install            → print sudo hint
#   - web update (JISHUSHELL_WEB_UPDATE)  → handled later by configure_postinstall_mode
_JISHUSHELL_SERVICE_EXISTS=0
if [[ -f "/etc/systemd/system/jishushell.service" ]] || \
   [[ -f "${HOME}/Library/LaunchAgents/com.jishushell.panel.plist" ]]; then
    _JISHUSHELL_SERVICE_EXISTS=1
fi

if [[ "${JISHUSHELL_WEB_UPDATE:-0}" != "1" && $EUID -ne 0 ]]; then
    _HAS_PASSWORDLESS_SUDO=0
    if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        _HAS_PASSWORDLESS_SUDO=1
    fi

    if [[ "$_HAS_PASSWORDLESS_SUDO" == "0" ]]; then
        backup_postinstall_scripts
        _WRAPPERS_REFRESHED=0
        if refresh_postinstall_wrappers_quiet; then
            _WRAPPERS_REFRESHED=1
        fi
        # sudo resets PATH and HOME on many distros. Prefer the installed
        # wrapper because it embeds the real user home and Node lookup logic.
        _JISHU_BIN="${JISHUSHELL_BIN_DIR}/jishushell"
        if [[ ! -x "$_JISHU_BIN" && -x "${JISHUSHELL_BIN_DIR}/jishushell-core-start" ]]; then
            ln -sf "${JISHUSHELL_BIN_DIR}/jishushell-core-start" "$_JISHU_BIN" 2>/dev/null || {
                cp "${JISHUSHELL_BIN_DIR}/jishushell-core-start" "$_JISHU_BIN" 2>/dev/null || true
                chmod +x "$_JISHU_BIN" 2>/dev/null || true
            }
        fi
        if [[ ! -x "$_JISHU_BIN" ]]; then
            _JISHU_BIN="$(command -v jishushell 2>/dev/null || command -v jishushell 2>/dev/null || echo "jishushell")"
        fi

        if [[ "$_JISHUSHELL_SERVICE_EXISTS" == "1" ]]; then
            # Upgrade: package files updated, but no sudo to restart services.
            print_package_only_update_notice "sudo ${_JISHU_BIN} system reload" "$_WRAPPERS_REFRESHED"
        else
            # First install: cannot do system setup without root.
            postinstall_print ""
            postinstall_print "  ✓ JishuShell 包文件已安装。"
            postinstall_print ""
            postinstall_print "  首次安装需要 root 权限来配置系统服务。"
            postinstall_print "  请执行："
            postinstall_print "    sudo npm install -g <同一个 .tgz 路径>"
            postinstall_print ""
        fi
        exit 0
    fi
fi

# ── npm post-install privilege mode ───────────────────────────────────────────
# npm lifecycle scripts need careful sudo handling:
#   - when there is an interactive TTY, prompt explicitly on /dev/tty so the
#     operator can finish system service reconciliation during install
#   - when npm runs from the web updater, CI, or another non-TTY context, never
#     block on sudo; finish the package update and print a clear follow-up action
#
# So postinstall performs privileged steps when it is root, has passwordless
# sudo, or can visibly ask for sudo on /dev/tty. Otherwise it degrades to a
# best-effort package refresh.
POST_INSTALL_BEST_EFFORT=0
print_postinstall_best_effort_notice() {
    echo ""
    echo -e "${WARN}${BOLD}Action required — system service was not refreshed${NC}"
    echo -e "${WARN}  npm installed the JishuShell package files, but post-install did not run${NC}"
    echo -e "${WARN}  privileged Docker/Nomad/systemd reconciliation because it could not${NC}"
    echo -e "${WARN}  prompt for sudo in this environment.${NC}"
    echo ""
    echo -e "${WARN}  If this machine already runs JishuShell as a service, it may still be using${NC}"
    echo -e "${WARN}  the previous code until you refresh it from a normal shell:${NC}"
    echo -e "${ACCENT}    jishushell install --yes${NC}"
    echo -e "${WARN}  Or, if the system service is already configured and only needs the new code:${NC}"
    if jishushell_panel_bundled; then
        echo -e "${ACCENT}    sudo systemctl restart jishushell jishushell-panel${NC}"
    else
        echo -e "${ACCENT}    sudo systemctl restart jishushell${NC}"
    fi
    echo ""
}

configure_postinstall_mode() {
    # Web-triggered upgrade: npm was spawned by the panel backend without a
    # controlling TTY.  Skip all privileged steps so npm can exit cleanly.
    if [[ "${JISHUSHELL_WEB_UPDATE:-0}" == "1" ]]; then
        POST_INSTALL_BEST_EFFORT=1
        NO_PROMPT=1
        SUDO=""
        SKIP_DOCKER=1
        SKIP_NOMAD=1
        SKIP_OPENCLAW=1
        SKIP_JISHUSHELL_SERVICE=1
        return 0
    fi

    if [[ $EUID -eq 0 ]]; then
        SUDO=""
        return 0
    fi

    if ! command -v sudo &>/dev/null; then
        POST_INSTALL_BEST_EFFORT=1
        NO_PROMPT=1
        SUDO=""
        SKIP_DOCKER=1
        SKIP_NOMAD=1
        SKIP_OPENCLAW=1
        SKIP_JISHUSHELL_SERVICE=1
        return 0
    fi

    if sudo -n true 2>/dev/null; then
        SUDO="sudo"
        NO_PROMPT=1
        return 0
    fi

    if _post_install_has_tty; then
        SUDO="sudo"
        NO_PROMPT=0
        return 0
    fi

    POST_INSTALL_BEST_EFFORT=1
    NO_PROMPT=1
    SUDO=""
    SKIP_DOCKER=1
    SKIP_NOMAD=1
    SKIP_OPENCLAW=1
    SKIP_JISHUSHELL_SERVICE=1
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
configure_postinstall_mode
if [[ "$POST_INSTALL_BEST_EFFORT" == "1" ]]; then
    backup_postinstall_scripts
    _WRAPPERS_REFRESHED=0
    if refresh_postinstall_wrappers_quiet; then
        _WRAPPERS_REFRESHED=1
    fi
    schedule_web_update_service_restart
    _JISHU_BIN="${JISHUSHELL_BIN_DIR}/jishushell"
    if [[ ! -x "$_JISHU_BIN" ]]; then
        _JISHU_BIN="$(command -v jishushell 2>/dev/null || command -v jishushell 2>/dev/null || echo "jishushell")"
    fi
    print_package_only_update_notice "sudo ${_JISHU_BIN} system reload" "$_WRAPPERS_REFRESHED"
    _rc=0
else
    check_sudo
    ensure_prerequisites
    if run_install_components --with-jishushell; then
        _rc=0
    else
        _rc=$?
    fi
    show_summary --with-jishushell
fi

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
