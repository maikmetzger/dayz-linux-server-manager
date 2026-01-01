#!/usr/bin/env bash
# =============================================================================
# DayZ Workshop Browser - TUI Library
# =============================================================================
# Provides high-fidelity Steam Workshop discovery and mod installation.
# =============================================================================

# Fetch workshop items via Python backend
_fetch_workshop_items() {
    local text="$1" sort="$2" num="$3" page="$4" mode="${5:-title}" clear_flag="${6:-}"
    # Use python backend
    python3 "${SCRIPT_DIR}/lib/workshop_search.py" \
        --search "$text" \
        --sort "$sort" \
        --num "$num" \
        --page "$page" \
        --mode "$mode" $clear_flag
}

# Fetch details for specific IDs (used for dependencies)
_fetch_workshop_details() {
    local ids="$1"
    local recursive="${2:-""}"
    local rules_path="${3:-""}"
    echo "FETCH_DETAILS: ids=$ids recursive=$recursive" >> /tmp/workshop_crash.log
    local cmd="timeout 90s python3 \"${SCRIPT_DIR}/lib/workshop_search.py\" --details \"$ids\""
    [[ "$recursive" == "1" ]] && cmd="$cmd --recursive"
    [[ -n "$rules_path" ]] && cmd="$cmd --update-rules \"$rules_path\""
    echo "FETCH_DETAILS: Running cmd" >> /tmp/workshop_crash.log
    eval "$cmd"
    echo "FETCH_DETAILS: Done" >> /tmp/workshop_crash.log
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
    local query_status="${WHITE}${f_text:-"None"}"
    
    printf "%sQuery: %-30s %sSort: %s%-15s %sPage: %s%d %s" \
        "$YLW" "$query_status" \
        "$YLW" "$WHITE" "$f_sort" \
        "$YLW" "$WHITE" "$page" "$RESET"
    
    # 3. Table Header
    local table_start=3
    move_to $table_start 1
    printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"
    
    local col_stat=2 w_stat=2
    local col_name=$((col_stat + w_stat + 1)) w_name=38
    local col_id=$((col_name + w_name)) w_id=12
    local col_size=$((col_id + w_id)) w_size=9
    local col_stars=$((col_size + w_size)) w_stars=7
    local col_subs=$((col_stars + w_stars)) w_subs=14
    local col_date=$((col_subs + w_subs)) w_date=12
    
    move_to $((table_start + 1)) $col_name
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_name "NAME" "$RESET"
    move_to $((table_start + 1)) $col_id
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_id "ID" "$RESET"
    move_to $((table_start + 1)) $col_size
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_size "SIZE" "$RESET"
    move_to $((table_start + 1)) $col_stars
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_stars "RATING" "$RESET"
    move_to $((table_start + 1)) $col_subs
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_subs "SUBSCRIBERS" "$RESET"
    move_to $((table_start + 1)) $col_date
    printf "%s%s%-*s%s" "$DIM" "$WHITE" $w_date "UPDATED" "$RESET"
    
    move_to $((table_start + 2)) 1
    printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"
    
    # 4. Rows
    local start_row=$((table_start + 3))
    # ... (height logic unchanged) ...
    local v_height=$((TERM_ROWS - 14))
    [[ $v_height -lt 5 ]] && v_height=5
    
    if [[ $count -eq 0 ]]; then
        move_to $start_row 2; printf "%s(No results found for this query)%s" "$DIM" "$RESET"
    fi
    
    for ((i=0; i<v_height; i++)); do
        local idx=$((offset + i))
        move_to $((start_row + i)) 1
        
        if [[ $idx -lt $count ]]; then
            # Fields: id|name|rating|subs_f|size|updated_f|desc|children|subs_raw
            IFS='|' read -r mid mname mrating msubs msize mdate mdesc mchildren msubs_raw <<< "${_items_ref[$idx]:-}"
            
            local style="$WHITE"
            local status_mark=" "
            
            [[ -n "${_installed_ref[$mid]:-}" ]] && { style="$GRN"; status_mark="✓"; }
            [[ "${_rules_ref[$mid]:-}" == "conflict" ]] && { style="$RED"; status_mark="!"; }
            [[ "${_rules_ref[$mid]:-}" == "framework" ]] && { [[ "$style" == "$WHITE" ]] && style="$YLW"; }

            if [[ $idx -eq $selection ]]; then
                style="$BG_RED$WHITE$BOLD"
                printf "%s%*s%s" "$BG_RED" "$TERM_COLS" "" "$RESET"
                move_to $((start_row + i)) 1
            fi
            
            local d_name="$mname"
            [[ ${#d_name} -ge $((w_name-4)) ]] && d_name="${d_name:0:$((w_name-6))}.."
            
            # Format Rating Stars
            local d_stars=""
            if [[ "$mrating" =~ ^[0-5]$ ]]; then
                d_stars="$mrating/5"
                [[ "$mrating" == "0" ]] && d_stars=" - "
                [[ "$mrating" == "5" ]] && d_stars="5/5"
            else
                d_stars=" ? "
            fi
            
            move_to $((start_row + i)) $col_stat
            printf "%s%-*s" "$style" $w_stat "$status_mark"
            move_to $((start_row + i)) $col_name
            printf "%s%-*s" "$style" $((w_name-2)) "$d_name"
            move_to $((start_row + i)) $col_id
            printf "%s%-*s" "$style" $w_id "$mid"
            move_to $((start_row + i)) $col_size
            printf "%s%-*s" "$style" $w_size "$msize"
            move_to $((start_row + i)) $col_stars
            printf "%s%-*s" "$style" $w_stars "$d_stars"
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
    local footer_text=" [↑↓] Nav  [←→] Pag  [Enter] Inst  [f] Search  [ Space ] Details  [c] Reset  [q] Back"
    local pad_len=$((TERM_COLS - ${#footer_text}))
    [[ $pad_len -lt 0 ]] && pad_len=0
    printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer_text" "$pad_len" "" "$RESET"
}

# Mod Details View Screen
_draw_workshop_details_screen() {
    local mid="$1" mname="$2" mauthor="$3" msize="$4" msubs="$5" mupdated="$6" mdesc="$7" mdeps="$8" mrating_stars="$9" mrating_count="${10}" scroll_offset="${11}"
    local -n _images_ref=${12}
    local img_sel=${13}
    
    get_term_size
    printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
    
    # 1. Header with Mod Name
    move_to 1 1
    printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_BLUE" "$WHITE$BOLD" "Mod Details: $mname" "$RESET"
    if [[ ${#mname} -gt $((TERM_COLS-14)) ]]; then
         move_to 1 14; printf "%s%s" "$BG_BLUE" "${mname:0:$((TERM_COLS-15))}..."
    fi

    local meta_width=40
    # Clean split author string by comma (assuming comma separated from python)
    local -a authors_list=()
    IFS=',' read -ra ADDR <<< "$mauthor"
    for i in "${ADDR[@]}"; do authors_list+=("$(echo "$i" | sed 's/^ *//')"); done
    if [[ ${#authors_list[@]} -eq 0 ]]; then authors_list=("Unknown"); fi

    # Flexible Metadata Height Calculation
    # Fixed fields: ID(1) + Size(1) + Subs(1) + Updated(1) + Deps(1) + Rating(1) = 6 lines
    # Available lines for authors: N
    # Max Box Height = 15
    # Max Content Lines = 15 - 2 = 13
    # Max Author Lines = 13 - 6 = 7
    
    local num_authors=${#authors_list[@]}
    local display_authors=$num_authors
    local meta_height=$((6 + num_authors + 2))
    
    # Cap height and authors
    if [[ $meta_height -gt 15 ]]; then
        meta_height=15
        display_authors=7
    fi
    # If we have exactly 8 authors, 7+1more is same lines, so just show 8? 
    # Logic: If num > 7, show 6 and "... and X more" (1 line) = 7 lines.
    
    local show_more_msg=""
    if [[ $num_authors -gt $display_authors ]]; then
        # We need to truncate
        # Reserve last line for "... and X more"
        display_authors=$((display_authors - 1))
        local diff=$((num_authors - display_authors))
        show_more_msg="... and $diff more"
    fi
    
    draw_box 3 2 $meta_height $meta_width "Metadata"
    
    # Row 1: ID
    move_to 5 4; printf "%sID       :%s %s" "$DIM" "$RESET" "$mid"
    
    # Row 2+: Authors
    move_to 6 4; printf "%sAuthor(s):%s" "$DIM" "$RESET"
    local a_row=6
    
    for ((i=0; i<display_authors; i++)); do
         move_to $a_row 15; printf "%s" "${authors_list[$i]:0:22}" # Truncate name width too
         ((a_row++))
    done
    
    if [[ -n "$show_more_msg" ]]; then
         move_to $a_row 15; printf "%s%s%s" "$DIM" "$show_more_msg" "$RESET"
         ((a_row++))
    fi
    
    # Continue after authors (Fixed fields)
    move_to $a_row 4; printf "%sSize     :%s %s" "$DIM" "$RESET" "$msize"
    ((a_row++))
    move_to $a_row 4; printf "%sSubs     :%s %s" "$DIM" "$RESET" "$msubs"
    ((a_row++))
    move_to $a_row 4; printf "%sUpdated  :%s %s" "$DIM" "$RESET" "$mupdated"
    ((a_row++))
    move_to $a_row 4; printf "%sDeps     :%s %s" "$DIM" "$RESET" "${mdeps:-None}"
    ((a_row++))
    
    # Rating Display
    local r_disp="-"
    if [[ "$mrating_stars" =~ ^[0-5]$ ]]; then
         r_disp="$mrating_stars/5 ($mrating_count)"
    else
         r_disp="? ($mrating_count)"
    fi
    move_to $a_row 4; printf "%sRating   :%s %s" "$DIM" "$RESET" "$r_disp"

    # 3. Images Box (Left, below Metadata)
    local img_height=$((TERM_ROWS - meta_height - 6))
    if [[ $img_height -gt 4 ]]; then
        local img_color="$RED"
        draw_box $((3 + meta_height)) 2 $img_height $meta_width "Images (${#_images_ref[@]})" "$img_color"
        
        local start_img_row=$((5 + meta_height))
        local max_imgs=$((img_height - 2))
        local display_offset=0
        
        # Simple scroll for images if selected index is deep
        # FIX: Ensure it handles scrolling UP as well by clamping display_offset
        if [[ $img_sel -ge $max_imgs ]]; then 
             display_offset=$((img_sel - max_imgs + 1))
        fi
        
        for ((i=0; i<max_imgs; i++)); do
            local idx=$((display_offset + i))
            if [[ $idx -lt ${#_images_ref[@]} ]]; then
                move_to $((start_img_row + i)) 4
                local style="$DIM"
                [[ $idx -eq $img_sel && $img_sel -ge 0 ]] && style="$BG_RED$WHITE$BOLD"
                local img_url="${_images_ref[$idx]}"
                # Use OSC 8 Hyperlink with truncation for best TUI experience
                # \033]8;;URL\033\\TEXT\033]8;;\033\\
                local img_url="${_images_ref[$idx]}"
                local link_text="${img_url:0:36}"
                printf "%s\033]8;;%s\033\\%-36s\033]8;;\033\\%s" "$style" "$img_url" "$link_text" "$RESET"
            fi
        done
    fi

    # 4. Description Box (Right)
    local desc_col=$((meta_width + 4))
    local desc_width=$((TERM_COLS - desc_col - 2))
    local desc_height=$((TERM_ROWS - 6))
    
    if [[ $desc_width -gt 20 ]]; then
        draw_box 3 $desc_col $desc_height $desc_width "Description" "$RED"
        
        # Use fold to wrap lines nicely respecting paragraphs
        local -a lines=()
        # Ensure we don't trip set -e with empty output or subshell failures
        while IFS= read -r line; do
            lines+=("$line")
        done < <(echo -e "$mdesc" | fold -s -w $((desc_width - 2)))
        
        # FIX: Reduce height by 1 to avoid touching bottom border
        local view_height=$((desc_height - 3))
        local total_lines=${#lines[@]}
        # Max scroll snap to page (floor division of total-1 to get max page index, times height)
        local max_scroll=$(( ((total_lines - 1) / view_height) * view_height ))
        [[ $max_scroll -lt 0 ]] && max_scroll=0
        [[ $scroll_offset -gt $max_scroll ]] && scroll_offset=$max_scroll
        
        for ((i=0; i<view_height; i++)); do
            local l_idx=$((scroll_offset + i))
            if [[ $l_idx -lt $total_lines ]]; then
                move_to $((5 + i)) $((desc_col + 2))
                local line="${lines[$l_idx]}"
                # RICH TEXT RENDERING
                if [[ "$line" == ">> "* ]]; then
                     # HEADER: Red/Bold (DayZ Style)
                     printf "%s%s%s" "$RED$BOLD" "${line//>>/}" "$RESET"
                else
                     # INLINE PARSING: *bold* -> BOLD, _italic_ -> ITALIC
                     # We use simple sed replacement for standard ANSI codes
                     # Note: This is simple and might break on mixed edge cases but works for standard desc
                     local styled_line="$line"
                     styled_line=$(echo "$styled_line" | sed "s/\*\([^*]*\)\*/${WHITE}${BOLD}\1${RESET}/g")
                     styled_line=$(echo "$styled_line" | sed "s/_\([^_]*\)_/${ITALIC}\1${RESET}/g")
                     printf "%s" "$styled_line"
                fi
            fi
        done
        
        # Page Indicator (Bottom Center of Box)
        if [[ $total_lines -gt $view_height ]]; then
            local current_page=$(( (scroll_offset / view_height) + 1 ))
            local total_pages=$(( (total_lines + view_height - 1) / view_height ))
            local p_str=" Page $current_page/$total_pages "
            move_to $((3 + desc_height - 1)) $((desc_col + (desc_width / 2) - (${#p_str} / 2)))
            printf "%s%s%s" "$BG_DARKGRAY" "$p_str" "$RESET"
        fi
    fi

    # 5. Footer Actions
    move_to $((TERM_ROWS)) 1
    local footer=" [Enter] Install  [b] Steam  [↑↓] Img  [←→] Page  [ Space ] Back "
    printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer" $((TERM_COLS - ${#footer})) "" "$RESET"
}

# Handler for Details View
_view_mod_details() {
    local mid="$1" instance_dir="$2" mods_txt="$3" rules_json="$4"
    
    # Run ENTIRE fetch/parse block in permissive mode
    # Disable exit-on-error AND exit-on-unset-variable
    set +eu
    
    echo "STARTING DETAILS for $mid" > /tmp/workshop_crash.log
    
    # Fetch FRESH details (recursive=0, just this mod, but get FULL info)
    move_to $((TERM_ROWS / 2)) $((TERM_COLS / 2 - 10))
    printf "%s%s Fetching Full Details... %s" "$BG_BLUE" "$WHITE$BOLD" "$RESET"
    
    # Use temp file to avoid subshell exit issues
    # Force unique name with timestamp to avoid collision
    local tmp_json="/tmp/workshop_details_${mid}_$(date +%s).json"
    echo "FETCHING PYTHON..." >> /tmp/workshop_crash.log
    echo "XYZZY_SYNC_CHECK_2026" >> /tmp/workshop_crash.log
    
    # Timeout after 30s, capture stderr for debugging
    timeout 30s python3 "${SCRIPT_DIR}/lib/workshop_search.py" --details "$mid" > "$tmp_json" 2>> /tmp/workshop_crash.log
    echo "XYZZY_AFTER_TIMEOUT" >> /tmp/workshop_crash.log
    local py_exit=$?
    echo "PYTHON EXIT CODE: $py_exit" >> /tmp/workshop_crash.log
    echo "DEBUG: After py_exit" >> /tmp/workshop_crash.log
    
    if [[ $py_exit -ne 0 ]]; then
        echo "PYTHON FAILED, using defaults" >> /tmp/workshop_crash.log
    fi
    
    echo "PARSING JSON..." >> /tmp/workshop_crash.log
    
    # Parse Python output
    local mname="Loading..." mauthor="Unknown" msize="0B" msubs="0" mupdated="-" mdesc="Loading..." mdeps="0" mrating_stars="-" mrating_count="0"
    local -a mimages=()
    
    local tmp_source="/tmp/workshop_source_${mid}.sh"
    
    # Python writes direct shell assignments to file
    cat "$tmp_json" 2>/dev/null | python3 -c "
import sys, json, datetime, shlex
try:
    data = json.load(sys.stdin)
    if data:
        x = data[0]
        ud = datetime.datetime.fromtimestamp(x.get('updated', 0)).strftime('%Y-%m-%d')
        
        def clean(s): return str(s).encode('ascii', 'ignore').decode('ascii').strip()
        
        desc = x.get('description_clean', x.get('description', ''))
        
        # Write to file instead of stdout for eval
        with open('$tmp_source', 'w') as f:
            f.write(f'mname={shlex.quote(clean(x.get(\"name\",\"\")))}\\n')
            f.write(f'mauthor={shlex.quote(clean(x.get(\"author\",\"Unknown\")))}\\n')
            f.write(f'msize={shlex.quote(x.get(\"size\",\"0B\"))}\\n')
            f.write(f'msubs={shlex.quote(x.get(\"subscribers_f\",\"0\"))}\\n')
            f.write(f'mupdated={shlex.quote(ud)}\\n')
            f.write(f'mdesc={shlex.quote(clean(desc))}\\n')
            f.write(f'mdeps={len(x.get(\"dependencies\",[]))}\\n')
            f.write(f'mrating_stars={shlex.quote(str(x.get(\"rating_stars\",\"-\")))}\\n')
            f.write(f'mrating_count={shlex.quote(str(x.get(\"rating_count\",\"0\")))}\\n')
            
            imgs = x.get('images', [])
            img_str = ' '.join([shlex.quote(i) for i in imgs])
            f.write(f'mimages=({img_str})\\n')
except Exception as e:
    print(f'PARSE ERROR: {e}', file=sys.stderr)
" 2>> /tmp/workshop_crash.log
    rm -f "$tmp_json"
    
    echo "SOURCING..." >> /tmp/workshop_crash.log
    
    # Source the generated file (Safe loading of variables)
    if [[ -f "$tmp_source" ]]; then
        source "$tmp_source" 2>> /tmp/workshop_crash.log
        rm -f "$tmp_source"
    fi
    rm -f "$tmp_json"
    
    echo "ENTERING UI LOOP..." >> /tmp/workshop_crash.log
    
    # Run UI loop in permissive mode to prevent crashes from fold/printf
    set +eu
    
    local scroll=0
    local img_sel=-1
    [[ ${#mimages[@]} -gt 0 ]] && img_sel=0
    
    while true; do
        # Recalculate view_height for paging logic inside the loop (depends on resize)
        local desc_height=$((TERM_ROWS - 6))
        local view_height=$((desc_height - 3))
        
        _draw_workshop_details_screen "$mid" "$mname" "$mauthor" "$msize" "$msubs" "$mupdated" "$mdesc" "$mdeps" "$mrating_stars" "$mrating_count" "$scroll" mimages $img_sel
        
        IFS= read -rsn1 k
        if [[ "$k" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 s || { set -eu; return; } # ESC - restore strict
            case "$s" in
                "[A") # Up - Images
                    [[ $img_sel -gt 0 ]] && ((img_sel--)); ;;
                "[B") # Down - Images
                    [[ $img_sel -lt $((${#mimages[@]} - 1)) ]] && ((img_sel++)); ;;
                "[D") # Left - Page Up
                    scroll=$((scroll - view_height))
                    [[ $scroll -lt 0 ]] && scroll=0; ;;
                "[C") # Right - Page Down
                    scroll=$((scroll + view_height)); ;;
            esac
        elif [[ "$k" == "q" || "$k" == "Q" || "$k" == " " ]]; then 
            set -eu; return
        elif [[ "$k" == "b" || "$k" == "B" ]]; then
            local url="https://steamcommunity.com/sharedfiles/filedetails/?id=${mid}"
            if command -v open &>/dev/null; then open "$url"
            elif command -v xdg-open &>/dev/null; then xdg-open "$url" &>/dev/null &
            else show_message "URL: $url" "Link"; fi
        elif [[ "$k" == "" ]]; then
            set -eu; return 10 # Signal to install
        fi
    done
}

# Unified Filter Dialog (Similar to types.sh)
# Unified Filter Dialog (Similar to types.sh)
_draw_workshop_filter_dialog() {
    local -n _fn=$1 _fs=$2 _fl=$3 _fm=$4
    local -a _sort_opts=("trend" "mostsubscribed" "mostsubscribed_asc" "newestfirst" "lastupdated" "relevance")
    local -a _sort_names=("Standard (Trend)" "Subscribers (Desc)" "Subscribers (Asc)" "Newest First" "Last Updated" "Relevancy")
    local -a _lim_opts=("Fill" "5" "10" "25" "50" "100")
    local -a _mode_opts=("Title" "Author")
    
    local d_width=60 d_height=14
    local d_row=$(( (TERM_ROWS - d_height) / 2 ))
    local d_col=$(( (TERM_COLS - d_width) / 2 ))
    local d_sel=0

    while true; do
        draw_box $d_row $d_col $d_height $d_width "Search Workshop"
        
        move_to $((d_row + 2)) $((d_col + 2))
        local s_style="$WHITE"
        [[ $d_sel -eq 0 ]] && s_style="$RED$BOLD"
        printf "%sSearch: [%-38s]%s" "$s_style" "${_fn:0:38}" "$RESET"
        
        move_to $((d_row + 4)) $((d_col + 2))
        local o_style="$WHITE"
        [[ $d_sel -eq 1 ]] && o_style="$RED$BOLD"
        local cur_sort="Trend"
        for i in "${!_sort_opts[@]}"; do [[ "${_sort_opts[$i]}" == "$_fs" ]] && cur_sort="${_sort_names[$i]}"; done
        printf "%sSort  : < %-36s >%s" "$o_style" "$cur_sort" "$RESET"
        
        move_to $((d_row + 6)) $((d_col + 2))
        local l_style="$WHITE"
        [[ $d_sel -eq 2 ]] && l_style="$RED$BOLD"
        printf "%sLimit : < %-36s >%s" "$l_style" "$_fl" "$RESET"
        
        move_to $((d_row + 8)) $((d_col + 2))
        local m_style="$WHITE"
        [[ $d_sel -eq 3 ]] && m_style="$RED$BOLD"
        printf "%sMode  : < %-36s >%s" "$m_style" "$_fm" "$RESET"
        
        move_to $((d_row + 10)) $((d_col + 2))
        local c_style="$WHITE"
        [[ $d_sel -eq 4 ]] && c_style="$RED$BOLD"
        printf "%s[ Reset All Defaults ]%s" "$c_style" "$RESET"
        
        move_to $((d_row + 13)) $((d_col + 2))
        printf "[ Enter ] Edit Select  [ Esc ] Close Apply"
        
        IFS= read -rsn1 k
        if [[ "$k" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 s || true
            case "$s" in
                "[A") [[ $d_sel -gt 0 ]] && ((d_sel--)) ;;
                "[B") [[ $d_sel -lt 4 ]] && ((d_sel++)) ;;
                "") return 1 ;;
            esac
        elif [[ "$k" == "" ]]; then
            case $d_sel in
                0) local new;_fn=$(read_input "Global Search Term" "$_fn" "Search"); return 0 ;;
                1) if run_menu _sort_names "Select Workshop Sort"; then _fs="${_sort_opts[$MENU_RESULT]}"; return 0; fi ;;
                2) if run_menu _lim_opts "Select Items Per Page"; then _fl="${_lim_opts[$MENU_RESULT]}"; return 0; fi ;;
                3) if run_menu _mode_opts "Select Search Mode"; then _fm="${_mode_opts[$MENU_RESULT]}"; return 0; fi ;;
                4) _fn="DayZ"; _fs="mostsubscribed"; _fl="Fill"; _fm="Title"; return 2 ;;
            esac
        fi
    done
}

# Main Workshop Controller
workshop_browser() {
    local instance_dir="$1"
    local mods_txt="${instance_dir}/data/config/mods.txt"
    local rules_json="${SCRIPT_DIR}/data/workshop_rules.json"
    
    local f_text="DayZ" f_sort="mostsubscribed" f_limit="Fill" f_mode="Title" current_page=1
    local selection=0 offset=0 f_changed=1 count=0 last_fetch_limit=0 f_clear=0
    local -a items=()
    declare -A installed_mods workshop_rules

    while true; do
        if [[ $f_changed -eq 1 ]]; then
            installed_mods=()
            [[ -f "$mods_txt" ]] && { while IFS='|' read -r mid status; do installed_mods["$mid"]="$status"; done < <(read_mod_ids_with_status "$mods_txt"); }
            workshop_rules=()
            [[ -f "$rules_json" ]] && { while IFS='|' read -r mid val; do workshop_rules["$mid"]="$val"; done < <(python3 -c "import json; r=json.load(open('$rules_json')); for k,v in r.get('incompatibilities', {}).items(): print(f'{k}|conflict'); for k in r.get('frameworks', []): print(f'{k}|framework')"); }

            # Calculate dynamic fetch count based on viewport or limit
            local v_height=$((TERM_ROWS - 14))
            [[ $v_height -lt 5 ]] && v_height=5
            local fetch_count=$v_height
            if [[ "$f_limit" != "Fill" ]]; then fetch_count=$f_limit; fi
            
            # Show Non-blocking Fetching Badge
            _draw_workshop_screen "0" "$selection" "$offset" "$f_text" "$f_sort" "$current_page" items installed_mods workshop_rules
            move_to $((TERM_ROWS / 2)) $((TERM_COLS / 2 - 10))
            printf "%s%s Fetching Workshop Data ($fetch_count)... %s" "$BG_RED" "$WHITE$BOLD" "$RESET"
            
            local json
            local clean_mode="title"; [[ "$f_mode" == "Author" ]] && clean_mode="author"
            local clear_arg=""; [[ $f_clear -eq 1 ]] && clear_arg="--clear"
            json=$(_fetch_workshop_items "$f_text" "$f_sort" "$fetch_count" "$current_page" "$clean_mode" "$clear_arg")
            f_clear=0
            
            # Robust JSON conversion
            local read_items=()
            while IFS= read -r line; do 
                [[ -z "$line" ]] && continue
                read_items+=("$line")
            done < <(printf "%s" "$json" | python3 -c "
import sys, json, datetime
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): data = []
    for x in data:
        updated_dt = datetime.datetime.fromtimestamp(x.get('updated', 0)).strftime('%Y-%m-%d')
        # id|name|rating|subs_f|size|updated_f|desc|children|subs_raw
        desc = x.get('description_clean', x.get('description',''))[:500].replace('|',' ').replace('\n', ' ').replace('\r', ' ')
        print(f\"{x['id']}|{x['name']}|{x.get('rating_stars','?')}|{x.get('subscribers_f','0')}|{x.get('size','0 MB')}|{updated_dt}|{desc}|{','.join(x.get('dependencies', []))}|{x.get('subscribers',0)}\")
except Exception as e:
    pass
")
            items=("${read_items[@]}")
            
            # Custom sorting ONLY for ASC (Steam doesn't support ascending)
            if [[ "$f_sort" == "mostsubscribed_asc" ]]; then
                local -a sorted=()
                while IFS= read -r line; do sorted+=("$line"); done < <(printf "%s\n" "${items[@]}" | sort -t'|' -k8,8n)
                items=("${sorted[@]}")
            fi
            # Note: mostsubscribed DESC relies on Steam's server-side sort - do NOT re-sort locally
            
            count=${#items[@]}
            [[ $selection -ge $count ]] && selection=$((count > 0 ? count - 1 : 0))
            f_changed=0
            last_fetch_limit=$fetch_count
        fi

        # Recalculate v_height for offset logic (redundant but safe for resize)
        local v_height=$((TERM_ROWS - 14))
        [[ $v_height -lt 5 ]] && v_height=5
        if [[ $selection -lt $offset ]]; then offset=$selection; fi
        if [[ $selection -ge $((offset + v_height)) ]]; then offset=$((selection - v_height + 1)); fi

        _draw_workshop_screen "$count" "$selection" "$offset" "$f_text" "$f_sort" "$current_page" items installed_mods workshop_rules
        
        # Determine current active limit for resize logic
        local current_active_limit=$fetch_count

        IFS= read -rsn1 -t 0.5 key || { 
            # Timeout - Check for Resize
            local new_v_height=$((TERM_ROWS - 14))
            [[ $new_v_height -lt 5 ]] && new_v_height=5
            
            if [[ "$f_limit" == "Fill" && "$new_v_height" -ne "$last_fetch_limit" && "$last_fetch_limit" -gt 0 ]]; then
                 # Resize Detected in Fill Mode - Recalculate Page to prevent gaps
                 # Global Index of first item on old page
                 local global_idx=$(( (current_page - 1) * last_fetch_limit ))
                 # New Page Target
                 current_page=$(( (global_idx / new_v_height) + 1 ))
                 selection=0; offset=0
                 f_clear=1 # Force clear cache on resize
                 f_changed=1
            fi
            continue
        }
        
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 seq || { continue; } # ESC pressed
            case "$seq" in
                "[A") [[ $selection -gt 0 ]] && ((selection--)) ;;
                "[B") [[ $selection -lt $((count - 1)) ]] && ((selection++)) ;;
                "") [[ $count -gt 0 ]] && { ((current_page++)); selection=0; offset=0; f_changed=1; } ;; # Right (Fallback)
                "[D") [[ $current_page -gt 1 ]] && { ((current_page--)); selection=0; offset=0; f_changed=1; } ;; # Left
                "[C") [[ $count -gt 0 ]] && { ((current_page++)); selection=0; offset=0; f_changed=1; } ;; # Right
            esac
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then return
        elif [[ "$key" == "f" || "$key" == "F" ]]; then
            _draw_workshop_filter_dialog f_text f_sort f_limit f_mode
            local d_res=$?
            if [[ $d_res -eq 0 ]]; then
                # Filter applied -> Force Clear Cache
                f_clear=1; current_page=1; selection=0; f_changed=1; continue
            elif [[ $d_res -eq 2 ]]; then
                # Reset triggered from dialog
                f_clear=1; current_page=1; selection=0; f_changed=1; continue
            fi
        elif [[ "$key" == "c" || "$key" == "C" ]]; then
            f_text="DayZ"; f_sort="mostsubscribed"; f_limit="Fill"; f_mode="Title"; current_page=1; selection=0; f_clear=1; f_changed=1; continue
        elif [[ "$key" == "o" || "$key" == "O" || "$key" == " " ]]; then
            if [[ $count -gt 0 ]]; then
                IFS='|' read -r mid mname msubs msize mdate mdesc mchildren msubs_raw <<< "${items[$selection]:-}"
                _view_mod_details "$mid" "$instance_dir" "$mods_txt" "$rules_json"
                local ret=$?
                if [[ $ret -eq 10 ]]; then key=""; fi # Fallthrough to install if user pressed Enter in details
            fi
        elif [[ "$key" == "" ]]; then
            if [[ $count -gt 0 ]]; then
                # Disable strict mode for install block to prevent crashes
                set +e
                
                IFS='|' read -r mid mname msubs msize mdate mdesc mchildren msubs_raw <<< "${items[$selection]:-}"
                if [[ -z "${installed_mods[$mid]:-}" ]]; then
                    # Fetch dependencies (no visual banner - TUI conflict)
                    echo "INSTALL: Starting for $mid" > /tmp/workshop_crash.log
                    
                    echo "INSTALL: Calling _fetch_workshop_details" >> /tmp/workshop_crash.log
                    local chain_json=""
                    chain_json=$(_fetch_workshop_details "$mid" "1" "$rules_json") || true
                    echo "INSTALL: Got chain_json len=${#chain_json}" >> /tmp/workshop_crash.log
                    
                    if [[ -z "$chain_json" ]]; then
                        show_message "Failed to fetch dependencies (timeout or network error)." "Error"
                        set -e
                        continue
                    fi
                    
                    echo "INSTALL: Parsing JSON..." >> /tmp/workshop_crash.log
                    local -a to_install_ids=() to_install_names=() frameworks_found=()
                    while IFS='|' read -r cid cname; do
                        if [[ -n "$cid" && -z "${installed_mods[$cid]:-}" ]]; then
                            to_install_ids+=("$cid"); to_install_names+=("$cname")
                            [[ "${workshop_rules[$cid]:-}" == "framework" ]] && frameworks_found+=("$cname")
                        fi
                    done < <(echo "$chain_json" | python3 -c "import sys, json; [print(f\"{x['id']}|{x['name']}\") for x in json.load(sys.stdin)]" 2>> /tmp/workshop_crash.log)
                    echo "INSTALL: Found ${#to_install_ids[@]} mods to install" >> /tmp/workshop_crash.log
                    if [[ ${#to_install_ids[@]} -eq 0 ]]; then show_message "This mod (and dependencies) are already in your list." "Info"; continue; fi
                    local install_summary="${to_install_names[*]}"
                    [[ ${#to_install_names[@]} -gt 3 ]] && install_summary="${to_install_names[0]}, ${to_install_names[1]} and $(( ${#to_install_names[@]} - 2 )) more"
                    echo "INSTALL: About to confirm" >> /tmp/workshop_crash.log
                    local confirm_msg="Install ${#to_install_ids[@]} mod(s): ${install_summary}"
                    if confirm "$confirm_msg" "y"; then
                        local auto_top=0
                        if [[ ${#frameworks_found[@]} -gt 0 ]] && confirm "Move frameworks (${frameworks_found[*]}) to top of load order?" "y"; then auto_top=1; fi
                        for ((i=0; i<${#to_install_ids[@]}; i++)); do
                            local cid="${to_install_ids[$i]}"
                            if [[ $auto_top -eq 1 ]]; then sed -i "1i$cid" "$mods_txt"; else echo "$cid" >> "$mods_txt"; fi
                        done
                        f_changed=1; show_message "Mod(s) added to your list. Run 'Sync' to download." "Added"
                    fi
                else show_message "This mod is already in your list." "Info"; fi
            fi
        fi
    done
}
