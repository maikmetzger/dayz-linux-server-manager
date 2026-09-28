#!/usr/bin/env bash
# =============================================================================
# DayZ Docker Server Manager - Pure Bash TUI
# =============================================================================
# Arrow-key navigation, no external dependencies (no dialog/whiptail)
# DayZ Theme: Black background, Red accents
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# =============================================================================
# Load Libraries
# =============================================================================
for lib in colors tui menu dialogs utils docker instance mods config mod_config types workshop server_control; do
    source "${SCRIPT_DIR}/lib/${lib}.sh"
done

# Set up cleanup trap
trap cleanup EXIT
tui_init

# =============================================================================
# Docker & User Identity
# =============================================================================
require_docker
init_user_identity

# Standard search root: ~/servers
SEARCH_ROOT="${INVOKING_HOME}/servers"

# =============================================================================
# Instance Selector (TUI)
# =============================================================================
select_instance() {
    local selection=0
    while true; do
        scan_instances
        
        # Build menu items with status
        local -a items=()
        if [[ ${#INSTANCE_NAMES[@]} -gt 0 ]]; then
            for i in "${!INSTANCE_NAMES[@]}"; do
                local name="${INSTANCE_NAMES[$i]}"
                local container="${INSTANCE_CONTAINERS[$i]}"
                local instance_dir="${INSTANCE_DIRS[$i]}"
                local status
                status="$(get_container_status "$container")"
                
                local status_icon="${RED}○${RESET}"
                [[ "$status" == "RUNNING" ]] && status_icon="${GREEN}●${RESET}"
                
                # Get update summary if cache exists
                local update_summary=""
                update_summary=$(get_update_summary "$instance_dir" 2>/dev/null || true)
                
                if [[ -n "$update_summary" ]]; then
                    items+=("${status_icon}|${name} [${status}] ${YELLOW}${update_summary}${RESET}")
                else
                    items+=("${status_icon}|${name} [${status}]")
                fi
            done
            items+=("--------------------")
        else
            items+=("No instances found.")
            items+=("--------------------")
        fi
        
        items+=("✨|Install/Manage Instances")
        items+=("--------------------")
        items+=("❌|Quit")
        
        if run_menu items "DayZ Server Manager - Select Instance" $selection; then
            selection=$MENU_RESULT
            local selected_item="${items[$MENU_RESULT]}"
            local count=${#INSTANCE_NAMES[@]}
            
            # 1. Handle dynamic instances
            if [[ $MENU_RESULT -lt $count ]]; then
                SELECTED_DIR="${INSTANCE_DIRS[$MENU_RESULT]}"
                SELECTED_NAME="${INSTANCE_NAMES[$MENU_RESULT]}"
                SELECTED_CONTAINER="${INSTANCE_CONTAINERS[$MENU_RESULT]}"
                return
            fi
            
            # 2. Handle static menu items by content
            if [[ "$selected_item" == "✨|Install/Manage Instances" ]]; then
                # Installer
                if [[ -f "${SCRIPT_DIR}/install-dayz-docker.sh" ]]; then
                    export DAYZ_USER="$INVOKING_USER"
                    export DAYZ_HOME="$INVOKING_HOME"
                    
                    if ! groups | grep -q "\\bdocker\\b"; then
                        if confirm "Installer requires root/docker privileges. Run with sudo?" "y"; then
                            printf "%s" "$SHOW_CURSOR"
                            sudo -E bash "${SCRIPT_DIR}/install-dayz-docker.sh"
                            selection=0
                            continue
                        fi
                    fi
                    
                    printf "%s" "$SHOW_CURSOR"
                    bash "${SCRIPT_DIR}/install-dayz-docker.sh"
                    selection=0
                    continue
                else
                    show_message "install-dayz-docker.sh not found."
                fi
            elif [[ "$selected_item" == "❌|Quit" ]]; then
                exit 0
            fi
        else
            exit 0
        fi
    done
}

# =============================================================================
# Mod Manager (TUI)
# =============================================================================
# Let the user pick one mod from the current list via a menu.
# Uses the caller's mod_ids/mod_count. On success MENU_RESULT holds the
# index into mod_ids; returns 1 when the user cancels.
_mod_manager_pick_mod() {
    local title="$1"
    local -a pick_items=()
    local i
    for ((i=0; i<mod_count; i++)); do
        pick_items+=("📦|$(get_mod_name "${mod_ids[$i]}") (${mod_ids[$i]})")
    done
    pick_items+=("--------------------")
    pick_items+=("←|Cancel")
    run_menu pick_items "$title" || return 1
    [[ $MENU_RESULT -lt $mod_count ]] || return 1
    return 0
}

# Remove one mod: dependency check, confirmation, CE cleanup, key cleanup.
# Uses the caller's mod_ids/mods_file/servermods_file.
# Returns 0 when the mod was removed, 1 otherwise.
_mod_manager_remove_mod() {
    local mid="$1"
    local mname
    mname=$(get_mod_name "$mid")

    local blocker
    blocker=$(check_reverse_dependencies "$mid" "${enabled_mod_ids[@]}")
    if [[ -n "$blocker" ]]; then
        show_message "Cannot remove '$mname':\nRequired by '$blocker'" "DEPENDENCY ERROR"
        return 1
    fi
    confirm "Remove mod '$mname' from list?" "n" || return 1

    # Auto-Cleanup CE (unlink/unmerge)
    cleanup_mod_ce_files "${SELECTED_DIR}" "$mid"

    local server_keys="${SELECTED_DIR}/data/serverfiles/keys"
    local workshop_base="${SELECTED_DIR}/data/serverfiles/steamapps/workshop/content/221100"
    local removed_keys
    removed_keys=$(uninstall_mod "$mid" "$mods_file" "$servermods_file" "$server_keys" "$workshop_base")
    show_message "Removed: $mname ($removed_keys keys deleted)" "Removed"
    return 0
}

# Buttons of the action bar, in cursor order after the mod rows
MOD_MANAGER_ACTIONS=("[A] Add" "[R] Remove" "[S] Sync" "[F] FixMods" "[I] Info" "[Q] Back")

# The _mod_manager_* helpers below run inside mod_manager and work on its
# locals (bash dynamic scoping): mod_ids, mod_names, mod_types, mod_warnings,
# enabled_mod_ids, mod_count, selected, dirty, needs_rebuild,
# pending_sync_mods, mods_file, servermods_file, needs_sync_file,
# pending_mods_file, plus the mod_*_dates/flags/reasons arrays.

# Rebuild the table data from mods.txt/servermods.txt, the update cache and
# the workshop folders.
_mod_manager_rebuild() {
    mod_ids=(); mod_names=(); mod_types=(); mod_warnings=()
    mapfile -t mod_ids < <(get_all_mod_ids "$mods_file" "$servermods_file")
    prefetch_mod_names ${mod_ids[@]+"${mod_ids[@]}"}   # one API request for all unknown names

    local max_name=$((TERM_COLS - 45))
    [[ $max_name -lt 20 ]] && max_name=20
    local mid mname
    for mid in ${mod_ids[@]+"${mod_ids[@]}"}; do
        mname="$(get_mod_name "$mid")"
        [[ ${#mname} -gt $max_name ]] && mname="${mname:0:$((max_name-3))}..."
        mod_names+=("$mname")
        mod_types+=("$(get_mod_type "$mid" "$mods_file" "$servermods_file")")
    done
    _mod_manager_load_status

    # Only enabled mods count for dependency checks: a disabled framework
    # is not loaded, and a disabled dependent must not block a removal.
    enabled_mod_ids=()
    local i
    for i in "${!mod_ids[@]}"; do
        [[ "${mod_types[$i]}" != "disabled" ]] && enabled_mod_ids+=("${mod_ids[$i]}")
    done
    local warn
    for i in "${!mod_ids[@]}"; do
        warn=""
        if [[ "${mod_types[$i]}" != "disabled" ]]; then
            warn="$(check_mod_dependencies "${mod_ids[$i]}" ${enabled_mod_ids[@]+"${enabled_mod_ids[@]}"} 2>/dev/null || true)"
        fi
        mod_warnings+=("$warn")
    done
}

# Dates and update flags per mod from lib/mod_status.py (one process for all)
_mod_manager_load_status() {
    mod_ws_dates=(); mod_sync_dates=(); mod_install_dates=(); mod_update_flags=(); mod_update_reasons=()
    local ws_d sync_d inst_d has_up reason
    while IFS='|' read -r ws_d sync_d inst_d has_up reason; do
        [[ -z "$ws_d" ]] && continue
        mod_ws_dates+=("$ws_d")
        mod_sync_dates+=("$sync_d")
        mod_install_dates+=("$inst_d")
        mod_update_flags+=("$has_up")
        mod_update_reasons+=("$reason")
    done < <(get_cached_update_info "$SELECTED_DIR" | python3 "${SCRIPT_DIR}/lib/mod_status.py" \
        --workshop-dir "${SELECTED_DIR}/serverfiles/steamapps/workshop/content/221100" \
        --workshop-dir "${SELECTED_DIR}/data/serverfiles/steamapps/workshop/content/221100" \
        ${mod_ids[@]+"${mod_ids[@]}"})
}

# ---- drawing -----------------------------------------------------------------

# Whole screen: header, column titles, mod rows, action bar, footer
_mod_manager_draw() {
    printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
    move_to 1 1
    local header_title="Mod Manager - $SELECTED_NAME"
    if [[ $dirty -eq 1 ]]; then
        header_title="Mod Manager - $SELECTED_NAME ${YELLOW}[ SYNC NEEDED ]${RESET}${BG_RED}${WHITE}${BOLD}"
    fi
    printf "%s%s %s%s%s" "$BG_RED" "$WHITE$BOLD" "$header_title" "${ESC}[K" "$RESET"

    # column positions, shared with the row functions
    local table_start=3 col_status=2 col_type=8 col_name=15
    local col_id=$((TERM_COLS - 45)) col_wsver=$((TERM_COLS - 32)) col_synced=$((TERM_COLS - 15))
    tui_draw_rule $table_start
    local col title
    for col in "$col_status:STATUS" "$col_type:TYPE" "$col_name:MOD NAME" "$col_id:ID" "$col_wsver:WORKSHOP DATE" "$col_synced:SYNCED"; do
        move_to $((table_start + 1)) "${col%%:*}"
        printf "%s%s%s%s" "$DIM" "$WHITE" "${col#*:}" "$RESET"
    done
    tui_draw_rule $((table_start + 2))

    local row=$((table_start + 3))
    if [[ $mod_count -eq 0 ]]; then
        move_to $row 1
        printf "%s  (No mods - press A to add)%s" "$DIM" "$RESET"
        row=$((row + 1))
    fi
    local i
    for i in "${!mod_ids[@]}"; do
        _mod_manager_draw_row "$i" "$row"
        row=$((row + 1))
    done
    tui_draw_rule $row
    _mod_manager_draw_actions $((row + 1))
    _mod_manager_draw_footer
}

# Values both row styles need for mod index $1; sets mid, mtype, mname,
# status_icon, type_short, ws_ver, sync_ver, ws_color, sync_color in the caller
_mod_manager_row_values() {
    local i="$1"
    mid="${mod_ids[$i]}"
    mtype="${mod_types[$i]}"
    mname="${mod_names[$i]}"
    local max_name_len=$((col_id - col_name - 2))
    [[ ${#mname} -gt $max_name_len ]] && mname="${mname:0:$((max_name_len-3))}..."

    case "$mtype" in
        both)     status_icon="✓"; type_short="C+S" ;;
        client)   status_icon="✓"; type_short="Cli" ;;
        server)   status_icon="✓"; type_short="Srv" ;;
        disabled) status_icon="✗"; type_short="Off" ;;
    esac
    [[ -n "${mod_warnings[$i]:-}" ]] && status_icon="!"

    ws_ver="${mod_ws_dates[$i]:--}"
    sync_ver="${mod_sync_dates[$i]:--}"
    ws_color="$WHITE"
    sync_color="$DIM"
    [[ ${mod_update_flags[$i]:-0} -eq 1 ]] && { ws_color="$YELLOW"; sync_color="$YELLOW"; }
    local reason="${mod_update_reasons[$i]:-}"
    [[ "$reason" == *D* ]] && { sync_color="$RED"; sync_ver="MISSING LINK"; }
    [[ "$reason" == *M* ]] && { sync_color="$RED"; sync_ver="MISSING FILE"; }
    return 0
}

# One mod row; the row under the cursor is drawn inverted
_mod_manager_draw_row() {
    local i="$1" row="$2"
    local mid mtype mname status_icon type_short ws_ver sync_ver ws_color sync_color
    _mod_manager_row_values "$i"
    move_to "$row" 1
    if [[ $i -eq $selected ]]; then
        _mod_manager_draw_row_selected
    else
        _mod_manager_draw_row_plain "$i"
    fi
}

_mod_manager_draw_row_selected() {
    printf "%s%s%s" "$BG_RED" "$WHITE$BOLD" "${ESC}[K"
    move_to "$row" $col_status
    printf "▶ %s" "$status_icon"
    move_to "$row" $col_type
    case "$mtype" in
        both)     printf "[%sC%s+%sS%s]" "$MOD_CL" "$WHITE$BOLD" "$MOD_SV" "$WHITE$BOLD" ;;
        client)   printf "[%s%s%s]" "$MOD_CL" "$type_short" "$WHITE$BOLD" ;;
        server)   printf "[%s%s%s]" "$MOD_SV" "$type_short" "$WHITE$BOLD" ;;
        disabled) printf "[%s]" "$type_short" ;;
    esac
    move_to "$row" $col_name
    printf "%s" "$mname"
    move_to "$row" $col_id
    printf "%s" "$mid"
    move_to "$row" $col_wsver
    printf "%-14s" "${ws_ver:0:14}"
    move_to "$row" $col_synced
    printf "%-14s" "${sync_ver:0:14}"
    printf "%s" "$RESET"
}

_mod_manager_draw_row_plain() {
    local i="$1"
    local row_color="$RESET" id_color="$DIM"
    # yellow: update available, dependency warning, missing files, pending type change
    [[ ${mod_update_flags[$i]:-0} -eq 1 ]] && row_color="$YELLOW"
    [[ -n "${mod_warnings[$i]:-}" ]] && row_color="$YELLOW"
    [[ "$sync_ver" == *MISSING* ]] && row_color="$YELLOW"
    [[ "$pending_sync_mods" == *"$mid"* ]] && row_color="$YELLOW"
    if [[ "$mtype" == "disabled" ]]; then
        row_color="$DARKGRAY"; ws_color="$DARKGRAY"; sync_color="$DARKGRAY"; id_color="$DARKGRAY"
    fi

    printf "%s" "$row_color"
    move_to "$row" $col_status
    if [[ "$mtype" == "disabled" ]]; then
        printf "  %s%s%s" "$RED" "$status_icon" "$row_color"
    elif [[ -n "${mod_warnings[$i]:-}" ]]; then
        printf "  %s%s%s" "$YELLOW$BOLD" "$status_icon" "$row_color"
    else
        printf "  %s%s%s" "$GREEN" "$status_icon" "$row_color"
    fi
    move_to "$row" $col_type
    case "$mtype" in
        both)     printf "[%sC%s+%sS%s]%s" "$MOD_CL" "$row_color" "$MOD_SV" "$row_color" "$RESET" ;;
        client)   printf "[%s%s%s]%s" "$MOD_CL" "$type_short" "$row_color" "$RESET" ;;
        server)   printf "[%s%s%s]%s" "$MOD_SV" "$type_short" "$row_color" "$RESET" ;;
        disabled) printf "[%s%s%s]" "$RED" "$type_short" "$row_color" ;;
    esac
    move_to "$row" $col_name
    printf "%s%s" "$row_color" "$mname"
    move_to "$row" $col_id
    printf "%s%s%s" "$id_color" "$mid" "$row_color"
    move_to "$row" $col_wsver
    printf "%s%-14s%s" "$ws_color" "${ws_ver:0:14}" "$row_color"
    move_to "$row" $col_synced
    printf "%s%-14s%s" "$sync_color" "${sync_ver:0:14}" "$row_color"
    printf "%s" "$RESET"
}

