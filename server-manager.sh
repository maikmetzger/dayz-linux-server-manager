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

mod_manager() {
    local mods_file="${SELECTED_DIR}/data/config/mods.txt"
    local servermods_file="${SELECTED_DIR}/data/config/servermods.txt"
    
    [[ -f "$mods_file" ]] || touch "$mods_file"
    [[ -f "$servermods_file" ]] || touch "$servermods_file"
    
    local selected=0
    local dirty=0
    local needs_sync_file="${SELECTED_DIR}/data/config/.needs_sync"
    local pending_mods_file="${SELECTED_DIR}/data/config/.pending_sync_mods"
    
    # Load persisted dirty state
    [[ -f "$needs_sync_file" ]] && dirty=1
    
    # Load pending sync mods (for yellow highlighting)
    local pending_sync_mods=""
    [[ -f "$pending_mods_file" ]] && pending_sync_mods="$(cat "$pending_mods_file")"
    
    local needs_rebuild=1
    local -a mod_ids=()
    local -a mod_names=()
    local -a mod_types=()
    local -a mod_warnings=()
    local -a enabled_mod_ids=()   # ids that are actually loaded; used for dependency checks
    
    local last_cols=0
    
    while true; do
        get_term_size
        
        # Trigger rebuild if terminal width changed (for name truncation)
        if [[ $TERM_COLS -ne $last_cols ]]; then
            needs_rebuild=1
            last_cols=$TERM_COLS
        fi
        
        # Only rebuild arrays when data has changed
        if [[ $needs_rebuild -eq 1 ]]; then
            mod_ids=()
            mod_names=()
            mod_types=()
            mod_warnings=()
            
            while IFS= read -r mid; do
                [[ -z "$mid" ]] && continue
                mod_ids+=("$mid")
                
                local mname
                mname="$(get_mod_name "$mid")"
                local max_name=$((TERM_COLS - 45))
                [[ $max_name -lt 20 ]] && max_name=20
                [[ ${#mname} -gt $max_name ]] && mname="${mname:0:$((max_name-3))}..."
                mod_names+=("$mname")
                
                local mtype
                mtype="$(get_mod_type "$mid" "$mods_file" "$servermods_file")"
                mod_types+=("$mtype")
            done < <(get_all_mod_ids "$mods_file" "$servermods_file")
            
            # Pre-calculate versions and updates (ONE Python call for all)
            local cache_data
            cache_data=$(get_cached_update_info "$SELECTED_DIR")
            
            mod_versions=()
            mod_update_flags=()
            
            # Use Python to extract all info at once for speed
            # Pass IDs on a separate line or via env
            mod_ws_dates=()
            mod_sync_dates=()
            mod_install_dates=()
            mod_update_flags=()
            mod_update_reasons=()
            
            while IFS='|' read -r ws_d sync_d inst_d has_up reason; do
                # If script fails/prints garbage, safeguard
                [[ -z "$ws_d" ]] && continue
                mod_ws_dates+=("$ws_d")
                mod_sync_dates+=("$sync_d")
                mod_install_dates+=("$inst_d")
                mod_update_flags+=("$has_up")
                mod_update_reasons+=("$reason")
            done < <(
                export WS_PATH_1="${SELECTED_DIR}/serverfiles/steamapps/workshop/content/221100"
                export WS_PATH_2="${SELECTED_DIR}/data/serverfiles/steamapps/workshop/content/221100"
                export MOD_IDS_STR="${mod_ids[*]}"
                export CACHE_JSON="$cache_data"
                
                python3 <<'END_PYTHON'
import json, sys, datetime, os

mod_ids = os.environ.get('MOD_IDS_STR', '').split()
ws_path1 = os.environ.get('WS_PATH_1', '')
ws_path2 = os.environ.get('WS_PATH_2', '')
cache_json = os.environ.get('CACHE_JSON', '{}')

try:
    data = json.loads(cache_json) if cache_json else {}
except Exception:
    data = {}
mods_info = data.get('mods', {})

def fmt(ts):
    if not ts or ts == 0: return '-'
    # Compact format: 02.01.26 14:00
    return datetime.datetime.fromtimestamp(ts).strftime('%d.%m.%y %H:%M')

def read_ts(path, fallback):
    try:
        with open(path) as f: return int(f.read().strip())
    except Exception:
        return int(fallback)

def is_deployed_anywhere(m_path, mid):
    # Look for the @<id> symlink next to serverfiles and next to steamapps
    check_roots = [os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(m_path))))]
    parts = m_path.split(os.sep)
    if 'serverfiles' in parts:
        idx = parts.index('serverfiles')
        check_roots.append(os.sep.join(parts[:idx+1]))
    # Use lexists for Docker symlinks
    return any(os.path.lexists(os.path.join(r, f'@{mid}')) for r in check_roots)

def status_line(mid):
    m = mods_info.get(mid, {})

    # Check both potential workshop paths and pick the newest one
    # to handle mirrored folders smoothly. m_path stays None when the
    # mod has not been downloaded yet.
    choices = [p for p in (os.path.join(ws_path1, mid), os.path.join(ws_path2, mid)) if os.path.exists(p)]
    m_path = max(choices, key=os.path.getmtime) if choices else None

    local_v = 0
    install_ts = 0
    is_deployed = False

    if m_path:
        # SYNCED (local_v) = actual filesystem modification time
        # We touch this on every sync/fix, so it tells us when we last processed it.
        local_v = int(os.path.getmtime(m_path))

        # INSTALLED (install_ts) = Persistent original install date
        f_inst = os.path.join(m_path, '.first_installed')
        v_file = os.path.join(m_path, '.installed_version')
        ctime = os.path.getctime(m_path)
        if os.path.exists(f_inst):
            install_ts = read_ts(f_inst, ctime)
        elif os.path.exists(v_file):
            # Fallback: check .installed_version (Steam timestamp)
            install_ts = read_ts(v_file, ctime)
        else:
            install_ts = int(ctime)

        try:
            is_deployed = is_deployed_anywhere(m_path, mid)
        except Exception:
            is_deployed = False

    # Remote Stats
    remote_v = m.get('updated', 0) or m.get('latest', 0)

    reason = ''
    if remote_v > local_v: reason += 'U'
    if local_v == 0: reason += 'M'
    if not is_deployed: reason += 'D'

    has_update = 1 if reason else 0
    # Output: WS_DATE | SYNC_DATE | INSTALL_DATE | HAS_UPDATE | REASON
    return f'{fmt(remote_v)}|{fmt(local_v)}|{fmt(install_ts)}|{has_update}|{reason}'

for mid in mod_ids:
    # Exactly one line per mod, always: one broken mod must not hide the others.
    try:
        print(status_line(mid))
    except Exception:
        print('-|-|-|1|Err')
END_PYTHON
            )
            
            # Global sync flag
            global_sync_needed=0
            for flag in "${mod_update_flags[@]}"; do
                [[ "$flag" -eq 1 ]] && { global_sync_needed=1; break; }
            done
            
            # Only enabled mods count for dependency checks: a disabled framework
            # is not loaded, and a disabled dependent must not block a removal.
            enabled_mod_ids=()
            for i in "${!mod_ids[@]}"; do
                [[ "${mod_types[$i]}" != "disabled" ]] && enabled_mod_ids+=("${mod_ids[$i]}")
            done

            # Pre-calculate dependency warnings
            for i in "${!mod_ids[@]}"; do
                local mid="${mod_ids[$i]}"
                local mtype="${mod_types[$i]}"
                local warn=""
                if [[ "$mtype" != "disabled" ]]; then
                    warn="$(check_mod_dependencies "$mid" "${enabled_mod_ids[@]}" 2>/dev/null || true)"
                fi
                mod_warnings+=("$warn")
            done
            
            needs_rebuild=0
        fi
        
        local mod_count=${#mod_ids[@]}
        local total_items=$((mod_count + 5))
        
        [[ $selected -lt 0 ]] && selected=0
        [[ $selected -ge $total_items ]] && selected=$((total_items - 1))
        
        # Draw screen
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        
        # Header bar
        move_to 1 1
        local header_title="Mod Manager - $SELECTED_NAME"
        if [[ $dirty -eq 1 ]]; then
            header_title="Mod Manager - $SELECTED_NAME ${YELLOW}[ SYNC NEEDED ]${RESET}${BG_RED}${WHITE}${BOLD}"
        fi
        printf "%s%s %s%s%s" "$BG_RED" "$WHITE$BOLD" "$header_title" "${ESC}[K" "$RESET"
        
        # Table header
        local table_start=3
        local col_status=2
        local col_type=8
        local col_name=15
        local col_id=$((TERM_COLS - 45))
        local col_wsver=$((TERM_COLS - 32))
        local col_synced=$((TERM_COLS - 15))
        
        move_to $table_start 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        
        move_to $((table_start + 1)) $col_status
        printf "%s%sSTATUS%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_type
        printf "%s%sTYPE%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_name
        printf "%s%sMOD NAME%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_id
        printf "%s%sID%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_wsver
        printf "%s%sWORKSHOP DATE%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_synced
        printf "%s%sSYNCED%s" "$DIM" "$WHITE" "$RESET"
        
        move_to $((table_start + 2)) 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        
        # Mod rows
        local row=$((table_start + 3))
        if [[ $mod_count -eq 0 ]]; then
            move_to $row 1
            printf "%s  (No mods - press A to add)%s" "$DIM" "$RESET"
            row=$((row+1))
        fi
        for i in "${!mod_ids[@]}"; do
            local mid="${mod_ids[$i]}"
            local mname="${mod_names[$i]}"
            local max_name_len=$((col_id - col_name - 2))
            [[ ${#mname} -gt $max_name_len ]] && mname="${mname:0:$((max_name_len-3))}..."
            
            local mtype="${mod_types[$i]}"
            local status_icon type_short
            # Status icon
            case "$mtype" in
                both|client|server) status_icon="✓" ;;
                disabled) status_icon="✗" ;;
            esac
            
            # Type Label formatting
            case "$mtype" in
                both)     type_short="C+S" ;;
                client)   type_short="Cli" ;;
                server)   type_short="Srv" ;;
                disabled) type_short="Off" ;;
            esac
            
            if [[ -n "${mod_warnings[$i]:-}" ]]; then
                status_icon="!"
            fi
            
            
            # Get pre-calculated version info
            local ws_ver="${mod_ws_dates[$i]:--}"
            local sync_ver="${mod_sync_dates[$i]:--}"
            
            # Highlight Logic
            local ws_color="$WHITE"
            local sync_color="$DIM"
            [[ ${mod_update_flags[$i]:-0} -eq 1 ]] && ws_color="$YELLOW" && sync_color="$YELLOW"
            
            # Check for specific reasons
            local reason="${mod_update_reasons[$i]}"
            if [[ "$reason" == *"D"* ]]; then sync_color="$RED"; sync_ver="MISSING LINK"; fi
            if [[ "$reason" == *"M"* ]]; then sync_color="$RED"; sync_ver="MISSING FILE"; fi
            
            move_to $row 1
            if [[ $i -eq $selected ]]; then
                printf "%s%s%s" "$BG_RED" "$WHITE$BOLD" "${ESC}[K"
                move_to $row $col_status
                printf "▶ %s" "$status_icon"
                move_to $row $col_type
                
                # Selected row color logic for Types
                case "$mtype" in
                    both)     printf "[%sC%s+%sS%s]" "$MOD_CL" "$WHITE$BOLD" "$MOD_SV" "$WHITE$BOLD" ;;
                    client)   printf "[%s%s%s]" "$MOD_CL" "$type_short" "$WHITE$BOLD" ;;
                    server)   printf "[%s%s%s]" "$MOD_SV" "$type_short" "$WHITE$BOLD" ;;
                    disabled) printf "[%s]" "$type_short" ;;
                esac
                move_to $row $col_name
                printf "%s" "$mname"
                move_to $row $col_id
                printf "%s" "$mid"
                move_to $row $col_wsver
                printf "%-14s" "${ws_ver:0:14}"
                move_to $row $col_synced
                printf "%-14s" "${sync_ver:0:14}"
                printf "%s" "$RESET"
            else
                local row_color="$RESET"
                local id_color="$DIM"
                
                [[ ${mod_update_flags[$i]:-0} -eq 1 ]] && row_color="$YELLOW"
                [[ -n "${mod_warnings[$i]:-}" ]] && row_color="$YELLOW"
                # Non-synced mods (missing files) should be yellow
                [[ "$sync_ver" == *"MISSING"* ]] && row_color="$YELLOW"
                # Mods with pending type changes should be yellow
                [[ "$pending_sync_mods" == *"$mid"* ]] && row_color="$YELLOW"
                
                if [[ "$mtype" == "disabled" ]]; then
                    row_color="$DARKGRAY"
                    ws_color="$DARKGRAY"
                    sync_color="$DARKGRAY"
                    id_color="$DARKGRAY"
                fi
                
                printf "%s" "$row_color"
                move_to $row $col_status
                if [[ "$mtype" == "disabled" ]]; then
                    printf "  %s%s%s" "$RED" "$status_icon" "$row_color"
                elif [[ -n "${mod_warnings[$i]:-}" ]]; then
                    printf "  %s%s%s" "$YELLOW$BOLD" "$status_icon" "$row_color"
                else
                    printf "  %s%s%s" "$GREEN" "$status_icon" "$row_color"
                fi
                move_to $row $col_type
                case "$mtype" in
                    both)     printf "[%sC%s+%sS%s]%s" "$MOD_CL" "$row_color" "$MOD_SV" "$row_color" "$RESET" ;;
                    client)   printf "[%s%s%s]%s" "$MOD_CL" "$type_short" "$row_color" "$RESET" ;;
                    server)   printf "[%s%s%s]%s" "$MOD_SV" "$type_short" "$row_color" "$RESET" ;;
                    disabled) printf "[%s%s%s]" "$RED" "$type_short" "$row_color" ;;
                esac
                move_to $row $col_name
                printf "%s%s" "$row_color" "$mname"
                move_to $row $col_id
                printf "%s%s%s" "$id_color" "$mid" "$row_color"
                move_to $row $col_wsver
                
                # Truncate dates to fit
                local d_ws="${ws_ver:0:14}"
                local d_sync="${sync_ver:0:14}"
                printf "%s%-14s%s" "$ws_color" "$d_ws" "$row_color"
                move_to $row $col_synced
                printf "%s%-14s%s" "$sync_color" "$d_sync" "$row_color"
                printf "%s" "$RESET"
            fi
            row=$((row+1))
        done
        
        # Separator
        move_to $row 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        row=$((row + 1))
        
        # Action bar
        local action_row=$row
        local sys_time
        sys_time=$(date +"%H:%M:%S")
        local actions=("[A] Add" "[R] Remove" "[S] Sync" "[F] FixMods" "[I] Info" "[Q] Back")
        
        move_to $action_row $((TERM_COLS - 20))
        printf "%s%s[ %s ]%s" "$DIM" "$WHITE" "$sys_time" "$RESET"
        
        move_to $action_row 2
        for a in "${!actions[@]}"; do
            local action_idx=$((mod_count + a))
            local action_label="${actions[$a]}"
            
            # Highlight Sync button in yellow when dirty
            if [[ "$action_label" == "[S] Sync" && $dirty -eq 1 ]]; then
                action_label="[!S] Sync"
            fi
            
            if [[ $selected -eq $action_idx ]]; then
                if [[ "$action_label" == "[!S] Sync" ]]; then
                    printf "%s%s▶ %s %s" "$BG_YELLOW" "$BLACK$BOLD" "$action_label" "$RESET"
                else
                    printf "%s%s▶ %s %s" "$BG_RED" "$WHITE$BOLD" "$action_label" "$RESET"
                fi
            else
                if [[ "$action_label" == "[!S] Sync" ]]; then
                    printf "  %s%s%s " "$YELLOW$BOLD" "$action_label" "$RESET"
                else
                    printf "  %s " "$action_label"
                fi
            fi
            printf " "
        done
        
        # Footer warning
        move_to $((TERM_ROWS-1)) 1
        if [[ $selected -lt $mod_count ]]; then
            local sel_mid="${mod_ids[$selected]}"
            # Warnings were computed once during the rebuild; no python per keypress
            local sel_warn="${mod_warnings[$selected]:-}"
            if [[ -n "$sel_warn" ]]; then
                printf "%s%s WARN: %s %s%s" "$BG_RED" "$WHITE$BOLD" "$sel_warn" "${ESC}[K" "$RESET"
            else
                printf "%s" "${ESC}[2K"
            fi
        else
            printf "%s" "${ESC}[2K"
        fi

        move_to $TERM_ROWS 1
        move_to $TERM_ROWS 1
        printf "%s%s [↑↓] Select  [U/D] Move  [Enter] Toggle  [A] Add  [R] Remove  [S] Sync  [F] Fix  [Space] Info  [Q] Back%s%s" "$BG_DARKGRAY" "$WHITE" "${ESC}[K" "$RESET"
        
        # Read input (EOF, e.g. closed stdin, leaves the menu instead of looping)
        IFS= read -rsn1 key || return 0
        
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') if ((selected > 0)); then selected=$((selected-1)); fi ;;
                    '[B') if ((selected < total_items - 1)); then selected=$((selected+1)); fi ;;
                esac
                ;;
            'u'|'U'|'+')
                if [[ $selected -gt 0 && $selected -lt $mod_count ]]; then
                    local mid="${mod_ids[$selected]}"
                    move_mod_up "$mid" "$mods_file" "$servermods_file"
                    selected=$((selected - 1))
                    dirty=1; needs_rebuild=1; touch "$needs_sync_file"
                fi
                continue
                ;;
            'd'|'D'|'-')
                if [[ $selected -lt $((mod_count - 1)) ]]; then
                    local mid="${mod_ids[$selected]}"
                    move_mod_down "$mid" "$mods_file" "$servermods_file"
                    selected=$((selected + 1))
                    dirty=1; needs_rebuild=1; touch "$needs_sync_file"
                fi
                continue
                ;;

            'a'|'A')
                local new_id
                new_id=$(read_input "Enter Steam Workshop ID:" "" "Add Workshop Mod")
                if [[ "$new_id" =~ ^[0-9]+$ ]]; then
                    if ! is_mod_in_file "$new_id" "$mods_file" && ! is_mod_in_file "$new_id" "$servermods_file"; then
                        # Show details first
                        _view_mod_details "$new_id" "$SELECTED_DIR" "$mods_file" "${SCRIPT_DIR}/data/workshop_rules.json"
                        if [[ $? -eq 10 ]]; then
                            add_mod_to_file "$new_id" "$mods_file"
                            show_message "Added mod $new_id as [Client]" "Mod Added"
                            dirty=1; needs_rebuild=1; touch "$needs_sync_file"
                        fi
                    else
                        show_message "Mod already in list" "Already Exists"
                    fi
                fi
                ;;
            'r'|'R')
                if [[ $selected -lt $mod_count ]]; then
                    if _mod_manager_remove_mod "${mod_ids[$selected]}"; then
                        dirty=1; needs_rebuild=1; touch "$needs_sync_file"
                        [[ $selected -ge $((mod_count - 1)) ]] && selected=$((selected - 1))
                        [[ $selected -lt 0 ]] && selected=0
                    fi
                fi
                ;;
            '')  # Enter
                if [[ $selected -lt $mod_count ]]; then
                    local mid="${mod_ids[$selected]}"
                    local mtype="${mod_types[$selected]}"
                    case "$mtype" in
                        disabled) add_mod_to_file "$mid" "$mods_file" ;;
                        client) remove_mod_from_file "$mid" "$mods_file"; add_mod_to_file "$mid" "$servermods_file" ;;
                        server) add_mod_to_file "$mid" "$mods_file"; add_mod_to_file "$mid" "$servermods_file" ;;
                        both) remove_mod_from_file "$mid" "$mods_file"; remove_mod_from_file "$mid" "$servermods_file" ;;
                    esac
                    dirty=1; needs_rebuild=1; touch "$needs_sync_file"
                    append_line "$pending_mods_file" "$mid"
                    pending_sync_mods="$pending_sync_mods $mid"
                elif [[ $selected -eq $mod_count ]]; then
                    # Add
                    local new_id
                    new_id=$(read_input "Enter Steam Workshop ID:" "" "Add Workshop Mod")
                    if [[ "$new_id" =~ ^[0-9]+$ ]]; then
                        if ! is_mod_in_file "$new_id" "$mods_file" && ! is_mod_in_file "$new_id" "$servermods_file"; then
                            # Show details first
                            _view_mod_details "$new_id" "$SELECTED_DIR" "$mods_file" "${SCRIPT_DIR}/data/workshop_rules.json"
                            if [[ $? -eq 10 ]]; then
                                add_mod_to_file "$new_id" "$mods_file"
                                show_message "Added mod $new_id as [Client]" "Mod Added"
                                dirty=1; needs_rebuild=1; touch "$needs_sync_file"
                            fi
                        else
                            show_message "Mod already in list" "Already Exists"
                        fi
                    fi
                elif [[ $selected -eq $((mod_count + 1)) ]]; then
                    # Remove: while the cursor sits on the action bar no mod is
                    # highlighted, so let the user pick one from a list.
                    if [[ $mod_count -gt 0 ]] && _mod_manager_pick_mod "Remove which mod?"; then
                        if _mod_manager_remove_mod "${mod_ids[$MENU_RESULT]}"; then
                            dirty=1; needs_rebuild=1; touch "$needs_sync_file"
                            # The list shrinks by one, keep the cursor on this button
                            selected=$((selected - 1))
                        fi
                    fi
                elif [[ $selected -eq $((mod_count + 2)) ]]; then
                    # Sync
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" != "RUNNING" ]]; then
                        show_message "Container must be running to sync"
                    else
                        run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods; /dayz/run.sh sync-servermods"
                        dirty=0; rm -f "$needs_sync_file" "$pending_mods_file"; pending_sync_mods=""
                        needs_rebuild=1
                        # Refresh update cache after sync with progress bar
                        show_progress_start "Sync" "Refreshing update cache..."
                        show_progress_update "Checking mod versions..." 50
                        check_all_mod_updates "$SELECTED_DIR" "${SELECTED_DIR}/serverfiles/steamapps/workshop/content/221100" "${SELECTED_DIR}/data/config/mods.txt" "${SELECTED_DIR}/data/config/servermods.txt" >/dev/null 2>&1 || true
                        show_progress_end "Sync complete!" 300
                    fi
                elif [[ $selected -eq $((mod_count + 3)) ]]; then
                    # FixMods
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" != "RUNNING" ]]; then
                        show_message "Container must be running to fix mods"
                    else
                        run_with_output "Fixing Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods; /dayz/run.sh sync-servermods"
                    fi
                elif [[ $selected -eq $((mod_count + 4)) ]]; then
                    # Info: same as Remove, pick the mod from a list
                    if [[ $mod_count -gt 0 ]] && _mod_manager_pick_mod "Show info for which mod?"; then
                        _view_mod_details "${mod_ids[$MENU_RESULT]}" "$SELECTED_DIR" "$mods_file" "${SCRIPT_DIR}/data/workshop_rules.json"
                        needs_rebuild=1
                    fi
                elif [[ $selected -eq $((mod_count + 5)) ]]; then
                    return 0
                fi
                ;;
            'i'|'I'|' ')
                if [[ $selected -lt $mod_count ]]; then
                    local mid="${mod_ids[$selected]}"
                    _view_mod_details "$mid" "$SELECTED_DIR" "$mods_file" "${SCRIPT_DIR}/data/workshop_rules.json"
                    needs_rebuild=1
                fi
                ;;
            'q'|'Q')
                if [[ $dirty -eq 1 ]]; then
                    if confirm "Sync is pending! Leave without syncing?" "n"; then
                        return 0
                    fi
                else
                    return 0
                fi
                ;;

            's'|'S')
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to sync"
                else
                    run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods; /dayz/run.sh sync-servermods"
                    dirty=0; rm -f "$needs_sync_file" "$pending_mods_file"; pending_sync_mods=""
                    needs_rebuild=1
                    
                    # Progress bar for post-sync operations
                    show_progress_start "Sync" "Refreshing update cache..."
                    local workshop_path="${SELECTED_DIR}/data/serverfiles/steamapps/workshop/content/221100"
                    if [[ ! -d "$workshop_path" ]]; then workshop_path="${SELECTED_DIR}/serverfiles/steamapps/workshop/content/221100"; fi
                    
                    show_progress_update "Checking mod versions..." 30
                    check_all_mod_updates "$SELECTED_DIR" "$workshop_path" "${SELECTED_DIR}/data/config/mods.txt" "${SELECTED_DIR}/data/config/servermods.txt" >/dev/null 2>&1 || true
                    
                    # Offer to activate the CE files the synced mods ship
                    show_progress_update "Scanning CE files..." 60
                    local -a ce_mod_ids ce_mod_names ce_file_paths ce_filenames ce_types
                    scan_new_ce_files "$SELECTED_DIR" "$workshop_path"
                    show_progress_end "Sync complete!" 300
                    ce_link_files_dialog "$SELECTED_DIR" "Link CE Files - $SELECTED_NAME"
                fi
                ;;
            'f'|'F')
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to fix mods"
                else
                    run_with_output "Fixing Mod Casing & Keys" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh fix-mods && /dayz/run.sh fix-servermods"
                fi
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