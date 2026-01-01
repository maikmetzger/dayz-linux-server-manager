#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Menu System
# =============================================================================
# Arrow-key navigable menu system with DayZ styling
# Requires: lib/colors.sh, lib/tui.sh
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_MENU_LOADED:-}" ]] && return 0
_DAYZ_MENU_LOADED=1

# -----------------------------------------------------------------------------
# Menu State
# -----------------------------------------------------------------------------
MENU_RESULT=0

# -----------------------------------------------------------------------------
# Menu Drawing
# -----------------------------------------------------------------------------

# Draw menu items with current selection highlighted
# Usage: draw_menu "array_name" selected_index start_row start_col width
# Items can be "icon|label" format for alignment, or plain text
draw_menu() {
    local _arr_name=$1
    local selected=$2
    local start_row=$3
    local start_col=$4
    local width=$5
    
    eval "local -a _items=(\"\${${_arr_name}[@]}\")"
    
    # Column offsets (relative to start_col)
    # Format: [selector 3ch] [icon 4ch] [label rest]
    local icon_offset=4   # Icon starts at +4
    local label_offset=8  # Label starts at +8
    
    local i=0
    for item in "${_items[@]}"; do
        local icon=""
        local label="$item"
        
        # Check for pipe delimiter: "icon|label"
        if [[ "$item" == *"|"* ]]; then
            icon="${item%%|*}"
            label="${item#*|}"
        fi
        
        # Draw row
        move_to $((start_row + i)) $start_col
        
        if [[ $i -eq $selected ]]; then
            # Selected: fill with red background
            printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$width" ""
            
            # Selector
            move_to $((start_row + i)) $start_col
            printf "%s%s ▶ " "$BG_RED" "$WHITE$BOLD"
            
            if [[ -n "$icon" ]]; then
                # Icon at fixed column
                move_to $((start_row + i)) $((start_col + icon_offset))
                printf "%s" "$icon"
                # Label at fixed column
                move_to $((start_row + i)) $((start_col + label_offset))
                printf "%s" "$label"
            else
                # No icon, label right after selector
                printf "%s" "$label"
            fi
            printf "%s" "$RESET"
        else
            # Non-selected row
            printf "%s   " "$WHITE"
            
            if [[ -n "$icon" ]]; then
                move_to $((start_row + i)) $((start_col + icon_offset))
                printf "%s" "$icon"
                move_to $((start_row + i)) $((start_col + label_offset))
                printf "%s" "$label"
            else
                printf "%s" "$label"
            fi
            printf "%s" "$RESET"
        fi
        ((i+=1))
    done
}

# -----------------------------------------------------------------------------
# Menu Runner
# -----------------------------------------------------------------------------

# Check if menu item is a separator (starts with dashes)
_is_separator() {
    [[ "$1" == ----* ]]
}

# Find next valid (non-separator) index in direction
# Usage: _find_valid_index "array_name" current_index direction(1 or -1)
_find_next_valid() {
    local _arr_name=$1
    local current=$2
    local direction=$3
    
    eval "local count=\${#${_arr_name}[@]}"
    local next=$((current + direction))
    
    while [[ $next -ge 0 && $next -lt $count ]]; do
        local item
        eval "item=\"\${${_arr_name}[\$next]}\""
        if ! _is_separator "$item"; then
            echo "$next"
            return 0
        fi
        next=$((next + direction))
    done
    
    # No valid item found, return current
    echo "$current"
}

# Run an interactive menu and get selection
# Usage: run_menu "array_name" "Title" [initial_selection]
# Returns: 0 on selection (result in MENU_RESULT), 1 on quit
run_menu() {
    local _menu_arr_name=$1
    local title="$2"
    local selected=${3:-0}
    
    eval "local count=\${#${_menu_arr_name}[@]}"
    
    [[ $count -eq 0 ]] && return 1
    
    [[ $selected -ge $count ]] && selected=$((count - 1))
    [[ $selected -lt 0 ]] && selected=0
    
    # Ensure initial selection is not a separator
    local init_item
    eval "init_item=\"\${${_menu_arr_name}[\$selected]}\""
    if _is_separator "$init_item"; then
        selected=$(_find_next_valid "$_menu_arr_name" "$selected" 1)
    fi
    
    printf "%s" "$HIDE_CURSOR"
    
    while true; do
        get_term_size
        draw_header "$title"
        
        # Draw menu box
        local box_height=$((count + 4))
        local box_width=$((TERM_COLS - 10))
        local box_row=$(( (TERM_ROWS - box_height) / 2 ))
        local box_col=$(( (TERM_COLS - box_width) / 2 ))
        
        draw_box $box_row $box_col $box_height $box_width
        draw_menu "$_menu_arr_name" $selected $((box_row + 2)) $((box_col + 2)) $((box_width - 4))
        
        # Read key
        IFS= read -rsn1 key
        
        case "$key" in
            $'\x1b')  # Escape sequence
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') # Up
                        selected=$(_find_next_valid "$_menu_arr_name" "$selected" -1)
                        ;;
                    '[B') # Down
                        selected=$(_find_next_valid "$_menu_arr_name" "$selected" 1)
                        ;;
                esac
                ;;
            '') # Enter
                MENU_RESULT=$selected
                printf "%s" "$SHOW_CURSOR"
                return 0
                ;;
            'q'|'Q')
                printf "%s" "$SHOW_CURSOR"
                return 1
                ;;
        esac
    done
}
