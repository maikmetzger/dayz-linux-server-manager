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
    local f_local="$5"
    local f_sort="$6"
    local page=$7
    local -n _items_ref=$8
    local -n _installed_ref=$9
    local -n _rules_ref=${10}
    
    get_term_size
    printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
    
    # 1. Header Bar
    move_to 1 1
    printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Steam Workshop Browser - DayZ" "$RESET"
    
    # 2. Search Status
    move_to 2 2
    local query_status="${WHITE}${f_text:-"None"}"
    [[ -n "$f_local" ]] && query_status+=" ${DIM}(Filtered: $f_local)${RESET}"
    
    printf "%sQuery: %-30s %sSort: %s%-15s %sPage: %s%d %s" \
        "$YLW" "$query_status" \
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
    
    if [[ $count -eq 0 ]]; then
        move_to $start_row 2; printf "%s(No results found for this query)%s" "$DIM" "$RESET"
    fi
    
    for ((i=0; i<v_height; i++)); do
        local idx=$((offset + i))
        move_to $((start_row + i)) 1
        
        if [[ $idx -lt $count ]]; then
            # Fields: id|name|subs_f|size|updated_f|desc|children|subs_raw
            IFS='|' read -r mid mname msubs msize mdate mdesc mchildren msubs_raw <<< "${_items_ref[$idx]:-}"
            
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
        IFS='|' read -r mid mname msubs msize mdate mdesc mchildren msubs_raw <<< "${_items_ref[$selection]:-}"
        move_to $((footer_row + 1)) 2; printf "%sDescription:%s" "$YLW" "$RESET"
        local clean_desc=$(echo "$mdesc" | tr '\n' ' ' | sed 's/  */ /g')
        move_to $((footer_row + 2)) 4; printf "%s%s%s" "$WHITE" "${clean_desc:0:$((TERM_COLS-8))}" "$RESET"
        move_to $((footer_row + 3)) 2; printf "%sDependencies: %s%s" "$YLW" "$WHITE" "${mchildren:-"None (Direct)"}"
        
        # Sort marker
        move_to $((footer_row + 4)) 2;
        local s_desc="Standard"
        [[ "$f_sort" == "mostsubscribed" ]] && s_desc="Subscribers (Desc)"
        [[ "$f_sort" == "mostsubscribed_asc" ]] && s_desc="Subscribers (Asc)"
        [[ "$f_sort" == "newestfirst" ]] && s_desc="Newest First"
        [[ "$f_sort" == "lastupdated" ]] && s_desc="Last Updated"
        [[ "$f_sort" == "relevance" ]] && s_desc="Relevancy"
        printf "%sSorted By: %s%s" "$CYN" "$WHITE" "$s_desc"
    fi
    
    # 6. Keyboard Hints
    move_to $((TERM_ROWS - 1)) 1
    local footer_text=" [↑↓] Nav  [←→] Pag  [Enter] Inst  [f] Filter  [o] Open  [c] Clear  [q] Back"
    local pad_len=$((TERM_COLS - ${#footer_text}))
    [[ $pad_len -lt 0 ]] && pad_len=0
    printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer_text" "$pad_len" "" "$RESET"
}

# Unified Filter Dialog (Similar to types.sh)
_draw_workshop_filter_dialog() {
    local -n _fn=$1 _fl=$2 _fs=$3
    local -a _sort_opts=("trend" "mostsubscribed" "mostsubscribed_asc" "newestfirst" "lastupdated" "relevance")
    local -a _sort_names=("Standard (Trend)" "Subscribers (Desc)" "Subscribers (Asc)" "Newest First" "Last Updated" "Relevancy")
    
    local d_width=60 d_height=12
    local d_row=$(( (TERM_ROWS - d_height) / 2 ))
    local d_col=$(( (TERM_COLS - d_width) / 2 ))
    local d_sel=0

    while true; do
        draw_box $d_row $d_col $d_height $d_width "Filter & Search Workshop"
        
        move_to $((d_row + 2)) $((d_col + 2))
        local s_style="$WHITE"
        [[ $d_sel -eq 0 ]] && s_style="$RED$BOLD"
        printf "%sSearch: [%-38s]%s" "$s_style" "${_fn:0:38}" "$RESET"
        
        move_to $((d_row + 4)) $((d_col + 2))
        local f_style="$WHITE"
        [[ $d_sel -eq 1 ]] && f_style="$RED$BOLD"
        printf "%sFilter: [%-38s]%s" "$f_style" "${_fl:0:38}" "$RESET"
        
        move_to $((d_row + 6)) $((d_col + 2))
        local o_style="$WHITE"
        [[ $d_sel -eq 2 ]] && o_style="$RED$BOLD"
        local cur_sort="Trend"
        for i in "${!_sort_opts[@]}"; do [[ "${_sort_opts[$i]}" == "$_fs" ]] && cur_sort="${_sort_names[$i]}"; done
        printf "%sSort  : < %-36s >%s" "$o_style" "$cur_sort" "$RESET"
        
        move_to $((d_row + 8)) $((d_col + 2))
        local c_style="$WHITE"
        [[ $d_sel -eq 3 ]] && c_style="$RED$BOLD"
        printf "%s[ Reset All Filters ]%s" "$c_style" "$RESET"
        
        move_to $((d_row + 11)) $((d_col + 2))
        printf "[ Enter ] Edit Select  [ Esc ] Close Apply"
        
        IFS= read -rsn1 k
        if [[ "$k" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 s || true
            case "$s" in
                "[A") [[ $d_sel -gt 0 ]] && ((d_sel--)) ;;
                "[B") [[ $d_sel -lt 3 ]] && ((d_sel++)) ;;
                "") return 0 ;;
            esac
        elif [[ "$k" == "" ]]; then
            case $d_sel in
                0) local new;_fn=$(read_input "Global Search Term" "$_fn" "Search"); return 1 ;;
                1) _fl=$(read_input "Filter Results Locally" "$_fl" "Filter"); return 1 ;;
                2) if run_menu _sort_names "Select Workshop Sort"; then _fs="${_sort_opts[$MENU_RESULT]}"; return 1; fi ;;
                3) _fn="DayZ"; _fl=""; _fs="trend"; return 1 ;;
            esac
        fi
    done
}

