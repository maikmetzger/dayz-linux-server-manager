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
# The _players_* and _bans_* helpers run inside players_menu / ban_list_menu
# and use their locals (bash dynamic scoping): the data arrays, player_count /
# ban_count, selected, needs_refresh, inst_dir and the col_* layout set by
# the draw function.

# Action bar of both table screens; the buttons follow the data rows in cursor order
TABLE_SCREEN_ACTIONS=("[R] Refresh" "[Q] Back")

# Action bar at ROW; ITEM_COUNT data rows precede the buttons
_table_actions() {
    local row="$1" item_count="$2"
    move_to "$row" 2
    local a label
    for a in "${!TABLE_SCREEN_ACTIONS[@]}"; do
        label="${TABLE_SCREEN_ACTIONS[$a]}"
        if [[ $selected -eq $((item_count + a)) ]]; then
            printf "%s%s▶ %s %s" "$BG_RED" "$WHITE$BOLD" "$label" "$RESET"
        else
            printf "  %s " "$label"
        fi
        printf " "
    done
}

# Fetch the online players via RCON and rebuild the player_* arrays
_players_refresh() {
    max_players=$(get_max_players "$inst_dir")
    local player_json
    player_json=$(fetch_online_players "$inst_dir")
    error=$(json_get "$player_json" "error" "")
    player_ids=(); player_names=(); player_pings=(); player_guids=(); player_times=(); player_joined=()
    if [[ -z "$error" || "$error" == "null" ]] && [[ "$(json_get "$player_json" "count" "0")" -gt 0 ]]; then
        # One python process for the whole list: session bookkeeping, cleanup
        # of departed players and one row per player (previously 5 processes
        # per player). Fields are 0x1F separated: a tab would swallow empty
        # fields such as the GUID of a lobby player (see lib/rowfmt.py).
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
}

# Minutes on the server as "3h05m" or "12m"
_players_time_str() {
    local minutes="${1:-0}"
    if [[ $minutes -ge 60 ]]; then
        printf "%dh%02dm" $((minutes / 60)) $((minutes % 60))
    else
        printf "%dm" "$minutes"
    fi
}

# One player row for index I at screen ROW; the selected row is inverted
_players_draw_row() {
    local i="$1" row="$2"
    local pname="${player_names[$i]}"
    local max_name_len=$((col_joined - col_name - 2))
    [[ ${#pname} -gt $max_name_len ]] && pname="${pname:0:$((max_name_len-3))}..."
    local id_cell time_str
    printf -v id_cell '#%-4s' "${player_ids[$i]}"
    time_str=$(_players_time_str "${player_times[$i]:-0}")

    local dim="$DIM"
    move_to "$row" 1
    if [[ $i -eq $selected ]]; then
        printf "%s%s%s" "$BG_RED" "$WHITE$BOLD" "${ESC}[K"
        move_to "$row" $col_status
        printf "▶ 👤"
        dim=""
    else
        printf "%s" "${ESC}[K"
        move_to "$row" $col_status
        printf "  %s👤%s" "$GREEN" "$RESET"
    fi
    tui_draw_cells "$row" "$col_id:$dim:$id_cell" "$col_name::$pname" "$col_joined:$dim:${player_joined[$i]:-?}" \
        "$col_time:$dim:$time_str" "$col_ping:$dim:${player_pings[$i]}ms" "$col_guid:$dim:${player_guids[$i]:-?}"
    [[ $i -eq $selected ]] && printf "%s" "$RESET"
    return 0
}

# Title, column titles, rows (or the error/empty line), action bar, footer
_players_draw() {
    tui_draw_header "👥 Players - Online: ${player_count} / ${max_players}"
    local table_start=3 col_status=2 col_id=6 col_name=12
    local col_joined=$((TERM_COLS - 70)) col_time=$((TERM_COLS - 52))
    local col_ping=$((TERM_COLS - 45)) col_guid=$((TERM_COLS - 38))
    tui_draw_rule $table_start
    tui_draw_titles $((table_start + 1)) "$col_status:  " "$col_id:ID" "$col_name:PLAYER NAME" \
        "$col_joined:JOINED" "$col_time:TIME" "$col_ping:PING" "$col_guid:GUID"
    tui_draw_rule $((table_start + 2))

    local row=$((table_start + 3)) i
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
            _players_draw_row "$i" "$row"
            row=$((row + 1))
        done
    fi
    tui_draw_rule $row
    _table_actions $((row + 1)) "$player_count"
    tui_draw_footer " [↑↓] Select  [Enter] Player Actions  [R] Refresh  [K] Kick  [B] Ban  [M] Message  [Q] Back"
}

# [Enter]/[K]/[B]/[M] on the selected player; nothing while the cursor is on a button
_players_key_action() {
    local action="$1"
    [[ $selected -lt $player_count ]] || return 0
    local pid="${player_ids[$selected]}" pname="${player_names[$selected]}"
    local pping="${player_pings[$selected]}" pguid="${player_guids[$selected]}"
    case "$action" in
        details)
            player_details_menu "$inst_dir" "$(player_to_json "$pid" "$pname" "$pping" "$pguid")" || true
            needs_refresh=1 ;;
        kick)    kick_player_dialog "$inst_dir" "$pid" "$pname" "$pguid" || true; needs_refresh=1 ;;
        ban)     ban_player_dialog "$inst_dir" "$pid" "$pname" "$pguid" || true; needs_refresh=1 ;;
        message) send_message_dialog "$inst_dir" "$pname" || true ;;
    esac
}

