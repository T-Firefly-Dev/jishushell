#!/bin/bash
set -euo pipefail

JISHU_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

_get_user_home() {
    local user="$1"
    local user_home=""

    if [[ -z "$user" ]]; then
        return 1
    fi

    if command -v getent >/dev/null 2>&1; then
        user_home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    elif command -v dscl >/dev/null 2>&1; then
        user_home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '/NFSHomeDirectory:/{print $2; exit}')"
    fi

    if [[ -z "$user_home" ]]; then
        user_home="$(eval "printf '%s' ~${user}" 2>/dev/null || true)"
    fi

    [[ -n "$user_home" ]] && printf '%s' "$user_home"
}

if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    REAL_USER="${SUDO_USER}"
    REAL_HOME="$(_get_user_home "${SUDO_USER}")"
else
    REAL_USER="$(id -un)"
    REAL_HOME="${HOME}"
fi

[[ -z "${REAL_HOME}" ]] && REAL_HOME="${HOME}"
USER_HOME="${REAL_HOME}"
JISHUSHELL_HOME="${JISHUSHELL_HOME:-${USER_HOME}/.jishushell}"
_COLIMA_HOME="${JISHUSHELL_HOME}/colima"
_COLIMA_PROFILE="jishushell"

# colima binary: prefer PATH, fall back to both Homebrew prefixes.
# Mirrors install/jishu-install.sh — non-interactive shells (launchd,
# sshd without a login profile) often lack /opt/homebrew/bin in PATH,
# so a bare `command colima` fails even when colima is installed.
COLIMA_BIN="$(command -v colima 2>/dev/null || true)"
[[ -z "$COLIMA_BIN" && -x /opt/homebrew/bin/colima ]] && COLIMA_BIN="/opt/homebrew/bin/colima"
[[ -z "$COLIMA_BIN" && -x /usr/local/bin/colima ]] && COLIMA_BIN="/usr/local/bin/colima"
COLIMA_BIN_FOUND=1
[[ -z "$COLIMA_BIN" ]] && COLIMA_BIN_FOUND=0 && COLIMA_BIN="colima"
DOCKER_BIN="$(PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}" command -v docker 2>/dev/null || true)"
[[ -z "$DOCKER_BIN" && -x /opt/homebrew/bin/docker ]] && DOCKER_BIN="/opt/homebrew/bin/docker"
[[ -z "$DOCKER_BIN" && -x /usr/local/bin/docker ]] && DOCKER_BIN="/usr/local/bin/docker"
DOCKER_BIN_FOUND=1
[[ -z "$DOCKER_BIN" ]] && DOCKER_BIN_FOUND=0 && DOCKER_BIN="docker"
COLIMA_STD_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

BOLD='\033[1m'
ACCENT='\033[38;2;66;135;245m'
INFO='\033[38;2;136;146;176m'
SUCCESS='\033[38;2;0;229;204m'
WARN='\033[38;2;255;176;32m'
ERROR='\033[38;2;230;57;70m'
MUTED='\033[38;2;90;100;128m'
NC='\033[0m'

DRY_RUN="${DRY_RUN:-0}"
DO_DOCKER=0
DO_NOMAD=0
DO_XCODE_CLT=0
DO_BREW=0
AUTO_YES=0
SUDO=""
PKG_MANAGER="none"
OS=""
OS_ID=""
OS_VERSION=""
OS_NAME=""

ui_info() {
    echo -e "${MUTED}·${NC} $*"
}

ui_success() {
    echo -e "${SUCCESS}✓${NC} $*"
}

ui_warn() {
    echo -e "${WARN}!${NC} $*"
}

ui_error() {
    echo -e "${ERROR}✗${NC} $*" >&2
}

ui_section() {
    echo -e "\n${ACCENT}${BOLD}── $* ──${NC}"
}

confirm() {
    local prompt="$1"

    if [[ "${NO_PROMPT:-0}" == "1" ]]; then
        ui_info "$prompt → auto-confirmed (NO_PROMPT=1)"
        return 0
    fi

    if [[ "${AUTO_YES:-0}" == "1" ]]; then
        ui_info "$prompt → auto-confirmed (--yes)"
        return 0
    fi

    local answer answer_lc
    read -r -p "$(echo -e "${WARN}  ${prompt} [y/N]: ${NC}")" answer </dev/tty || answer="n"
    answer_lc="$(echo "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer_lc" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

_run_as_real_user() {
    if [[ $EUID -eq 0 && -n "${REAL_USER:-}" && "${REAL_USER}" != "root" ]]; then
        sudo -u "${REAL_USER}" -H env HOME="${USER_HOME}" "$@"
        return $?
    fi
    "$@"
}

_load_homebrew_shellenv() {
    local brew_bin=""

    if command -v brew >/dev/null 2>&1; then
        brew_bin="$(command -v brew)"
    elif [[ -x "/opt/homebrew/bin/brew" ]]; then
        brew_bin="/opt/homebrew/bin/brew"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        brew_bin="/usr/local/bin/brew"
    fi

    if [[ -z "$brew_bin" ]]; then
        return 1
    fi

    eval "$(${brew_bin} shellenv 2>/dev/null)"
    command -v brew >/dev/null 2>&1
}

detect_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OS="macos"
        OS_ID="macos"
        OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
        OS_NAME="macOS ${OS_VERSION}"
        if _load_homebrew_shellenv; then
            PKG_MANAGER="brew"
        else
            PKG_MANAGER="none"
        fi
        ui_success "OS: ${OS_NAME}"
        return 0
    fi

    if [[ ! -f /etc/os-release ]]; then
        ui_error "Cannot detect OS: /etc/os-release not found"
        ui_error "This uninstaller supports Linux and macOS"
        exit 1
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    OS="linux"
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION}"

    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux|fedora|amzn)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then
                PKG_MANAGER="apt"
            elif command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            elif command -v yum >/dev/null 2>&1; then
                PKG_MANAGER="yum"
            fi
            ;;
    esac

    ui_success "OS: ${OS_NAME} (package manager: ${PKG_MANAGER})"
}

