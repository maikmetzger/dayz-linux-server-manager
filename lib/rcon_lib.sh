#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Unified RCON Library
# =============================================================================
# Consolidates all RCON connection and execution logic
# SECURITY: Passwords passed via environment variables, not command line
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_RCON_LIB_LOADED:-}" ]] && return 0
_DAYZ_RCON_LIB_LOADED=1

# Source dependencies
RCON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${RCON_LIB_DIR}/constants.sh"

# =============================================================================
# Docker command
# =============================================================================

# Docker CLI as an array, honouring $DOCKER ("docker" or "sudo docker").
# With sudo the password variables are preserved so they never have to be
# written onto the command line.
# Usage: local -a dcmd; mapfile -t dcmd < <(_rcon_docker_cmd)
_rcon_docker_cmd() {
    local -a cmd
    local IFS=' '
    read -r -a cmd <<< "${DOCKER:-docker}"
    if [[ "${cmd[0]}" == "sudo" ]]; then
        cmd=(sudo --preserve-env=RCON_PASSWORD,ADMIN_PASSWORD "${cmd[@]:1}")
    fi
    printf '%s\n' "${cmd[@]}"
}

# =============================================================================
# RCON Credential Extraction
# =============================================================================

# Get RCON connection details for an instance
# Usage: mapfile -t details < <(get_rcon_credentials "$inst_dir")
#        port="${details[0]}" pass="${details[1]}" container="${details[2]}"
# Returns: port, password, container_name (3 lines)
get_rcon_credentials() {
    local inst_dir="$1"

    local marker
    marker=$(get_instance_marker "$inst_dir")

    if [[ ! -f "$marker" ]]; then
        return 1
    fi

    # Get container name
    local container_name
    container_name=$(grep -oP 'CONTAINER_NAME=\K.*' "$marker" 2>/dev/null || echo "")
    if [[ -z "$container_name" ]]; then
        # Try alternative key
        container_name=$(grep -oP 'CONTAINER=\K.*' "$marker" 2>/dev/null || echo "")
    fi

    if [[ -z "$container_name" ]]; then
        return 1
    fi

    # Get port
    local dz_port
    dz_port=$(grep -oP 'DZ_PORT=\K[0-9]+' "$marker" 2>/dev/null || echo "$DAYZ_DEFAULT_PORT")
    local rcon_port=$((dz_port + RCON_PORT_OFFSET))

    # Get password from BattlEye config
    local be_cfg
    be_cfg=$(get_be_cfg "$inst_dir")

    if [[ ! -f "$be_cfg" ]]; then
        return 1
    fi

    # BEServer_x64.cfg may set its own port (RConPort <n>); it wins over DZ_PORT+3
    local cfg_port
    cfg_port=$(grep -E '^RConPort[[:space:]]+[0-9]+' "$be_cfg" 2>/dev/null | awk '{print $2}' | tr -d '\r' | head -n 1)
    [[ "$cfg_port" =~ ^[0-9]+$ ]] && rcon_port="$cfg_port"

    local rcon_pass
    rcon_pass=$(grep "^RConPassword" "$be_cfg" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "")

    if [[ -z "$rcon_pass" ]]; then
        return 1
    fi

    # Output all three values
    echo "$rcon_port"
    echo "$rcon_pass"
    echo "$container_name"
}

# Get DayZ admin password (for #login command)
# Usage: admin_pass=$(get_dayz_admin_pass "$inst_dir")
get_dayz_admin_pass() {
    local inst_dir="$1"
    local server_cfg
    server_cfg=$(get_server_cfg "$inst_dir")

    if [[ -f "$server_cfg" ]]; then
        grep -oP 'passwordAdmin\s*=\s*"\K[^"]*' "$server_cfg" 2>/dev/null || echo ""
    fi
}

# =============================================================================
# RCON Script Management
# =============================================================================

# Ensure RCON Python script is deployed to container
# Usage: ensure_rcon_script "$container_name" "$script_dir"
ensure_rcon_script() {
    local container_name="$1"
    local script_dir="${2:-$RCON_LIB_DIR}"

    local python_src="${script_dir}/be_rcon.py"
    if [[ ! -f "$python_src" ]]; then
        echo "RCON client script not found: $python_src" >&2
        return 1
    fi

    # Copy script to container
    local -a dcmd; mapfile -t dcmd < <(_rcon_docker_cmd)
    "${dcmd[@]}" cp "$python_src" "${container_name}:${DAYZ_CONTAINER_RCON_SCRIPT}" 2>/dev/null
}

# =============================================================================
# RCON Execution (SECURE)
# =============================================================================

