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
source "${PLAYERS_LIB_DIR}/constants.sh"
source "${PLAYERS_LIB_DIR}/json_helpers.sh"
source "${PLAYERS_LIB_DIR}/rcon_lib.sh"

# Build one player object as JSON. Unlike json_create this keeps the name a
# string even when a player is called "123", "true" or "null".
# Usage: json=$(player_to_json "$id" "$name" "$ping" "$guid")
player_to_json() {
    python3 - "$@" <<'PY_PLAYER_JSON'
import json, sys
pid, name, ping, guid = sys.argv[1:5]
def num(v):
    try: return int(v)
    except ValueError: return 0
print(json.dumps({"id": num(pid), "name": name, "ping": num(ping), "guid": guid}))
PY_PLAYER_JSON
}

# Build one ban record as JSON for the details menu.
# Usage: json=$(ban_to_json "$name" "$reason" "$duration_minutes" "$banned_at" "$expires" "$guid")
ban_to_json() {
    python3 - "$@" <<'PY_BAN_JSON'
import json, sys
name, reason, minutes, banned_at, expires, guid = sys.argv[1:7]
try: minutes = int(minutes)
except ValueError: minutes = -1
print(json.dumps({"name": name, "reason": reason, "duration_minutes": minutes,
                  "banned_at": banned_at, "expires": expires, "guid": guid}))
PY_BAN_JSON
}

# =============================================================================
# JSON Parsing Helpers - Now provided by lib/json_helpers.sh
# =============================================================================
# The following functions are now available from json_helpers.sh:
# - json_get "$json" ".field" "default"
# - json_array "$json" ".players"
# - json_count "$json" ".players"
# - json_create "key1" "val1" "key2" "val2"
# =============================================================================

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
    
    # rcon_action comes from lib/rcon_lib.sh (single RCON implementation)
    rcon_output=$(rcon_action "$inst_dir" "players")
    
    if [[ -z "$rcon_output" ]]; then
        echo '{"count": 0, "players": [], "error": "RCON failed"}'
    else
        echo "$rcon_output"
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
            player_joined=()
            
            if [[ -z "$error" || "$error" == "null" ]] && [[ "$player_count" -gt 0 ]]; then
                # One python process for the whole list: session bookkeeping,
                # cleanup of departed players and one row per player.
                # (Previously 5 processes per player, several seconds per refresh.)
                # Fields are 0x1F separated: a tab would swallow empty fields
                # such as the GUID of a lobby player (see lib/rowfmt.py).
                local pid pname pping pguid ptime pjoined
                while IFS=$'\x1f' read -r pid pname pping pguid ptime pjoined; do
                    [[ -z "$pid" ]] && continue
                    player_ids+=("$pid")
                    player_names+=("$pname")
                    player_pings+=("$pping")
                    player_guids+=("$pguid")
                    player_times+=("$ptime")
                    player_joined+=("$pjoined")
                done < <(printf '%s' "$player_json" | python3 "${PLAYERS_LIB_DIR}/player_manager.py" session \
                            --file "$sessions_file" --action sync --now "$(date +%s)" 2>/dev/null)
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
        row=$((row + 1))
        
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
                    local full_player_data
                    full_player_data=$(player_to_json "${player_ids[$selected]}" "${player_names[$selected]}" "${player_pings[$selected]}" "${player_guids[$selected]}")
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
    result=$(rcon_action "$inst_dir" "say" --message "$formatted")
    
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
    result=$(rcon_action "$inst_dir" "kick" --player-name "$player_name")
    
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
    
    # Parse duration: "30m", "2h", "7d" or perm. Anything else is rejected
    # instead of silently becoming a permanent ban.
    local human_duration="permanent"
    local duration_minutes=-1
    if [[ "${duration,,}" != "perm" && "${duration,,}" != "permanent" ]]; then
        if [[ ! "$duration" =~ ^([0-9]+)([mhdMHD])$ ]] || [[ "${BASH_REMATCH[1]}" -eq 0 ]]; then
            show_message "Invalid duration '${duration}'. Use 30m, 2h, 7d or perm." "✗ Error"
            return 1
        fi
        local num="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2],,}" in
            m) duration_minutes=$num;               human_duration="$num minutes" ;;
            h) duration_minutes=$((num * 60));      human_duration="$num hours" ;;
            d) duration_minutes=$((num * 60 * 24)); human_duration="$num days" ;;
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
    
    if [[ -z "$player_guid" ]]; then
        show_message "'$player_name' has no verified GUID yet (still in lobby).
Wait until the player is in game, then ban." "✗ Error"
        return 1
    fi

    # Step 1: Kick the player via RCON
    local kick_json
    kick_json=$(rcon_action "$inst_dir" "kick" --player-name "$player_name" 2>/dev/null)

    # Step 2: Write GUID directly to bans.txt (RCON addBan fails silently)
    # Format: GUID -1 (permanent ban, -1 = no expiry timestamp)
    # SECURITY: Use safe_container_append_line to prevent command injection
    if ! safe_container_append_line "$container_name" "$DAYZ_CONTAINER_BANS_TXT" "${player_guid} ${BAN_PERMANENT_MARKER}"; then
        show_message "Could not write bans.txt inside the container. Is it running?" "✗ Error"
        return 1
    fi

    # Step 3: Reload bans via RCON
    local reload_json
    reload_json=$(rcon_action "$inst_dir" "loadbans" 2>/dev/null)

    # Save ban record to our tracking file (includes duration, reason, timestamps).
    # Without it a timed ban never expires, so a failure here is not a success.
    local save_error
    if ! save_error=$(save_ban_record "$inst_dir" "$player_guid" "$player_name" "$duration_minutes" "$reason"); then
        show_message "GUID written to bans.txt, but the ban record could not be saved:
${save_error}

Without the record this ban will NOT expire automatically." "⚠ Warning"
        return 1
    fi

    # Report what actually happened: the file write is done, RCON steps may have failed
    local warnings=""
    [[ "$(json_get "$kick_json" "success" "false")" == "true" ]] || warnings+="
- kick failed, the player may still be connected"
    [[ "$(json_get "$reload_json" "success" "false")" == "true" ]] || warnings+="
- loadBans failed, the ban applies after the next server restart"
    if [[ -n "$warnings" ]]; then
        show_message "Banned '$player_name' for $human_duration, with warnings:${warnings}" "⚠ Partial"
    else
        show_message "Banned '$player_name' for $human_duration" "✓ Success"
    fi
}

# =============================================================================
# Ban Tracking
# =============================================================================

# Save ban record to JSON file for tracking
# Usage: save_ban_record "$inst_dir" "$guid" "$name" "$duration_minutes" "$reason"
# Uses ban_manager.py for safe JSON handling
save_ban_record() {
    local inst_dir="$1"
    local guid="$2"
    local name="$3"
    local duration_minutes="$4"
    local reason="$5"

    local bans_file="${PLAYERS_STATE_DIR:-${inst_dir}/data/state/players}/bans.json"

    # Format duration for ban_manager.py
    local duration_arg="perm"
    if [[ "$duration_minutes" -gt 0 ]]; then
        duration_arg="${duration_minutes}m"
    fi

    # ban_manager.py exits non-zero with a JSON error when the record cannot
    # be written; print that error so the caller can warn the admin.
    local output
    if ! output=$(python3 "${PLAYERS_LIB_DIR}/ban_manager.py" --file "$bans_file" add \
        --guid "$guid" \
        --name "$name" \
        --reason "$reason" \
        --duration "$duration_arg" 2>&1); then
        json_get "$output" "error" "$output"
        return 1
    fi
    return 0
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
                # One process for the whole list instead of six per ban.
                # 0x1F separated so empty fields (GUID, reason) keep their place.
                local bguid bname breason bminutes bat bexp
                while IFS=$'\x1f' read -r bguid bname breason bminutes bat bexp; do
                    [[ -z "$bguid$bname" ]] && continue
                    ban_guids+=("$bguid")
                    ban_names+=("${bname:-Unknown}")
                    ban_reasons+=("${breason:--}")
                    ban_durations+=("${bminutes:-0}")
                    ban_banned_at+=("${bat:--}")
                    ban_expires+=("${bexp:-never}")
                done < <(python3 "${PLAYERS_LIB_DIR}/ban_manager.py" --file "$bans_file" list --rows 2>/dev/null)
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
        local col_guid=$((TERM_COLS - 38))
        
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
                
                # Truncate fields (but not GUID)
                [[ ${#bname} -gt 20 ]] && bname="${bname:0:17}..."
                [[ ${#breason} -gt 20 ]] && breason="${breason:0:17}..."
                
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
        row=$((row + 1))
        
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
                    local ban_record
                    ban_record=$(ban_to_json "${ban_names[$selected]}" "${ban_reasons[$selected]}" "${ban_durations[$selected]}" "${ban_banned_at[$selected]}" "${ban_expires[$selected]}" "${ban_guids[$selected]}")
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
                        unban_player "$inst_dir" "$unban_guid" "$unban_name" && needs_refresh=1
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
    local name="${3:-$2}"

    # An empty GUID would match every line of bans.txt
    if [[ -z "$guid" ]]; then
        show_message "This ban record has no GUID, so nothing can be removed from bans.txt.
Remove the entry from bans.json by hand." "✗ Error"
        return 1
    fi

    # Get container name
    local marker="${inst_dir}/.dayz-instance"
    local container_name
    container_name="$(grep -oP 'CONTAINER_NAME=\K.*' "$marker" 2>/dev/null || echo "")"

    if [[ -z "$container_name" ]]; then
        show_message "No container found" "✗ Error"
        return
    fi

    # Remove from our tracking (bans.json) using ban_manager.py
    local bans_file="${PLAYERS_STATE_DIR:-${inst_dir}/data/state/players}/bans.json"
    if [[ -f "$bans_file" ]]; then
        python3 "${PLAYERS_LIB_DIR}/ban_manager.py" --file "$bans_file" remove \
            --guid "$guid" >/dev/null 2>&1 || true
    fi

    # Remove from BattlEye bans.txt INSIDE the container (exact GUID match)
    # SECURITY: Use safe_container_remove_line to prevent command injection
    if ! safe_container_remove_line "$container_name" "$DAYZ_CONTAINER_BANS_TXT" "$guid"; then
        show_message "Could not update bans.txt inside the container. Is it running?" "✗ Error"
        return 1
    fi

    # Reload bans via RCON
    local reload_json
    reload_json=$(rcon_action "$inst_dir" "loadbans" 2>/dev/null)
    if [[ "$(json_get "$reload_json" "success" "false")" == "true" ]]; then
        show_message "Unbanned '$name'" "✓ Success"
    else
        show_message "Unbanned '$name' in bans.txt, but loadBans failed.
The change applies after the next server restart." "⚠ Partial"
    fi
    return 0
}
