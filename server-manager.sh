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
for lib in colors tui menu dialogs utils docker instance mods config mod_config types workshop; do
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
mod_manager() {
    local mods_file="${SELECTED_DIR}/data/config/mods.txt"
    local servermods_file="${SELECTED_DIR}/data/config/servermods.txt"
    
    [[ -f "$mods_file" ]] || touch "$mods_file"
    [[ -f "$servermods_file" ]] || touch "$servermods_file"
    
    local selected=0
    local dirty=0
    
    local needs_rebuild=1
    local -a mod_ids=()
    local -a mod_names=()
    local -a mod_types=()
    local -a mod_warnings=()
    
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
            # Pass IDs on a separate line or via env to avoid quoting hell
            mod_versions=()
            mod_update_flags=()
            
            while IFS='|' read -r v_disp has_up; do
                [[ -z "$v_disp" ]] && continue
                mod_versions+=("$v_disp")
                mod_update_flags+=("$has_up")
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

ws_dir = ws_path1
if not os.path.exists(ws_dir) and os.path.exists(ws_path2):
    ws_dir = ws_path2

try:
    data = json.loads(cache_json) if cache_json else {}
    mods_info = data.get('mods', {})
    
    def fmt(ts):
        if not ts or ts == 0: return '-'
        return datetime.datetime.fromtimestamp(ts).strftime('%d. %b %Y %H:%M')
    
    for mid in mod_ids:
        if not mid: continue
        m = mods_info.get(mid, {})
        m_path = os.path.join(ws_dir, mid)
        local_v = 0
        if os.path.exists(m_path):
            v_file = os.path.join(m_path, '.installed_version')
            if os.path.exists(v_file):
                try: 
                    with open(v_file) as f: local_v = int(f.read().strip())
                except: local_v = int(os.path.getmtime(m_path))
            else:
                local_v = int(os.path.getmtime(m_path))
        
        # Deployment Check: Verify mod link in server root
        is_deployed = False
        if ws_dir:
            try:
                # serverfiles/steamapps/workshop/content/221100 -> serverfiles/
                # Check 1: Standard relative path
                check_roots = []
                p1 = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(ws_dir))))
                check_roots.append(p1)
                
                # Check 2: Explicit 'serverfiles' heuristic for odd layouts
                if 'serverfiles' in ws_dir:
                    parts = ws_dir.split(os.sep)
                    if 'serverfiles' in parts:
                        idx = parts.index('serverfiles')
                        p2 = os.sep.join(parts[:idx+1])
                        check_roots.append(p2)
                
                for r in check_roots:
                    # DEBUG: sys.stderr.write(f"DEBUG_CHECK: {os.path.join(r, f'@{mid}')}\n")
                    # Use lexists because symlinks might be absolute paths valid only inside container
                    # and thus 'broken' on the host, but the link itself EXISTS.
                    if os.path.lexists(os.path.join(r, f'@{mid}')):
                        is_deployed = True
                        break
            except: pass

        remote_v = m.get('updated', 0)
        if remote_v == 0: remote_v = m.get('latest', 0)
        
        # DEBUG: Add specific codes to know WHY
        reason = ''
        if (remote_v > local_v): reason += 'U'
        if (local_v == 0): reason += 'M'
        if (not is_deployed): reason += 'D'
        
        has_update = (len(reason) > 0)
        
        v = fmt(local_v)
        if has_update: v = f'NEED SYNC ({reason})'
        print(f'{v}|{1 if has_update else 0}')
except Exception as e:
    # DEBUG: sys.stderr.write(f"ERROR: {e}\n")
    for _ in mod_ids: print('NEED SYNC (Err)|1')