# Execute RCON action and return JSON result
# SECURITY: Password passed via environment variable, not command line
# Usage: result=$(rcon_action "$inst_dir" "action" [extra_args...])
rcon_action() {
    local inst_dir="$1"
    local action="$2"
    shift 2
    local extra_args=("$@")

    # Get credentials
    local details
    if ! mapfile -t details < <(get_rcon_credentials "$inst_dir"); then
        echo '{"success": false, "error": "Failed to get RCON credentials"}'
        return 1
    fi

    if [[ ${#details[@]} -lt 3 ]]; then
        echo '{"success": false, "error": "Incomplete RCON configuration"}'
        return 1
    fi

    local port="${details[0]}"
    local pass="${details[1]}"
    local container_name="${details[2]}"

    # Get optional admin password
    local admin_pass
    admin_pass=$(get_dayz_admin_pass "$inst_dir")

    # Ensure script is deployed
    if ! ensure_rcon_script "$container_name" "$RCON_LIB_DIR"; then
        echo '{"success": false, "error": "RCON client not found"}'
        return 1
    fi

    # Build RCON command arguments
    local rcon_args=(
        --host "127.0.0.1"
        --port "$port"
        --action "$action"
    )

    # Admin password (for #login) travels through the environment as well
    if [[ -n "$admin_pass" ]]; then
        rcon_args+=(--admin-password-env ADMIN_PASSWORD)
    fi

    # Add extra arguments
    for arg in "${extra_args[@]}"; do
        rcon_args+=("$arg")
    done

    # Add debug flag if DEBUG_RCON is set
    if [[ -n "${DEBUG_RCON:-}" ]]; then
        local debug_log
        debug_log=$(get_state_dir "$inst_dir")/rcon_debug.log
        mkdir -p "$(dirname "$debug_log")" 2>/dev/null
        rcon_args+=(--debug)
        echo "--- $(date) ---" >> "$debug_log"
        echo "Action: $action" >> "$debug_log"
    fi

    # Passwords go through the environment only. "-e NAME" without a value
    # copies the variable from our environment, so neither the host's docker
    # process nor the container's python process shows it on the command line.
    local -a dcmd; mapfile -t dcmd < <(_rcon_docker_cmd)
    local stderr_target=/dev/null
    [[ -n "${DEBUG_RCON:-}" ]] && stderr_target="$debug_log"
    RCON_PASSWORD="$pass" ADMIN_PASSWORD="$admin_pass" \
        "${dcmd[@]}" exec -e RCON_PASSWORD -e ADMIN_PASSWORD "$container_name" \
        python3 "${DAYZ_CONTAINER_RCON_SCRIPT}" "${rcon_args[@]}" --password-env RCON_PASSWORD 2>> "$stderr_target"
}

# =============================================================================
# Safe Container Command Execution
# =============================================================================

# Safely append a line to a file in container
# SECURITY: Uses printf with proper quoting to prevent injection
# Usage: safe_container_append_line "$container" "/path/to/file" "line content"
safe_container_append_line() {
    local container="$1"
    local file_path="$2"
    local content="$3"

    # Use printf to safely write the content
    # The content is passed as a separate argument to printf, not interpolated
    local -a dcmd; mapfile -t dcmd < <(_rcon_docker_cmd)
    "${dcmd[@]}" exec "$container" sh -c 'printf "%s\n" "$1" >> "$2"' _ "$content" "$file_path" 2>/dev/null
}

# Safely remove a line starting with pattern from file in container
# SECURITY: Uses grep -v with fixed string matching where possible
# Usage: safe_container_remove_line "$container" "/path/to/file" "pattern"
safe_container_remove_line() {
    local container="$1"
    local file_path="$2"
    local key="$3"

    # An empty key would match every line and empty the file
    if [[ -z "$key" ]]; then
        echo "safe_container_remove_line: refusing empty key for ${file_path}" >&2
        return 1
    fi

    # Remove only lines whose first field is exactly the key
    # (bans.txt lines look like "<guid> <expiry> [reason]"). Returns docker's status.
    local -a dcmd; mapfile -t dcmd < <(_rcon_docker_cmd)
    "${dcmd[@]}" exec "$container" sh -c '
        [ -f "$2" ] || exit 0
        awk -v key="$1" '"'"'$1 != key'"'"' "$2" > "$2.tmp" && mv "$2.tmp" "$2"
    ' _ "$key" "$file_path" 2>/dev/null
}

# =============================================================================
# High-Level RCON Operations
# =============================================================================

# Kick a player by name
# Usage: result=$(rcon_kick_player "$inst_dir" "PlayerName")
rcon_kick_player() {
    local inst_dir="$1"
    local player_name="$2"

    rcon_action "$inst_dir" "kick" --player-name "$player_name"
}

# Send a message to all players
# Usage: result=$(rcon_say "$inst_dir" "Message text")
rcon_say() {
    local inst_dir="$1"
    local message="$2"

    rcon_action "$inst_dir" "say" --message "$message"
}

# Get online players list
# Usage: result=$(rcon_get_players "$inst_dir")
rcon_get_players() {
    local inst_dir="$1"

    rcon_action "$inst_dir" "players"
}

# Reload bans from bans.txt
# Usage: result=$(rcon_reload_bans "$inst_dir")
rcon_reload_bans() {
    local inst_dir="$1"

    rcon_action "$inst_dir" "loadbans"
}

# Lock server (prevent new connections)
# Usage: result=$(rcon_lock "$inst_dir")
rcon_lock() {
    local inst_dir="$1"

    rcon_action "$inst_dir" "lock"
}

# Unlock server
# Usage: result=$(rcon_unlock "$inst_dir")
rcon_unlock() {
    local inst_dir="$1"

    rcon_action "$inst_dir" "unlock"
}

# Shutdown server
# Usage: result=$(rcon_shutdown "$inst_dir")
rcon_shutdown() {
    local inst_dir="$1"

    rcon_action "$inst_dir" "shutdown"
}
