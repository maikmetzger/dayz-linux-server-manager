#!/usr/bin/env bash
# =============================================================================
# DayZ types.xml Editor - TUI Library
# =============================================================================
# Provides high-performance XML editing for loot economy files.
# Extracted from lib/config.sh
# =============================================================================

# Fetch filtered items from types.xml
_fetch_xml_items() {
    local xml_file="$1"
    local name="$2"
    local cat="$3"
    local use="$4"
    local tier="$5"
    
    local cmd=("python3" "${SCRIPT_DIR}/lib/xml_parser.py" "query" "$xml_file")
    [[ -n "$name" ]] && cmd+=("--name" "$name")
    [[ -n "$cat" ]] && cmd+=("--cat" "$cat")
    [[ -n "$use" ]] && cmd+=("--usage" "$use")
    [[ -n "$tier" ]] && cmd+=("--tier" "$tier")
    
    "${cmd[@]}"
}

config_xml_editor() {
    local container="$1"
    local xml_file="$2"
    local id="$3"
    
    local f_name=""
    local f_cat=""
    local f_use=""
    local f_tier=""
    
    # Load metadata for menus
    local meta_json
    meta_json=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" metadata "$xml_file")
    
    local -a cat_list=()
    local -a use_list=()
    local -a tier_list=()
    
    # Extract metadata using python
    while IFS= read -r line; do cat_list+=("$line"); done < <(echo "$meta_json" | python3 -c "import sys, json; [print(x) for x in json.load(sys.stdin)['categories']]")
    while IFS= read -r line; do use_list+=("$line"); done < <(echo "$meta_json" | python3 -c "import sys, json; [print(x) for x in json.load(sys.stdin)['usages']]")
    while IFS= read -r line; do tier_list+=("$line"); done < <(echo "$meta_json" | python3 -c "import sys, json; [print(x) for x in json.load(sys.stdin)['tiers']]")

    local selection=0
    local offset=0
    local f_changed=1
    local -a items=()
    local count=0
    
    while true; do
        if [[ $f_changed -eq 1 ]]; then
            # 1. Fetch filtered items
            local items_json
            items_json=$(_fetch_xml_items "$xml_file" "$f_name" "$f_cat" "$f_use" "$f_tier")
            
            # Parse into bash arrays
            items=()
            while IFS= read -r line; do items+=("$line"); done < <(echo "$items_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for x in data:
    print(f\"{x['name']}|{x['nominal']}|{x['min']}|{x['lifetime']}|{x['restock']}|{x['category']}|{x['usages']}|{x['tiers']}|{json.dumps(x['flags'])}\")
")
            count=${#items[@]}
            [[ $selection -ge $count ]] && selection=$((count > 0 ? count - 1 : 0))
            f_changed=0
        fi
        
        # 2. Draw Table
        draw_header "Loot Economy Editor - $(basename "$xml_file")"
        
        # Filter status line
        local filter_str=""
        [[ -n "$f_name" ]] && filter_str+="Name: $f_name "
        [[ -n "$f_cat" ]] && filter_str+="Cat: $f_cat "
        [[ -n "$f_use" ]] && filter_str+="Use: $f_use "
        [[ -n "$f_tier" ]] && filter_str+="Tier: $f_tier "
        
        move_to 2 2
        if [[ -n "$filter_str" ]]; then
            printf "%sFilter: %s%s (%d found)%s" "$YLW" "$WHITE" "$filter_str" "$count" "$RESET"
        else
            printf "%sTotal Items: %s%d%s" "$YLW" "$WHITE" "$count" "$RESET"
        fi
        
        # Table Header
        local col_name=34 col_nom=8 col_min=8 col_life=10 col_rs=10
        move_to 4 2
        printf "%s%-*s %-*s %-*s %-*s %-*s%s" "$BOLD$WHITE" \
            $col_name "Name" $col_nom "Nom" $col_min "Min" $col_life "Life" $col_rs "RS" "$RESET"
        move_to 5 2
        printf "%s%s%s" "$WHITE" "$(printf '%.0s─' $(seq 1 $((col_name+col_nom+col_min+col_life+col_rs+4))))" "$RESET"
        
        # Viewport variables
        local start_row=6
        local v_height=$((TERM_ROWS - 14))
        [[ $v_height -lt 5 ]] && v_height=5
        
        # Adjust offset
        if [[ $selection -lt $offset ]]; then offset=$selection; fi
        if [[ $selection -ge $((offset + v_height)) ]]; then offset=$((selection - v_height + 1)); fi
        
        for ((i=0; i<v_height; i++)); do
            local idx=$((offset + i))
            move_to $((start_row + i)) 2
            
            if [[ $idx -lt $count ]]; then
                IFS='|' read -r name nom min life rs cat usages tiers flags <<< "${items[$idx]}"
                
                local style="$WHITE"
                [[ $idx -eq $selection ]] && style="$BG_RED$WHITE$BOLD"
                
                # Truncate name if needed
                local disp_name="${name:0:$((col_name-1))}"
                
                printf "%s%-*s %*s %*s %*s %*s%s" "$style" \
                    $col_name "$disp_name" $col_nom "$nom" $col_min "$min" $col_life "$life" $col_rs "$rs" "$RESET"
            else
                printf "%$((col_name+col_nom+col_min+col_life+col_rs+4))s" ""
            fi
        done
        
        # 3. Footer (Detail Pane)
        local footer_row=$((start_row + v_height + 1))
        move_to $footer_row 2
        printf "%s%s%s" "$WHITE" "$(printf '%.0s─' $(seq 1 $((col_name+col_nom+col_min+col_life+col_rs+4))))" "$RESET"
        
        if [[ $count -gt 0 ]]; then
            IFS='|' read -r name nom min life rs cat usages tiers flags <<< "${items[$selection]}"
            move_to $((footer_row + 1)) 2
            printf "%sCategory: %s%-15s %sUsage: %s%s" "$YLW" "$WHITE" "$cat" "$YLW" "$WHITE" "$usages"
            move_to $((footer_row + 2)) 2
            printf "%sTiers:    %s%s" "$YLW" "$WHITE" "$tiers"
            
            # Flags
            local f_map f_hoarder f_cargo f_player f_crafted f_deloot
            f_map=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin)['count_in_map'])")
            f_hoarder=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin)['count_in_hoarder'])")
            f_cargo=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin)['count_in_cargo'])")
            f_player=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin)['count_in_player'])")
            f_crafted=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin)['crafted'])")
            f_deloot=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin)['deloot'])")
            
            move_to $((footer_row + 3)) 2
            printf "%sFlags:    %s[%s] Map  [%s] Hoarder  [%s] Cargo  [%s] Player  [%s] Crafted  [%s] DeLoot" \
                "$YLW" "$WHITE" \
                "$([[ $f_map == 1 ]] && echo "x" || echo " ")" \
                "$([[ $f_hoarder == 1 ]] && echo "x" || echo " ")" \
                "$([[ $f_cargo == 1 ]] && echo "x" || echo " ")" \
                "$([[ $f_player == 1 ]] && echo "x" || echo " ")" \
                "$([[ $f_crafted == 1 ]] && echo "x" || echo " ")" \
                "$([[ $f_deloot == 1 ]] && echo "x" || echo " ")"
        fi
        
        draw_footer "↑↓ Navigate  Enter Edit  f Filter  x Clear  q Back"

        # 4. Input Handling
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 seq || true
            case "$seq" in
                "[A") [[ $selection -gt 0 ]] && ((selection--)) ;;
                "[B") [[ $selection -lt $((count - 1)) ]] && ((selection++)) ;;
            esac
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            return
        elif [[ "$key" == "x" || "$key" == "X" ]]; then
            f_name="" f_cat="" f_use="" f_tier=""
            f_changed=1
            selection=0
        elif [[ "$key" == "f" || "$key" == "F" ]]; then
            # Filter Dialog
            _draw_xml_filter_dialog f_name f_cat f_use f_tier cat_list[@] use_list[@] tier_list[@]
            f_changed=1
            selection=0
        elif [[ "$key" == "" ]]; then
            # Edit Item
            if [[ $count -gt 0 ]]; then
                IFS='|' read -r name nom min life rs cat usages tiers flags <<< "${items[$selection]}"
                _edit_xml_item "$xml_file" "$name"
                f_changed=1
            fi
        fi
    done
}

