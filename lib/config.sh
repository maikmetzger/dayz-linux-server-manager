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
# Use simple keys (no emojis) for reliable associative array lookup
declare -A SERVERDZ_CATEGORIES=(
    ["General"]="hostname,motd,motdInterval,maxPlayers,instanceId"
    ["Security"]="password,passwordAdmin,verifySignatures,BattlEye,allowFilePatching,forceSameBuild"
    ["Time"]="serverTime,serverTimeAcceleration,serverTimePersistent,serverNightTimeAcceleration"
    ["Network"]="steamQueryPort,respawnTime,storeHouseStateDisabled,disableVoN,vonCodecQuality"
    ["Gameplay"]="disable3rdPerson,disableCrosshair,enableCfgGameplayFile,lootHistory"
)

# Display names with emojis (for menu display only)
declare -A SERVERDZ_CATEGORY_DISPLAY=(
    ["General"]="🏠 General"
    ["Security"]="🔒 Security"
    ["Time"]="⏱️  Time & Weather"
    ["Network"]="🌐 Network"
    ["Gameplay"]="🎮 Gameplay"
)

# Order for category display (simple keys)
SERVERDZ_CATEGORY_ORDER=(
    "General"
    "Security"
    "Time"
    "Network"
    "Gameplay"
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
    [[ -f "${parser_script}" ]] || { echo '{"status":"error","message":"Parser script not found"}'; return 0; }
    
    # Disable exit on error for docker commands
    set +e
    
    # Copy script to container
    $DOCKER cp "${parser_script}" "${container}:/tmp/config_parser.py" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        set -e
        echo '{"status":"error","message":"Failed to copy parser to container. Is the container running?"}'
        return 0
    fi
    
    # Execute in container
    local output
    output=$($DOCKER exec "${container}" python3 /tmp/config_parser.py "${args[@]}" 2>&1)
    local exit_code=$?
    
    set -e
    
    if [[ $exit_code -ne 0 ]]; then
        echo "{\"status\":\"error\",\"message\":\"Parser failed: ${output}\"}"
        return 0
    fi
    
    echo "$output"
}

# Parse JSON response from Python
# Usage: result=$(config_parser_exec ...) && value=$(json_get "$result" "value")
json_get() {
    local json="$1"
    local key="$2"
    
    # Grep for "key": ... up to comma or closing brace
    # Handle quoted "value" or unquoted value (numbers/bools)
    # Use || true to prevent crash if not found (due to set -o pipefail)
    local match
    match=$(echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[^,}]*" || true)
    
    # Clean up structure to extract value
    # Remove key
    local value="${match#*:}"
    # methods to trim whitespace and quotes:
    # 1. Remove leading whitespace/colon
    value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/^[[:space:]]*"//' -e 's/"$//')
    
    echo "$value"
}

json_get_status() {
    local json="$1"
    json_get "$json" "status"
}