# Action bar with the clock; the button under the cursor is highlighted
_mod_manager_draw_actions() {
    local action_row="$1"
    move_to "$action_row" $((TERM_COLS - 20))
    printf "%s%s[ %s ]%s" "$DIM" "$WHITE" "$(date +"%H:%M:%S")" "$RESET"
    move_to "$action_row" 2
    local a label
    for a in "${!MOD_MANAGER_ACTIONS[@]}"; do
        label="${MOD_MANAGER_ACTIONS[$a]}"
        [[ "$label" == "[S] Sync" && $dirty -eq 1 ]] && label="[!S] Sync"   # sync pending
        if [[ $selected -eq $((mod_count + a)) ]]; then
            if [[ "$label" == "[!S] Sync" ]]; then
                printf "%s%s▶ %s %s" "$BG_YELLOW" "$BLACK$BOLD" "$label" "$RESET"
            else
                printf "%s%s▶ %s %s" "$BG_RED" "$WHITE$BOLD" "$label" "$RESET"
            fi
        elif [[ "$label" == "[!S] Sync" ]]; then
            printf "  %s%s%s " "$YELLOW$BOLD" "$label" "$RESET"
        else
            printf "  %s " "$label"
        fi
        printf " "
    done
}

# Footer: dependency warning of the selected mod (computed in the rebuild,
# no python per keypress) and the key help
_mod_manager_draw_footer() {
    move_to $((TERM_ROWS - 1)) 1
    local sel_warn=""
    [[ $selected -lt $mod_count ]] && sel_warn="${mod_warnings[$selected]:-}"
    if [[ -n "$sel_warn" ]]; then
        printf "%s%s WARN: %s %s%s" "$BG_RED" "$WHITE$BOLD" "$sel_warn" "${ESC}[K" "$RESET"
    else
        printf "%s" "${ESC}[2K"
    fi
    move_to "$TERM_ROWS" 1
    printf "%s%s [↑↓] Select  [U/D] Move  [Enter] Toggle  [A] Add  [R] Remove  [S] Sync  [F] Fix  [Space] Info  [Q] Back%s%s" "$BG_DARKGRAY" "$WHITE" "${ESC}[K" "$RESET"
}

