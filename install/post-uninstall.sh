#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# JishuShell Pre-Uninstall Script
#
# Called by npm's preuninstall lifecycle hook during global package uninstall.
# Runs BEFORE npm removes the package files.
#
# npm lifecycle hooks may run under sudo/root, where HOME can point at /root
# even though JishuShell data belongs to the invoking user. Resolve the real
# target home before deciding whether data exists or should be removed.
#
# Guard: only clean up when the resolved JISHUSHELL_HOME exists (indicates a
# real global install). This makes the script safe regardless of npm_config_global
# being set or not.
# ═══════════════════════════════════════════════════════════════════════════════

_jishu_user_home() {
    local user="$1"
    local user_home=""

    if [ -z "$user" ]; then
        return 1
    fi

    if command -v getent >/dev/null 2>&1; then
        user_home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    elif command -v dscl >/dev/null 2>&1; then
        user_home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '/NFSHomeDirectory:/{print $2; exit}' || true)"
    fi

    if [ -z "$user_home" ]; then
        user_home="$(eval "printf '%s' ~${user}" 2>/dev/null || true)"
    fi

    [ -n "$user_home" ] && printf '%s' "$user_home"
}

_jishu_uid_home() {
    local uid="$1"
    local user_home=""

    if [ -z "$uid" ]; then
        return 1
    fi

    if command -v getent >/dev/null 2>&1; then
        user_home="$(getent passwd "$uid" 2>/dev/null | cut -d: -f6 || true)"
    fi

    [ -n "$user_home" ] && printf '%s' "$user_home"
}

_REAL_HOME="${HOME}"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    _resolved_home="$(_jishu_user_home "${SUDO_USER}")"
    [ -n "$_resolved_home" ] && _REAL_HOME="$_resolved_home"
elif [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID}" != "0" ]; then
    _resolved_home="$(_jishu_uid_home "${SUDO_UID}")"
    [ -n "$_resolved_home" ] && _REAL_HOME="$_resolved_home"
fi

JISHUSHELL_HOME="${JISHUSHELL_HOME:-${_REAL_HOME}/.jishushell}"

if [ ! -d "${JISHUSHELL_HOME}" ] && [ ! -d "/etc/jishushell" ]; then
    exit 0
fi

_SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    _SUDO="sudo"
fi

echo "· JishuShell: stopping services and cleaning up..."
echo "· JishuShell data directory: ${JISHUSHELL_HOME}"

_remove_docker_containers_with_jishu_mounts() {
    command -v docker >/dev/null 2>&1 || return 0

    local ids id mounts removed
    ids="$($_SUDO docker ps -a --format '{{.ID}}' 2>/dev/null || true)"
    [ -n "$ids" ] || return 0

    removed=0
    for id in $ids; do
        mounts="$($_SUDO docker inspect "$id" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null || true)"
        if printf '%s\n' "$mounts" | grep -F -- "${JISHUSHELL_HOME}" >/dev/null 2>&1; then
            $_SUDO docker rm -f "$id" >/dev/null 2>&1 || true
            removed=$((removed + 1))
        fi
    done

    if [ "$removed" -gt 0 ]; then
        echo "· Removed ${removed} Docker container(s) using JishuShell data"
    fi
}

# ── systemd (Linux) ───────────────────────────────────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
    for svc in jishushell-panel jishushell nomad; do
        $_SUDO systemctl stop    "$svc" 2>/dev/null || true
        $_SUDO systemctl disable "$svc" 2>/dev/null || true
        $_SUDO rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
    done
    if [ -L "/usr/local/bin/jishushell" ]; then
        _jishu_link_target="$(readlink "/usr/local/bin/jishushell" 2>/dev/null || true)"
        if [ "$_jishu_link_target" = "${JISHUSHELL_HOME}/bin/jishushell" ]; then
            $_SUDO rm -f "/usr/local/bin/jishushell" 2>/dev/null || true
        fi
    fi
    $_SUDO systemctl daemon-reload 2>/dev/null || true
fi

# ── launchd (macOS) ──────────────────────────────────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    for label in com.jishushell.core com.jishushell.panel com.jishushell.nomad; do
        launchctl unload -w "${HOME}/Library/LaunchAgents/${label}.plist" 2>/dev/null || true
        rm -f "${HOME}/Library/LaunchAgents/${label}.plist" 2>/dev/null || true
    done
fi

# ── Remove ~/.jishushell data directory ──────────────────────────────────────
# This is the full JishuShell runtime state for npm uninstall: app-installed
# instances, legacy instances, configs, user secrets, Nomad data, backups and logs.
if [ -d "${JISHUSHELL_HOME}" ]; then
    _remove_docker_containers_with_jishu_mounts
    $_SUDO rm -rf "${JISHUSHELL_HOME}"
    echo "· Removed ${JISHUSHELL_HOME}"
fi

# System-level JishuShell secrets/env files are not under ~/.jishushell but are
# still JishuShell-owned runtime data. Remove them on npm uninstall so reinstall
# starts from a clean state.
if [ -d "/etc/jishushell" ]; then
    $_SUDO rm -rf "/etc/jishushell"
    echo "· Removed /etc/jishushell"
fi
