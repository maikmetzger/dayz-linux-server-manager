#!/usr/bin/env bash
# =============================================================================
# DayZ Player Management - TUI Library
# =============================================================================
# Provides player list view and admin actions (kick, ban, message) via RCON
# Requires: lib/tui.sh, lib/dialogs.sh, lib/colors.sh
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_PLAYERS_LOADED:-}" ]] && return 0
_DAYZ_PLAYERS_LOADED=1

# Source dependencies
PLAYERS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PLAYERS_LIB_DIR}/colors.sh"
source "${PLAYERS_LIB_DIR}/tui.sh"
source "${PLAYERS_LIB_DIR}/dialogs.sh"
source "${PLAYERS_LIB_DIR}/utils.sh"

# =============================================================================
# JSON Parsing Helpers (uses python3, no jq dependency)
# =============================================================================

# Parse JSON field using Python
# Usage: value=$(json_get "$json" ".field" "default")
json_get() {
    local json="$1"
    local path="$2"
    local default="${3:-}"
    
    python3 -c "
import json, sys
try:
    data = json.loads('''$json''')
    keys = '$path'.lstrip('.').split('.')
    result = data
    for key in keys:
        if key:
            result = result.get(key, None) if isinstance(result, dict) else None
            if result is None:
                break
    if result is None:
        print('$default')
    elif isinstance(result, bool):
        print('true' if result else 'false')
    elif isinstance(result, (dict, list)):
        print(json.dumps(result))
    else:
        print(result)
except:
    print('$default')
" 2>/dev/null
}

# Parse JSON array to lines using Python
# Usage: while IFS= read -r item; do ... done < <(json_array "$json" ".players")
json_array() {
    local json="$1"
    local path="$2"
    
    python3 -c "
import json, sys
try:
    data = json.loads('''$json''')
    keys = '$path'.lstrip('.').split('.')
    result = data
    for key in keys:
        if key:
            result = result.get(key, []) if isinstance(result, dict) else []
    if isinstance(result, list):
        for item in result:
            print(json.dumps(item))
except:
    pass
" 2>/dev/null
}

# Count JSON array length
# Usage: count=$(json_count "$json" ".players")
json_count() {
    local json="$1"
    local path="$2"
    
    python3 -c "
import json
try:
    data = json.loads('''$json''')
    keys = '$path'.lstrip('.').split('.')
    result = data
    for key in keys:
        if key:
            result = result.get(key, []) if isinstance(result, dict) else []
    print(len(result) if isinstance(result, list) else 0)
except:
    print(0)
" 2>/dev/null
}

