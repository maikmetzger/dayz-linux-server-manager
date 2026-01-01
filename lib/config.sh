#!/usr/bin/env bash
# =============================================================================
# DayZ Config Editor - TUI Wrapper
# =============================================================================
# Provides file selection, category navigation, and inline editing for
# DayZ server configuration files.
# =============================================================================

# Ensure script directory is set (should be sourced from server-manager.sh)
[[ -z "${SCRIPT_DIR:-}" ]] && SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# =============================================================================
# Config Registry
# =============================================================================
# Format: "parser|relative_path|display_name"
declare -A CONFIG_REGISTRY=(
    ["serverDZ"]="cfg|data/config/serverDZ.cfg|🔧 Server Settings"
    ["BEServer"]="cfg|data/config/BEServer_x64.cfg|🔐 RCON Settings"
)

# =============================================================================
# Category Definitions for serverDZ.cfg
# =============================================================================
declare -A SERVERDZ_CATEGORIES=(
    ["🏠 General"]="hostname,motd,motdInterval,maxPlayers,instanceId"
    ["🔒 Security"]="password,passwordAdmin,verifySignatures,BattlEye,allowFilePatching,forceSameBuild"
    ["⏱️  Time & Weather"]="serverTime,serverTimeAcceleration,serverTimePersistent,serverNightTimeAcceleration"
    ["🌐 Network"]="steamQueryPort,respawnTime,storeHouseStateDisabled,disableVoN,vonCodecQuality"
    ["🎮 Gameplay"]="disable3rdPerson,disableCrosshair,enableCfgGameplayFile,lootHistory"
)

# Order for category display
SERVERDZ_CATEGORY_ORDER=(
    "🏠 General"
    "🔒 Security"
    "⏱️  Time & Weather"
    "🌐 Network"
    "🎮 Gameplay"
)

# =============================================================================
# Python Parser Wrapper
# =============================================================================
# Executes the config_parser.py in the container

config_parser_exec() {
    local container="$1"
    shift
    local args=("$@")
    
    local parser_script="${SCRIPT_DIR}/lib/config_parser.py"
    [[ -f "${parser_script}" ]] || { echo '{"status":"error","message":"Parser script not found"}'; return 1; }
    
    # Copy script to container
    $DOCKER cp "${parser_script}" "${container}:/tmp/config_parser.py" 2>/dev/null || {
        echo '{"status":"error","message":"Failed to copy parser to container"}'
        return 1
    }
    
    # Execute in container
    $DOCKER exec "${container}" python3 /tmp/config_parser.py "${args[@]}" 2>/dev/null
}

# Parse JSON response from Python
# Usage: result=$(config_parser_exec ...) && value=$(json_get "$result" "value")
json_get() {
    local json="$1"
    local key="$2"
    # Simple extraction using grep/sed (works for flat JSON)
    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*: *"\([^"]*\)".*/\1/' | head -1
}

json_get_status() {
    local json="$1"
    json_get "$json" "status"
}

json_get_keys() {
    local json="$1"
    # Extract keys array: ["key1", "key2"] -> key1 key2
    echo "$json" | grep -o '"keys"[[:space:]]*:[[:space:]]*\[[^]]*\]' | \
        sed 's/.*\[\(.*\)\].*/\1/' | tr ',' '\n' | sed 's/[" ]//g'
}

# =============================================================================
# Config Editor Main Menu
# =============================================================================

config_editor_menu() {
    local container="$SELECTED_CONTAINER"
    local inst_dir="$SELECTED_DIR"
    
    while true; do
        draw_header "Config Editor"
        
        local -a items=()
        local -a config_ids=()
        
        for id in "${!CONFIG_REGISTRY[@]}"; do
            IFS='|' read -r fmt rel_path display_name <<< "${CONFIG_REGISTRY[$id]}"
            local full_path="${inst_dir}/${rel_path}"
            
            # Check if file exists (via host path since it's mounted)
            if [[ -f "${full_path}" ]]; then
                items+=("${display_name}")
            else
                items+=("${display_name} (not found)")
            fi
            config_ids+=("$id")
        done
        
        items+=("← Back")
        
        if ! run_menu items "Select Config File"; then
            return
        fi
        
        if [[ $MENU_RESULT -eq ${#config_ids[@]} ]]; then
            return
        fi
        
        local selected_id="${config_ids[$MENU_RESULT]}"
        IFS='|' read -r fmt rel_path display_name <<< "${CONFIG_REGISTRY[$selected_id]}"
        local full_path="${inst_dir}/${rel_path}"
        
        if [[ ! -f "${full_path}" ]]; then
            show_message "File not found: ${rel_path}" "Error"
            continue
        fi
        
        # Route to appropriate editor based on config ID
        case "$selected_id" in
            "serverDZ") config_category_editor "$container" "$full_path" "serverDZ" ;;
            "BEServer") config_flat_editor "$container" "$full_path" "BEServer" ;;
            *) config_flat_editor "$container" "$full_path" "$selected_id" ;;
        esac
    done
}