check_sudo() {
    if [[ "$DRY_RUN" == "1" ]]; then
        if [[ $EUID -eq 0 ]]; then
            SUDO=""
        else
            SUDO="sudo"
        fi
        return 0
    fi

    if [[ $EUID -eq 0 ]]; then
        SUDO=""
        return 0
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        ui_error "Not running as root and sudo is not installed. Re-run as root."
        exit 1
    fi

    if ! sudo -n true 2>/dev/null; then
        ui_info "Some steps require sudo — you may be prompted for your password."
        if [[ ! -t 0 || ! -t 1 ]]; then
            ui_error "Failed to obtain sudo privileges (no interactive TTY available)"
            exit 1
        fi
        if ! sudo -v; then
            ui_error "Failed to obtain sudo privileges"
            exit 1
        fi
    fi

    SUDO="sudo"
    ui_success "sudo privileges confirmed"
}

run_sudo() {
    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] ${SUDO:+sudo }$*"
        return 0
    fi
    ${SUDO} "$@"
}

wait_for_apt_lock() {
    if [[ "${PKG_MANAGER:-}" != "apt" ]]; then
        return 0
    fi

    local max_wait=60
    local waited=0

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [[ $waited -eq 0 ]]; then
            ui_info "Waiting for apt lock to be released..."
        fi
        sleep 2
        waited=$((waited + 2))
        if [[ $waited -ge $max_wait ]]; then
            ui_error "Timed out waiting for apt lock (${max_wait}s). Check for other running package managers."
            exit 1
        fi
    done
}

_colima() {
    PATH="${COLIMA_STD_PATH}${PATH:+:${PATH}}" \
        COLIMA_HOME="${_COLIMA_HOME}" \
        "${COLIMA_BIN:-colima}" "$@"
}

_docker() {
    PATH="${COLIMA_STD_PATH}${PATH:+:${PATH}}" \
        "${DOCKER_BIN:-docker}" "$@"
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: bash jishu-uninstall.sh [options]

    Run without options to remove only JishuShell-owned files and runtime data:
    stop JishuShell services, remove the jishushell package, and optionally
    delete the data directory (~/.jishushell).

    System-installed tools (colima, docker, nomad, Homebrew, Xcode Command Line
    Tools, Node.js) are never removed unless you explicitly pass extra flags.

Options:
  --docker         Also uninstall Docker/Colima system packages (brew/apt/dnf)
  --nomad          Also uninstall Nomad system package (brew/apt/dnf)
    --xcode-clt      Also delete macOS Xcode Command Line Tools
    --brew           Also run the official Homebrew uninstall script (macOS)
  --all            Full uninstall: default cleanup + --docker + --nomad + --yes
  --dry-run        Print the removal plan only, do not execute anything
  --yes, -y        Skip all confirmation prompts (auto-yes)
  --help, -h       Show this help message

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --docker)        DO_DOCKER=1 ;;
            --nomad)         DO_NOMAD=1 ;;
            --xcode-clt)     DO_XCODE_CLT=1 ;;
            --brew)          DO_BREW=1 ;;
            --all)           DO_DOCKER=1; DO_NOMAD=1; AUTO_YES=1 ;;
            --dry-run)  DRY_RUN=1 ;;
            --yes|-y)   AUTO_YES=1 ;;
            --help|-h)  usage; exit 0 ;;
            *)          ui_warn "Unknown argument: $1" ;;
        esac
        shift
    done
}

# ─── Helper: kill processes matching our private profile ──────────────────────
# Usage: _kill_jishu_procs "colima" "jishushell"
_kill_jishu_procs() {
    local pattern="$1"
    local profile_hint="${2:-${_COLIMA_PROFILE}}"
    local pids
    pids="$(pgrep -f "${pattern}" 2>/dev/null || true)"
    [[ -z "$pids" ]] && return 0
    local killed=0
    local pid
    for pid in $pids; do
        # Only kill processes related to our profile — not system-wide colima/docker
        local cmdline
        cmdline="$(ps -p "$pid" -o args= 2>/dev/null || true)"
        if [[ "$cmdline" == *"${profile_hint}"* || "$cmdline" == *"${_COLIMA_HOME}"* ]]; then
            kill "$pid" 2>/dev/null || true
            ((killed++)) || true
        fi
    done
    if [[ $killed -gt 0 ]]; then
        ui_info "Sent SIGTERM to ${killed} ${pattern} process(es)"
        # Wait briefly for graceful shutdown
        sleep 2
        # Force-kill any survivors
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                local cmdline
                cmdline="$(ps -p "$pid" -o args= 2>/dev/null || true)"
                if [[ "$cmdline" == *"${profile_hint}"* || "$cmdline" == *"${_COLIMA_HOME}"* ]]; then
                    kill -9 "$pid" 2>/dev/null || true
                fi
            fi
        done
    fi
}

