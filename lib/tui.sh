#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Terminal UI Primitives
# =============================================================================
# Terminal setup, sizing, and drawing primitives
# Requires: lib/colors.sh
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_TUI_LOADED:-}" ]] && return 0
_DAYZ_TUI_LOADED=1

# -----------------------------------------------------------------------------
# Terminal Size
# -----------------------------------------------------------------------------
TERM_ROWS=24
TERM_COLS=80

# Update terminal dimensions
get_term_size() {
    TERM_ROWS=$(tput lines 2>/dev/null || echo 24)
    TERM_COLS=$(tput cols 2>/dev/null || echo 80)
}

# -----------------------------------------------------------------------------
# Cleanup Handler
# -----------------------------------------------------------------------------
# Restore terminal state on exit
# Call: trap cleanup EXIT
cleanup() {
    printf "%s" "$SHOW_CURSOR"
    tput sgr0 2>/dev/null || true
    stty echo 2>/dev/null || true
    printf "%s" "$CLEAR_SCREEN"
}

# -----------------------------------------------------------------------------
# Drawing Primitives
# -----------------------------------------------------------------------------

# Draw header bar with title (full width, red background)
# Usage: draw_header "Title Text"
draw_header() {
    local title="$1"
    get_term_size
    
    printf "%s" "$CLEAR_SCREEN"
    
    # Strip ANSI codes from title to calculate actual visible length
    local clean_title
    clean_title=$(printf '%s' "$title" | sed $'s/\033\\[[0-9;]*m//g')
    local title_len=${#clean_title}
    local padding=$((TERM_COLS - title_len - 1))
    [[ $padding -lt 0 ]] && padding=0
    
    # Header bar - red background full width
    move_to 1 1
    printf "%s%s %s%${padding}s%s" "$BG_RED" "$WHITE$BOLD" "$title" "" "$RESET"
    
    # Footer hint
    move_to $TERM_ROWS 1
    printf "%s%s" "$BG_DARKGRAY" "$WHITE"
    printf " ↑↓ Navigate  Enter Select  q Quit%$((TERM_COLS-38))s" ""
    printf "%s" "$RESET"
}

# Draw a bordered box
# Usage: draw_box row col height width [title]
draw_box() {
    local row=$1 col=$2 height=$3 width=$4 title="${5:-}"
    
    # Top border
    move_to $row $col
    printf "%s%s┌" "$RED" "$BOLD"
    printf "─%.0s" $(seq 1 $((width-2)))
    printf "┐%s" "$RESET"
    
    # Title (optional)
    if [[ -n "$title" ]]; then
        move_to $row $((col + 2))
        printf "%s%s %s %s" "$RED" "$BOLD" "$title" "$RESET"
    fi
    
    # Sides
    for ((i=1; i<height-1; i++)); do
        move_to $((row+i)) $col
        printf "%s│%s" "$RED" "$RESET"
        move_to $((row+i)) $((col+width-1))
        printf "%s│%s" "$RED" "$RESET"
    done
    
    # Bottom border
    move_to $((row+height-1)) $col
    printf "%s└" "$RED"
    printf "─%.0s" $(seq 1 $((width-2)))
    printf "┘%s" "$RESET"
}