json_get_keys() {
    local json="$1"
    # Extract keys array: ["key1", "key2"] -> key1 key2
    # Use || true to prevent crash
    echo "$json" | grep -o '"keys"[[:space:]]*:[[:space:]]*\[[^]]*\]' | \
        sed 's/.*\[\(.*\)\].*/\1/' | tr ',' '\n' | sed 's/[" ]//g' || true
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
        
        # Build menu with display names (emojis)
        local -a items=()
        for cat in "${SERVERDZ_CATEGORY_ORDER[@]}"; do
            items+=("${SERVERDZ_CATEGORY_DISPLAY[$cat]}")
        done
        items+=("← Back")
        
        if ! run_menu items "Select Category"; then
            return
        fi
        
        if [[ $MENU_RESULT -eq ${#SERVERDZ_CATEGORY_ORDER[@]} ]]; then
            return
        fi
        
        # Use simple key for lookup
        local selected_cat="${SERVERDZ_CATEGORY_ORDER[$MENU_RESULT]}"
        local keys_csv="${SERVERDZ_CATEGORIES[$selected_cat]}"
        local display_name="${SERVERDZ_CATEGORY_DISPLAY[$selected_cat]}"
        
        config_table_editor "$container" "$config_path" "$display_name" "$keys_csv"
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
    local filename
    filename="$(basename "$config_path")"
    
    # Parse keys
    IFS=',' read -ra keys <<< "$keys_csv"
    
    local selection=0
    local scroll_offset=0
    
    while true; do
        # Fetch current values every loop (or optimization: only on enter?)
        # For now, fetch every time to be safe, or cache it?
        # Fetching every frame is slow for TUI. Fetch once, then update locally?
        # Better: Fetch at start of loop, but optimize if user just moved cursor?
        # Let's fetch once per loop for now, optimize if laggy.
        
        local result
        result=$(config_parser_exec "$container" getall cfg "$container_path")
        
        if [[ "$(json_get_status "$result")" != "ok" ]]; then
            show_message "Failed to read config" "Error"
            return
        fi
        
        # Parse values into array
        local -a values=()
        local max_key_len=10
        for key in "${keys[@]}"; do
            local val
            val=$(json_get "$result" "$key")
            values+=("$val")
            (( ${#key} > max_key_len )) && max_key_len=${#key}
        done
        [[ $max_key_len -gt 40 ]] && max_key_len=40
        
        # Calculate Layout
        get_term_size
        local table_start=3
        local col_key=2
        local col_val=$((col_key + max_key_len + 5))
        local max_rows=$((TERM_ROWS - table_start - 3)) # leave space for footer
        
        # Input Loop (Inner loop to avoid re-fetching data just for navigation)
        while true; do
             # Handle scrolling
            if [[ $selection -lt $scroll_offset ]]; then
                scroll_offset=$selection
            elif [[ $selection -ge $((scroll_offset + max_rows)) ]]; then
                scroll_offset=$((selection - max_rows + 1))
            fi
            
            # Draw UI
            printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
            
            # 1. Header Bar
            move_to 1 1
            printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Config Editor - $filename - $title" "$RESET"
            
            # 2. Table Header
            local table_start=3
            move_to $table_start 1
            printf "%s%s" "$DIM" "$RED"
            printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
            printf "%s" "$RESET"
            
            move_to $((table_start + 1)) $col_key
            printf "%s%sKEY%s" "$DIM" "$WHITE" "$RESET"
            move_to $((table_start + 1)) $col_val
            printf "%s%sVALUE%s" "$DIM" "$WHITE" "$RESET"
            
            move_to $((table_start + 2)) 1
            printf "%s%s" "$DIM" "$RED"
            printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
            printf "%s" "$RESET"
            
            # 3. Rows
            local row=$((table_start + 3))
            local count=${#keys[@]}
            
            for (( i=scroll_offset; i<count && i<(scroll_offset + max_rows); i++ )); do
                local key="${keys[$i]}"
                local val="${values[$i]}"
                
                # Truncate value
                local max_val_len=$((TERM_COLS - col_val - 2))
                [[ ${#val} -gt $max_val_len ]] && val="${val:0:$((max_val_len-3))}..."
                [[ -z "$val" ]] && val="(empty)"
                
                move_to $row 1
                if [[ $i -eq $selection ]]; then
                    # Selected Row
                    printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
                    move_to $row $col_key
                    printf "▶ %s" "$key"
                    move_to $row $col_val
                    printf "%s" "$val"
                    printf "%s" "$RESET"
                else
                    # Normal Row
                    move_to $row $col_key
                    printf "  %s" "$key"
                    move_to $row $col_val
                    printf "%s%s%s" "$DIM" "$val" "$RESET"
                fi
                ((row++))
            done
            
            # 4. Footer
            move_to $TERM_ROWS 1
            local footer_text=" [Enter] Edit   [q] Back"
            local pad_len=$((TERM_COLS - ${#footer_text} - 1))
            printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer_text" "$pad_len" "" "$RESET"
            
            # Input Handling
            IFS= read -rsn1 key
            case "$key" in
                $'\x1b')
                    read -rsn2 -t 0.1 seq || true
                    case "$seq" in
                        '[A') 
                            if [[ $selection -gt 0 ]]; then
                                selection=$((selection - 1))
                            fi
                            ;;
                        '[B') 
                            if [[ $selection -lt $((count - 1)) ]]; then
                                selection=$((selection + 1))
                            fi
                            ;;
                    esac
                    ;;
                '') # Enter - Edit
                    break # Break inner loop to edit
                    ;;
                'q'|'Q')
                    return # Exit function
                    ;;
            esac
        done
        
        # Edit Action
        local selected_key="${keys[$selection]}"
        local current_val="${values[$selection]}"
        [[ "$current_val" == "(empty)" ]] && current_val=""
        
        local new_val
        new_val=$(read_input "Edit $selected_key" "$current_val" "$title")
        
        if [[ -n "$new_val" && "$new_val" != "$current_val" ]]; then
            local set_result
            set_result=$(config_parser_exec "$container" set cfg "$container_path" "$selected_key" "$new_val")
            if [[ "$(json_get_status "$set_result")" != "ok" ]]; then
                show_message "Failed to save: $(json_get "$set_result" "message")" "Error"
            fi
        fi
    done
}
