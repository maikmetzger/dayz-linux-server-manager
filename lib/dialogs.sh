#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Dialog Components
# =============================================================================
# User interaction dialogs: input, confirm, message boxes
# Requires: lib/colors.sh, lib/tui.sh
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_DIALOGS_LOADED:-}" ]] && return 0
_DAYZ_DIALOGS_LOADED=1

# -----------------------------------------------------------------------------
# Text Input Dialog
# -----------------------------------------------------------------------------

# Show an input dialog and return user input
# Usage: result=$(read_input "Prompt:" "default_value" "Title")
read_input() {
    local prompt="$1"
    local default="${2:-}"
    local title="${3:-Input}"
    
    # All display output goes to /dev/tty so it renders even when captured in $()
    exec 3>/dev/tty
    
    get_term_size
    
    printf "%s" "$CLEAR_SCREEN" >&3
    
    # Header bar
    move_to 1 1 >&3
    printf "%s%s" "$BG_RED" "$WHITE$BOLD" >&3
    printf " %-$((TERM_COLS-1))s" "$title" >&3
    printf "%s" "$RESET" >&3
    
    local box_width=60
    [[ $box_width -gt $((TERM_COLS - 10)) ]] && box_width=$((TERM_COLS - 10))
    local box_height=9
    local box_row=$(( (TERM_ROWS - box_height) / 2 ))
    local box_col=$(( (TERM_COLS - box_width) / 2 ))
    
    # Calculate input field position
    local input_row=$((box_row + 6))
    local input_col=$((box_col + 5))
    
    # Draw box to tty
    move_to $box_row $box_col >&3
    printf "%s%s┌" "$RED" "$BOLD" >&3
    printf "─%.0s" $(seq 1 $((box_width-2))) >&3
    printf "┐%s" "$RESET" >&3
    
    # Title in box
    move_to $box_row $((box_col + 2)) >&3
    printf "%s%s %s %s" "$RED" "$BOLD" "$title" "$RESET" >&3
    
    # Sides and clear interior
    for ((i=1; i<box_height-1; i++)); do
        move_to $((box_row+i)) $box_col >&3
        printf "%s│%s" "$RED" "$RESET" >&3
        printf "%*s" "$((box_width-2))" "" >&3
        move_to $((box_row+i)) $((box_col+box_width-1)) >&3
        printf "%s│%s" "$RED" "$RESET" >&3
    done
    
    # Bottom border
    move_to $((box_row+box_height-1)) $box_col >&3
    printf "%s└" "$RED" >&3
    printf "─%.0s" $(seq 1 $((box_width-2))) >&3
    printf "┘%s" "$RESET" >&3
    
    # Prompt with default hint
    move_to $((box_row + 2)) $((box_col + 3)) >&3
    printf "%s%s%s" "$WHITE" "$prompt" "$RESET" >&3
    
    # Show default value hint
    if [[ -n "$default" ]]; then
        move_to $((box_row + 4)) $((box_col + 3)) >&3
        printf "%sDefault: %s%s" "$DIM" "$default" "$RESET" >&3
    else
        move_to $((box_row + 4)) $((box_col + 3)) >&3
        printf "%s(Empty to cancel)%s" "$DIM" "$RESET" >&3
    fi
    
    # Input field prompt
    move_to $input_row $((box_col + 3)) >&3
    printf "%s▸ %s" "$RED" "$RESET" >&3
    
    exec 3>&-
    
    # Show cursor and position for input
    printf "%s" "$SHOW_CURSOR" >/dev/tty
    move_to $input_row $input_col >/dev/tty
    
    # Simple read without -e -i to avoid cursor positioning bugs
    local input=""
    read -r input </dev/tty
    
    printf "%s" "$HIDE_CURSOR" >/dev/tty
    
    # If empty or contains Escape (\e), use the default or return empty (cancel)
    input="${input//[$'\e']/}"
    if [[ -z "$input" && -n "$default" ]]; then
        echo "$default"
    else
        echo "$input"
    fi
}

# -----------------------------------------------------------------------------
# Confirmation Dialog
# -----------------------------------------------------------------------------

# Show a yes/no confirmation dialog
# Usage: if confirm "Are you sure?" "n"; then ... fi
confirm() {
    local message="$1"
    local default="${2:-n}"
    
    get_term_size
    draw_header "Confirm"
    
    local box_width=50
    local box_height=7
    local box_row=$(( (TERM_ROWS - box_height) / 2 ))
    local box_col=$(( (TERM_COLS - box_width) / 2 ))
    
    draw_box $box_row $box_col $box_height $box_width
    
    move_to $((box_row + 2)) $((box_col + 3))
    printf "%s%s%s" "$WHITE" "$message" "$RESET"
    
    move_to $((box_row + 4)) $((box_col + 3))
    if [[ "$default" == "y" ]]; then
        printf "%s[Y]%s/n : " "$GREEN$BOLD" "$RESET"
    else
        printf "y/%s[N]%s : " "$RED$BOLD" "$RESET"
    fi
    
    printf "%s" "$SHOW_CURSOR"
    read -rsn1 answer
    printf "%s" "$HIDE_CURSOR"
    
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# Message Box
# -----------------------------------------------------------------------------

# Show an informational message and wait for keypress
# Usage: show_message "Message text" "Title"
show_message() {
    local message="$1"
    local title="${2:-Info}"
    
    get_term_size
    draw_header "$title"
    
    local box_width=60
    local box_height=7
    local box_row=$(( (TERM_ROWS - box_height) / 2 ))
    local box_col=$(( (TERM_COLS - box_width) / 2 ))
    
    draw_box $box_row $box_col $box_height $box_width "$title"
    
    move_to $((box_row + 3)) $((box_col + 3))
    printf "%s%s%s" "$WHITE" "$message" "$RESET"
    
    move_to $((box_row + 5)) $((box_col + 3))
    printf "%s[Press any key]%s" "$DIM" "$RESET"
    
    read -rsn1
}

# -----------------------------------------------------------------------------
# Command Execution with Output
# -----------------------------------------------------------------------------

# Execute a command and show its output, then wait for keypress
# Usage: run_with_output "Title" command arg1 arg2 ...
run_with_output() {
    local title="$1"
    shift
    local cmd=("$@")
    
    printf "%s%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
    printf "%s%s%s\n" "$RED$BOLD" "═══ $title ═══" "$RESET"
    printf "%s%s%s\n\n" "$DIM" "Running: ${cmd[*]}" "$RESET"
    
    "${cmd[@]}" 2>&1 || true
    
    printf "\n%s[Press any key to continue]%s" "$DIM" "$RESET"
    read -rsn1
    printf "%s" "$HIDE_CURSOR"
}
