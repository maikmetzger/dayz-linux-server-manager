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
# Enable alternate screen buffer
tui_init() {
    tput smcup 2>/dev/null || printf "${ESC}[?1049h"
    printf "%s" "$HIDE_CURSOR"
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
    tput rmcup 2>/dev/null || printf "${ESC}[?1049l"
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
    # Header bar - red background full width using Erase Line (EL)
    move_to 1 1
    printf "%s%s %s%s%s" "$BG_RED" "$WHITE$BOLD" "$title" "${ESC}[K" "$RESET"
    
    # Footer hint
    move_to $TERM_ROWS 1
    printf "%s%s" "$BG_DARKGRAY" "$WHITE"
    # Use EL to fill footer background
    printf " ↑↓ Navigate  Enter Select  q Quit%s" "${ESC}[K"
    printf "%s" "$RESET"
}

# Draw a bordered box
# Usage: draw_box row col height width [title] [color]
draw_box() {
    local row=$1 col=$2 height=$3 width=$4 title="${5:-}" color="${6:-$RED}"
    
    # Top border
    move_to $row $col
    printf "%s%s┌" "$color" "$BOLD"
    printf "─%.0s" $(seq 1 $((width-2)))
    printf "┐%s" "$RESET"
    
    # Title (optional)
    if [[ -n "$title" ]]; then
        move_to $row $((col + 2))
        printf "%s%s %s %s" "$color" "$BOLD" "$title" "$RESET"
    fi
    
    # Sides and background fill
    for ((i=1; i<height-1; i++)); do
        move_to $((row+i)) $col
        printf "%s│%s%*s%s│%s" "$color" "$BOLD" $((width-2)) "" "$color" "$BOLD"
    done
    
    # Bottom border
    move_to $((row+height-1)) $col
    printf "%s└" "$color"
    printf "─%.0s" $(seq 1 $((width-2)))
    printf "┘%s" "$RESET"
}