# Online players in a table with kick, ban, message and details actions
# Usage: players_menu "$inst_dir"
players_menu() {
    local inst_dir="$1"
    PLAYERS_STATE_DIR="${inst_dir}/data/state/players"
    mkdir -p "$PLAYERS_STATE_DIR" 2>/dev/null
    local sessions_file="${PLAYERS_STATE_DIR}/sessions.json"

    local selected=0 needs_refresh=1
    local -a player_ids=() player_names=() player_pings=() player_guids=() player_times=() player_joined=()
    local player_count=0 max_players=0 error=""
    local total_items key seq
    while true; do
        if [[ $needs_refresh -eq 1 ]]; then
            _players_refresh
            needs_refresh=0
        fi
        total_items=$((player_count + ${#TABLE_SCREEN_ACTIONS[@]}))
        [[ $selected -lt 0 ]] && selected=0
        [[ $selected -ge $total_items ]] && selected=$((total_items - 1))
        get_term_size
        _players_draw

        IFS= read -rsn1 key || return 0   # EOF: leave instead of looping
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') if [[ $selected -gt 0 ]]; then selected=$((selected - 1)); fi ;;
                    '[B') if [[ $selected -lt $((total_items - 1)) ]]; then selected=$((selected + 1)); fi ;;
                esac
                ;;
            '')  # Enter: player details, or the button under the cursor
                if [[ $selected -lt $player_count ]]; then
                    _players_key_action details
                elif [[ $selected -eq $player_count ]]; then
                    needs_refresh=1
                else
                    return 0
                fi
                ;;
            r|R) needs_refresh=1 ;;
            k|K) _players_key_action kick ;;
            b|B) _players_key_action ban ;;
            m|M) _players_key_action message ;;
            q|Q) return 0 ;;
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

# Rebuild the ban_* arrays from bans.json (one ban_manager.py call)
_bans_refresh() {
    ban_names=(); ban_reasons=(); ban_durations=(); ban_banned_at=(); ban_expires=(); ban_guids=()
    if [[ -f "$bans_file" ]]; then
        # 0x1F separated so empty fields (GUID, reason) keep their place
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
}

# ISO timestamp as "YYYY-MM-DD HH:MM" (was a sed|sed|cut pipeline per cell)
_bans_date_str() {
    local ts="$1"
    case "$ts" in
        never)     echo "Never" ;;
        -|null|"") echo "-" ;;
        *)         ts="${ts/T/ }"; ts="${ts/Z/}"; echo "${ts:0:16}" ;;
    esac
}

# "Permanent" or "<minutes>m"
_bans_duration_str() {
    if [[ "${1:-0}" == "0" || -z "${1:-}" ]]; then
        echo "Permanent"
    else
        echo "${1}m"
    fi
}

