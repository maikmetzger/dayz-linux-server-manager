#!/usr/bin/env bash
# =============================================================================
# DayZ types.xml Editor - TUI Library
# =============================================================================
# Provides high-performance XML editing for loot economy files.
# =============================================================================

# Fetch filtered items from types.xml
_fetch_xml_items() {
    local xml_file="$1"
    local name="$2"
    local cat="$3"
    local use="$4"
    local tier="$5"
    local vanilla_file="$6"
    
    local cmd=("python3" "${SCRIPT_DIR}/lib/xml_parser.py" "query" "$xml_file")
    [[ -n "$name" ]] && cmd+=("--name" "$name")
    [[ -n "$cat" ]] && cmd+=("--cat" "$cat")
    [[ -n "$use" ]] && cmd+=("--usage" "$use")
    [[ -n "$tier" ]] && cmd+=("--tier" "$tier")
    [[ -n "$vanilla_file" ]] && cmd+=("--vanilla" "$vanilla_file")
    
    "${cmd[@]}"
}

# Unified Drawing Logic for the Table View
_draw_xml_editor_screen() {
    local xml_file="$1"
    local count=$2
    local selection=$3
    local offset=$4
    local f_name="$5"
    local f_cat="$6"
    local f_use="$7"
    local f_tier="$8"
    local -n _items_ref=$9
    
    get_term_size
    printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
    
    # 1. Header Bar
    local filename=$(basename "$xml_file")
    move_to 1 1
    printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Loot Economy Editor - $filename" "$RESET"
    
    # 2. Filter Status
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
    
    # 3. Table Header
    local table_start=3
    move_to $table_start 1
    printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"
    
    local col_name=2 w_name=34
    local col_nom=$((col_name + w_name)) w_nom=8
    local col_min=$((col_nom + w_nom)) w_min=8
    local col_life=$((col_min + w_min)) w_life=10
    local col_rs=$((col_life + w_life)) w_rs=10
    
    move_to $((table_start + 1)) $col_name
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_name "NAME" "$RESET"
    move_to $((table_start + 1)) $col_nom
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_nom "NOM" "$RESET"
    move_to $((table_start + 1)) $col_min
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_min "MIN" "$RESET"
    move_to $((table_start + 1)) $col_life
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_life "LIFE" "$RESET"
    move_to $((table_start + 1)) $col_rs
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_rs "RS" "$RESET"
    
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
            # Fields: name|nom|min|life|rs|cat|usages|tiers|flags|nom_v|min_v|life_v|rs_v
            IFS='|' read -r name nom min life rs cat usages tiers flags nom_v min_v life_v rs_v <<< "${_items_ref[$idx]:-}"
            local style="$WHITE"
            if [[ $idx -eq $selection ]]; then
                style="$BG_RED$WHITE$BOLD"
                printf "%s%*s%s" "$BG_RED" "$TERM_COLS" "" "$RESET"
                move_to $((start_row + i)) 1
            fi
            
            local d_name="$name"
            [[ ${#d_name} -ge $((w_name-2)) ]] && d_name="${d_name:0:$((w_name-4))}.."
            
            move_to $((start_row + i)) $col_name
            printf "%s%-*s%s" "$style" $w_name "$d_name" "$RESET"
            move_to $((start_row + i)) $col_nom
            printf "%s%-*s%s" "$style" $w_nom "$nom" "$RESET"
            move_to $((start_row + i)) $col_min
            printf "%s%-*s%s" "$style" $w_min "$min" "$RESET"
            move_to $((start_row + i)) $col_life
            printf "%s%-*s%s" "$style" $w_life "$life" "$RESET"
            move_to $((start_row + i)) $col_rs
            printf "%s%-*s%s" "$style" $w_rs "$rs" "$RESET"
        fi
    done
    
    # 5. Detail Pane
    local footer_row=$((start_row + v_height + 1))
    move_to $footer_row 1
    printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"
    
    if [[ $count -gt 0 ]]; then
        IFS='|' read -r name nom min life rs cat usages tiers flags nom_v min_v life_v rs_v <<< "${_items_ref[$selection]:-}"
        move_to $((footer_row + 1)) 2
        printf "%sCategory: %s%-15s %sUsage: %s%s" "$YLW" "$WHITE" "$cat" "$YLW" "$WHITE" "$usages"
        move_to $((footer_row + 2)) 2
        printf "%sVanilla : %sNom: %-6s Min: %-6s Life: %-8s RS: %-6s" "$YLW" "$DIM" "$nom_v" "$min_v" "$life_v" "$rs_v"
        
        # Flags
        if [[ -n "$flags" ]]; then
            local f_map f_hoarder f_cargo f_player f_crafted f_deloot
            f_map=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin).get('count_in_map', 0))")
            f_hoarder=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin).get('count_in_hoarder', 0))")
            f_cargo=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin).get('count_in_cargo', 0))")
            f_player=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin).get('count_in_player', 0))")
            f_crafted=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin).get('crafted', 0))")
            f_deloot=$(echo "$flags" | python3 -c "import sys, json; print(json.load(sys.stdin).get('deloot', 0))")
            
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
    fi
    
    # 6. Keyboard Hints
    move_to $((TERM_ROWS - 1)) 1
    local footer_text=" [↑↓] Navigate   [Enter] Edit   [f] Filter   [x] Clear   [q] Back"
    local pad_len=$((TERM_COLS - ${#footer_text}))
    [[ $pad_len -lt 0 ]] && pad_len=0
    printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer_text" "$pad_len" "" "$RESET"
}

config_xml_editor() {
    local container="$1"
    local xml_file="$2"
    local id="$3"
    
    # Create vanilla backup if needed
    local vanilla_file="${xml_file}.vanilla"
    if [[ ! -f "$vanilla_file" ]]; then
        cp "$xml_file" "$vanilla_file"
    fi

    local f_name="" f_cat="" f_use="" f_tier=""
    
    # Load metadata for menus
    local meta_json
    meta_json=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" metadata "$xml_file")
    local -a cat_list=() use_list=() tier_list=()
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
            local items_json
            items_json=$(_fetch_xml_items "$xml_file" "$f_name" "$f_cat" "$f_use" "$f_tier" "$vanilla_file")
            items=()
            while IFS= read -r line; do items+=("$line"); done < <(echo "$items_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for x in data:
    print(f\"{x['name']}|{x['nominal']}|{x['min']}|{x['lifetime']}|{x['restock']}|{x['category']}|{x['usages']}|{x['tiers']}|{json.dumps(x['flags'])}|{x['nominal_v']}|{x['min_v']}|{x['lifetime_v']}|{x['restock_v']}\")
")
            count=${#items[@]}
            [[ $selection -ge $count ]] && selection=$((count > 0 ? count - 1 : 0))
            f_changed=0
        fi
        
        # Viewport adjustment
        local v_height=$((TERM_ROWS - 14))
        [[ $v_height -lt 5 ]] && v_height=5
        if [[ $selection -lt $offset ]]; then offset=$selection; fi
        if [[ $selection -ge $((offset + v_height)) ]]; then offset=$((selection - v_height + 1)); fi

        _draw_xml_editor_screen "$xml_file" "$count" "$selection" "$offset" "$f_name" "$f_cat" "$f_use" "$f_tier" items

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
            _draw_xml_filter_dialog f_name f_cat f_use f_tier cat_list[@] use_list[@] tier_list[@] \
                "$xml_file" "$count" "$selection" "$offset" items
            f_changed=1
            selection=0
        elif [[ "$key" == "" ]]; then
            if [[ $count -gt 0 ]]; then
                _edit_xml_item "$xml_file" "$count" "$selection" "$offset" "$f_name" "$f_cat" "$f_use" "$f_tier" items
                f_changed=1
            fi
        fi
    done
}

_draw_xml_filter_dialog() {
    local -n _fn=$1 _fc=$2 _fu=$3 _ft=$4
    local -a _cats=("${!5}") _uses=("${!6}") _tiers=("${!7}")
    local bg_xml="$8" bg_count="$9" bg_sel="${10}" bg_off="${11}"
    local -n _bg_items_ref=${12}
    
    local d_width=60 d_height=16
    local d_row=$(( (TERM_ROWS - d_height) / 2 ))
    local d_col=$(( (TERM_COLS - d_width) / 2 ))
    local d_sel=0

    while true; do
        _draw_xml_editor_screen "$bg_xml" "$bg_count" "$bg_sel" "$bg_off" "$_fn" "$_fc" "$_fu" "$_ft" _bg_items_ref
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
                "") return ;;
            esac
        elif [[ "$k" == "" ]]; then
            case $d_sel in
                0) _fn=$(read_input "Filter by Classname" "$_fn" "Filter") ;;
                1) local -a m=("all" "${_cats[@]}"); if run_menu m "Select Category"; then
                   [[ "${m[$MENU_RESULT]}" == "all" ]] && _fc="" || _fc="${m[$MENU_RESULT]}"; fi ;;
                2) local -a m=("all" "${_uses[@]}"); if run_menu m "Select Usage"; then
                   [[ "${m[$MENU_RESULT]}" == "all" ]] && _fu="" || _fu="${m[$MENU_RESULT]}"; fi ;;
                3) local -a m=("all" "${_tiers[@]}"); if run_menu m "Select Tier"; then
                   [[ "${m[$MENU_RESULT]}" == "all" ]] && _ft="" || _ft="${m[$MENU_RESULT]}"; fi ;;
                4) _fn="" _fc="" _fu="" _ft="" ;;
            esac
        fi
    done
}

