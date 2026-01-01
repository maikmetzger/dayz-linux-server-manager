#!/usr/bin/env bash
# =============================================================================
# DayZ Workshop Browser - TUI Library
# =============================================================================
# Provides high-fidelity Steam Workshop discovery and mod installation.
# =============================================================================

# Fetch workshop items via Python backend
_fetch_workshop_items() {
    local text="$1"
    local sort="$2"
    local num="${3:-25}"
    local page="${4:-1}"
    
    python3 "${SCRIPT_DIR}/lib/workshop_search.py" --search "$text" --sort "$sort" --num "$num" --page "$page"
}

# Fetch details for specific IDs (used for dependencies)
_fetch_workshop_details() {
    local ids="$1"
    local recursive="${2:-""}"
    local rules_path="${3:-""}"
    local cmd="python3 \"${SCRIPT_DIR}/lib/workshop_search.py\" --details \"$ids\""
    [[ "$recursive" == "1" ]] && cmd="$cmd --recursive"
    [[ -n "$rules_path" ]] && cmd="$cmd --update-rules \"$rules_path\""
    eval "$cmd"
}

# Unified Drawing Logic for the Workshop Browser
_draw_workshop_screen() {
    local count=$1
    local selection=$2
    local offset=$3
    local f_text="$4"
    local f_sort="$5"
    local page=$6
    local -n _items_ref=$7
    local -n _installed_ref=$8
    local -n _rules_ref=$9
    
    get_term_size
    printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
    
    # 1. Header Bar
    move_to 1 1
    printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Steam Workshop Browser - DayZ" "$RESET"
    
    # 2. Search Status
    move_to 2 2
    printf "%sSearch: %s%-30s %sSort: %s%s %sPage: %s%d (25 per page)%s" \
        "$YLW" "$WHITE" "${f_text:-"None"}" \
        "$YLW" "$WHITE" "$f_sort" \
        "$YLW" "$WHITE" "$page" "$RESET"
    
    # 3. Table Header
    local table_start=3
    move_to $table_start 1
    printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"
    
    local col_name=2 w_name=40
    local col_id=$((col_name + w_name)) w_id=12
    local col_size=$((col_id + w_id)) w_size=10
    local col_subs=$((col_size + w_size)) w_subs=15
    local col_date=$((col_subs + w_subs)) w_date=12
    
    move_to $((table_start + 1)) $col_name
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_name "NAME" "$RESET"
    move_to $((table_start + 1)) $col_id
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_id "ID" "$RESET"
    move_to $((table_start + 1)) $col_size
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_size "SIZE" "$RESET"
    move_to $((table_start + 1)) $col_subs
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_subs "SUBSCRIBERS" "$RESET"
    move_to $((table_start + 1)) $col_date
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_date "UPDATED" "$RESET"
    
    move_to $((table_start + 2)) 1
    printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"
    
    # 4. Rows
    local start_row=$((table_start + 3))
    local v_height=$((TERM_ROWS - 14))
    [[ $v_height -lt 5 ]] && v_height=5
    
    for ((i=0; i<v_height; i++)); do
        local idx=$((offset + i))
        move_to $((start_row + i)) 1
        
        if [[ $idx -lt $count ]]; then
            # Fields: id|name|subs_f|size|updated_f|desc|children
            IFS='|' read -r mid mname msubs msize mdate mdesc mchildren <<< "${_items_ref[$idx]:-}"
            
            local style="$WHITE"
            local status_mark=""
            
            [[ -n "${_installed_ref[$mid]:-}" ]] && { style="$GRN"; status_mark="$GRN$BOLD✓$RESET"; }
            [[ "${_rules_ref[$mid]:-}" == "conflict" ]] && { style="$RED"; status_mark="$RED$BOLD!$RESET"; }
            [[ "${_rules_ref[$mid]:-}" == "framework" ]] && { [[ "$style" == "$WHITE" ]] && style="$YLW"; }

            if [[ $idx -eq $selection ]]; then
                style="$BG_RED$WHITE$BOLD"
                printf "%s%*s%s" "$BG_RED" "$TERM_COLS" "" "$RESET"
                move_to $((start_row + i)) 1
            fi
            
            local d_name="$mname"
            [[ ${#d_name} -ge $((w_name-4)) ]] && d_name="${d_name:0:$((w_name-6))}.."
            
            move_to $((start_row + i)) $col_name
            printf "%s%-*s %s" "$style" $((w_name-2)) "$d_name" "$status_mark"
            move_to $((start_row + i)) $col_id
            printf "%s%-*s" "$style" $w_id "$mid"
            move_to $((start_row + i)) $col_size
            printf "%s%-*s" "$style" $w_size "$msize"
            move_to $((start_row + i)) $col_subs
            printf "%s%-*s" "$style" $w_subs "$msubs"
            move_to $((start_row + i)) $col_date
            printf "%s%-10s" "$style" "$mdate"
            printf "%s" "$RESET"
        fi
    done
    
    # 5. Detail Pane
    local footer_row=$((start_row + v_height + 1))
    move_to $footer_row 1
    printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"
    
    if [[ $count -gt 0 ]]; then
        IFS='|' read -r mid mname msubs msize mdate mdesc mchildren <<< "${_items_ref[$selection]:-}"
        move_to $((footer_row + 1)) 2; printf "%sDescription:%s" "$YLW" "$RESET"
        local clean_desc=$(echo "$mdesc" | tr '\n' ' ' | sed 's/  */ /g')
        move_to $((footer_row + 2)) 4; printf "%s%s%s" "$WHITE" "${clean_desc:0:$((TERM_COLS-8))}" "$RESET"
        move_to $((footer_row + 3)) 2; printf "%sDependencies: %s%s" "$YLW" "$WHITE" "${mchildren:-"None (Direct)"}"
    fi
    
    # 6. Keyboard Hints
    move_to $((TERM_ROWS - 1)) 1
    local footer_text=" [↑↓] Navigate   [←→] Pages   [Enter] Install   [f] Search   [s] Sort   [q] Back"
    local pad_len=$((TERM_COLS - ${#footer_text}))
    [[ $pad_len -lt 0 ]] && pad_len=0
    printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer_text" "$pad_len" "" "$RESET"
}

# Main Workshop Controller
workshop_browser() {
    local instance_dir="$1"
    local mods_txt="${instance_dir}/data/config/mods.txt"
    local rules_json="${SCRIPT_DIR}/data/workshop_rules.json"
    
    local f_text="" f_sort="trend" current_page=1
    local -a sort_options=("trend" "mostsubscribed" "newestfirst" "lastupdated")
    
    local selection=0 offset=0 f_changed=1 count=0
    local -a items=()
    declare -A installed_mods workshop_rules

    while true; do
        if [[ $f_changed -eq 1 ]]; then
            installed_mods=()
            [[ -f "$mods_txt" ]] && { while IFS='|' read -r mid status; do installed_mods["$mid"]="$status"; done < <(read_mod_ids_with_status "$mods_txt"); }
            workshop_rules=()
            [[ -f "$rules_json" ]] && { while IFS='|' read -r mid val; do workshop_rules["$mid"]="$val"; done < <(python3 -c "import json; r=json.load(open('$rules_json')); for k,v in r.get('incompatibilities', {}).items(): print(f'{k}|conflict'); for k in r.get('frameworks', []): print(f'{k}|framework')"); }

            if [[ -n "$f_text" ]]; then
                show_message "Fetching page $current_page for '$f_text'..." "Workshop" "1"
                local json
                json=$(_fetch_workshop_items "$f_text" "$f_sort" "25" "$current_page")
                items=()
                while IFS= read -r line; do items+=("$line"); done < <(echo "$json" | python3 -c "import sys, json, datetime; data = json.load(sys.stdin); for x in data: updated_dt = datetime.datetime.fromtimestamp(x['updated']).strftime('%Y-%m-%d'); print(f\"{x['id']}|{x['name']}|{x['subscribers_f']}|{x['size']}|{updated_dt}|{x['description']}|{','.join(x['dependencies'])}\")")
                count=${#items[@]}
            else items=(); count=0; fi
            [[ $selection -ge $count ]] && selection=$((count > 0 ? count - 1 : 0))
            f_changed=0
        fi

        local v_height=$((TERM_ROWS - 14))
        [[ $v_height -lt 5 ]] && v_height=5
        if [[ $selection -lt $offset ]]; then offset=$selection; fi
        if [[ $selection -ge $((offset + v_height)) ]]; then offset=$((selection - v_height + 1)); fi

        _draw_workshop_screen "$count" "$selection" "$offset" "$f_text" "$f_sort" "$current_page" items installed_mods workshop_rules

        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 seq || { continue; } # ESC pressed
            case "$seq" in
                "[A") [[ $selection -gt 0 ]] && ((selection--)) ;;
                "[B") [[ $selection -lt $((count - 1)) ]] && ((selection++)) ;;
                "[D") [[ $current_page -gt 1 ]] && { ((current_page--)); selection=0; offset=0; f_changed=1; } ;; # Left
                "[C") [[ $count -eq 25 ]] && { ((current_page++)); selection=0; offset=0; f_changed=1; } ;; # Right
            esac
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then return
        elif [[ "$key" == "s" || "$key" == "S" ]]; then
            local -a m=("Trend" "Most Subscribed" "Newest" "Last Updated")
            if run_menu m "Sort Workshop By"; then f_sort="${sort_options[$MENU_RESULT]}"; current_page=1; selection=0; f_changed=1; fi
        elif [[ "$key" == "f" || "$key" == "F" ]]; then
            local new_search
            new_search=$(read_input "Search Steam Workshop" "$f_text" "Search")
            if [[ -n "$new_search" ]]; then f_text="$new_search"; current_page=1; selection=0; f_changed=1; fi
        elif [[ "$key" == "" ]]; then
            if [[ $count -gt 0 ]]; then
                IFS='|' read -r mid mname msubs msize mdate mdesc mchildren <<< "${items[$selection]:-}"
                if [[ -z "${installed_mods[$mid]:-}" ]]; then
                    show_message "Resolving full dependency chain for '$mname'..." "Workshop"
                    local chain_json
                    chain_json=$(_fetch_workshop_details "$mid" "1" "$rules_json")
                    local -a to_install_ids=() to_install_names=() frameworks_found=()
                    while IFS='|' read -r cid cname; do
                        if [[ -n "$cid" && -z "${installed_mods[$cid]:-}" ]]; then
                            to_install_ids+=("$cid"); to_install_names+=("$cname")
                            [[ "${workshop_rules[$cid]:-}" == "framework" ]] && frameworks_found+=("$cname")
                        fi
                    done < <(echo "$chain_json" | python3 -c "import sys, json; [print(f\"{x['id']}|{x['name']}\") for x in json.load(sys.stdin)]")
                    if [[ ${#to_install_ids[@]} -eq 0 ]]; then show_message "Mod and all dependencies are already installed." "Info"; continue; fi
                    local install_summary="${to_install_names[*]}"
                    [[ ${#to_install_names[@]} -gt 3 ]] && install_summary="${to_install_names[0]}, ${to_install_names[1]} and $(( ${#to_install_names[@]} - 2 )) more"
                    if show_confirm "Install ${#to_install_ids[@]} item(s)?\nChain: $install_summary" "Confirm Installation"; then
                        local auto_top=0
                        if [[ ${#frameworks_found[@]} -gt 0 ]] && show_confirm "Frameworks detected (${frameworks_found[*]}).\nMove to top of load order automatically?" "Intelligent Load Order"; then auto_top=1; fi
                        for ((i=0; i<${#to_install_ids[@]}; i++)); do
                            local cid="${to_install_ids[$i]}"
                            if [[ $auto_top -eq 1 ]]; then sed -i "1i$cid" "$mods_txt"; else echo "$cid" >> "$mods_txt"; fi
                        done
                        f_changed=1; show_message "Chain installed successfully. Knowledge layer updated." "Success"
                    fi
                else show_message "Mod is already installed." "Info"; fi
            fi
        fi
    done
}