# ─── Stop & deregister auto-start services ───────────────────────────────────
stop_services() {
    ui_section "Stopping services and removing auto-start"

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would stop and deregister: com.jishushell.core, com.jishushell.panel, com.jishushell.nomad, com.jishushell.colima"
        ui_info "[dry-run] Would: npm uninstall -g jishushell-gui and/or jishushell and/or jishushell-panel"
        if [[ "$OS" == "macos" ]]; then
            ui_info "[dry-run] Would: kill stale colima/limactl/ssh processes for profile ${_COLIMA_PROFILE}"
            ui_info "[dry-run] Would: COLIMA_HOME=${_COLIMA_HOME} colima stop ${_COLIMA_PROFILE}"
            ui_info "[dry-run] Would: COLIMA_HOME=${_COLIMA_HOME} colima delete ${_COLIMA_PROFILE} --force"
            ui_info "[dry-run] Would: docker context rm colima-${_COLIMA_PROFILE}"
        fi
        return 0
    fi

    if [[ "$(uname -s)" == "Darwin" ]]; then
        local core_plist="${USER_HOME}/Library/LaunchAgents/com.jishushell.core.plist"
        local panel_plist="${USER_HOME}/Library/LaunchAgents/com.jishushell.panel.plist"
        local nomad_plist="${USER_HOME}/Library/LaunchAgents/com.jishushell.nomad.plist"
        local colima_plist="${USER_HOME}/Library/LaunchAgents/com.jishushell.colima.plist"

        if launchctl list 2>/dev/null | grep -q "com.jishushell.core"; then
            ui_info "Stopping JishuShell core..."
            launchctl unload -w "$core_plist" 2>/dev/null || true
            ui_success "JishuShell core stopped and removed from auto-start"
        else
            ui_info "JishuShell core is not running"
        fi

        if [[ -f "$core_plist" ]]; then
            rm -f "$core_plist"
            ui_success "Removed: ${core_plist}"
        fi

        if launchctl list 2>/dev/null | grep -q "com.jishushell.panel"; then
            ui_info "Stopping JishuShell Panel..."
            launchctl unload -w "$panel_plist" 2>/dev/null || true
            ui_success "JishuShell Panel stopped and removed from auto-start"
        else
            ui_info "JishuShell Panel is not running"
        fi

        if [[ -f "$panel_plist" ]]; then
            rm -f "$panel_plist"
            ui_success "Removed: ${panel_plist}"
        fi

        if launchctl list 2>/dev/null | grep -q "com.jishushell.nomad"; then
            ui_info "Stopping Nomad..."
            launchctl unload -w "$nomad_plist" 2>/dev/null || true
            ui_success "Nomad stopped and removed from auto-start"
        else
            ui_info "Nomad launchd agent is not running"
        fi

        if [[ -f "$nomad_plist" ]]; then
            rm -f "$nomad_plist"
            ui_success "Removed: ${nomad_plist}"
        fi

        # Colima self-retrying launchd agent (added by the colima-headless-autostart
        # branch). Must unload before colima delete below — otherwise launchd will
        # immediately try to restart the just-deleted profile.
        if launchctl list 2>/dev/null | grep -q "com.jishushell.colima"; then
            ui_info "Stopping Colima launchd agent..."
            launchctl unload -w "$colima_plist" 2>/dev/null || true
            ui_success "Colima launchd agent stopped and removed from auto-start"
        else
            ui_info "Colima launchd agent is not running"
        fi

        if [[ -f "$colima_plist" ]]; then
            rm -f "$colima_plist"
            ui_success "Removed: ${colima_plist}"
        fi
    else
        if command -v systemctl &>/dev/null; then
            for svc in jishushell-panel jishushell nomad; do
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    ui_info "Stopping ${svc}..."
                    ${SUDO} systemctl stop "$svc" 2>/dev/null || true
                fi
                if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                    ui_info "Disabling ${svc} from auto-start..."
                    ${SUDO} systemctl disable "$svc" 2>/dev/null || true
                fi
                ${SUDO} rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
            done
            ${SUDO} systemctl daemon-reload 2>/dev/null || true
            ui_success "Services stopped and removed from auto-start"
        fi
    fi

    if command -v npm &>/dev/null; then
        local _removed_npm_package=0
        for pkg in jishushell-gui jishushell jishushell-panel; do
            if npm list -g "$pkg" &>/dev/null 2>&1; then
                ui_info "Uninstalling ${pkg} npm package..."
                npm uninstall -g "$pkg" 2>/dev/null || true
                _removed_npm_package=1
            fi
        done
        if [[ "$_removed_npm_package" == "1" ]]; then
            ui_success "JishuShell npm package(s) removed"
        fi
    fi

    # Kill any nomad agent process started by jishushell (match our config path)
    local _nomad_pids
    _nomad_pids="$(pgrep -f "nomad agent" 2>/dev/null || true)"
    if [[ -n "$_nomad_pids" ]]; then
        local _killed_nomad=0
        for _pid in $_nomad_pids; do
            local _cmd
            _cmd="$(ps -p "$_pid" -o args= 2>/dev/null || true)"
            # Only kill nomad agents that reference our config directory
            if [[ "$_cmd" == *"${JISHUSHELL_HOME}"* ]]; then
                kill "$_pid" 2>/dev/null || true
                ((_killed_nomad++)) || true
            fi
        done
        if [[ $_killed_nomad -gt 0 ]]; then
            ui_info "Stopped ${_killed_nomad} JishuShell Nomad agent process(es)"
            sleep 2
            # Force-kill survivors
            for _pid in $_nomad_pids; do
                if kill -0 "$_pid" 2>/dev/null; then
                    local _cmd
                    _cmd="$(ps -p "$_pid" -o args= 2>/dev/null || true)"
                    if [[ "$_cmd" == *"${JISHUSHELL_HOME}"* ]]; then
                        kill -9 "$_pid" 2>/dev/null || true
                    fi
                fi
            done
        fi
    fi

    # ── macOS: Tear down private Colima VM ────────────────────────────────────
    if [[ "$OS" == "macos" ]]; then
        ui_info "Checking for JishuShell Colima VM (profile: ${_COLIMA_PROFILE})..."

        # Kill stale colima/limactl/ssh processes for our profile
        _kill_jishu_procs "colima" "${_COLIMA_PROFILE}"
        _kill_jishu_procs "limactl" "colima-${_COLIMA_PROFILE}"
        _kill_jishu_procs "ssh.*colima-${_COLIMA_PROFILE}"

        # Graceful stop + delete via colima CLI
        if [[ "$COLIMA_BIN_FOUND" == "1" ]]; then
            if _colima list 2>/dev/null | grep -q "${_COLIMA_PROFILE}"; then
                ui_info "Stopping Colima VM (profile: ${_COLIMA_PROFILE})..."
                _colima stop "${_COLIMA_PROFILE}" 2>/dev/null || true
                ui_info "Deleting Colima VM..."
                _colima delete "${_COLIMA_PROFILE}" --force 2>/dev/null || true
                ui_success "Colima instance '${_COLIMA_PROFILE}' stopped and deleted"
            else
                ui_info "Colima VM '${_COLIMA_PROFILE}' not found"
            fi
        else
            ui_info "Colima CLI not found — skipping VM teardown"
        fi

        # Safety net: remove docker context
        if [[ "$DOCKER_BIN_FOUND" == "1" ]]; then
            _docker context rm "colima-${_COLIMA_PROFILE}" 2>/dev/null || true
        fi

        # Clean leaked ~/.colima directory (Colima stat-guard artifact)
        local default_colima_home="${USER_HOME}/.colima"
        if [[ -d "$default_colima_home" ]]; then
            local real_files
            real_files="$(find "$default_colima_home" -type f 2>/dev/null | head -1 || true)"
            if [[ -z "$real_files" ]]; then
                rm -rf "$default_colima_home" 2>/dev/null || true
                if [[ ! -d "$default_colima_home" ]]; then
                    ui_success "Removed leaked ~/.colima (empty)"
                fi
            else
                ui_info "~/.colima contains files from other profiles — kept"
            fi
        fi
    fi

    local wrapper="${JISHUSHELL_HOME}/bin/jishushell-core-start"
    if [[ -f "$wrapper" ]]; then
        rm -f "$wrapper"
        ui_success "Removed wrapper: ${wrapper}"
    fi
    local panel_wrapper="${JISHUSHELL_HOME}/bin/jishushell-panel-start"
    if [[ -f "$panel_wrapper" ]]; then
        rm -f "$panel_wrapper"
        ui_success "Removed wrapper: ${panel_wrapper}"
    fi

    # Clean JishuShell PATH entries from shell RC files.
    local marker="# jishushell-bin-path"
    local shell_configs=("${USER_HOME}/.bashrc" "${USER_HOME}/.bash_profile" "${USER_HOME}/.profile" "${USER_HOME}/.zshrc")
    for cfg in "${shell_configs[@]}"; do
        if [[ -f "$cfg" ]] && grep -qF "$marker" "$cfg" 2>/dev/null; then
            ui_info "Cleaning JishuShell PATH from ${cfg}..."
            if [[ "$DRY_RUN" == "1" ]]; then
                ui_info "[dry-run] Would remove jishushell-bin-path lines from ${cfg}"
            else
                cp "$cfg" "${cfg}.bak-jishu-uninstall"
                if [[ "$(uname -s)" == "Darwin" ]]; then
                    sed -i '' "/${marker//\//\\/}/d; /jishushell.*bin.*PATH/d; /\.jishushell\/bin/d" "$cfg"
                else
                    sed -i "/${marker//\//\\/}/d; /jishushell.*bin.*PATH/d; /\.jishushell\/bin/d" "$cfg"
                fi
                ui_success "Cleaned ${cfg} (backup: ${cfg}.bak-jishu-uninstall)"
            fi
        fi
    done
}

