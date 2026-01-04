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
    
    # Add --debug flag if DEBUG_RCON is set, log to file
    if [[ -n "${DEBUG_RCON:-}" ]]; then
        local debug_log="${inst_dir}/data/state/rcon_debug.log"
        mkdir -p "$(dirname "$debug_log")" 2>/dev/null
        rcon_args+=(--debug)
        echo "--- $(date) ---" >> "$debug_log"
        echo "Action: $action" >> "$debug_log"
        docker exec "$container_name" python3 /tmp/rcon_client.py "${rcon_args[@]}" 2>> "$debug_log"
    else
        docker exec "$container_name" python3 /tmp/rcon_client.py "${rcon_args[@]}" 2>/dev/null
    fi
}

# =============================================================================
# Players Menu
# =============================================================================

# Main players menu showing online player list in table view
# Usage: players_menu "$inst_dir"
players_menu() {
    local inst_dir="$1"
    
    # Initialize state directory
    PLAYERS_STATE_DIR="${inst_dir}/data/state/players"
    mkdir -p "$PLAYERS_STATE_DIR" 2>/dev/null
    
    local selected=0
    local needs_refresh=1
    
    # Player data arrays
    local -a player_ids=()
    local -a player_names=()
    local -a player_pings=()
    local -a player_guids=()
    local -a player_times=()  # Time on server in minutes
    local -a player_joined=() # Formatted join timestamp
    local player_count=0
    local max_players=0
    local error=""
    
    # Session tracking file
    local sessions_file="${PLAYERS_STATE_DIR}/sessions.json"
    
    while true; do
        # Refresh player data if needed
        if [[ $needs_refresh -eq 1 ]]; then
            max_players=$(get_max_players "$inst_dir")
            
            local player_json
            player_json=$(fetch_online_players "$inst_dir")
            
            player_count=$(json_get "$player_json" "count" "0")
            error=$(json_get "$player_json" "error" "")
            
            # Clear and rebuild arrays
            player_ids=()
            player_names=()
            player_pings=()
            player_guids=()
            player_times=()
            
            if [[ -z "$error" || "$error" == "null" ]] && [[ "$player_count" -gt 0 ]]; then
                # Update session tracking and get times
                local now_ts
                now_ts=$(date +%s)
                
                while IFS= read -r player; do
                    [[ -z "$player" ]] && continue
                    local pid pname pping pguid
                    pid=$(json_get "$player" "id" "0")
                    pname=$(json_get "$player" "name" "Unknown")
                    pping=$(json_get "$player" "ping" "0")
                    pguid=$(json_get "$player" "guid" "")
                    
                    player_ids+=("$pid")
                    player_names+=("$pname")
                    player_pings+=("$pping")
                    player_guids+=("$pguid")
                    
                    # Get or set join time from sessions.json
                    local join_ts
                    join_ts=$(python3 << PYTHON_SESSION
import json
import os

sessions_file = "${sessions_file}"
guid = "${pguid}"
now = ${now_ts}

# Load or create sessions
sessions = {}
if os.path.exists(sessions_file):
    try:
        with open(sessions_file, 'r') as f:
            sessions = json.load(f)
    except: pass

# Get or set join time for this player
if guid and guid in sessions:
    print(sessions[guid])
else:
    # New player - record join time
    if guid:
        sessions[guid] = now
        with open(sessions_file, 'w') as f:
            json.dump(sessions, f, indent=2)
    print(now)
PYTHON_SESSION
                    )
                    
                    # Calculate time on server
                    local time_on_server_mins=0
                    local joined_str=""
                    if [[ -n "$join_ts" && "$join_ts" =~ ^[0-9]+$ ]]; then
                        time_on_server_mins=$(( (now_ts - join_ts) / 60 ))
                        [[ $time_on_server_mins -lt 0 ]] && time_on_server_mins=0
                        # Format join timestamp as DD/MM/YYYY HH:MM
                        joined_str=$(date -d "@${join_ts}" +"%d/%m/%Y %H:%M" 2>/dev/null || date -r "${join_ts}" +"%d/%m/%Y %H:%M" 2>/dev/null || echo "?")
                    fi
                    player_times+=("$time_on_server_mins")
                    player_joined+=("$joined_str")
                done < <(json_array "$player_json" "players")
                
                # Clean up departed players from sessions.json
                if [[ -f "$sessions_file" ]]; then
                    local current_guids
                    current_guids=$(printf '%s\n' "${player_guids[@]}" | tr '\n' '|')
                    python3 << PYTHON_CLEANUP
import json
sessions_file = "${sessions_file}"
current_guids = set("${current_guids}".strip('|').split('|'))
try:
    with open(sessions_file, 'r') as f:
        sessions = json.load(f)
    # Remove GUIDs not in current player list
    sessions = {k: v for k, v in sessions.items() if k in current_guids}
    with open(sessions_file, 'w') as f:
        json.dump(sessions, f, indent=2)
except: pass
PYTHON_CLEANUP
                fi
            fi
            
            player_count=${#player_ids[@]}
            needs_refresh=0
        fi
        
        local total_items=$((player_count + 2))  # Players + Refresh + Back
        [[ $selected -lt 0 ]] && selected=0
        [[ $selected -ge $total_items ]] && selected=$((total_items - 1))
        
        # Get terminal size
        get_term_size
        
        # Draw screen
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        
        # Header bar
        move_to 1 1
        local header_title="Players - Online: ${player_count} / ${max_players}"
        printf "%s%s 👥 %s%s%s" "$BG_RED" "$WHITE$BOLD" "$header_title" "${ESC}[K" "$RESET"
        
        # Table header
        local table_start=3
        local col_status=2
        local col_id=6
        local col_name=12
        local col_joined=$((TERM_COLS - 70))
        local col_time=$((TERM_COLS - 52))
        local col_ping=$((TERM_COLS - 45))
        local col_guid=$((TERM_COLS - 38))
        
        move_to $table_start 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        
        move_to $((table_start + 1)) $col_status
        printf "%s%s  %s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_id
        printf "%s%sID%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_name
        printf "%s%sPLAYER NAME%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_joined
        printf "%s%sJOINED%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_time
        printf "%s%sTIME%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_ping
        printf "%s%sPING%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_guid
        printf "%s%sGUID%s" "$DIM" "$WHITE" "$RESET"
        
        move_to $((table_start + 2)) 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        
        # Player rows
        local row=$((table_start + 3))
        
        if [[ -n "$error" && "$error" != "null" ]]; then
            move_to $row 1
            printf "%s%s  ⚠️  Error: %s%s" "$BG_RED" "$WHITE" "$error" "$RESET"
            row=$((row + 1))
        elif [[ $player_count -eq 0 ]]; then
            move_to $row 1
            printf "%s  ℹ️  No players online (press R to refresh)%s" "$DIM" "$RESET"
            row=$((row + 1))
        else
            for i in "${!player_ids[@]}"; do
                local pid="${player_ids[$i]}"
                local pname="${player_names[$i]}"
                local pping="${player_pings[$i]}"
                local pguid="${player_guids[$i]:-?}"
                
                local ptime="${player_times[$i]:-0}"
                
                # Format time as HH:MM
                local time_str
                if [[ $ptime -ge 60 ]]; then
                    time_str=$(printf "%dh%02dm" $((ptime / 60)) $((ptime % 60)))
                else
                    time_str=$(printf "%dm" $ptime)
                fi
                
                local pjoined="${player_joined[$i]:-?}"
                
                # Truncate name if too long
                local max_name_len=$((col_joined - col_name - 2))
                [[ ${#pname} -gt $max_name_len ]] && pname="${pname:0:$((max_name_len-3))}..."
                
                move_to $row 1
                if [[ $i -eq $selected ]]; then
                    # Selected row
                    printf "%s%s%s" "$BG_RED" "$WHITE$BOLD" "${ESC}[K"
                    move_to $row $col_status
                    printf "▶ 👤"
                    move_to $row $col_id
                    printf "#%-4s" "$pid"
                    move_to $row $col_name
                    printf "%s" "$pname"
                    move_to $row $col_joined
                    printf "%s" "$pjoined"
                    move_to $row $col_time
                    printf "%s" "$time_str"
                    move_to $row $col_ping
                    printf "%sms" "$pping"
                    move_to $row $col_guid
                    printf "%s" "$pguid"
                    printf "%s" "$RESET"
                else
                    # Normal row
                    printf "%s" "${ESC}[K"
                    move_to $row $col_status
                    printf "  %s👤%s" "$GREEN" "$RESET"
                    move_to $row $col_id
                    printf "%s#%-4s%s" "$DIM" "$pid" "$RESET"
                    move_to $row $col_name
                    printf "%s" "$pname"
                    move_to $row $col_joined
                    printf "%s%s%s" "$DIM" "$pjoined" "$RESET"
                    move_to $row $col_time
                    printf "%s%s%s" "$DIM" "$time_str" "$RESET"
                    move_to $row $col_ping
                    printf "%s%sms%s" "$DIM" "$pping" "$RESET"
                    move_to $row $col_guid
                    printf "%s%s%s" "$DIM" "$pguid" "$RESET"
                fi
                row=$((row + 1))
            done
        fi
        
        # Separator
        move_to $row 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        ((row++))
        
        # Action bar
        local action_row=$row
        local actions=("[R] Refresh" "[Q] Back")
        
        move_to $action_row 2
        for a in "${!actions[@]}"; do
            local action_idx=$((player_count + a))
            local action_label="${actions[$a]}"
            
            if [[ $selected -eq $action_idx ]]; then
                printf "%s%s▶ %s %s" "$BG_RED" "$WHITE$BOLD" "$action_label" "$RESET"
            else
                printf "  %s " "$action_label"
            fi
            printf " "
        done
        
        # Footer help
        move_to $TERM_ROWS 1
        printf "%s%s [↑↓] Select  [Enter] Player Actions  [R] Refresh  [K] Kick  [B] Ban  [M] Message  [Q] Back%s%s" "$BG_DARKGRAY" "$WHITE" "${ESC}[K" "$RESET"
        
        # Read input
        IFS= read -rsn1 key
        
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') if ((selected > 0)); then selected=$((selected-1)); fi ;;
                    '[B') if ((selected < total_items - 1)); then selected=$((selected+1)); fi ;;
                esac
                ;;
            '') # Enter
                if [[ $selected -lt $player_count ]]; then
                    # Open player details
                    local full_player_data="{\"id\": ${player_ids[$selected]}, \"name\": \"${player_names[$selected]}\", \"ping\": ${player_pings[$selected]}, \"guid\": \"${player_guids[$selected]}\"}"
                    player_details_menu "$inst_dir" "$full_player_data"
                    needs_refresh=1
                elif [[ $selected -eq $player_count ]]; then
                    # Refresh
                    needs_refresh=1
                elif [[ $selected -eq $((player_count + 1)) ]]; then
                    # Back
                    return 0
                fi
                ;;
            'r'|'R')
                needs_refresh=1
                ;;
            'k'|'K')
                if [[ $selected -lt $player_count ]]; then
                    kick_player_dialog "$inst_dir" "${player_ids[$selected]}" "${player_names[$selected]}" "${player_guids[$selected]}"
                    needs_refresh=1
                fi
                ;;
            'b'|'B')
                if [[ $selected -lt $player_count ]]; then
                    ban_player_dialog "$inst_dir" "${player_ids[$selected]}" "${player_names[$selected]}" "${player_guids[$selected]}"
                    needs_refresh=1
                fi
                ;;
            'm'|'M')
                if [[ $selected -lt $player_count ]]; then
                    send_message_dialog "$inst_dir" "${player_names[$selected]}"
                fi
                ;;
            'q'|'Q')
                return 0
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