# ---- actions -----------------------------------------------------------------

# The mod list changed: header shows [SYNC NEEDED], the table gets rebuilt
_mod_manager_mark_dirty() {
    dirty=1
    needs_rebuild=1
    touch "$needs_sync_file"
}

# 0 when the container runs, otherwise a message naming the action
# Usage: _mod_manager_require_running "sync" || return 0
_mod_manager_require_running() {
    [[ "$(get_container_status "$SELECTED_CONTAINER")" == "RUNNING" ]] && return 0
    show_message "Container must be running to $1"
    return 1
}

# [U]/[D] move the selected mod one position in the load order
_mod_manager_move() {
    local direction="$1"
    if [[ "$direction" == "up" ]]; then
        [[ $selected -gt 0 && $selected -lt $mod_count ]] || return 0
        move_mod_up "${mod_ids[$selected]}" "$mods_file" "$servermods_file"
        selected=$((selected - 1))
    else
        [[ $selected -lt $((mod_count - 1)) ]] || return 0
        move_mod_down "${mod_ids[$selected]}" "$mods_file" "$servermods_file"
        selected=$((selected + 1))
    fi
    _mod_manager_mark_dirty
}

# [Enter] on a mod: disabled -> client -> server -> both -> disabled
_mod_manager_toggle_mod() {
    local mid="${mod_ids[$selected]}"
    case "${mod_types[$selected]}" in
        disabled) add_mod_to_file "$mid" "$mods_file" ;;
        client)   remove_mod_from_file "$mid" "$mods_file"; add_mod_to_file "$mid" "$servermods_file" ;;
        server)   add_mod_to_file "$mid" "$mods_file"; add_mod_to_file "$mid" "$servermods_file" ;;
        both)     remove_mod_from_file "$mid" "$mods_file"; remove_mod_from_file "$mid" "$servermods_file" ;;
    esac
    append_line "$pending_mods_file" "$mid"
    pending_sync_mods="$pending_sync_mods $mid"
    _mod_manager_mark_dirty
}