_edit_xml_item() {
    local xml_file="$1"
    local bg_count="$2"
    local bg_sel="$3"
    local bg_off="$4"
    local bg_fn="$5"
    local bg_fc="$6"
    local bg_fu="$7"
    local bg_ft="$8"
    local -n _bg_items_ref=$9

    # Extract all data from background list
    IFS='|' read -r item_name nom min life rs cat usages tiers flags nom_v min_v life_v rs_v <<< "${_bg_items_ref[$bg_sel]:-}"

    local d_width=52 d_height=12
    local d_row=$(( (TERM_ROWS - d_height) / 2 ))
    local d_col=$(( (TERM_COLS - d_width) / 2 ))
    local d_sel=0

    while true; do
        _draw_xml_editor_screen "$xml_file" "$bg_count" "$bg_sel" "$bg_off" "$bg_fn" "$bg_fc" "$bg_fu" "$bg_ft" _bg_items_ref
        draw_box $d_row $d_col $d_height $d_width "Edit: $item_name"
        
        local fields=("Nominal" "Min" "Lifetime" "Restock")
        local values=("$nom" "$min" "$life" "$rs")
        local vanillas=("$nom_v" "$min_v" "$life_v" "$rs_v")
        
        for i in "${!fields[@]}"; do
            move_to $((d_row + 2 + i)) $((d_col + 2))
            local style="$WHITE"
            [[ $d_sel -eq $i ]] && style="$RED$BOLD"
            printf "%s%-10s: %-8s %s(Vanilla: %s)%s" "$style" "${fields[$i]}" "${values[$i]}" "$DIM" "${vanillas[$i]}" "$RESET"
        done
        
        move_to $((d_row + d_height - 3)) $((d_col + 2))
        printf "%s─" "$(printf '%.0s─' $(seq 1 $((d_width - 4))))"
        move_to $((d_row + d_height - 2)) $((d_col + 2))
        printf "[ Enter ] Edit     [ Esc ] Close"
        
        IFS= read -rsn1 k
        if [[ "$k" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 s || true
            case "$s" in
                "[A") [[ $d_sel -gt 0 ]] && ((d_sel--)) ;;
                "[B") [[ $d_sel -lt 3 ]] && ((d_sel++)) ;;
                "") return ;;
            esac
        elif [[ "$k" == "" ]]; then
            local field="" current_val=""
            case $d_sel in
                0) field="nominal"; current_val="$nom" ;;
                1) field="min";     current_val="$min" ;;
                2) field="lifetime"; current_val="$life" ;;
                3) field="restock";  current_val="$rs" ;;
            esac
            
            local new_val
            new_val=$(read_input "Edit $field" "$current_val" "Edit $item_name")
            
            if [[ -n "$new_val" && "$new_val" != "$current_val" ]]; then
                if python3 "${SCRIPT_DIR}/lib/xml_parser.py" update "$xml_file" --item "$item_name" --key "$field" --val "$new_val"; then
                    case $field in
                        nominal)  nom="$new_val" ;;
                        min)      min="$new_val" ;;
                        lifetime) life="$new_val" ;;
                        restock)  rs="$new_val" ;;
                    esac
                else
                    show_message "Failed to update XML" "Error"
                fi
            fi
        fi
    done
}