# ─── Delete ~/.jishushell data directory ──────────────────────────────────────
delete_data_dir() {
    local jishu_home="${JISHUSHELL_HOME}"
    if [[ ! -d "$jishu_home" ]]; then
        ui_info "Data directory does not exist: ${jishu_home}"
        return 0
    fi

    local size
    size="$(du -sh "$jishu_home" 2>/dev/null | cut -f1 || echo "?")"
    echo ""
    ui_info "Data directory: ${jishu_home} (${size})"
    ui_info "This contains your apps, instances, config, secrets, Nomad data, and Colima data."

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would: ${SUDO} rm -rf ${jishu_home}"
        return 0
    fi

    if ! confirm "Delete data directory (~/.jishushell)?"; then
        ui_info "Data directory kept: ${jishu_home}"
        return 0
    fi

    # On macOS, Docker Desktop keeps VirtioFS shares open for containers that are
    # stopped but not removed (docker rm).  Force-remove any such containers first.
    if command -v docker &>/dev/null; then
        local _containers_to_rm
        _containers_to_rm="$(docker ps -a --format '{{.ID}}' 2>/dev/null | xargs -I{} sh -c \
            'docker inspect {} --format "{{.ID}} {{range .Mounts}}{{.Source}} {{end}}" 2>/dev/null' \
            | grep -F "$jishu_home" | awk '{print $1}' || true)"
        if [[ -n "$_containers_to_rm" ]]; then
            ui_info "Removing Docker containers with bind-mounts from ${jishu_home}..."
            echo "$_containers_to_rm" | xargs docker rm -f 2>/dev/null || true
        fi
    fi
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ${SUDO} chflags -R nouchg,noschg "$jishu_home" 2>/dev/null || true
    fi
    ${SUDO} rm -rf "$jishu_home" || true
    ${SUDO} rm -rf /etc/jishushell 2>/dev/null || true
    if [[ ! -d "$jishu_home" ]]; then
        ui_success "Data directory removed"
    else
        ui_warn "Could not remove ${jishu_home}"
        return 1
    fi
}

