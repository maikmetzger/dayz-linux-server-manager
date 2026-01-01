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
    
    while true; do
        
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
                local max_name=$((TERM_COLS - 35))
                [[ $max_name -lt 20 ]] && max_name=20
                [[ ${#mname} -gt $max_name ]] && mname="${mname:0:$((max_name-3))}..."
                mod_names+=("$mname")
                
                local mtype
                mtype="$(get_mod_type "$mid" "$mods_file" "$servermods_file")"
                mod_types+=("$mtype")
            done < <(get_all_mod_ids "$mods_file" "$servermods_file")
            
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
        local total_items=$((mod_count + 6))
        
        [[ $selected -lt 0 ]] && selected=0
        [[ $selected -ge $total_items ]] && selected=$((total_items - 1))
        
        # Draw screen
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        
        # Header bar
        move_to 1 1
        printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Mod Manager - $SELECTED_NAME" "$RESET"
        
        # Table header
        local table_start=3
        local col_status=2
        local col_version=10
        local col_name=26
        local col_id=$((TERM_COLS - 25))
        local col_type=$((TERM_COLS - 10))
        
        move_to $table_start 1
        printf "%s%s" "$DIM" "$RED"
        printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
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
        printf "%s%s" "$DIM" "$RED"
        printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
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
            
            # Get version info for this mod
            local version_display
            version_display=$(get_mod_version_info "$SELECTED_DIR" "$mid" 2>/dev/null || echo "-")
            local version_color="$WHITE"
            if get_mod_update_status "$SELECTED_DIR" "$mid" 2>/dev/null; then
                version_color="$YELLOW"
            fi
            
            move_to $row 1
            if [[ $i -eq $selected ]]; then
                printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
                move_to $row $col_status
                printf "▶ %s" "$status_icon"
                move_to $row $col_version
                printf "%-14s" "${version_display:0:14}"
                move_to $row $col_name
                printf "%s" "$mname"
                move_to $row $col_id
                printf "%s" "$mid"
                move_to $row $col_type
                printf "[%s]" "$type_short"
                printf "%s" "$RESET"
            else
                move_to $row $col_status
                if [[ "$mtype" == "disabled" ]]; then
                    printf "  %s%s%s" "$RED" "$status_icon" "$RESET"
                else
                    printf "  %s%s%s" "$GREEN" "$status_icon" "$RESET"
                fi
                move_to $row $col_version
                printf "%s%-14s%s" "$version_color" "${version_display:0:14}" "$RESET"
                move_to $row $col_name
                printf "%s" "$mname"
                move_to $row $col_id
                printf "%s%s%s" "$DIM" "$mid" "$RESET"
                move_to $row $col_type
                case "$mtype" in
                    both)     printf "%s%s%s" "$GREEN" "$type_label" "$RESET" ;;
                    client)   printf "%s%s%s" "$YELLOW" "$type_label" "$RESET" ;;
                    server)   printf "%s%s%s" "$YELLOW" "$type_label" "$RESET" ;;
                    disabled) printf "%s%s%s" "$RED" "$type_label" "$RESET" ;;
                esac
            fi
            row=$((row+1))
        done
        
        # Separator
        move_to $row 1
        printf "%s%s" "$DIM" "$RED"
        printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        ((row++))
        
        # Action bar
        local action_row=$row
        local actions=("[A] Add" "[R] Remove" "[W] Workshop" "[S] Sync" "[F] FixMods" "[Q] Back")
        
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
                printf "%s%s WARN: %s %s" "$BG_RED" "$WHITE$BOLD" "$sel_warn" "$RESET"
            else
                printf "%s" "$CLEAR_LINE"
            fi
        fi

        move_to $TERM_ROWS 1
        printf "%s%s ↑↓ Select  U/D Move  Enter Toggle  [A] Add  [R] Remove  [S] Sync  [F] FixMods  [Q] Back%*s%s" "$BG_DARKGRAY" "$WHITE" "$((TERM_COLS - 90))" "" "$RESET"
        
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
            'w'|'W')
                workshop_browser "$SELECTED_DIR"
                needs_rebuild=1
                ;;
            'a'|'A')
                local new_id
                new_id=$(read_input "Enter Steam Workshop ID:" "" "Add Workshop Mod")
                if [[ "$new_id" =~ ^[0-9]+$ ]]; then
                    if ! is_mod_in_file "$new_id" "$mods_file" && ! is_mod_in_file "$new_id" "$servermods_file"; then
                        echo "$new_id" >> "$mods_file"
                        show_message "Added mod $new_id as [Client]" "Mod Added"
                        dirty=1; needs_rebuild=1
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
                            echo "$new_id" >> "$mods_file"
                            show_message "Added mod $new_id as [Client]" "Mod Added"
                            dirty=1; needs_rebuild=1
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
                    # Workshop
                    workshop_browser "$SELECTED_DIR"
                    needs_rebuild=1
                elif [[ $selected -eq $((mod_count + 3)) ]]; then
                    # Sync
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" != "RUNNING" ]]; then
                        show_message "Container must be running to sync"
                    else
                        run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                        # Refresh update cache after sync
                        show_message "Refreshing update cache..." "Sync"
                        check_all_mod_updates "$SELECTED_DIR" "${SELECTED_DIR}/serverfiles/steamapps/workshop/content/221100" "${SELECTED_DIR}/data/config/mods.txt" "${SELECTED_DIR}/data/config/servermods.txt" >/dev/null 2>&1 || true
                    fi
                elif [[ $selected -eq $((mod_count + 4)) ]]; then
                    # FixMods
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" != "RUNNING" ]]; then
                        show_message "Container must be running to fix mods"
                    else
                        run_with_output "Fixing Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                    fi
                elif [[ $selected -eq $((mod_count + 5)) ]]; then
                    return
                fi
                ;;
            'q'|'Q')
                return 0
                ;;
            'w'|'W')
                workshop_browser "$SELECTED_DIR"
                needs_rebuild=1
                ;;
            's'|'S')
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to sync"
                else
                    run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                    
                    # Refresh update cache after sync
                    show_message "Refreshing update cache..." "Sync"
                    check_all_mod_updates "$SELECTED_DIR" "${SELECTED_DIR}/serverfiles/steamapps/workshop/content/221100" "${SELECTED_DIR}/data/config/mods.txt" "${SELECTED_DIR}/data/config/servermods.txt" >/dev/null 2>&1 || true
                    
                    # Scan for CE files (Phase 3-4)
                    local ce_result
                    echo "DEBUG: Running scan on $SELECTED_DIR" > "${SELECTED_DIR}/debug_post_sync.log"
                    ce_result=$(scan_dayz_ce_files_python "$SELECTED_DIR" "${SELECTED_DIR}/serverfiles/steamapps/workshop/content/221100" | tail -n 1)
                    
                    echo "DEBUG: CE Result raw: '$ce_result'" >> "${SELECTED_DIR}/debug_post_sync.log"

                    # Count new CE files
                    local new_ce_count
                    if [[ -z "$ce_result" ]]; then
                         new_ce_count=0
                         echo "DEBUG: Empty result!" >> "${SELECTED_DIR}/debug_post_sync.log"
                    else
                         new_ce_count=$(echo "$ce_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for x in d if x.get('status')=='new'))" 2>> "${SELECTED_DIR}/debug_post_sync.log" || echo "0")
                    fi
                    
                    echo "DEBUG: New Count: $new_ce_count" >> "${SELECTED_DIR}/debug_post_sync.log"
                    
                    show_message "Debug: Check debug_post_sync.log (Count: $new_ce_count)" "Debug"
                    
                    if [[ "$new_ce_count" -gt 0 ]]; then
                        # Ask user if they want to link new CE files
                        if confirm "Found ${new_ce_count} new CE file(s) from mods. Link them now?" "y"; then
                            # Process each new CE file
                            local mission_path
                            mission_path=$(get_mission_path "$SELECTED_DIR" 2>/dev/null)
                            
                            echo "$ce_result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data:
    if item.get('status') == 'new':
        print(f\"{item['mod_id']}|{item['file_path']}|{item['filename']}|{item['ce_type']}\")
" | while IFS='|' read -r mod_id file_path filename ce_type; do
                                [[ -z "$mod_id" ]] && continue
                                
                                # Ask for each file
                                printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
                                move_to 1 1
                                printf "%s%s New CE File Found %s\n" "$BG_RED" "$WHITE$BOLD" "$RESET"
                                echo ""
                                echo "  Mod ID:   $mod_id"
                                echo "  File:     $filename"
                                echo "  Type:     $ce_type"
                                echo "  Path:     $file_path"
                                echo ""
                                
                                if confirm "Link this file to cfgeconomycore.xml?" "y"; then
                                    register_modular_loot "$SELECTED_DIR" "$file_path" "$mod_id" 0
                                else
                                    echo "Skipped."
                                    sleep 1
                                fi
                            done
                            
                            show_message "CE file linking complete!" "CE Detection"
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
            "📝|Config Editor"
            "🧹|Wipe Server Data"
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
            "📝|Config Editor") config_editor_menu || true ;;
            "🧹|Wipe Server Data") wipe_menu || true ;;
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