# Main Workshop Controller
workshop_browser() {
    local instance_dir="$1"
    local mods_txt="${instance_dir}/data/config/mods.txt"
    local rules_json="${SCRIPT_DIR}/data/workshop_rules.json"
    
    local f_text="DayZ" f_sort="relevance" current_page=1 f_local=""
    local selection=0 offset=0 f_changed=1 count=0
    local -a items=()
    declare -A installed_mods workshop_rules

    while true; do
        if [[ $f_changed -eq 1 ]]; then
            installed_mods=()
            [[ -f "$mods_txt" ]] && { while IFS='|' read -r mid status; do installed_mods["$mid"]="$status"; done < <(read_mod_ids_with_status "$mods_txt"); }
            workshop_rules=()
            [[ -f "$rules_json" ]] && { while IFS='|' read -r mid val; do workshop_rules["$mid"]="$val"; done < <(python3 -c "import json; r=json.load(open('$rules_json')); for k,v in r.get('incompatibilities', {}).items(): print(f'{k}|conflict'); for k in r.get('frameworks', []): print(f'{k}|framework')"); }

            # Show Non-blocking Fetching Badge
            _draw_workshop_screen "0" "$selection" "$offset" "$f_text" "$f_local" "$f_sort" "$current_page" items installed_mods workshop_rules
            move_to $((TERM_ROWS / 2)) $((TERM_COLS / 2 - 10))
            printf "%s%s Fetching Workshop Data... %s" "$BG_RED" "$WHITE$BOLD" "$RESET"
            
            local json
            json=$(_fetch_workshop_items "$f_text" "$f_sort" "25" "$current_page")
            
            # Robust JSON conversion
            local read_items=()
            while IFS= read -r line; do 
                [[ -z "$line" ]] && continue
                # Local filtering
                if [[ -n "$f_local" ]]; then
                    if ! echo "$line" | grep -qi "$f_local"; then continue; fi
                fi
                read_items+=("$line")
            done < <(printf "%s" "$json" | python3 -c "
import sys, json, datetime
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): data = []
    for x in data:
        updated_dt = datetime.datetime.fromtimestamp(x.get('updated', 0)).strftime('%Y-%m-%d')
        # id|name|subs_f|size|updated_f|desc|children|subs_raw
        print(f\"{x['id']}|{x['name']}|{x.get('subscribers_f','0')}|{x.get('size','0 MB')}|{updated_dt}|{x.get('description','')[:500].replace('|',' ')}|{','.join(x.get('dependencies', []))}|{x.get('subscribers',0)}\")
except Exception as e:
    pass
")
            items=("${read_items[@]}")
            
            # Custom sorting for asc/desc (if needed)
            if [[ "$f_sort" == "mostsubscribed_asc" ]]; then
                local -a sorted=()
                while IFS= read -r line; do sorted+=("$line"); done < <(printf "%s\n" "${items[@]}" | sort -t'|' -k8,8n)
                items=("${sorted[@]}")
            elif [[ "$f_sort" == "mostsubscribed" ]]; then
                local -a sorted=()
                while IFS= read -r line; do sorted+=("$line"); done < <(printf "%s\n" "${items[@]}" | sort -t'|' -k8,8nr)
                items=("${sorted[@]}")
            fi
            
            count=${#items[@]}
            [[ $selection -ge $count ]] && selection=$((count > 0 ? count - 1 : 0))
            f_changed=0
        fi

        local v_height=$((TERM_ROWS - 14))
        [[ $v_height -lt 5 ]] && v_height=5
        if [[ $selection -lt $offset ]]; then offset=$selection; fi
        if [[ $selection -ge $((offset + v_height)) ]]; then offset=$((selection - v_height + 1)); fi

        _draw_workshop_screen "$count" "$selection" "$offset" "$f_text" "$f_local" "$f_sort" "$current_page" items installed_mods workshop_rules

        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 seq || { continue; } # ESC pressed
            case "$seq" in
                "[A") [[ $selection -gt 0 ]] && ((selection--)) ;;
                "[B") [[ $selection -lt $((count - 1)) ]] && ((selection++)) ;;
                "[D") [[ $current_page -gt 1 ]] && { ((current_page--)); selection=0; offset=0; f_changed=1; } ;; # Left
                "[C") [[ $count -gt 0 ]] && { ((current_page++)); selection=0; offset=0; f_changed=1; } ;; # Right
            esac
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then return
        elif [[ "$key" == "f" || "$key" == "F" ]]; then
            if _draw_workshop_filter_dialog f_text f_local f_sort; then
                current_page=1; selection=0; f_changed=1
            fi
        elif [[ "$key" == "c" || "$key" == "C" ]]; then
            f_text="DayZ"; f_local=""; f_sort="relevance"; current_page=1; selection=0; f_changed=1
        elif [[ "$key" == "o" || "$key" == "O" ]]; then
            if [[ $count -gt 0 ]]; then
                IFS='|' read -r mid mname msubs msize mdate mdesc mchildren msubs_raw <<< "${items[$selection]:-}"
                local url="https://steamcommunity.com/sharedfiles/filedetails/?id=${mid}"
                if command -v open &>/dev/null; then open "$url"
                elif command -v xdg-open &>/dev/null; then xdg-open "$url" &>/dev/null &
                else show_message "URL: $url" "Link (No Browser Found)"; fi
            fi
        elif [[ "$key" == "" ]]; then
            if [[ $count -gt 0 ]]; then
                IFS='|' read -r mid mname msubs msize mdate mdesc mchildren msubs_raw <<< "${items[$selection]:-}"
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