# One ban row for index I at screen ROW; the selected row is inverted
_bans_draw_row() {
    local i="$1" row="$2"
    local bname="${ban_names[$i]}" breason="${ban_reasons[$i]}"
    [[ ${#bname} -gt 20 ]] && bname="${bname:0:17}..."
    [[ ${#breason} -gt 20 ]] && breason="${breason:0:17}..."
    local duration_str banned_str expires_str
    duration_str=$(_bans_duration_str "${ban_durations[$i]}")
    banned_str=$(_bans_date_str "${ban_banned_at[$i]}")
    expires_str=$(_bans_date_str "${ban_expires[$i]}")

    local dim="$DIM"
    move_to "$row" 1
    if [[ $i -eq $selected ]]; then
        printf "%s%s%s" "$BG_RED" "$WHITE$BOLD" "${ESC}[K"
        move_to "$row" $col_status
        printf "▶ 🚫"
        dim=""
    else
        printf "%s" "${ESC}[K"
        move_to "$row" $col_status
        printf "  %s🚫%s" "$RED" "$RESET"
    fi
    tui_draw_cells "$row" "$col_name::$bname" "$col_reason:$dim:$breason" "$col_duration:$dim:$duration_str" \
        "$col_banned:$dim:$banned_str" "$col_expires:$dim:$expires_str" "$col_guid:$dim:${ban_guids[$i]}"
    [[ $i -eq $selected ]] && printf "%s" "$RESET"
    return 0
}

# Title, column titles, rows (or the empty line), action bar, footer
_bans_draw() {
    tui_draw_header "🚫 Ban List - ${ban_count} bans"
    local table_start=3 col_status=2 col_name=6
    local col_reason=$((col_name + 22))
    local col_duration=$((col_reason + 22))
    local col_banned=$((col_duration + 10))
    local col_expires=$((col_banned + 18))
    local col_guid=$((TERM_COLS - 38))
    tui_draw_rule $table_start
    tui_draw_titles $((table_start + 1)) "$col_status:  " "$col_name:PLAYER NAME" "$col_reason:REASON" \
        "$col_duration:DURATION" "$col_banned:BANNED AT" "$col_expires:EXPIRES" "$col_guid:GUID"
    tui_draw_rule $((table_start + 2))

    local row=$((table_start + 3)) i
    if [[ $ban_count -eq 0 ]]; then
        move_to $row 1
        printf "%s  ℹ️  No bans recorded (press R to refresh)%s" "$DIM" "$RESET"
        row=$((row + 1))
    else
        for i in "${!ban_names[@]}"; do
            _bans_draw_row "$i" "$row"
            row=$((row + 1))
        done
    fi
    tui_draw_rule $row
    _table_actions $((row + 1)) "$ban_count"
    tui_draw_footer " [↑↓] Select  [Enter] Ban Details  [U] Unban  [R] Refresh  [Q] Back"
}

# [Enter] details of the selected ban
_bans_key_details() {
    [[ $selected -lt $ban_count ]] || return 0
    local record
    record=$(ban_to_json "${ban_names[$selected]}" "${ban_reasons[$selected]}" "${ban_durations[$selected]}" \
        "${ban_banned_at[$selected]}" "${ban_expires[$selected]}" "${ban_guids[$selected]}")
    ban_details_menu "$inst_dir" "$record" || true
    needs_refresh=1
}

# [U] unban the selected record after confirmation
_bans_key_unban() {
    [[ $selected -lt $ban_count ]] || return 0
    confirm "Unban '${ban_names[$selected]}'?" "n" || return 0
    if unban_player "$inst_dir" "${ban_guids[$selected]}" "${ban_names[$selected]}"; then
        needs_refresh=1
    fi
}

# Ban list in a table with details and unban
# Usage: ban_list_menu "$inst_dir"
ban_list_menu() {
    local inst_dir="$1"
    PLAYERS_STATE_DIR="${inst_dir}/data/state/players"
    local bans_file="${PLAYERS_STATE_DIR}/bans.json"

    local selected=0 needs_refresh=1
    local -a ban_names=() ban_reasons=() ban_durations=() ban_banned_at=() ban_expires=() ban_guids=()
    local ban_count=0
    local total_items key seq
    while true; do
        if [[ $needs_refresh -eq 1 ]]; then
            _bans_refresh
            needs_refresh=0
        fi
        total_items=$((ban_count + ${#TABLE_SCREEN_ACTIONS[@]}))
        [[ $selected -lt 0 ]] && selected=0
        [[ $selected -ge $total_items ]] && selected=$((total_items - 1))
        get_term_size
        _bans_draw

        IFS= read -rsn1 key || return 0   # EOF: leave instead of looping
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') if [[ $selected -gt 0 ]]; then selected=$((selected - 1)); fi ;;
                    '[B') if [[ $selected -lt $((total_items - 1)) ]]; then selected=$((selected + 1)); fi ;;
                esac
                ;;
            '')  # Enter: ban details, or the button under the cursor
                if [[ $selected -lt $ban_count ]]; then
                    _bans_key_details
                elif [[ $selected -eq $ban_count ]]; then
                    needs_refresh=1
                else
                    return 0
                fi
                ;;
            r|R) needs_refresh=1 ;;
            u|U) _bans_key_unban ;;
            q|Q) return 0 ;;
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