# Kick player dialog
# Usage: kick_player_dialog "$inst_dir" "$player_id" "$player_name" "$player_guid"
kick_player_dialog() {
    local inst_dir="$1"
    local player_id="$2"
    local player_name="$3"
    local player_guid="${4:-}"
    
    # Confirm
    if ! confirm "Kick '${player_name}' from server?

They can rejoin at any time." "n"; then
        return
    fi
    
    # Execute kick - uses player NAME (not ID)
    # Note: BattlEye #kick doesn't support reason field
    local result
    result=$(run_rcon_action "$inst_dir" "kick" --player-name "$player_name")
    
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
    
    # Get container name for direct file write
    local marker="${inst_dir}/.dayz-instance"
    local container_name
    container_name="$(grep -oP 'CONTAINER_NAME=\K.*' "$marker" 2>/dev/null || echo "")"
    
    if [[ -z "$container_name" ]]; then
        show_message "No container found" "✗ Error"
        return
    fi
    
    # Step 1: Kick the player via RCON (this works!)
    run_rcon_action "$inst_dir" "kick" --player-name "$player_name" >/dev/null 2>&1
    
    # Step 2: Write GUID directly to bans.txt (RCON addBan fails silently)
    # Format: GUID -1 (permanent ban, -1 = no expiry timestamp)
    local bans_file="/dayz/serverfiles/battleye/bans.txt"
    docker exec "$container_name" bash -c "echo '${player_guid} -1' >> ${bans_file}" 2>/dev/null
    
    # Step 3: Reload bans via RCON
    run_rcon_action "$inst_dir" "loadbans" >/dev/null 2>&1
    
    # Save ban record to our tracking file (includes duration, reason, timestamps)
    save_ban_record "$inst_dir" "$player_guid" "$player_name" "$duration_minutes" "$reason"
    show_message "Banned '$player_name' for $human_duration" "✓ Success"
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

# Show ban list in table view and allow unbanning
# Usage: ban_list_menu "$inst_dir"
ban_list_menu() {
    local inst_dir="$1"
    
    PLAYERS_STATE_DIR="${inst_dir}/data/state/players"
    local bans_file="${PLAYERS_STATE_DIR}/bans.json"
    
    local selected=0
    local needs_refresh=1
    
    # Ban data arrays
    local -a ban_names=()
    local -a ban_reasons=()
    local -a ban_durations=()
    local -a ban_banned_at=()
    local -a ban_expires=()
    local -a ban_guids=()
    local ban_count=0
    
    while true; do
        # Refresh ban data if needed
        if [[ $needs_refresh -eq 1 ]]; then
            ban_names=()
            ban_reasons=()
            ban_durations=()
            ban_banned_at=()
            ban_expires=()
            ban_guids=()
            
            if [[ -f "$bans_file" ]]; then
                local bans_data
                bans_data=$(cat "$bans_file" 2>/dev/null || echo '{"bans": []}')
                
                while IFS= read -r ban; do
                    [[ -z "$ban" ]] && continue
                    ban_names+=("$(json_get "$ban" "name" "Unknown")")
                    ban_reasons+=("$(json_get "$ban" "reason" "-")")
                    ban_durations+=("$(json_get "$ban" "duration_minutes" "0")")
                    ban_banned_at+=("$(json_get "$ban" "banned_at" "-")")
                    ban_expires+=("$(json_get "$ban" "expires" "never")")
                    ban_guids+=("$(json_get "$ban" "guid" "-")")
                done < <(json_array "$bans_data" "bans")
            fi
            
            ban_count=${#ban_names[@]}
            needs_refresh=0
        fi
        
        local total_items=$((ban_count + 2))  # Bans + Refresh + Back
        [[ $selected -lt 0 ]] && selected=0
        [[ $selected -ge $total_items ]] && selected=$((total_items - 1))
        
        # Get terminal size
        get_term_size
        
        # Draw screen
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        
        # Header bar
        move_to 1 1
        local header_title="Ban List - ${ban_count} bans"
        printf "%s%s 🚫 %s%s%s" "$BG_RED" "$WHITE$BOLD" "$header_title" "${ESC}[K" "$RESET"
        
        # Table header - calculate column positions
        local table_start=3
        local col_status=2
        local col_name=6
        local col_reason=$((col_name + 22))
        local col_duration=$((col_reason + 22))
        local col_banned=$((col_duration + 10))
        local col_expires=$((col_banned + 18))
        local col_guid=$((col_expires + 18))
        
        move_to $table_start 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        
        move_to $((table_start + 1)) $col_status
        printf "%s%s  %s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_name
        printf "%s%sPLAYER NAME%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_reason
        printf "%s%sREASON%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_duration
        printf "%s%sDURATION%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_banned
        printf "%s%sBANNED AT%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_expires
        printf "%s%sEXPIRES%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_guid
        printf "%s%sGUID%s" "$DIM" "$WHITE" "$RESET"
        
        move_to $((table_start + 2)) 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        
        # Ban rows
        local row=$((table_start + 3))
        
        if [[ $ban_count -eq 0 ]]; then
            move_to $row 1
            printf "%s  ℹ️  No bans recorded (press R to refresh)%s" "$DIM" "$RESET"
            row=$((row + 1))
        else
            for i in "${!ban_names[@]}"; do
                local bname="${ban_names[$i]}"
                local breason="${ban_reasons[$i]}"
                local bduration="${ban_durations[$i]}"
                local bbanned="${ban_banned_at[$i]}"
                local bexpires="${ban_expires[$i]}"
                local bguid="${ban_guids[$i]}"
                
                # Format duration
                local duration_str
                if [[ "$bduration" == "0" || -z "$bduration" ]]; then
                    duration_str="Permanent"
                else
                    duration_str="${bduration}m"
                fi
                
                # Format timestamps (convert ISO to DD/MM HH:MM)
                local banned_str expires_str
                if [[ "$bbanned" != "-" && "$bbanned" != "null" ]]; then
                    banned_str=$(echo "$bbanned" | sed 's/T/ /' | sed 's/Z//' | cut -c1-16 || echo "$bbanned")
                else
                    banned_str="-"
                fi
                if [[ "$bexpires" == "never" ]]; then
                    expires_str="Never"
                elif [[ "$bexpires" != "-" && "$bexpires" != "null" ]]; then
                    expires_str=$(echo "$bexpires" | sed 's/T/ /' | sed 's/Z//' | cut -c1-16 || echo "$bexpires")
                else
                    expires_str="-"
                fi
                
                # Truncate fields
                [[ ${#bname} -gt 20 ]] && bname="${bname:0:17}..."
                [[ ${#breason} -gt 20 ]] && breason="${breason:0:17}..."
                [[ ${#bguid} -gt 16 ]] && bguid="${bguid:0:13}..."
                
                move_to $row 1
                if [[ $i -eq $selected ]]; then
                    # Selected row
                    printf "%s%s%s" "$BG_RED" "$WHITE$BOLD" "${ESC}[K"
                    move_to $row $col_status
                    printf "▶ 🚫"
                    move_to $row $col_name
                    printf "%s" "$bname"
                    move_to $row $col_reason
                    printf "%s" "$breason"
                    move_to $row $col_duration
                    printf "%s" "$duration_str"
                    move_to $row $col_banned
                    printf "%s" "$banned_str"
                    move_to $row $col_expires
                    printf "%s" "$expires_str"
                    move_to $row $col_guid
                    printf "%s" "$bguid"
                    printf "%s" "$RESET"
                else
                    # Normal row
                    printf "%s" "${ESC}[K"
                    move_to $row $col_status
                    printf "  %s🚫%s" "$RED" "$RESET"
                    move_to $row $col_name
                    printf "%s" "$bname"
                    move_to $row $col_reason
                    printf "%s%s%s" "$DIM" "$breason" "$RESET"
                    move_to $row $col_duration
                    printf "%s%s%s" "$DIM" "$duration_str" "$RESET"
                    move_to $row $col_banned
                    printf "%s%s%s" "$DIM" "$banned_str" "$RESET"
                    move_to $row $col_expires
                    printf "%s%s%s" "$DIM" "$expires_str" "$RESET"
                    move_to $row $col_guid
                    printf "%s%s%s" "$DIM" "$bguid" "$RESET"
                fi
                row=$((row + 1))
            done
        fi
        
        # Separator
        move_to $row 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        ((row++))
        
        # Action bar
        local action_row=$row
        local actions=("[R] Refresh" "[Q] Back")
        
        move_to $action_row 2
        for a in "${!actions[@]}"; do
            local action_idx=$((ban_count + a))
            local action_label="${actions[$a]}"
            
            if [[ $selected -eq $action_idx ]]; then
                printf "%s%s▶ %s %s" "$BG_RED" "$WHITE$BOLD" "$action_label" "$RESET"
            else
                printf "  %s " "$action_label"
            fi
            printf " "
        done
        
        # Footer help
        move_to $TERM_ROWS 1
        printf "%s%s [↑↓] Select  [Enter] Ban Details  [U] Unban  [R] Refresh  [Q] Back%s%s" "$BG_DARKGRAY" "$WHITE" "${ESC}[K" "$RESET"
        
        # Read input
        IFS= read -rsn1 key
        
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') if ((selected > 0)); then selected=$((selected-1)); fi ;;
                    '[B') if ((selected < total_items - 1)); then selected=$((selected+1)); fi ;;
                esac
                ;;
            '') # Enter
                if [[ $selected -lt $ban_count ]]; then
                    # Build ban record JSON for details menu
                    local ban_record="{\"name\": \"${ban_names[$selected]}\", \"reason\": \"${ban_reasons[$selected]}\", \"duration_minutes\": ${ban_durations[$selected]}, \"banned_at\": \"${ban_banned_at[$selected]}\", \"expires\": \"${ban_expires[$selected]}\", \"guid\": \"${ban_guids[$selected]}\"}"
                    ban_details_menu "$inst_dir" "$ban_record"
                    needs_refresh=1
                elif [[ $selected -eq $ban_count ]]; then
                    # Refresh
                    needs_refresh=1
                elif [[ $selected -eq $((ban_count + 1)) ]]; then
                    # Back
                    return 0
                fi
                ;;
            'r'|'R')
                needs_refresh=1
                ;;
            'u'|'U')
                if [[ $selected -lt $ban_count ]]; then
                    local unban_guid="${ban_guids[$selected]}"
                    local unban_name="${ban_names[$selected]}"
                    if confirm "Unban '${unban_name}'?" "n"; then
                        unban_player "$inst_dir" "$unban_guid"
                        show_message "Unbanned: $unban_name" "Success"
                        needs_refresh=1
                    fi
                fi
                ;;
            'q'|'Q')
                return 0
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
    
    # Get container name
    local marker="${inst_dir}/.dayz-instance"
    local container_name
    container_name="$(grep -oP 'CONTAINER_NAME=\K.*' "$marker" 2>/dev/null || echo "")"
    
    if [[ -z "$container_name" ]]; then
        show_message "No container found" "✗ Error"
        return
    fi
    
    # Remove from our tracking (bans.json)
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
    
    # Remove from BattlEye bans.txt INSIDE the container
    local bans_txt="/dayz/serverfiles/battleye/bans.txt"
    docker exec "$container_name" bash -c "sed -i '/^${guid}/d' ${bans_txt}" 2>/dev/null || true
    
    # Reload bans via RCON
    run_rcon_action "$inst_dir" "loadbans" >/dev/null 2>&1
    
    show_message "Unbanned '$name'" "✓ Success"
}
