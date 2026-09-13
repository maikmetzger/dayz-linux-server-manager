#!/usr/bin/env bash
# =============================================================================
# DayZ Server Control via RCON
# =============================================================================
# Provides server control functions accessible via BattlEye RCON:
# - Graceful shutdown
# - Lock/Unlock server
# - Performance monitoring
# =============================================================================

# Ensure script directory is set
[[ -z "${SCRIPT_DIR:-}" ]] && SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Source dependencies
source "${SCRIPT_DIR}/lib/menu.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/dialogs.sh" 2>/dev/null || true

# =============================================================================
# RCON Action Helper
# =============================================================================

# Execute server control RCON action
# Usage: result=$(server_rcon_action "$inst_dir" "action" [args...])
server_rcon_action() {
    local inst_dir="$1"
    local action="$2"
    shift 2
    local extra_args=("$@")
    
    # Get container name
    local marker="${inst_dir}/.dayz-instance"
    if [[ ! -f "$marker" ]]; then
        echo '{"success": false, "error": "Not a DayZ instance"}'
        return 1
    fi
    
    local container_name
    container_name=$(grep -oP 'CONTAINER_NAME=\K.*' "$marker" 2>/dev/null || echo "")
    if [[ -z "$container_name" ]]; then
        echo '{"success": false, "error": "Container name not found"}'
        return 1
    fi
    
    # Get RCON port and password
    local dz_port
    dz_port=$(grep -oP 'DZ_PORT=\K[0-9]+' "$marker" 2>/dev/null || echo "2300")
    local port=$((dz_port + 3))
    
    local be_config="${inst_dir}/data/config/BEServer_x64.cfg"
    if [[ ! -f "$be_config" ]]; then
        echo '{"success": false, "error": "BattlEye config not found"}'
        return 1
    fi
    
    local pass
    pass=$(grep "^RConPassword" "$be_config" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "")
    
    if [[ -z "$pass" ]]; then
        echo '{"success": false, "error": "RCON password not configured"}'
        return 1
    fi
    
    # Build RCON command
    local rcon_args=(
        --host "127.0.0.1"
        --port "$port"
        --action "$action"
    )
    
    for arg in "${extra_args[@]}"; do
        rcon_args+=("$arg")
    done
    
    # Execute via Docker
    local python_src="${SCRIPT_DIR}/lib/be_rcon.py"
    if [[ ! -f "$python_src" ]]; then
        echo '{"success": false, "error": "RCON client not found"}'
        return 1
    fi
    
    docker cp "$python_src" "${container_name}:/tmp/rcon_client.py" 2>/dev/null
    # Password via environment: command lines are visible in /proc and docker inspect
    docker exec -e "RCON_PASSWORD=$pass" "$container_name" python3 /tmp/rcon_client.py "${rcon_args[@]}" 2>/dev/null
}

# =============================================================================
# JSON Helper (same as players.sh)
# =============================================================================

json_get() {
    local json="$1"
    local path="$2"
    local default="${3:-}"

    # Data is passed as arguments, never pasted into Python source:
    # player names from RCON may contain quotes or backslashes.
    python3 - "$json" "$path" "$default" <<'PY_JSON_GET'
import json, sys
raw, path, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    result = json.loads(raw)
    for key in path.lstrip('.').split('.'):
        if key:
            result = result.get(key) if isinstance(result, dict) else None
        if result is None:
            break
    if result is None:
        print(default)
    elif isinstance(result, bool):
        print('true' if result else 'false')
    elif isinstance(result, (dict, list)):
        print(json.dumps(result))
    else:
        print(result)
except Exception:
    print(default)
PY_JSON_GET
}

# =============================================================================
# Server Control Menu
# =============================================================================

server_control_menu() {
    local inst_dir="$1"
    local selection=0
    
    while true; do
        local -a items=(
            "🔴|Shutdown Server"
            "🔒|Lock Server"
            "🔓|Unlock Server"
            "📊|Monitor Performance"
            "--------------------"
            "←|Back"
        )
        
        if ! run_menu items "Server Control" $selection; then
            return
        fi
        
        selection=$MENU_RESULT
        local selected="${items[$MENU_RESULT]}"
        
        case "$selected" in
            "🔴|Shutdown Server")
                shutdown_server_dialog "$inst_dir"
                ;;
            "🔒|Lock Server")
                lock_server "$inst_dir"
                ;;
            "🔓|Unlock Server")
                unlock_server "$inst_dir"
                ;;
            "📊|Monitor Performance")
                monitor_server "$inst_dir"
                ;;
            "←|Back")
                return
                ;;
        esac
    done
}

# =============================================================================
# Server Control Actions
# =============================================================================

shutdown_server_dialog() {
    local inst_dir="$1"
    
    # Confirm with warning
    if ! confirm "Are you sure you want to shutdown the server?

This will disconnect all players and stop the DayZ process.
The container will remain running." "n"; then
        return
    fi
    
    # Optional: warn players first
    if confirm "Warn players before shutdown?" "y"; then
        local result
        result=$(server_rcon_action "$inst_dir" "say" --message "[ADMIN] Server shutting down in 30 seconds!")
        show_message "Warning sent to players" "📢 Notice"
        sleep 5
    fi
    
    # Execute shutdown
    local result
    result=$(server_rcon_action "$inst_dir" "shutdown")
    
    local success
    success=$(json_get "$result" "success" "false")
    
    if [[ "$success" == "true" ]]; then
        show_message "Server shutdown command sent" "✓ Success"
    else
        local error
        error=$(json_get "$result" "error" "Unknown error")
        show_message "Failed: $error" "✗ Error"
    fi
}

lock_server() {
    local inst_dir="$1"
    
    local result
    result=$(server_rcon_action "$inst_dir" "lock")
    
    local success
    success=$(json_get "$result" "success" "false")
    
    if [[ "$success" == "true" ]]; then
        show_message "Server locked - no new connections allowed" "🔒 Locked"
    else
        local error
        error=$(json_get "$result" "error" "Unknown error")
        show_message "Failed: $error" "✗ Error"
    fi
}

unlock_server() {
    local inst_dir="$1"
    
    local result
    result=$(server_rcon_action "$inst_dir" "unlock")
    
    local success
    success=$(json_get "$result" "success" "false")
    
    if [[ "$success" == "true" ]]; then
        show_message "Server unlocked - new connections allowed" "🔓 Unlocked"
    else
        local error
        error=$(json_get "$result" "error" "Unknown error")
        show_message "Failed: $error" "✗ Error"
    fi
}

monitor_server() {
    local inst_dir="$1"
    
    show_message "Fetching performance data..." "⏳ Please wait"
    
    local result
    result=$(server_rcon_action "$inst_dir" "monitor" --seconds 5)
    
    local success
    success=$(json_get "$result" "success" "false")
    
    if [[ "$success" == "true" ]]; then
        local response
        response=$(json_get "$result" "response" "No data")
        show_message "Performance Data:

$response" "📊 Monitor"
    else
        local error
        error=$(json_get "$result" "error" "Unknown error")
        show_message "Failed: $error" "✗ Error"
    fi
}