END_PYTHON
            )
            
            # Global sync flag
            global_sync_needed=0
            for flag in "${mod_update_flags[@]}"; do
                [[ "$flag" -eq 1 ]] && { global_sync_needed=1; break; }
            done
            
            # Pre-calculate dependency warnings
            for i in "${!mod_ids[@]}"; do
                local mid="${mod_ids[$i]}"
                local mtype="${mod_types[$i]}"
                local warn=""
                if [[ "$mtype" != "disabled" ]]; then
                    warn="$(check_mod_dependencies "$mid" "${mod_ids[@]}" 2>/dev/null || true)"
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
        [[ ${global_sync_needed:-0} -eq 1 ]] && header_title="$header_title ${YELLOW}[ SYNC NEEDED ]${RESET}${BG_RED}${WHITE}${BOLD}"
        printf "%s%s %s%s%s" "$BG_RED" "$WHITE$BOLD" "$header_title" "${ESC}[K" "$RESET"
        
        # Table header
        local table_start=3
        local col_status=2
        local col_version=10
        local col_name=33
        local col_id=$((TERM_COLS - 25))
        local col_type=$((TERM_COLS - 10))
        
        move_to $table_start 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        
        move_to $((table_start + 1)) $col_status
        printf "%s%sSTATUS%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_version
        printf "%s%sVERSION%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_name
        printf "%s%sMOD NAME%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_id
        printf "%s%sWORKSHOP ID%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_type
        printf "%s%sTYPE%s" "$DIM" "$WHITE" "$RESET"
        
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
            local status_icon type_label type_short
            case "$mtype" in
                both)     status_icon="✓"; type_label="[C+S]"; type_short="C+S" ;;
                client)   status_icon="✓"; type_label="[Cli]"; type_short="Cli" ;;
                server)   status_icon="✓"; type_label="[Srv]"; type_short="Srv" ;;
                disabled) status_icon="✗"; type_label="[Off]"; type_short="Off" ;;
            esac
            
            if [[ -n "${mod_warnings[$i]:-}" ]]; then
                status_icon="⚠️"
            fi
            
            # Get pre-calculated version info
            local version_display="${mod_versions[$i]:--}"
            local version_color="$WHITE"
            [[ ${mod_update_flags[$i]:-0} -eq 1 ]] && version_color="$YELLOW"
            
            move_to $row 1
            if [[ $i -eq $selected ]]; then
                printf "%s%s%s" "$BG_RED" "$WHITE$BOLD" "${ESC}[K"
                move_to $row $col_status
                printf "▶ %s" "$status_icon"
                move_to $row $col_version
                printf "%-22s" "${version_display:0:22}"
                move_to $row $col_name
                printf "%s" "$mname"
                move_to $row $col_id
                printf "%s" "$mid"
                move_to $row $col_type
                printf "[%s]" "$type_short"
                printf "%s" "$RESET"
            else
                local row_color="$RESET"
                [[ ${mod_update_flags[$i]:-0} -eq 1 ]] && row_color="$YELLOW"
                
                printf "%s" "$row_color"
                move_to $row $col_status
                if [[ "$mtype" == "disabled" ]]; then
                    printf "  %s%s%s" "$RED" "$status_icon" "$row_color"
                else
                    printf "  %s%s%s" "$GREEN" "$status_icon" "$row_color"
                fi
                move_to $row $col_version
                printf "%-22s" "${version_display:0:22}"
                move_to $row $col_name
                printf "%s" "$mname"
                move_to $row $col_id
                printf "%s%s%s" "$DIM" "$mid" "$row_color"
                move_to $row $col_type
                case "$mtype" in
                    both)     printf "%s%s%s" "$GREEN" "$type_label" "$row_color" ;;
                    client)   printf "%s%s%s" "$YELLOW" "$type_label" "$row_color" ;;
                    server)   printf "%s%s%s" "$YELLOW" "$type_label" "$row_color" ;;
                    disabled) printf "%s%s%s" "$RED" "$type_label" "$row_color" ;;
                esac
                printf "%s" "$RESET"
            fi
            row=$((row+1))
        done
        
        # Separator
        move_to $row 1
        printf "%s%s%s%s" "$DIM" "$RED" "${ESC}[K" "$RESET"
        printf "%.0s-" $(seq 1 $TERM_COLS)
        printf "%s" "$RESET"
        ((row++))
        
        # Action bar
        local action_row=$row
        local actions=("[A] Add" "[R] Remove" "[S] Sync" "[F] FixMods" "[Q] Back")
        
        move_to $action_row 2
        for a in "${!actions[@]}"; do
            local action_idx=$((mod_count + a))
            if [[ $selected -eq $action_idx ]]; then
                printf "%s%s▶ %s %s" "$BG_RED" "$WHITE$BOLD" "${actions[$a]}" "$RESET"
            else
                printf "  %s " "${actions[$a]}"
            fi
            printf "  "
        done
        
        # Footer warning
        move_to $((TERM_ROWS-1)) 1
        if [[ $selected -lt $mod_count ]]; then
            local sel_mid="${mod_ids[$selected]}"
            local sel_warn
            sel_warn="$(check_mod_dependencies "$sel_mid" "${mod_ids[@]}" || true)"
            if [[ -n "$sel_warn" ]]; then
                printf "%s%s WARN: %s %s%s" "$BG_RED" "$WHITE$BOLD" "$sel_warn" "${ESC}[K" "$RESET"
            else
                printf "%s" "${ESC}[2K"
            fi
        else
            printf "%s" "${ESC}[2K"
        fi

        move_to $TERM_ROWS 1
        printf "%s%s ↑↓ Select  U/D Move  Enter Toggle  [A] Add  [R] Remove  [S] Sync  [F] FixMods  [Q] Back%s%s" "$BG_DARKGRAY" "$WHITE" "${ESC}[K" "$RESET"
        
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
            'u'|'U'|'+')
                if [[ $selected -gt 0 && $selected -lt $mod_count ]]; then
                    local mid="${mod_ids[$selected]}"
                    move_mod_up "$mid" "$mods_file" "$servermods_file"
                    selected=$((selected - 1))
                    dirty=1; needs_rebuild=1
                fi
                continue
                ;;
            'd'|'D'|'-')
                if [[ $selected -lt $((mod_count - 1)) ]]; then
                    local mid="${mod_ids[$selected]}"
                    move_mod_down "$mid" "$mods_file" "$servermods_file"
                    selected=$((selected + 1))
                    dirty=1; needs_rebuild=1
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
                            echo "$new_id" >> "$mods_file"
                            show_message "Added mod $new_id as [Client]" "Mod Added"
                            dirty=1; needs_rebuild=1
                        fi
                    else
                        show_message "Mod already in list" "Already Exists"
                    fi
                fi
                ;;
            'r'|'R')
                if [[ $selected -lt $mod_count ]]; then
                    local mid="${mod_ids[$selected]}"
                    local mname=$(get_mod_name "$mid")
                    
                    if confirm "Remove mod '$mname' from list?" "n"; then
                        # Paths for key cleanup
                        local server_keys="${SELECTED_DIR}/data/serverfiles/keys"
                        local workshop_base="${SELECTED_DIR}/data/serverfiles/steamapps/workshop/content/221100"
                        
                        local removed_keys
                        removed_keys=$(uninstall_mod "$mid" "$mods_file" "$servermods_file" "$server_keys" "$workshop_base")
                        show_message "Removed: $mname ($removed_keys keys deleted)" "Removed"
                        dirty=1; needs_rebuild=1
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
                    dirty=1; needs_rebuild=1
                elif [[ $selected -eq $mod_count ]]; then
                    # Add
                    local new_id
                    new_id=$(read_input "Enter Steam Workshop ID:" "" "Add Workshop Mod")
                    if [[ "$new_id" =~ ^[0-9]+$ ]]; then
                        if ! is_mod_in_file "$new_id" "$mods_file" && ! is_mod_in_file "$new_id" "$servermods_file"; then
                            # Show details first
                            _view_mod_details "$new_id" "$SELECTED_DIR" "$mods_file" "${SCRIPT_DIR}/data/workshop_rules.json"
                            if [[ $? -eq 10 ]]; then
                                echo "$new_id" >> "$mods_file"
                                show_message "Added mod $new_id as [Client]" "Mod Added"
                                dirty=1; needs_rebuild=1
                            fi
                        else
                            show_message "Mod already in list" "Already Exists"
                        fi
                    fi
                elif [[ $selected -eq $((mod_count + 1)) ]]; then
                    # Remove
                    if [[ $selected -lt $mod_count ]]; then
                        local mid="${mod_ids[$selected]}"
                        local mname=$(get_mod_name "$mid")
                        if confirm "Remove mod '$mname' from list?" "n"; then
                            removed_keys=$(uninstall_mod "$mid" "$mods_file" "$servermods_file" "${SELECTED_DIR}/data/serverfiles/keys" "${SELECTED_DIR}/data/serverfiles/steamapps/workshop/content/221100")
                            show_message "Removed: $mname" "Success"
                            dirty=1; needs_rebuild=1
                        fi
                    else
                        show_message "Select a mod to remove first" "Info"
                    fi
                elif [[ $selected -eq $((mod_count + 2)) ]]; then
                    # Sync
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" != "RUNNING" ]]; then
                        show_message "Container must be running to sync"
                    else
                        run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
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
                        run_with_output "Fixing Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                    fi
                elif [[ $selected -eq $((mod_count + 4)) ]]; then
                    return
                fi
                ;;
            'q'|'Q')
                return 0
                ;;

            's'|'S')
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to sync"
                else
                    run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                    
                    # Progress bar for post-sync operations
                    show_progress_start "Sync" "Refreshing update cache..."
                    local workshop_path="${SELECTED_DIR}/data/serverfiles/steamapps/workshop/content/221100"
                    if [[ ! -d "$workshop_path" ]]; then workshop_path="${SELECTED_DIR}/serverfiles/steamapps/workshop/content/221100"; fi
                    
                    show_progress_update "Checking mod versions..." 30
                    check_all_mod_updates "$SELECTED_DIR" "$workshop_path" "${SELECTED_DIR}/data/config/mods.txt" "${SELECTED_DIR}/data/config/servermods.txt" >/dev/null 2>&1 || true
                    
                    # Scan for CE files (Phase 3-4)
                    show_progress_update "Scanning CE files..." 60
                    local ce_result
                    ce_result=$(scan_dayz_ce_files_python "$SELECTED_DIR" "$workshop_path" 2>/dev/null | tail -n 1)

                    # Load ignore list
                    local ignore_file
                    ignore_file=$(get_ce_ignore_file "$SELECTED_DIR" 2>/dev/null || echo "")
                    local ignored_list=""
                    if [[ -f "$ignore_file" ]]; then
                        ignored_list=$(python3 -c "
import json
try:
    with open('$ignore_file', 'r') as f:
        data = json.load(f)
    for item in data.get('ignored', []):
        print(item.lower())
except: pass
" 2>/dev/null)
                    fi

                    # Count new CE files (excluding ignored)
                    local new_ce_count
                    if [[ -z "$ce_result" ]]; then
                         new_ce_count=0
                    else
                         # Count NEW or UNLINKED files that aren't ignored
                         new_ce_count=$(echo "$ce_result" | python3 -c "
import json, sys
ignored_raw = '''$ignored_list'''
ignored = set(x.strip().lower() for x in ignored_raw.strip().split('\n') if x.strip())
try:
    d = json.load(sys.stdin)
    count = 0
    for x in d:
        if x.get('status') in ['new', 'unlinked']:
            key = f\"{x['mod_id']}|{x['filename']}\".lower()
            if key not in ignored:
                count += 1
    print(count)
except: print(0)
" 2>/dev/null || echo "0")
                    fi
                    
                    # Complete progress bar
                    show_progress_end "Sync complete!" 300
                    
                    if [[ "$new_ce_count" -gt 0 ]]; then
                        # Build arrays of new CE files for checklist (excluding ignored)
                        local -a ce_mod_ids=()
                        local -a ce_mod_names=()
                        local -a ce_file_paths=()
                        local -a ce_filenames=()
                        local -a ce_types=()
                        local -a ce_selected=()
                        
                        while IFS='|' read -r mid mname fpath fname cetype; do
                            [[ -z "$mid" ]] && continue
                            ce_mod_ids+=("$mid")
                            ce_mod_names+=("$mname")
                            ce_file_paths+=("$fpath")
                            ce_filenames+=("$fname")
                            ce_types+=("$cetype")
                            ce_selected+=(1)  # Pre-selected by default
                        done < <(echo "$ce_result" | python3 -c "
import json, sys
ignored_raw = '''$ignored_list'''
ignored = set(x.strip().lower() for x in ignored_raw.strip().split('\n') if x.strip())
try:
    data = json.load(sys.stdin)
    for x in data:
        if x.get('status') in ['new', 'unlinked']:
            mid = x['mod_id']
            fname = x['filename']
            key = f'{mid}|{fname}'.lower()
            if key not in ignored:
                mname = x.get('mod_name', mid)
                fpath = x['file_path']
                cetype = x['ce_type']
                print(f'{mid}|{mname}|{fpath}|{fname}|{cetype}')
except: pass
" 2>/dev/null)
                        
                        local ce_count=${#ce_filenames[@]}
                        if [[ $ce_count -gt 0 ]]; then
                            local selection=0
                            
                            while true; do
                                draw_header "Link CE Files - $SELECTED_NAME"
                                
                                # Build menu items with checkboxes (column-aligned)
                                local -a items=()
                                for ((i=0; i<ce_count; i++)); do
                                    local check=" "
                                    [[ ${ce_selected[$i]} -eq 1 ]] && check="x"
                                    # Format CE type for display
                                    local type_label
                                    case "${ce_types[$i]}" in
                                        types)          type_label="[TYPES]" ;;
                                        spawnabletypes) type_label="[SPAWNABLE]" ;;
                                        events)         type_label="[EVENTS]" ;;
                                        eventspawns)   type_label="[EVENTPOS]" ;;
                                        *)              type_label="[OTHER]" ;;
                                    esac
                                    items+=("[$check] ${ce_mod_names[$i]} $type_label - ${ce_filenames[$i]}")
                                done
                                
                                items+=("--------------------")
                                items+=("✅|LINK SELECTED FILES")
                                items+=("❌|Cancel / Skip All")
                                
                                if run_menu items "Toggle files with Enter, then Execute" $selection; then
                                    selection=$MENU_RESULT
                                    if [[ $selection -lt $ce_count ]]; then
                                        # Toggle selection
                                        ce_selected[$selection]=$((1 - ce_selected[$selection]))
                                    elif [[ $selection -eq $((ce_count + 1)) ]]; then
                                        # Execute linking
                                        local link_count=0
                                        for ((i=0; i<ce_count; i++)); do
                                            if [[ ${ce_selected[$i]} -eq 1 ]]; then
                                                register_modular_loot "$SELECTED_DIR" "${ce_file_paths[$i]}" "${ce_mod_ids[$i]}" 1 "${ce_types[$i]}"
                                                ((link_count++))
                                            fi
                                        done
                                        [[ $link_count -gt 0 ]] && show_message "Linked $link_count CE file(s)!" "Success"
                                        break
                                    elif [[ $selection -eq $((ce_count + 2)) ]]; then
                                        # Cancel
                                        break
                                    fi
                                else
                                    break
                                fi
                            done
                        fi
                    fi
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
        if [[ -n "$update_summary" ]]; then
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
            "📁|Mod Configs"
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
            "🔄|Restart Server") run_with_output "Restarting Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose restart" ;;
            "⚒️|Mod Manager") mod_manager || true ;;
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
            "📁|Mod Configs")
                local profile_dir="${SELECTED_DIR}/data/profile"
                mod_config_browser "$profile_dir" || true
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