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
for lib in colors tui menu dialogs utils docker instance mods; do
    source "${SCRIPT_DIR}/lib/${lib}.sh"
done

# Set up cleanup trap
trap cleanup EXIT

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
                local status
                status="$(get_container_status "$container")"
                
                local status_icon="${RED}○${RESET}"
                [[ "$status" == "RUNNING" ]] && status_icon="${GREEN}●${RESET}"
                
                items+=("$status_icon $name [$status]")
            done
            items+=("--------------------")
        else
            items+=("No instances found.")
            items+=("--------------------")
        fi
        
        items+=("✨ Install/Manage Instances")
        items+=("❌ Quit")
        
        if run_menu items "DayZ Server Manager - Select Instance" $selection; then
            selection=$MENU_RESULT
            local idx=$MENU_RESULT
            local count=${#INSTANCE_NAMES[@]}
            
            if [[ ${#INSTANCE_NAMES[@]} -gt 0 ]]; then
                if [[ $idx -lt $count ]]; then
                    SELECTED_DIR="${INSTANCE_DIRS[$idx]}"
                    SELECTED_NAME="${INSTANCE_NAMES[$idx]}"
                    SELECTED_CONTAINER="${INSTANCE_CONTAINERS[$idx]}"
                    return
                fi
                idx=$((idx - 1))
            else
                idx=$((idx - 2))
            fi
            
            if [[ $idx -eq $count ]]; then
                # Installer
                if [[ -f "${SCRIPT_DIR}/install-dayz-docker.sh" ]]; then
                    export DAYZ_USER="$INVOKING_USER"
                    export DAYZ_HOME="$INVOKING_HOME"
                    
                    if ! groups | grep -q "\\bdocker\\b"; then
                        if confirm "Installer requires root/docker privileges. Run with sudo?" "y"; then
                            printf "%s" "$SHOW_CURSOR"
                            exec sudo -E bash "${SCRIPT_DIR}/install-dayz-docker.sh"
                        fi
                    fi
                    
                    printf "%s" "$SHOW_CURSOR"
                    exec bash "${SCRIPT_DIR}/install-dayz-docker.sh"
                else
                    show_message "install-dayz-docker.sh not found."
                fi
            elif [[ $idx -eq $((count + 1)) ]]; then
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
        local total_items=$((mod_count + 4))
        
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
        local col_name=10
        local col_id=$((TERM_COLS - 25))
        local col_type=$((TERM_COLS - 10))
        
        move_to $table_start 1
        printf "%s%s" "$DIM" "$RED"
        printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        
        move_to $((table_start + 1)) $col_status
        printf "%s%sSTATUS%s" "$DIM" "$WHITE" "$RESET"
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
            
            move_to $row 1
            if [[ $i -eq $selected ]]; then
                printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
                move_to $row $col_status
                printf "▶ %s" "$status_icon"
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
        local actions=("[A] Add" "[S] Sync" "[F] FixMods" "[Q] Back")
        
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
        printf "%s%s ↑↓ Select   U/D Move   Enter Toggle   A Add   S Sync   F FixMods   Q Back%*s%s" "$BG_DARKGRAY" "$WHITE" "$((TERM_COLS - 75))" "" "$RESET"
        
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
                        echo "$new_id" >> "$mods_file"
                        show_message "Added mod $new_id as [Client]" "Mod Added"
                        dirty=1; needs_rebuild=1
                    else
                        show_message "Mod already in list" "Already Exists"
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
                    # Sync
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" != "RUNNING" ]]; then
                        show_message "Container must be running to sync"
                    else
                        run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                    fi
                elif [[ $selected -eq $((mod_count + 2)) ]]; then
                    # FixMods (sync lowercase)
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" != "RUNNING" ]]; then
                        show_message "Container must be running to fix mods"
                    else
                        run_with_output "Fixing Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                    fi
                elif [[ $selected -eq $((mod_count + 3)) ]]; then
                    return
                fi
                ;;
            'q'|'Q')
                return
                ;;
            's'|'S')
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to sync"
                else
                    run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                fi
                ;;
            'f'|'F')
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to fix mods"
                else
                    run_with_output "Fixing Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                fi
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
        if [[ ${states[0]} -eq 1 ]]; then items+=(" [x] 👤 Wipe Players (players.db)"); else items+=(" [ ] 👤 Wipe Players (players.db)"); fi
        if [[ ${states[1]} -eq 1 ]]; then items+=(" [x] 🚗 Wipe Vehicles (vehicles.bin)"); else items+=(" [ ] 🚗 Wipe Vehicles (vehicles.bin)"); fi
        if [[ ${states[2]} -eq 1 ]]; then items+=(" [x] 🏰 Wipe Bases (persistence/data)"); else items+=(" [ ] 🏰 Wipe Bases (persistence/data)"); fi
        if [[ ${states[3]} -eq 1 ]]; then items+=(" [x] 🎒 Wipe Loot (economy reset)"); else items+=(" [ ] 🎒 Wipe Loot (economy reset)"); fi
        
        items+=("--------------------")
        items+=("💀 EXECUTE SELECTED WIPE(S)")
        items+=("❌ Cancel / Back")
        
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
                    
                    if confirm "Wipe ${count} categories? This cannot be undone!" "n"; then
                        printf "%s" "$SHOW_CURSOR"
                        
                        [[ ${states[0]} -eq 1 ]] && rm -f "${storage_dir}/players.db" "${storage_dir}/players.db-journal"
                        [[ ${states[1]} -eq 1 ]] && rm -f "${storage_dir}/vehicles.bin" "${storage_dir}/vehicles.bin-journal"
                        [[ ${states[2]} -eq 1 && -d "${storage_dir}/data" ]] && rm -rf "${storage_dir}/data"/*
                        
                        if [[ ${states[3]} -eq 1 && ${states[2]} -eq 0 && -f "$economy_file" ]]; then
                            local was_running=0
                            if [[ "$(get_container_status "$SELECTED_CONTAINER")" == "RUNNING" ]]; then
                                was_running=1
                                echo "Stopping server for loot wipe..."
                                $DOCKER stop "$SELECTED_CONTAINER" >/dev/null
                            fi
                            
                            cp "$economy_file" "${economy_file}.bak"
                            sed -i 's/dynamic init="1" load="1"/dynamic init="1" load="0"/g' "$economy_file"
                            
                            echo "Starting server to clear loot (Wait 60s)..."
                            $DOCKER start "$SELECTED_CONTAINER" >/dev/null
                            sleep 60
                            
                            echo "Stopping server..."
                            $DOCKER stop "$SELECTED_CONTAINER" >/dev/null
                            
                            sed -i 's/dynamic init="1" load="0"/dynamic init="1" load="1"/g' "$economy_file"
                            
                            [[ $was_running -eq 1 ]] && { echo "Restarting server..."; $DOCKER start "$SELECTED_CONTAINER" >/dev/null; }
                        fi
                        
                        show_message "Wipe Complete." "Success"
                        states=(0 0 0 0)
                    fi
                    ;;
                6) return ;;
            esac
        else
            return
        fi
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
        
        local -a items=(
            "▶️  Start Server"
            "⏹️  Stop Server"
            "🔄 Restart Server"
            "--------------------"
            "⚒️  Mod Manager"
            "🧹 Wipe Server Data"
            "--------------------"
            "🎮 RCON Console"
            "📜 View Logs"
            "💻 Enter Shell"
            "--------------------"
            "⬆️  Update Server"
            "--------------------"
            "← Switch Instance"
        )
        
        if ! run_menu items "DayZ: $SELECTED_NAME [$status_text" $selection; then
            exit 0
        fi
        
        selection=$MENU_RESULT
        
        case $MENU_RESULT in
            0) run_with_output "Starting Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose up -d" ;;
            1) run_with_output "Stopping Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose stop" ;;
            2) run_with_output "Restarting Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose restart" ;;
            3) ;;
            4) mod_manager ;;
            5) wipe_menu ;;
            6) ;;
            7)
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
            8)
                trap : INT
                run_with_output "Live Logs (Ctrl+C to stop)" $DOCKER logs -f --tail=100 "$SELECTED_CONTAINER"
                trap - INT
                ;;
            9)
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running."
                else
                    printf "%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
                    $DOCKER exec -it "$SELECTED_CONTAINER" /bin/bash || echo "Container not running"
                    read -rp "Press Enter to continue..."
                    printf "%s" "$HIDE_CURSOR"
                fi
                ;;
            10) ;;
            11)
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to update"
                else
                    run_with_output "Updating Server" $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh update-server
                fi
                ;;
            12) ;;
            13) return ;;
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