# =============================================================================
# Category-based Editor (for serverDZ.cfg)
# =============================================================================

config_category_editor() {
    local container="$1"
    local config_path="$2"
    local config_id="$3"
    
    while true; do
        draw_header "Server Settings"
        
        local -a items=()
        for cat in "${SERVERDZ_CATEGORY_ORDER[@]}"; do
            items+=("$cat")
        done
        items+=("← Back")
        
        if ! run_menu items "Select Category"; then
            return
        fi
        
        if [[ $MENU_RESULT -eq ${#SERVERDZ_CATEGORY_ORDER[@]} ]]; then
            return
        fi
        
        local selected_cat="${SERVERDZ_CATEGORY_ORDER[$MENU_RESULT]}"
        local keys_csv="${SERVERDZ_CATEGORIES[$selected_cat]}"
        
        config_table_editor "$container" "$config_path" "$selected_cat" "$keys_csv"
    done
}

# =============================================================================
# Flat Editor (for simple configs like BEServer)
# =============================================================================

config_flat_editor() {
    local container="$1"
    local config_path="$2"
    local config_id="$3"
    
    # Get all keys from file
    local container_path="/dayz/config/$(basename "$config_path")"
    local result
    result=$(config_parser_exec "$container" list cfg "$container_path")
    
    if [[ "$(json_get_status "$result")" != "ok" ]]; then
        show_message "Failed to read config: $(json_get "$result" "message")" "Error"
        return
    fi
    
    local keys_raw
    keys_raw=$(json_get_keys "$result")
    local keys_csv
    keys_csv=$(echo "$keys_raw" | tr '\n' ',' | sed 's/,$//')
    
    config_table_editor "$container" "$config_path" "Settings" "$keys_csv"
}

# =============================================================================
# Table Editor (Key-Value pairs)
# =============================================================================

config_table_editor() {
    local container="$1"
    local config_path="$2"
    local title="$3"
    local keys_csv="$4"
    
    local container_path="/dayz/config/$(basename "$config_path")"
    
    # Parse keys
    IFS=',' read -ra keys <<< "$keys_csv"
    
    local selection=0
    
    while true; do
        draw_header "$title"
        
        # Fetch current values
        local result
        result=$(config_parser_exec "$container" getall cfg "$container_path")
        
        if [[ "$(json_get_status "$result")" != "ok" ]]; then
            show_message "Failed to read config" "Error"
            return
        fi
        
        # Build menu items with current values
        local -a items=()
        for key in "${keys[@]}"; do
            local value
            value=$(echo "$result" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | \
                    sed 's/.*: *"\([^"]*\)".*/\1/' | head -1)
            
            # Handle unquoted values (numbers, booleans)
            if [[ -z "$value" ]]; then
                value=$(echo "$result" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[^,}]*" | \
                        sed 's/.*: *\([^,}]*\).*/\1/' | tr -d ' ' | head -1)
            fi
            
            # Truncate long values for display
            if [[ ${#value} -gt 30 ]]; then
                value="${value:0:27}..."
            fi
            
            # Format: key = value (or key = (empty) if empty)
            if [[ -z "$value" ]]; then
                items+=("${key} = (empty)")
            else
                items+=("${key} = ${value}")
            fi
        done
        items+=("← Back")
        
        if ! run_menu items "$title - Press Enter to Edit" $selection; then
            return
        fi
        
        selection=$MENU_RESULT
        
        if [[ $MENU_RESULT -eq ${#keys[@]} ]]; then
            return
        fi
        
        # Edit selected key
        local selected_key="${keys[$MENU_RESULT]}"
        
        # Get current value
        local current_value
        current_value=$(config_parser_exec "$container" get cfg "$container_path" "$selected_key")
        current_value=$(json_get "$current_value" "value")
        
        # Show input dialog
        local new_value
        new_value=$(read_input "Edit: ${selected_key}" "$current_value" "$title")
        
        # If value changed, save it
        if [[ -n "$new_value" && "$new_value" != "$current_value" ]]; then
            local set_result
            set_result=$(config_parser_exec "$container" set cfg "$container_path" "$selected_key" "$new_value")
            
            if [[ "$(json_get_status "$set_result")" != "ok" ]]; then
                show_message "Failed to save: $(json_get "$set_result" "message")" "Error"
            fi
        fi
    done
}