# Create JSON object using Python
# Usage: json=$(json_create key1 val1 key2 val2 ...)
json_create() {
    local args=("$@")
    local pairs=""
    for ((i=0; i<${#args[@]}; i+=2)); do
        local key="${args[$i]}"
        local val="${args[$((i+1))]}"
        [[ -n "$pairs" ]] && pairs+=", "
        pairs+="\"$key\": \"$val\""
    done
    echo "{$pairs}"
}

# =============================================================================
# Configuration
# =============================================================================

# State directory for ban tracking
PLAYERS_STATE_DIR=""

# =============================================================================
# Helper Functions
# =============================================================================

# Get max players from serverDZ.cfg
# Usage: max=$(get_max_players "$inst_dir")
get_max_players() {
    local inst_dir="$1"
    local config_file="${inst_dir}/data/config/serverDZ.cfg"
    
    if [[ -f "$config_file" ]]; then
        local max
        max=$(grep -oP 'maxPlayers\s*=\s*\K[0-9]+' "$config_file" 2>/dev/null || echo "60")
        echo "${max:-60}"
    else
        echo "60"
    fi
}

# NOTE: Admin detection is NOT possible via RCON because:
# - RCON returns BattlEye GUID (32-char hex, MD5 hash)
# - serverDZ.cfg uses Steam64 ID (17-digit number)
# These are different formats that can't be directly compared.
# Additionally, you cannot kick/ban yourself via RCON.


# Fetch online players via RCON as JSON
# Usage: json=$(fetch_online_players "$inst_dir")
fetch_online_players() {
    local inst_dir="$1"
    local rcon_output
    
    # Use run_rcon_action function (defined below) to execute RCON
    rcon_output=$(run_rcon_action "$inst_dir" "players")
    
    if [[ -z "$rcon_output" ]]; then
        echo '{"count": 0, "players": [], "error": "RCON failed"}'
    else
        echo "$rcon_output"
    fi
}

# Run RCON action and return JSON
# Usage: result=$(run_rcon_action "$inst_dir" "action" [args...])
run_rcon_action() {
    local inst_dir="$1"
    local action="$2"
    shift 2
    local extra_args=("$@")
    
    # Get RCON details from the instance
    local marker="${inst_dir}/.dayz-instance"
    local container_name
    container_name="$(grep -oP 'CONTAINER_NAME=\K.*' "$marker" 2>/dev/null || echo "")"
    
    if [[ -z "$container_name" ]]; then
        echo '{"success": false, "error": "No container found"}'
        return 1
    fi
    
    # Get RCON port and password from BEServer config
    # Port is calculated as DayZ port + 3
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
    
    # Get DayZ admin password from serverDZ.cfg for #login command
    # NOTE: This is DIFFERENT from RCON password!
    # - RConPassword (BEServer_x64.cfg) = BattlEye protocol auth
    # - passwordAdmin (serverDZ.cfg) = DayZ in-game admin auth (#login)
    local server_cfg="${inst_dir}/data/config/serverDZ.cfg"
    local admin_pass=""
    if [[ -f "$server_cfg" ]]; then
        admin_pass=$(grep -oP 'passwordAdmin\s*=\s*"\K[^"]*' "$server_cfg" 2>/dev/null || echo "")
    fi
    
    # Build RCON command arguments
    local rcon_args=(
        --host "127.0.0.1"
        --port "$port"
        --password "$pass"
        --action "$action"
    )
    
    # Add admin password if available (required for kick/ban commands)
    if [[ -n "$admin_pass" ]]; then
        rcon_args+=(--admin-password "$admin_pass")
    fi
    
    # Add extra arguments
    for arg in "${extra_args[@]}"; do
        rcon_args+=("$arg")
    done
    
    # Execute via Docker
    local python_src="${PLAYERS_LIB_DIR}/be_rcon.py"
    if [[ ! -f "$python_src" ]]; then
        echo '{"success": false, "error": "RCON client not found"}'
        return 1
    fi
    
    # Copy script to container and execute
    docker cp "$python_src" "${container_name}:/tmp/rcon_client.py" 2>/dev/null
    
    # Add --debug flag if DEBUG_RCON is set
    if [[ -n "${DEBUG_RCON:-}" ]]; then
        rcon_args+=(--debug)
        # Run with stderr visible for debugging
        docker exec "$container_name" python3 /tmp/rcon_client.py "${rcon_args[@]}"
    else
        docker exec "$container_name" python3 /tmp/rcon_client.py "${rcon_args[@]}" 2>/dev/null
    fi
}

# =============================================================================
# Players Menu
# =============================================================================

# Main players menu showing online player list
# Usage: players_menu "$inst_dir"
players_menu() {
    local inst_dir="$1"
    
    # Initialize state directory
    PLAYERS_STATE_DIR="${inst_dir}/data/state/players"
    mkdir -p "$PLAYERS_STATE_DIR" 2>/dev/null
    
    while true; do
        local max_players
        max_players=$(get_max_players "$inst_dir")
        
        # Fetch player data
        local player_json
        player_json=$(fetch_online_players "$inst_dir")
        
        local player_count
        player_count=$(json_get "$player_json" "count" "0")
        
        local error
        error=$(json_get "$player_json" "error" "")
        
        # Build menu items
        local -a items=()
        
        if [[ -n "$error" && "$error" != "null" ]]; then
            # Error state
            items+=("⚠️|Error: $error")
        elif [[ "$player_count" -eq 0 ]]; then
            # No players
            items+=("ℹ️|No players online")
        else
            # Add each player as menu item
            while IFS= read -r player; do
                [[ -z "$player" ]] && continue
                local name ping pid
                name=$(json_get "$player" "name" "Unknown")
                ping=$(json_get "$player" "ping" "0")
                pid=$(json_get "$player" "id" "0")
                
                # Format: "👤|Name|Ping|#ID"
                items+=("👤|${name}|${ping}ms|#${pid}")
            done < <(json_array "$player_json" "players")
        fi
        
        items+=("--------------------")
        items+=("🔄|Refresh")
        items+=("←|Back")
        
        # Draw custom header with player count
        get_term_size
        printf "%s" "$CLEAR_SCREEN"
        
        # Header bar
        move_to 1 1
        printf "%s%s" "$BG_RED" "$WHITE$BOLD"
        printf " 👥 Players - Online: %d / %d%*s" "$player_count" "$max_players" "$((TERM_COLS - 30))" ""
        printf "%s\n" "$RESET"
        
        if ! run_menu items "Players" 3; then
            return
        fi
        
        local selected="${items[$MENU_RESULT]}"
        
        case "$selected" in
            "🔄|Refresh")
                continue
                ;;
            "←|Back"|"----"*|"⚠️|"*|"ℹ️|"*)
                [[ "$selected" == "←|Back" ]] && return
                ;;
            "👤|"*)
                # Parse player data from selection
                local player_name player_ping player_id
                IFS='|' read -r _ player_name player_ping player_id <<< "$selected"
                player_id="${player_id#\#}"  # Remove # prefix
                
                # Get full player data - construct it from known values
                local full_player_data
                full_player_data="{\"id\": ${player_id}, \"name\": \"${player_name}\", \"ping\": ${player_ping%ms}}"
                
                # Try to get GUID from the original JSON
                while IFS= read -r p; do
                    local pid
                    pid=$(json_get "$p" "id" "-1")
                    if [[ "$pid" == "$player_id" ]]; then
                        full_player_data="$p"
                        break
                    fi
                done < <(json_array "$player_json" "players")
                
                player_details_menu "$inst_dir" "$full_player_data"
                ;;
        esac
    done
}

