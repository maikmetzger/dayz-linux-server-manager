#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Common Utilities
# =============================================================================
# Logging, user identity, and helper functions
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_UTILS_LOADED:-}" ]] && return 0
_DAYZ_UTILS_LOADED=1

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------

# Standard log (used by run.sh and others)
log()  { printf '[%s] %s\n' "$(date -Is)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -Is)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -Is)" "$*" >&2; exit 1; }

# TUI-friendly logging (used by installer)
hr()   { printf '%s────────────────────────────────────────────────────────────%s\n' "${RED:-}" "${RESET:-}"; }
step() { printf '\n%s%s▶ %s%s\n' "${RED:-}" "${BOLD:-}" "$*" "${RESET:-}"; }
info() { printf '  %s%s%s\n' "${WHITE:-}" "$*" "${RESET:-}"; }
ok()   { printf '  %s✓ %s%s\n' "${GREEN:-}" "$*" "${RESET:-}"; }

# Command helpers
is_cmd() { command -v "$1" >/dev/null 2>&1; }
show_cmd() { printf '  %s$ %s%s\n' "${DIM:-}" "$*" "${RESET:-}"; }
run_shell() { show_cmd "$*"; eval "$*"; }
run_arr() { show_cmd "$*"; "$@"; }
# Run a command inside a directory without eval (paths may contain quotes/spaces)
# Usage: run_in_dir "/path/to/instance" docker compose up -d
run_in_dir() { local dir="$1"; shift; show_cmd "cd '$dir' && $*"; (cd "$dir" && "$@"); }

# Append one line to a file. If the file does not end with a newline the
# line is started on a fresh line first, otherwise "123" + "456" would
# silently become "123456".
# Usage: append_line "$file" "$text"
append_line() {
    local file="$1" text="$2"
    if [[ -s "$file" && -n "$(tail -c1 "$file")" ]]; then
        printf '\n' >> "$file"
    fi
    printf '%s\n' "$text" >> "$file"
}

# -----------------------------------------------------------------------------
# User Identity Resolution
# -----------------------------------------------------------------------------
# Determine the real invoking user (not root when running via sudo)
# DAYZ_USER is our custom variable that survives sudo; SUDO_USER is set by sudo itself

# Get home directory for a user using multiple fallback methods
# Usage: home=$(get_user_home "username")
get_user_home() {
    local user="$1"
    
    # Method 0: Use DAYZ_HOME if set (passed from installer)
    [[ -n "${DAYZ_HOME:-}" && -d "${DAYZ_HOME:-}" ]] && { echo "$DAYZ_HOME"; return 0; }
    
    # Method 1: getent passwd
    local home
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [[ -n "$home" && -d "$home" ]] && { echo "$home"; return 0; }
    
    # Method 2: Check common Linux home paths
    [[ -d "/home/$user" ]] && { echo "/home/$user"; return 0; }
    
    # Method 3: Use HOME if it looks valid (not /root when we expect a user)
    if [[ -n "$HOME" && -d "$HOME" && "$HOME" != "/root" ]]; then
        echo "$HOME"
        return 0
    fi
    
    # Method 4: If we're root but have SUDO_USER, check their home
    if [[ -d "/home/${SUDO_USER:-}" ]]; then
        echo "/home/$SUDO_USER"
        return 0
    fi
    
    # Fallback to HOME
    echo "${HOME:-/tmp}"
}

# Initialize user identity variables if not already set
init_user_identity() {
    # USER/LOGNAME are not guaranteed (cron, some containers, `env -i`); with
    # set -u the unguarded $USER aborted the script before the menu appeared.
    INVOKING_USER="${DAYZ_USER:-${SUDO_USER:-${LOGNAME:-${USER:-$(id -un)}}}}"
    INVOKING_HOME="${DAYZ_HOME:-$(get_user_home "$INVOKING_USER")}"
    export INVOKING_USER INVOKING_HOME
}

# -----------------------------------------------------------------------------
# File Helpers
# -----------------------------------------------------------------------------

# Quote a string for use in .env file
# Usage: quoted=$(env_quote "value with spaces")
# Quote a value for a docker compose .env file (double-quoted form).
# Compose interpolates $VAR and ${VAR} inside double quotes and rejects
# things like $1, so a literal dollar must be written as $$.
env_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//\$/\$\$}"
    printf "\"%s\"" "$s"
}

# Write content to a file, creating parent directories
# Usage: write_file "/path/to/file" "content"
write_file() {
    local path="$1"; shift
    mkdir -p "$(dirname "${path}")"
    cat > "${path}" <<EOF
$*
EOF
}

# -----------------------------------------------------------------------------
# Marker & .env File Parsing
# -----------------------------------------------------------------------------

# Get a value from a marker file (KEY=value format)
# Usage: value=$(marker_get "/path/.dayz-instance" "INSTANCE_NAME")
marker_get() {
    local marker="$1" key="$2"
    grep -E "^${key}=" "${marker}" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

# Get a value from a .env file (handles quoted values)
# Usage: value=$(dotenv_get "/path/.env" "STEAM_USER")
dotenv_get() {
    local file="$1" key="$2"
    local line val
    line="$(grep -E "^${key}=" "${file}" 2>/dev/null | head -n1 || true)"
    [[ -n "${line}" ]] || return 1
    val="${line#*=}"
    val="${val%$'\r'}"
    if [[ "${val}" =~ ^\".*\"$ ]]; then
        val="${val:1:${#val}-2}"
        val="${val//\\n/$'\n'}"
        val="${val//\\\"/\"}"
        val="${val//\\\\/\\}"
        val="${val//\$\$/\$}"
    fi
    printf "%s" "${val}"
}

# -----------------------------------------------------------------------------
# Mission Resolution
# -----------------------------------------------------------------------------

# Find active mission path from serverDZ.cfg
get_mission_path() {
    local instance_dir="$1"
    local cfg=""
    
    # Try common config locations
    local cfg_paths=(
        "${instance_dir}/data/config/serverDZ.cfg"
        "${instance_dir}/data/serverfiles/serverDZ.cfg"
        "${instance_dir}/serverfiles/serverDZ.cfg"
        "${instance_dir}/serverDZ.cfg"
    )
    for p in "${cfg_paths[@]}"; do
        if [[ -f "$p" ]]; then cfg="$p"; break; fi
    done

    local template=""
    if [[ -n "$cfg" ]]; then
        # More flexible regex for template (handles indentation and spaces)
        # Accept every spelling DayZ allows: indented, inside a one-line
        # "class Missions { class DayZ { template = "..."; }; };" and any case.
        template=$(grep -ioE 'template[[:space:]]*=[[:space:]]*"[^"]+"' "$cfg" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    if [[ -n "$template" ]]; then
        local paths=(
            "${instance_dir}/data/serverfiles/mpmissions/${template}"
            "${instance_dir}/data/mpmissions/${template}"
            "${instance_dir}/serverfiles/mpmissions/${template}"
            "${instance_dir}/mpmissions/${template}"
        )
        for p in "${paths[@]}"; do
            [[ -d "$p" ]] && { echo "$p"; return 0; }
        done
    fi

    # Fallback: Find mission by looking for economy files
    local fallback
    fallback=$(find "${instance_dir}" -maxdepth 6 -name "cfgeconomycore.xml" -o -name "economy.xml" 2>/dev/null | head -n 1)
    if [[ -n "$fallback" ]]; then
        dirname "$fallback"
        return 0
    fi

    return 1
}