# [A] ask for a Workshop ID, show its details and add it as client mod
_mod_manager_add_mod() {
    local new_id
    new_id=$(read_input "Enter Steam Workshop ID:" "" "Add Workshop Mod")
    [[ "$new_id" =~ ^[0-9]+$ ]] || return 0
    if is_mod_in_file "$new_id" "$mods_file" || is_mod_in_file "$new_id" "$servermods_file"; then
        show_message "Mod already in list" "Already Exists"
        return 0
    fi
    local rc=0
    _view_mod_details "$new_id" "$SELECTED_DIR" "$mods_file" "${SCRIPT_DIR}/data/workshop_rules.json" || rc=$?
    [[ $rc -eq 10 ]] || return 0   # 10: the details view's "add" action was chosen
    add_mod_to_file "$new_id" "$mods_file"
    show_message "Added mod $new_id as [Client]" "Mod Added"
    _mod_manager_mark_dirty
}

# Index of the mod to act on: the selected row, or one picked from a list
# when the cursor sits on the action bar. Prints the index, returns 1 on cancel.
_mod_manager_target_index() {
    local title="$1"
    if [[ $selected -lt $mod_count ]]; then
        echo "$selected"
        return 0
    fi
    [[ $mod_count -gt 0 ]] || return 1
    _mod_manager_pick_mod "$title" || return 1
    echo "$MENU_RESULT"
}