# =============================================================================
# Player Details Menu
# =============================================================================

# Show player details and action menu
# Usage: player_details_menu "$inst_dir" "$player_json"
player_details_menu() {
    local inst_dir="$1"
    local player_json="$2"
    
    local player_name player_id player_ping player_guid
    player_name=$(json_get "$player_json" "name" "Unknown")
    player_id=$(json_get "$player_json" "id" "0")
    player_ping=$(json_get "$player_json" "ping" "0")
    player_guid=$(json_get "$player_json" "guid" "")
    
    while true; do
        local -a items=(
            "💬|Send Message"
            "👢|Kick"
            "⛔|Ban"
            "--------------------"
            "←|Back"
        )
        
        # Custom header with player info
        get_term_size
        printf "%s" "$CLEAR_SCREEN"
        
        move_to 1 1
        printf "%s%s" "$BG_RED" "$WHITE$BOLD"
        printf " 👤 %s%*s" "$player_name" "$((TERM_COLS - ${#player_name} - 5))" ""
        printf "%s\n" "$RESET"
        
        move_to 2 1
        printf "%s Player #%s  │  Ping: %sms  │  GUID: %s...%s\n" \
            "$DIM" "$player_id" "$player_ping" "${player_guid:0:12}" "$RESET"
        
        if ! run_menu items "Player Actions" 4; then
            return
        fi
        
        local selected="${items[$MENU_RESULT]}"
        
        case "$selected" in
            "💬|Send Message")
                send_message_dialog "$inst_dir" "$player_name"
                ;;
            "👢|Kick")
                kick_player_dialog "$inst_dir" "$player_id" "$player_name" "$player_guid"
                return  # Return to player list after kick
                ;;
            "⛔|Ban")
                ban_player_dialog "$inst_dir" "$player_id" "$player_name" "$player_guid"
                return  # Return to player list after ban
                ;;
            "←|Back"|"----"*)
                [[ "$selected" == "←|Back" ]] && return
                ;;
        esac
    done
}