_draw_xml_filter_dialog() {
    local -n _fn=$1 _fc=$2 _fu=$3 _ft=$4
    local -a _cats=("${!5}")
    local -a _uses=("${!6}")
    local -a _tiers=("${!7}")
    
    local d_width=60
    local d_height=16
    local d_row=$(( (TERM_ROWS - d_height) / 2 ))
    local d_col=$(( (TERM_COLS - d_width) / 2 ))
    
    local d_sel=0
    while true; do
        draw_box $d_row $d_col $d_height $d_width "Filter types.xml"
        
        move_to $((d_row + 2)) $((d_col + 2))
        local name_style="$WHITE"
        [[ $d_sel -eq 0 ]] && name_style="$RED$BOLD"
        printf "%sName: [%-38s]%s" "$name_style" "${_fn:0:38}" "$RESET"
        
        move_to $((d_row + 4)) $((d_col + 2))
        printf "%s─" "$(printf '%.0s─' $(seq 1 $((d_width - 4))))"
        
        local options=("Category" "Usage" "Tier" "Reset All")
        for i in "${!options[@]}"; do
            move_to $((d_row + 5 + i)) $((d_col + 2))
            if [[ $((i + 1)) -eq $d_sel ]]; then
                printf "%s▶ %-10s%s" "$RED$BOLD" "${options[$i]}" "$RESET"
            else
                printf "  %-10s" "${options[$i]}"
            fi
        done
        
        move_to $((d_row + 11)) $((d_col + 2))
        printf "%s─" "$(printf '%.0s─' $(seq 1 $((d_width - 4))))"
        move_to $((d_row + 12)) $((d_col + 2))
        printf "Selected Filters:"
        move_to $((d_row + 13)) $((d_col + 2))
        local sel_str=""
        [[ -n "$_fc" ]] && sel_str+="[Cat: $_fc] "
        [[ -n "$_fu" ]] && sel_str+="[Use: $_fu] "
        [[ -n "$_ft" ]] && sel_str+="[Tier: $_ft] "
        printf "%s%s%s" "$CYN" "${sel_str:0:$((d_width - 4))}" "$RESET"
        
        move_to $((d_row + 15)) $((d_col + 2))
        printf "[ Enter ] Select     [ Esc ] Close/Back"
        
        IFS= read -rsn1 k
        if [[ "$k" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 s || true
            case "$s" in
                "[A") [[ $d_sel -gt 0 ]] && ((d_sel--)) ;;
                "[B") [[ $d_sel -lt 4 ]] && ((d_sel++)) ;;
                "") return ;; # Escape
            esac
        elif [[ "$k" == "" ]]; then
            case $d_sel in
                0) # Name Select
                    _fn=$(input_dialog "Filter by Classname" "$_fn")
                    ;;
                1) # Category dropdown
                    local -a m=("all" "${_cats[@]}")
                    if run_menu m "Select Category"; then
                        if [[ "${m[$MENU_RESULT]}" == "all" ]]; then _fc=""; else _fc="${m[$MENU_RESULT]}"; fi
                    fi
                    ;;
                2) # Usage dropdown
                    local -a m=("all" "${_uses[@]}")
                    if run_menu m "Select Usage"; then
                         if [[ "${m[$MENU_RESULT]}" == "all" ]]; then _fu=""; else _fu="${m[$MENU_RESULT]}"; fi
                    fi
                    ;;
                3) # Tier dropdown
                    local -a m=("all" "${_tiers[@]}")
                    if run_menu m "Select Tier"; then
                         if [[ "${m[$MENU_RESULT]}" == "all" ]]; then _ft=""; else _ft="${m[$MENU_RESULT]}"; fi
                    fi
                    ;;
                4) # Reset
                    _fn="" _fc="" _fu="" _ft=""
                    ;;
            esac
        fi
    done
}

_edit_xml_item() {
    local xml_file="$1"
    local item_name="$2"
    
    local -a fields=("nominal" "min" "lifetime" "restock")
    if run_menu fields "Edit Item: $item_name"; then
        local field="${fields[$MENU_RESULT]}"
        local current_val
        current_val=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" query "$xml_file" --name "$item_name" | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['$field'])")
        
        local new_val
        new_val=$(input_dialog "Edit $field for $item_name" "$current_val")
        
        if [[ -n "$new_val" && "$new_val" != "$current_val" ]]; then
            if python3 "${SCRIPT_DIR}/lib/xml_parser.py" update "$xml_file" --item "$item_name" --key "$field" --val "$new_val"; then
                show_message "Updated $item_name: $field = $new_val" "Success"
            else
                show_message "Failed to update XML" "Error"
            fi
        fi
    fi
}