# ─── Uninstall Colima system packages (macOS, --docker flag) ──────────────────
uninstall_colima() {
    ui_section "Uninstalling Colima / Docker / Lima system packages"

    if [[ "$OS" != "macos" ]]; then
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would: brew uninstall colima docker lima"
        return 0
    fi

    if ! command -v brew &>/dev/null; then
        ui_info "Homebrew not found — skipping"
        return 0
    fi

    local brew_pkgs_to_remove=()
    for pkg in colima docker lima; do
        if brew list "$pkg" &>/dev/null 2>&1; then
            brew_pkgs_to_remove+=("$pkg")
        fi
    done
    if [[ ${#brew_pkgs_to_remove[@]} -gt 0 ]]; then
        if confirm "Uninstall Homebrew packages: ${brew_pkgs_to_remove[*]}?"; then
            brew uninstall "${brew_pkgs_to_remove[@]}" 2>/dev/null || true
            ui_success "Homebrew packages removed: ${brew_pkgs_to_remove[*]}"
        else
            ui_info "Homebrew packages kept"
        fi
    else
        ui_info "No JishuShell-related Homebrew packages found"
    fi
}

# ─── macOS Xcode Command Line Tools (--xcode-clt flag) ───────────────────────
uninstall_xcode_clt() {
    ui_section "Removing Xcode Command Line Tools"

    if [[ "$OS" != "macos" ]]; then
        ui_info "Xcode Command Line Tools removal is only supported on macOS"
        return 0
    fi

    if [[ ! -d /Library/Developer/CommandLineTools ]]; then
        ui_info "Xcode Command Line Tools are not installed, skipping"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would: sudo rm -rf /Library/Developer/CommandLineTools"
        return 0
    fi

    ui_warn "This will delete /Library/Developer/CommandLineTools from this Mac."
    if ! confirm "Delete Xcode Command Line Tools?"; then
        ui_info "Xcode Command Line Tools kept"
        return 0
    fi

    run_sudo rm -rf /Library/Developer/CommandLineTools
    if [[ ! -d /Library/Developer/CommandLineTools ]]; then
        ui_success "Xcode Command Line Tools removed"
        return 0
    fi

    ui_warn "Could not fully remove /Library/Developer/CommandLineTools"
    return 1
}

# ─── Homebrew uninstall (--brew flag) ────────────────────────────────────────
uninstall_homebrew() {
    ui_section "Removing Homebrew"

    if [[ "$OS" != "macos" ]]; then
        ui_info "Homebrew removal is only supported on macOS"
        return 0
    fi

    if [[ ! -x /opt/homebrew/bin/brew && ! -x /usr/local/bin/brew && ! -d /opt/homebrew && ! -d /usr/local/Homebrew ]]; then
        ui_info "Homebrew not found — skipping"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info '[dry-run] Would: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"'
        return 0
    fi

    ui_warn "This will run the official Homebrew uninstall script and may remove all Homebrew packages on this Mac."
    if ! confirm "Run Homebrew uninstall script?"; then
        ui_info "Homebrew kept"
        return 0
    fi

    local uninstall_script=""
    if ! uninstall_script="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"; then
        ui_warn "Failed to download the Homebrew uninstall script"
        return 1
    fi

    if ! _run_as_real_user /bin/bash -c "$uninstall_script"; then
        ui_warn "Homebrew uninstall script failed"
        return 1
    fi

    hash -r 2>/dev/null || true
    if [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew || -d /opt/homebrew || -d /usr/local/Homebrew ]]; then
        ui_warn "Homebrew may still be present after uninstall"
        return 1
    fi

    ui_success "Homebrew removed"
}

# ─── Docker (Linux, --docker flag) ───────────────────────────────────────────
uninstall_docker() {
    ui_section "Removing Docker"

    local _docker_via_snap=0
    if command -v snap &>/dev/null && snap list docker &>/dev/null 2>&1; then
        _docker_via_snap=1
    fi
    if ! command -v docker &>/dev/null \
        && ! dpkg -l 2>/dev/null | grep -q 'docker\|containerd' \
        && [[ $_docker_via_snap -eq 0 ]]; then
        ui_info "Docker is not installed, skipping"
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would stop and disable docker.socket docker.service"
        if [[ $_docker_via_snap -eq 1 ]]; then
            ui_info "[dry-run] Would: snap remove docker"
        else
            ui_info "[dry-run] Would purge Docker packages (docker-ce, docker-ce-cli, containerd.io, etc.)"
            ui_info "[dry-run] Would remove Docker APT/YUM repo and GPG key"
        fi
        ui_info "[dry-run] Would groupdel docker"
        ui_info "[dry-run] Would remove /var/lib/docker /var/lib/containerd /etc/docker"
        ui_info "[dry-run] Would remove ${USER_HOME}/.docker"
        ui_info "[dry-run] Would: systemctl daemon-reload"
        return 0
    fi

    ui_warn "This will remove Docker packages and the docker group from this host."
    if ! confirm "Confirm removal of Docker?"; then
        ui_info "Cancelled"
        return 0
    fi

    # Stop and disable service — reset failed state first so stop succeeds
    if command -v systemctl &>/dev/null; then
        ui_info "Stopping Docker service..."
        ${SUDO} systemctl reset-failed docker.socket docker.service 2>/dev/null || true
        ${SUDO} systemctl stop docker docker.socket 2>/dev/null || true
        ${SUDO} systemctl disable docker docker.socket 2>/dev/null || true
    fi

    case "$PKG_MANAGER" in
        apt)
            ui_info "Removing Docker packages via apt purge..."
            local purge_pkgs=(
                docker-ce
                docker-ce-cli
                containerd.io
                docker-buildx-plugin
                docker-compose-plugin
                docker-ce-rootless-extras
                docker-model-plugin
            )
            # Only purge packages that are actually installed
            local installed_purge_pkgs=()
            for pkg in "${purge_pkgs[@]}"; do
                if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                    installed_purge_pkgs+=("$pkg")
                fi
            done
            if [[ ${#installed_purge_pkgs[@]} -gt 0 ]]; then
                ui_info "Packages to purge: ${installed_purge_pkgs[*]}"
                wait_for_apt_lock
                ${SUDO} apt-get purge -y "${installed_purge_pkgs[@]}" || true
            else
                ui_warn "None of the expected Docker packages found via dpkg"
            fi
            wait_for_apt_lock
            ${SUDO} apt-get autoremove -y || true
            # Remove apt repository and GPG key added by installer
            ${SUDO} rm -f /etc/apt/sources.list.d/docker.sources \
                          /etc/apt/sources.list.d/docker.list \
                          /etc/apt/keyrings/docker.asc \
                          /usr/share/keyrings/docker-archive-keyring.gpg \
                          /usr/share/keyrings/docker.gpg 2>/dev/null || true
            ;;
        dnf|yum)
            ui_info "Removing Docker packages via $PKG_MANAGER..."
            local docker_pkgs
            docker_pkgs="$(rpm -qa 2>/dev/null | grep -E 'docker|containerd' | tr '\n' ' ')"
            if [[ -n "$docker_pkgs" ]]; then
                ui_info "Packages to remove: ${docker_pkgs}"
                # shellcheck disable=SC2086
                ${SUDO} "$PKG_MANAGER" remove -y $docker_pkgs || true
            fi
            ${SUDO} rm -f /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
            ;;
    esac

    # Remove Docker installed via snap
    if [[ $_docker_via_snap -eq 1 ]]; then
        ui_info "Removing Docker snap package..."
        ${SUDO} snap remove docker 2>/dev/null || true
        if ! snap list docker &>/dev/null 2>&1; then
            ui_success "Docker snap package removed"
        else
            ui_warn "snap remove docker failed — try manually: sudo snap remove docker"
        fi
    fi

    # Verify packages actually removed — try a dynamic cleanup pass for any stragglers
    local remaining_pkgs
    remaining_pkgs="$(dpkg -l 2>/dev/null | awk '/^ii/ && /docker|containerd/ {print $2}' | tr '\n' ' ' || true)"
    if [[ -n "$remaining_pkgs" ]]; then
        ui_warn "Packages still installed after first pass: ${remaining_pkgs}"
        ui_info "Attempting dynamic cleanup..."
        wait_for_apt_lock
        # shellcheck disable=SC2086
        ${SUDO} apt-get purge -y $remaining_pkgs 2>/dev/null || true
        wait_for_apt_lock
        ${SUDO} apt-get autoremove -y 2>/dev/null || true
        # Re-check
        remaining_pkgs="$(dpkg -l 2>/dev/null | awk '/^ii/ && /docker|containerd/ {print $2}' | tr '\n' ' ' || true)"
        if [[ -n "$remaining_pkgs" ]]; then
            ui_warn "Packages still installed after removal: ${remaining_pkgs}"
            ui_warn "Try manually: sudo apt-get purge -y ${remaining_pkgs}"
        fi
    fi

    if getent group docker &>/dev/null 2>&1; then
        ${SUDO} groupdel docker 2>/dev/null || true
        ui_success "docker group removed"
    fi

    # Remove Docker daemon data and configuration directories
    for dir in /var/lib/docker /var/lib/containerd /etc/docker; do
        if [[ -d "$dir" ]]; then
            local dir_size
            dir_size="$(du -sh "$dir" 2>/dev/null | cut -f1 || echo '?')"
            if confirm "Delete Docker directory ${dir} (${dir_size})?"; then
                ${SUDO} rm -rf "$dir" 2>/dev/null || true
                if [[ ! -d "$dir" ]]; then
                    ui_success "Removed: ${dir}"
                else
                    ui_warn "Could not fully remove: ${dir}"
                fi
            else
                ui_info "Kept: ${dir}"
            fi
        fi
    done

    # Remove user Docker config directory (~/.docker contains credentials and config)
    if [[ -d "${USER_HOME}/.docker" ]]; then
        if confirm "Delete user Docker config directory (~/.docker)?"; then
            rm -rf "${USER_HOME}/.docker" 2>/dev/null || true
            ui_success "Removed: ${USER_HOME}/.docker"
        else
            ui_info "Kept: ${USER_HOME}/.docker"
        fi
    fi

    # Reload systemd unit database after removing service units
    if command -v systemctl &>/dev/null; then
        ${SUDO} systemctl daemon-reload 2>/dev/null || true
    fi

    # Final verification — flush shell command cache before checking
    hash -r 2>/dev/null || true
    local docker_path
    docker_path="$(command -v docker 2>/dev/null || true)"
    if [[ -n "$docker_path" && -f "$docker_path" ]]; then
        ui_error "Docker binary still present at: ${docker_path}"
        [[ -n "$remaining_pkgs" ]] && ui_error "Packages not removed: ${remaining_pkgs}"
        return 1
    fi
    ui_success "Docker removed successfully"
}

# ─── Nomad system package (--nomad flag) ──────────────────────────────────────
uninstall_nomad() {
    ui_section "Uninstalling Nomad system package"

    local system_nomad
    system_nomad="$(command -v nomad 2>/dev/null || true)"
    local local_bin="${JISHUSHELL_HOME}/bin/nomad"
    # Ignore if system PATH resolves to our local bin (that gets cleaned with ~/.jishushell)
    [[ "$system_nomad" == "$local_bin" ]] && system_nomad=""

    if [[ -z "$system_nomad" ]]; then
        ui_info "No system Nomad installation found, skipping"
        return 0
    fi

    local sys_ver
    sys_ver="$(nomad version 2>/dev/null | head -n1 || echo 'unknown')"
    ui_info "System Nomad: ${sys_ver} → ${system_nomad}"

    if [[ "$DRY_RUN" == "1" ]]; then
        ui_info "[dry-run] Would remove system Nomad via package manager"
        return 0
    fi

    if ! confirm "Uninstall system Nomad (${system_nomad})?"; then
        ui_info "Cancelled"
        return 0
    fi

    # Stop systemd service if running (Linux)
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet nomad 2>/dev/null; then
            ui_info "Stopping Nomad service..."
            run_sudo systemctl stop nomad 2>/dev/null || true
        fi
        if systemctl is-enabled --quiet nomad 2>/dev/null; then
            ui_info "Disabling Nomad on startup..."
            run_sudo systemctl disable nomad 2>/dev/null || true
        fi
    fi

    local removed_via_pkg=0
    case "$PKG_MANAGER" in
        brew)
            if brew list nomad &>/dev/null 2>&1; then
                ui_info "Removing Nomad via Homebrew..."
                brew uninstall nomad 2>/dev/null || true
                removed_via_pkg=1
            fi
            ;;
        apt)
            if dpkg -l nomad 2>/dev/null | grep -q '^ii'; then
                ui_info "Removing Nomad via apt..."
                run_sudo apt-get remove -y nomad 2>/dev/null || true
                run_sudo apt-get autoremove -y 2>/dev/null || true
                removed_via_pkg=1
            fi
            if [[ $removed_via_pkg -eq 1 ]]; then
                local hashi_sources=(/etc/apt/sources.list.d/hashicorp.list)
                for src in "${hashi_sources[@]}"; do
                    if [[ -f "$src" ]]; then
                        if confirm "Delete HashiCorp APT repository config ($src)?"; then
                            run_sudo rm -f "$src" \
                                         /usr/share/keyrings/hashicorp-archive-keyring.gpg 2>/dev/null || true
                        fi
                    fi
                done
            fi
            ;;
        dnf|yum)
            if rpm -q nomad &>/dev/null 2>&1; then
                ui_info "Removing Nomad via $PKG_MANAGER..."
                run_sudo "$PKG_MANAGER" remove -y nomad 2>/dev/null || true
                removed_via_pkg=1
            fi
            if [[ $removed_via_pkg -eq 1 ]] && [[ -f /etc/yum.repos.d/hashicorp.repo ]]; then
                if confirm "Delete HashiCorp YUM repository config (/etc/yum.repos.d/hashicorp.repo)?"; then
                    run_sudo rm -f /etc/yum.repos.d/hashicorp.repo 2>/dev/null || true
                fi
            fi
            ;;
    esac

    # Remove binary directly if still present and package manager didn't handle it
    local remaining
    remaining="$(command -v nomad 2>/dev/null || true)"
    if [[ -n "$remaining" && "$remaining" != "$local_bin" ]]; then
        ui_info "Removing remaining system binary: ${remaining}"
        run_sudo rm -f "$remaining" 2>/dev/null || true
    fi

    # Remove systemd service files
    run_sudo rm -f /etc/systemd/system/nomad.service \
                   /usr/lib/systemd/system/nomad.service 2>/dev/null || true

    # Nomad system data dirs
    if confirm "Delete Nomad system data directories (/etc/nomad.d /var/lib/nomad /var/log/nomad)?"; then
        run_sudo rm -rf /etc/nomad.d /var/lib/nomad /var/log/nomad 2>/dev/null || true
        ui_success "Nomad system data directories removed"
    fi

    if command -v systemctl &>/dev/null; then
        run_sudo systemctl daemon-reload 2>/dev/null || true
    fi

    # Final verification
    local nomad_remaining
    nomad_remaining="$(command -v nomad 2>/dev/null || true)"
    if [[ -n "$nomad_remaining" && "$nomad_remaining" != "$local_bin" ]]; then
        ui_warn "Nomad still found in PATH: ${nomad_remaining}"
        return 1
    fi
    ui_success "Nomad removed successfully"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
show_plan() {
    echo ""
    echo -e "${ACCENT}${BOLD}Uninstall Plan${NC}"
    echo -e "${MUTED}────────────────────────────────${NC}"
    echo -e "  ${WARN}·${NC} Stop all running services and remove from auto-start"
    echo -e "  ${WARN}·${NC} Stop and delete JishuShell Colima VM (macOS)"
    echo -e "  ${WARN}·${NC} Kill JishuShell-related processes"
    echo -e "  ${WARN}·${NC} Remove docker context, npm package, PATH entries"
    echo -e "  ${WARN}·${NC} Data directory (~/.jishushell) — will ask"
    [[ $DO_DOCKER -eq 1 ]] && echo -e "  ${WARN}·${NC} Uninstall Docker/Colima system packages (brew/apt/dnf)"
    [[ $DO_NOMAD  -eq 1 ]] && echo -e "  ${WARN}·${NC} Uninstall Nomad system package (brew/apt/dnf)"
    [[ $DO_BREW -eq 1 ]] && echo -e "  ${WARN}·${NC} Run the official Homebrew uninstall script (macOS)"
    [[ $DO_XCODE_CLT -eq 1 ]] && echo -e "  ${WARN}·${NC} Delete /Library/Developer/CommandLineTools (macOS)"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo ""
        echo -e "${WARN}  Dry-run mode: no changes will be made${NC}"
    fi
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    parse_args "$@"

    echo -e "${ACCENT}${BOLD}"
    echo "  ╔═══════════════════════════════════╗"
    echo "  ║     JishuShell Uninstaller        ║"
    echo "  ╚═══════════════════════════════════╝"
    echo -e "${NC}"

    detect_os
    check_sudo

    show_plan

    # ── Phase 1: Stop services & clean runtime artifacts ──────────────────────
    if ! confirm "Stop all JishuShell services and clean up runtime artifacts?"; then
        ui_info "Cancelled"
        exit 0
    fi

    local uninstall_errors=0

    stop_services || uninstall_errors=1

    # ── Phase 2: Delete data directory ────────────────────────────────────────
    delete_data_dir || uninstall_errors=1

    # ── Phase 3: System package removal (only with explicit flags) ────────────
    if [[ $DO_DOCKER -eq 1 ]]; then
        if [[ "$OS" == "macos" ]]; then
            uninstall_colima || uninstall_errors=1
        else
            uninstall_docker || uninstall_errors=1
        fi
    fi

    [[ $DO_NOMAD -eq 1 ]] && { uninstall_nomad || uninstall_errors=1; }
    [[ $DO_BREW -eq 1 ]] && { uninstall_homebrew || uninstall_errors=1; }
    [[ $DO_XCODE_CLT -eq 1 ]] && { uninstall_xcode_clt || uninstall_errors=1; }

    echo ""
    if [[ $uninstall_errors -eq 0 ]]; then
        echo -e "${SUCCESS}${BOLD}Done.${NC}"
    else
        echo -e "${WARN}${BOLD}Some steps could not be completed — review the output above.${NC}"
    fi
    echo ""
}

main "$@"