# =============================================================================
# Action Dialogs
# =============================================================================

# Send message dialog
# Usage: send_message_dialog "$inst_dir" "$player_name"
send_message_dialog() {
    local inst_dir="$1"
    local player_name="$2"
    
    local message
    message=$(read_input "Message to $player_name:" "" "Send Message")
    
    if [[ -z "$message" ]]; then
        return  # Cancelled
    fi
    
    # Format: [Admin → PlayerName]: message
    local formatted="[Admin → ${player_name}]: ${message}"
    
    # Send via RCON
    local result
    result=$(run_rcon_action "$inst_dir" "say" --message "$formatted")
    
    local success
    success=$(json_get "$result" "success" "false")
    
    if [[ "$success" == "true" ]]; then
        show_message "Message sent to server chat" "✓ Success"
    else
        local error
        error=$(json_get "$result" "error" "Unknown error")
        show_message "Failed: $error" "✗ Error"
    fi
}

# Kick player dialog with reason
# Usage: kick_player_dialog "$inst_dir" "$player_id" "$player_name" "$player_guid"
kick_player_dialog() {
    local inst_dir="$1"
    local player_id="$2"
    local player_name="$3"
    local player_guid="${4:-}"
    
    # Get reason (optional)
    local reason
    reason=$(read_input "Reason for kick (optional):" "" "Kick $player_name")
    
    # Confirm
    if ! confirm "Kick '${player_name}' from server?

They can rejoin at any time." "n"; then
        return
    fi
    
    # Execute kick - uses player NAME (not ID)
    local result
    if [[ -n "$reason" ]]; then
        result=$(run_rcon_action "$inst_dir" "kick" --player-name "$player_name" --reason "$reason")
    else
        result=$(run_rcon_action "$inst_dir" "kick" --player-name "$player_name")
    fi
    
    local success
    success=$(json_get "$result" "success" "false")
    
    # Get the actual RCON response for debugging
    local rcon_response
    rcon_response=$(json_get "$result" "response" "")
    
    if [[ "$success" == "true" ]]; then
        show_message "Kicked '$player_name'" "✓ Kick Sent"
    else
        local error
        error=$(json_get "$result" "error" "Unknown error")
        show_message "Failed: $error" "✗ Error"
    fi
}

# Ban player dialog with duration and reason
# Usage: ban_player_dialog "$inst_dir" "$player_id" "$player_name" "$player_guid"
ban_player_dialog() {
    local inst_dir="$1"
    local player_id="$2"
    local player_name="$3"
    local player_guid="$4"
    
    # Step 1: Get duration
    local duration
    duration=$(read_input "Ban duration (30m, 2h, 7d, perm):" "perm" "Ban $player_name")
    
    if [[ -z "$duration" ]]; then
        return  # Cancelled
    fi
    
    # Step 2: Get reason
    local reason
    reason=$(read_input "Reason for ban:" "" "Ban Reason")
    
    if [[ -z "$reason" ]]; then
        reason="Banned by admin"
    fi
    
    # Parse duration to human-readable
    local human_duration="permanent"
    local duration_minutes=-1
    
    if [[ "$duration" != "perm" && "$duration" != "permanent" ]]; then
        # Parse duration like "30m", "2h", "7d"
        local num="${duration%[mhdMHD]}"
        local unit="${duration: -1}"
        
        case "${unit,,}" in
            m) 
                duration_minutes=$num
                human_duration="$num minutes"
                ;;
            h) 
                duration_minutes=$((num * 60))
                human_duration="$num hours"
                ;;
            d) 
                duration_minutes=$((num * 60 * 24))
                human_duration="$num days"
                ;;
            *)
                human_duration="$duration"
                ;;
        esac
    fi
    
    # Step 3: Confirm
    if ! confirm "Ban '${player_name}' for ${human_duration}?