# [R] remove a mod (dependency check and confirmation in _mod_manager_remove_mod)
_mod_manager_remove() {
    local idx
    idx=$(_mod_manager_target_index "Remove which mod?") || return 0
    _mod_manager_remove_mod "${mod_ids[$idx]}" || return 0
    _mod_manager_mark_dirty
    # the list is one row shorter: keep the cursor on the same row/button
    [[ $selected -ge $((mod_count - 1)) ]] && selected=$((selected - 1))
    [[ $selected -lt 0 ]] && selected=0
    return 0
}

# [I]/[Space] workshop details of a mod
_mod_manager_info() {
    local idx
    idx=$(_mod_manager_target_index "Show info for which mod?") || return 0
    _view_mod_details "${mod_ids[$idx]}" "$SELECTED_DIR" "$mods_file" "${SCRIPT_DIR}/data/workshop_rules.json" || true
    needs_rebuild=1
}

# [S] sync the mod files into the container, refresh the update cache and
# offer to activate the CE files the mods ship
_mod_manager_sync() {
    _mod_manager_require_running "sync" || return 0
    run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods; /dayz/run.sh sync-servermods" || true
    dirty=0
    rm -f "$needs_sync_file" "$pending_mods_file"
    pending_sync_mods=""
    needs_rebuild=1

    show_progress_start "Sync" "Refreshing update cache..."
    local workshop_path="${SELECTED_DIR}/data/serverfiles/steamapps/workshop/content/221100"
    [[ -d "$workshop_path" ]] || workshop_path="${SELECTED_DIR}/serverfiles/steamapps/workshop/content/221100"
    show_progress_update "Checking mod versions..." 30
    check_all_mod_updates "$SELECTED_DIR" "$workshop_path" "$mods_file" "$servermods_file" >/dev/null 2>&1 || true

    show_progress_update "Scanning CE files..." 60
    local -a ce_mod_ids ce_mod_names ce_file_paths ce_filenames ce_types
    scan_new_ce_files "$SELECTED_DIR" "$workshop_path"
    show_progress_end "Sync complete!" 300
    ce_link_files_dialog "$SELECTED_DIR" "Link CE Files - $SELECTED_NAME"
}

# [F] fix mod folder casing and keys inside the container
_mod_manager_fix_mods() {
    _mod_manager_require_running "fix mods" || return 0
    run_with_output "Fixing Mod Casing & Keys" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh fix-mods && /dayz/run.sh fix-servermods" || true
}

# [Q] leaving with a pending sync needs confirmation
_mod_manager_can_leave() {
    [[ $dirty -eq 1 ]] || return 0
    confirm "Sync is pending! Leave without syncing?" "n"
}

