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
draw_menu() {
    local _arr_name=$1
    local selected=$2
    local start_row=$3
    local start_col=$4
    local width=$5
    
    eval "local -a _items=(\"\${${_arr_name}[@]}\")"
    
    # Fixed column for text (after emoji + spacing)
    # Emoji typically 2 chars + 2 spaces = 4 chars from start
    local text_offset=6
    
    local i=0
    for item in "${_items[@]}"; do
        move_to $((start_row + i)) $start_col
        
        # Check if item starts with emoji (high unicode range)
        local emoji=""
        local text="$item"
        
        # Extract emoji prefix if present (handles multi-byte emoji)
        # Regex: starts with emoji characters (non-ASCII)
        if [[ "$item" =~ ^([^[:ascii:]]+)[[:space:]]*(.*) ]]; then
            emoji="${BASH_REMATCH[1]}"
            text="${BASH_REMATCH[2]}"
        fi
        
        if [[ $i -eq $selected ]]; then
            # Selected row with red background
            printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$width" ""
            move_to $((start_row + i)) $start_col
            if [[ -n "$emoji" ]]; then
                printf "%s%s ▶ %s" "$BG_RED" "$WHITE$BOLD" "$emoji"
                move_to $((start_row + i)) $((start_col + text_offset))
                printf "%s" "$text"
            else
                printf "%s%s ▶ %s" "$BG_RED" "$WHITE$BOLD" "$text"
            fi
            printf "%s" "$RESET"
        else
            if [[ -n "$emoji" ]]; then
                printf "%s   %s" "$WHITE" "$emoji"
                move_to $((start_row + i)) $((start_col + text_offset))
                printf "%s%s" "$WHITE" "$text"
            else
                printf "%s   %s" "$WHITE" "$text"
            fi
            printf "%s" "$RESET"
        fi
        ((i+=1))
    done
}

# -----------------------------------------------------------------------------
# Menu Runner
# -----------------------------------------------------------------------------

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
                    '[A') if ((selected > 0)); then selected=$((selected-1)); fi ;;  # Up
                    '[B') if ((selected < count-1)); then selected=$((selected+1)); fi ;;  # Down
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