Reason: ${reason}" "y"; then
        return
    fi
    
    # Execute ban via RCON - uses GUID/Steam64ID
    local result
    result=$(run_rcon_action "$inst_dir" "ban" --player-guid "$player_guid" --reason "$reason")
    
    local success
    success=$(json_get "$result" "success" "false")
    
    if [[ "$success" == "true" ]]; then
        # Save ban record to our tracking file
        save_ban_record "$inst_dir" "$player_guid" "$player_name" "$duration_minutes" "$reason"
        show_message "Banned '$player_name' for $human_duration" "✓ Success"
    else
        local error
        error=$(json_get "$result" "error" "Unknown error")
        show_message "Failed: $error" "✗ Error"
    fi
}

# =============================================================================
# Ban Tracking
# =============================================================================

# Save ban record to JSON file for tracking
# Usage: save_ban_record "$inst_dir" "$guid" "$name" "$duration_minutes" "$reason"
save_ban_record() {
    local inst_dir="$1"
    local guid="$2"
    local name="$3"
    local duration_minutes="$4"
    local reason="$5"
    
    local bans_file="${PLAYERS_STATE_DIR}/bans.json"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Calculate expiry
    local expires="never"
    if [[ "$duration_minutes" -gt 0 ]]; then
        expires=$(date -u -d "+${duration_minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
    fi
    
    # Create or update bans file
    if [[ ! -f "$bans_file" ]]; then
        echo '{"bans": []}' > "$bans_file"
    fi
    
    # Create new ban entry using Python
    local new_ban
    new_ban=$(python3 -c "
import json
ban = {
    'guid': '$guid',
    'name': '''$name''',
    'reason': '''$reason''',
    'banned_at': '$now',
    'expires': '$expires',
    'duration_minutes': $duration_minutes
}
print(json.dumps(ban))
" 2>/dev/null)
    
    # Read existing bans and append using Python
    python3 -c "
import json
try:
    with open('$bans_file', 'r') as f:
        data = json.load(f)
except:
    data = {'bans': []}
data['bans'].append($new_ban)
with open('$bans_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
}

# =============================================================================
# Ban List Menu
# =============================================================================

# Show ban list and allow unbanning
# Usage: ban_list_menu "$inst_dir"
ban_list_menu() {
    local inst_dir="$1"
    
    PLAYERS_STATE_DIR="${inst_dir}/data/state/players"
    local bans_file="${PLAYERS_STATE_DIR}/bans.json"
    
    while true; do
        local -a items=()
        local ban_count=0
        
        if [[ -f "$bans_file" ]]; then
            # Read bans using Python
            local bans_data
            bans_data=$(cat "$bans_file" 2>/dev/null || echo '{"bans": []}')
            ban_count=$(json_count "$bans_data" "bans")
            
            if [[ "$ban_count" -gt 0 ]]; then
                while IFS= read -r ban; do
                    [[ -z "$ban" ]] && continue
                    local name reason
                    name=$(json_get "$ban" "name" "Unknown")
                    reason=$(json_get "$ban" "reason" "No reason")
                    
                    # Truncate reason for display
                    [[ ${#reason} -gt 20 ]] && reason="${reason:0:17}..."
                    
                    items+=("🚫|${name}|${reason}")
                done < <(json_array "$bans_data" "bans")
            fi
        fi
        
        if [[ "$ban_count" -eq 0 ]]; then
            items+=("ℹ️|No bans recorded")
        fi
        
        items+=("--------------------")
        items+=("🔄|Refresh")
        items+=("←|Back")
        
        # Header
        get_term_size
        printf "%s" "$CLEAR_SCREEN"
        move_to 1 1
        printf "%s%s" "$BG_RED" "$WHITE$BOLD"
        printf " 🚫 Ban List - %d bans%*s" "$ban_count" "$((TERM_COLS - 25))" ""
        printf "%s\n" "$RESET"
        
        if ! run_menu items "Ban List" 3; then
            return
        fi
        
        local selected="${items[$MENU_RESULT]}"
        
        case "$selected" in
            "🔄|Refresh")
                continue
                ;;
            "←|Back"|"----"*|"ℹ️|"*)
                [[ "$selected" == "←|Back" ]] && return
                ;;
            "🚫|"*)
                # Parse ban info and show details
                local ban_name
                IFS='|' read -r _ ban_name _ <<< "$selected"
                
                # Find full ban record using Python
                local ban_record bans_data
                bans_data=$(cat "$bans_file" 2>/dev/null || echo '{"bans": []}')
                while IFS= read -r b; do
                    [[ -z "$b" ]] && continue
                    local n
                    n=$(json_get "$b" "name" "")
                    if [[ "$n" == "$ban_name" ]]; then
                        ban_record="$b"
                        break
                    fi
                done < <(json_array "$bans_data" "bans")
                
                if [[ -n "$ban_record" ]]; then
                    ban_details_menu "$inst_dir" "$ban_record"
                fi
                ;;
        esac
    done
}

# Show ban details with unban option
# Usage: ban_details_menu "$inst_dir" "$ban_json"
ban_details_menu() {
    local inst_dir="$1"
    local ban_json="$2"
    
    local name guid reason banned_at expires
    name=$(json_get "$ban_json" "name" "Unknown")
    guid=$(json_get "$ban_json" "guid" "")
    reason=$(json_get "$ban_json" "reason" "No reason")
    banned_at=$(json_get "$ban_json" "banned_at" "Unknown")
    expires=$(json_get "$ban_json" "expires" "never")
    
    while true; do
        local -a items=(
            "🔓|Unban Player"
            "--------------------"
            "←|Back"
        )
        
        # Custom display with ban details
        get_term_size
        printf "%s" "$CLEAR_SCREEN"
        
        move_to 1 1
        printf "%s%s 🚫 Ban Details %s\n" "$BG_RED" "$WHITE$BOLD" "$RESET"
        
        move_to 3 3
        printf "%sPlayer:%s %s\n" "$DIM" "$RESET" "$name"
        move_to 4 3
        printf "%sGUID:%s %s\n" "$DIM" "$RESET" "$guid"
        move_to 5 3
        printf "%sBanned:%s %s\n" "$DIM" "$RESET" "$banned_at"
        move_to 6 3
        printf "%sExpires:%s %s\n" "$DIM" "$RESET" "$expires"
        move_to 7 3
        printf "%sReason:%s %s\n" "$DIM" "$RESET" "$reason"
        
        if ! run_menu items "Actions" 9; then
            return
        fi
        
        local selected="${items[$MENU_RESULT]}"
        
        case "$selected" in
            "🔓|Unban Player")
                if confirm "Unban '${name}'?

They will be able to rejoin immediately." "n"; then
                    unban_player "$inst_dir" "$guid" "$name"
                    return
                fi
                ;;
            "←|Back"|"----"*)
                [[ "$selected" == "←|Back" ]] && return
                ;;
        esac
    done
}

# Unban a player
# Usage: unban_player "$inst_dir" "$guid" "$name"
unban_player() {
    local inst_dir="$1"
    local guid="$2"
    local name="$3"
    
    # Remove from our tracking using Python
    local bans_file="${PLAYERS_STATE_DIR}/bans.json"
    if [[ -f "$bans_file" ]]; then
        python3 -c "
import json
try:
    with open('$bans_file', 'r') as f:
        data = json.load(f)
    data['bans'] = [b for b in data.get('bans', []) if b.get('guid') != '$guid']
    with open('$bans_file', 'w') as f:
        json.dump(data, f, indent=2)
except:
    pass
" 2>/dev/null
    fi
    
    # Remove from BattlEye bans.txt
    local be_bans="${inst_dir}/data/profile/BattlEye/bans.txt"
    if [[ -f "$be_bans" ]]; then
        grep -v "^${guid}" "$be_bans" > "${be_bans}.tmp" 2>/dev/null && \
            mv "${be_bans}.tmp" "$be_bans"
    fi
    
    # Reload bans via RCON
    run_rcon_action "$inst_dir" "loadbans" >/dev/null 2>&1
    
    show_message "Unbanned '$name'" "✓ Success"
}