# [Enter] toggle the selected mod, or run the action bar button under the cursor
_mod_manager_enter() {
    if [[ $selected -lt $mod_count ]]; then
        _mod_manager_toggle_mod
        return 0
    fi
    case "${MOD_MANAGER_ACTIONS[$((selected - mod_count))]}" in
        "[A] Add")     _mod_manager_add_mod ;;
        "[R] Remove")  _mod_manager_remove ;;
        "[S] Sync")    _mod_manager_sync ;;
        "[F] FixMods") _mod_manager_fix_mods ;;
        "[I] Info")    _mod_manager_info ;;
    esac
}

# Mod Manager screen: mod list with type and date columns, load order,
# add/remove, sync into the container.
mod_manager() {
    local mods_file="${SELECTED_DIR}/data/config/mods.txt"
    local servermods_file="${SELECTED_DIR}/data/config/servermods.txt"
    [[ -f "$mods_file" ]] || touch "$mods_file"
    [[ -f "$servermods_file" ]] || touch "$servermods_file"

    local selected=0
    local dirty=0
    local needs_sync_file="${SELECTED_DIR}/data/config/.needs_sync"
    local pending_mods_file="${SELECTED_DIR}/data/config/.pending_sync_mods"
    [[ -f "$needs_sync_file" ]] && dirty=1   # persisted dirty state
    local pending_sync_mods=""                # rows shown yellow until synced
    [[ -f "$pending_mods_file" ]] && pending_sync_mods="$(cat "$pending_mods_file")"

    local needs_rebuild=1
    local last_cols=0
    local -a mod_ids=() mod_names=() mod_types=() mod_warnings=()
    local -a enabled_mod_ids=()   # ids that are actually loaded; used for dependency checks
    local -a mod_ws_dates=() mod_sync_dates=() mod_install_dates=() mod_update_flags=() mod_update_reasons=()
    local mod_count total_items key seq

    while true; do
        get_term_size
        if [[ $TERM_COLS -ne $last_cols ]]; then   # names are truncated to the width
            needs_rebuild=1
            last_cols=$TERM_COLS
        fi
        if [[ $needs_rebuild -eq 1 ]]; then
            _mod_manager_rebuild
            needs_rebuild=0
        fi
        mod_count=${#mod_ids[@]}
        total_items=$((mod_count + ${#MOD_MANAGER_ACTIONS[@]}))
        [[ $selected -lt 0 ]] && selected=0
        [[ $selected -ge $total_items ]] && selected=$((total_items - 1))

        _mod_manager_draw

        # EOF (closed stdin) leaves the menu instead of looping
        IFS= read -rsn1 key || return 0
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') if [[ $selected -gt 0 ]]; then selected=$((selected - 1)); fi ;;
                    '[B') if [[ $selected -lt $((total_items - 1)) ]]; then selected=$((selected + 1)); fi ;;
                esac
                ;;
            u|U|+)   _mod_manager_move up ;;
            d|D|-)   _mod_manager_move down ;;
            a|A)     _mod_manager_add_mod ;;
            r|R)     _mod_manager_remove ;;
            i|I|' ') _mod_manager_info ;;
            s|S)     _mod_manager_sync ;;
            f|F)     _mod_manager_fix_mods ;;
            q|Q)     if _mod_manager_can_leave; then return 0; fi ;;
            '')      # Enter; the last button is [Q] Back
                if [[ $selected -eq $((total_items - 1)) ]]; then return 0; fi
                _mod_manager_enter
                ;;
        esac
    done
}

# =============================================================================
# Wipe Menu
# =============================================================================
wipe_menu() {
    local storage_root="${SELECTED_DIR}/data/serverfiles/mpmissions"
    local storage_dir
    storage_dir=$(find "${storage_root}" -name "storage_1" -type d -print -quit 2>/dev/null || true)
    
    if [[ -z "$storage_dir" ]]; then
        show_message "Could not find storage_1 directory in ${storage_root}" "Error"
        return
    fi

    local mission_dir
    mission_dir="$(dirname "$storage_dir")"
    local economy_file="${mission_dir}/db/economy.xml"

    local -a states=(0 0 0 0)
    local selection=0
    
    while true; do
        draw_header "Wipe Server Data - $SELECTED_NAME"
        
        local -a items=()
        if [[ ${states[0]} -eq 1 ]]; then items+=("[x] 👤|Wipe Players (players.db)"); else items+=("[ ] 👤|Wipe Players (players.db)"); fi
        if [[ ${states[1]} -eq 1 ]]; then items+=("[x] 🚗|Wipe Vehicles (vehicles.bin)"); else items+=("[ ] 🚗|Wipe Vehicles (vehicles.bin)"); fi
        if [[ ${states[2]} -eq 1 ]]; then items+=("[x] 🏰|Wipe Bases (persistence/data)"); else items+=("[ ] 🏰|Wipe Bases (persistence/data)"); fi
        if [[ ${states[3]} -eq 1 ]]; then items+=("[x] 🎒|Wipe Loot (economy reset)"); else items+=("[ ] 🎒|Wipe Loot (economy reset)"); fi
        
        items+=("--------------------")
        items+=("💀|EXECUTE SELECTED WIPE(S)")
        items+=("❌|Cancel / Back")
        
        if run_menu items "Select Data to Wipe (Enter to Toggle)" $selection; then
            selection=$MENU_RESULT
            case $MENU_RESULT in
                0) states[0]=$((1 - states[0])) ;;
                1) states[1]=$((1 - states[1])) ;;
                2) states[2]=$((1 - states[2])) ;;
                3) states[3]=$((1 - states[3])) ;;
                4) ;;
                5)
                    local count=$((states[0] + states[1] + states[2] + states[3]))
                    if [[ $count -eq 0 ]]; then
                        show_message "No items selected." "Error"
                        continue
                    fi
                    
                    # Safety Check: Server Status
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" == "RUNNING" ]]; then
                        show_message "Server is currently RUNNING. Please STOP it before wiping data to avoid database corruption." "Safety Warning"
                        continue
                    fi

                    if confirm "Wipe ${count} categories? This cannot be undone!" "n"; then
                        printf "%s" "$SHOW_CURSOR"
                        
                        # 0. Players
                        [[ ${states[0]} -eq 1 ]] && rm -f "${storage_dir}/players.db" "${storage_dir}/players.db-journal"
                        
                        # 1. Vehicles
                        [[ ${states[1]} -eq 1 ]] && rm -f "${storage_dir}/vehicles.bin" "${storage_dir}/vehicles.bin-journal"
                        
                        # 2. Bases / Persistence (World structures)
                        if [[ ${states[2]} -eq 1 ]]; then
                            echo "Wiping Bases/Persistence..."
                            # Delete everything in data except loot bins if loot is NOT being wiped? 
                            # Most users want a clean 'data' folder for a base wipe.
                            rm -rf "${storage_dir}/data"/*
                        fi
                        
                        # 3. Loot / CLE Reset (Types & Dynamics & Events)
                        if [[ ${states[3]} -eq 1 && ${states[2]} -eq 0 ]]; then
                            # Only delete loot bins if we didn't already wipe the whole data folder
                            echo "Wiping Loot Economy state..."
                            # Types (Spawn rules)
                            rm -f "${storage_dir}/data/types.bin" "${storage_dir}/data/types.bin-journal"
                            rm -f "${storage_dir}/data/types."*
                            
                            # Dynamics (Individual ground items - often chunked as dynamic_001.bin etc)
                            rm -f "${storage_dir}/data/dynamic_"*
                            rm -f "${storage_dir}/data/dynamics.bin" "${storage_dir}/data/dynamics.bin-journal"
                            
                            # Events (Heli crashes, convoys, etc)
                            rm -f "${storage_dir}/data/events.bin" "${storage_dir}/data/events.bin-journal"
                            rm -f "${storage_dir}/data/events."*
                        fi
                        
                        show_message "Wipe Complete. Files have been reset." "Success"
                        states=(0 0 0 0)
                    fi
                    ;;
                6) return 0 ;;
            esac
        else
            return 0
        fi
    done
}

# =============================================================================
# Log Browser
# =============================================================================
log_browser_menu() {
    local selection=0
    while true; do
        local -a items=(
            "🐳|Live Docker Logs (Container)"
            "📜|Server Logs (RPT, ADM, Scripts)"
            "--------------------"
            "←|Back"
        )
        
        if ! run_menu items "Log Browser: $SELECTED_NAME" $selection; then
            return
        fi
        
        selection=$MENU_RESULT
        case "$MENU_RESULT" in
            0)
                trap : INT
                run_with_output "Live Docker Logs (Ctrl+C to stop)" $DOCKER logs -f --tail=100 "$SELECTED_CONTAINER"
                trap - INT
                ;;
            1)
                local profile_dir="${SELECTED_DIR}/data/profile"
                if [[ ! -d "$profile_dir" ]]; then
                    show_message "Profile directory not found: $profile_dir" "Error"
                else
                    # Use generic browser for logs. No special select cmd needed, 
                    # use default recursion + tail/edit functionality.
                    fb_browse_dir "$profile_dir" "Server Log Browser" "ROOT > Logs" "" "all"
                fi
                ;;
            3) return 0 ;;
        esac
    done
}

# =============================================================================
# Main Menu
# =============================================================================
main_menu() {
    local selection=0
    while true; do
        local status
        status="$(get_container_status "$SELECTED_CONTAINER")"
        
        local status_text="${WHITE}● STOPPED]${RESET}"
        [[ "$status" == "RUNNING" ]] && status_text="${GREEN}● RUNNING${WHITE}]${RESET}"
        
        # Get update summary for header
        local update_summary=""
        update_summary=$(get_update_summary "$SELECTED_DIR" 2>/dev/null || true)
        local header_suffix=""
        if [[ -n "$update_summary" ]]; then
            header_suffix=" ${YELLOW}${update_summary}${RESET}"
        fi
        
        # Determine menu item labels (highlight if updates available)
        local mod_label="⚒️|Mod Manager"
        local update_label="⬆️|Update Server"
        local needs_sync_file="${SELECTED_DIR}/data/config/.needs_sync"
        
        if [[ -f "$needs_sync_file" ]]; then
            mod_label="⚒️|Mod Manager ${YELLOW}[ SYNC NEEDED ]${RESET}"
        elif [[ -n "$update_summary" ]]; then
            mod_label="⚒️|Mod Manager ${YELLOW}${update_summary}${RESET}"
        fi
        
        local -a items=(
            "▶️|Start Server"
            "⏹️|Stop Server"
            "🔄|Restart Server"
            "--------------------"
            "$mod_label"
            "🌐|Workshop"
            "🧹|Wipe Server Data"
            "--------------------"
            "📦|Loot Economy"
            "🔧|Server Settings"
            "🔐|RCON Settings"
            "🖥️|Server Control"
            "📁|Mod Configs"
            "👤|Admin Tools"
            "--------------------"
            "🎮|RCON Console"
            "📜|View Logs"
            "💻|Enter Shell"
            "--------------------"
            "$update_label"
            "--------------------"
            "←|Switch Instance"
        )
        
        if ! run_menu items "DayZ: $SELECTED_NAME [$status_text${header_suffix}" $selection; then
            return
        fi
        
        selection=$MENU_RESULT
        local selected_item="${items[$MENU_RESULT]}"
        
        case "$selected_item" in
            "▶️|Start Server") run_with_output "Starting Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose up -d" ;;
            "⏹️|Stop Server") run_with_output "Stopping Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose stop" ;;
            "🔄|Restart Server") run_with_output "Restarting Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose stop && $DOCKER compose up -d" ;;
            "⚒️|Mod Manager"*) mod_manager || true ;;
            "🌐|Workshop") workshop_browser "$SELECTED_DIR" || true ;;
            "🧹|Wipe Server Data") wipe_menu || true ;;
            "📦|Loot Economy") types_selection_menu "$SELECTED_DIR" "$SELECTED_CONTAINER" || true ;;
            "🔧|Server Settings")
                local server_path="${SELECTED_DIR}/data/config/serverDZ.cfg"
                if [[ -f "$server_path" ]]; then
                    config_category_editor "$SELECTED_CONTAINER" "$server_path" "serverDZ"
                else
                    show_message "Server config not found: serverDZ.cfg" "Error"
                fi
                ;;
            "🔐|RCON Settings")
                local rcon_path="${SELECTED_DIR}/data/config/BEServer_x64.cfg"
                if [[ -f "$rcon_path" ]]; then
                    config_category_editor "$SELECTED_CONTAINER" "$rcon_path" "BEServer"
                else
                    show_message "RCON config not found: BEServer_x64.cfg" "Error"
                fi
                ;;
            "🖥️|Server Control") server_control_menu "$SELECTED_DIR" || true ;;
            "📁|Mod Configs")
                local profile_dir="${SELECTED_DIR}/data/profile"
                mod_config_browser "$profile_dir" || true
                ;;
            "👤|Admin Tools")
                source "${SCRIPT_DIR}/lib/admin_config.sh"
                admin_tools_menu "$SELECTED_DIR" || true
                ;;
            "🎮|RCON Console")
                 printf "%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
                 set +e
                 "${SCRIPT_DIR}/rcon.sh" "$SELECTED_DIR"
                 local ret=$?
                 set -e
                 if [[ $ret -ne 130 ]]; then
                     printf "\n%s%sPress Enter to return to menu...%s" "$DIM" "$BOLD" "$RESET"
                     read -rsn1
                 fi
                 ;;
            "📜|View Logs") log_browser_menu || true ;;
            "💻|Enter Shell")
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running."
                else
                    printf "%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
                    $DOCKER exec -it "$SELECTED_CONTAINER" /bin/bash || echo "Container not running"
                    read -rp "Press Enter to continue..."
                    printf "%s" "$HIDE_CURSOR"
                fi
                ;;
            "⬆️|Update Server")
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to update"
                else
                    run_with_output "Updating Server" $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh update-server
                fi
                ;;
            "←|Switch Instance"|----*)
                return
                ;;
        esac
    done
}

# =============================================================================
# Entry Point
# =============================================================================
main() {
    get_term_size
    
    if [[ $TERM_ROWS -lt 15 ]] || [[ $TERM_COLS -lt 50 ]]; then
        echo "Terminal too small. Minimum: 50x15"
        exit 1
    fi
    
    printf "%s" "$HIDE_CURSOR"
    
    while true; do
        select_instance
        main_menu
    done
}

main "$@"