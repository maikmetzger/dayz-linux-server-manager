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
    
    local box_width=60
    local max_text_width=$((box_width - 6))
    
    # Split by newlines first, then word-wrap each line
    local -a lines=()
    while IFS= read -r input_line; do
        if [[ -z "$input_line" ]]; then
            lines+=("")  # Preserve empty lines
        else
            # Word-wrap this line
            local current_line=""
            for word in $input_line; do
                if [[ ${#current_line} -eq 0 ]]; then
                    current_line="$word"
                elif [[ $((${#current_line} + 1 + ${#word})) -le $max_text_width ]]; then
                    current_line="$current_line $word"
                else
                    lines+=("$current_line")
                    current_line="$word"
                fi
            done
            [[ -n "$current_line" ]] && lines+=("$current_line")
        fi
    done <<< "$message"
    
    local line_count=${#lines[@]}
    [[ $line_count -lt 1 ]] && line_count=1
    [[ $line_count -gt 15 ]] && line_count=15  # Cap height
    local box_height=$((line_count + 5))
    
    local box_row=$(( (TERM_ROWS - box_height) / 2 ))
    local box_col=$(( (TERM_COLS - box_width) / 2 ))
    
    draw_box $box_row $box_col $box_height $box_width
    
    # Print each line (capped at visible area)
    local max_lines=$((box_height - 4))
    for ((i=0; i<${#lines[@]} && i<max_lines; i++)); do
        move_to $((box_row + 2 + i)) $((box_col + 3))
        printf "%s%-${max_text_width}s%s" "$WHITE" "${lines[$i]:0:$max_text_width}" "$RESET"
    done
    
    move_to $((box_row + box_height - 2)) $((box_col + 3))
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
# Progress Bar Dialog (Auto-closes, no keypress needed)
# -----------------------------------------------------------------------------

# Global vars for progress bar state
_PROGRESS_BOX_ROW=0
_PROGRESS_BOX_COL=0
_PROGRESS_BOX_WIDTH=50
_PROGRESS_BAR_WIDTH=40

# Start a progress bar dialog
# Usage: show_progress_start "Title" "Initial message"
show_progress_start() {
    local title="${1:-Progress}"
    local message="${2:-Working...}"
    
    get_term_size
    draw_header "$title"
    
    _PROGRESS_BOX_WIDTH=50
    _PROGRESS_BAR_WIDTH=25
    local box_height=7
    _PROGRESS_BOX_ROW=$(( (TERM_ROWS - box_height) / 2 ))
    _PROGRESS_BOX_COL=$(( (TERM_COLS - _PROGRESS_BOX_WIDTH) / 2 ))
    
    draw_box $_PROGRESS_BOX_ROW $_PROGRESS_BOX_COL $box_height $_PROGRESS_BOX_WIDTH "$title"
    
    # Initial message
    move_to $((_PROGRESS_BOX_ROW + 2)) $((_PROGRESS_BOX_COL + 3))
    printf "%s%-$((_PROGRESS_BOX_WIDTH - 6))s%s" "$WHITE" "${message:0:$((_PROGRESS_BOX_WIDTH - 6))}" "$RESET"
    
    # Empty progress bar
    move_to $((_PROGRESS_BOX_ROW + 4)) $((_PROGRESS_BOX_COL + 3))
    printf "%s[%s]%s" "$DIM" "$(printf '%*s' $_PROGRESS_BAR_WIDTH ' ')" "$RESET"
}

# Update progress bar
# Usage: show_progress_update "Message" 50 (0-100 percent)
show_progress_update() {
    local message="${1:-Working...}"
    local percent="${2:-0}"
    
    [[ $percent -lt 0 ]] && percent=0
    [[ $percent -gt 100 ]] && percent=100
    
    local filled=$(( (_PROGRESS_BAR_WIDTH * percent) / 100 ))
    local empty=$((_PROGRESS_BAR_WIDTH - filled))
    
    # Update message
    move_to $((_PROGRESS_BOX_ROW + 2)) $((_PROGRESS_BOX_COL + 3))
    printf "%s%-$((_PROGRESS_BOX_WIDTH - 6))s%s" "$WHITE" "${message:0:$((_PROGRESS_BOX_WIDTH - 6))}" "$RESET"
    
    # Update progress bar - use ASCII chars for Docker/SSH compatibility
    move_to $((_PROGRESS_BOX_ROW + 4)) $((_PROGRESS_BOX_COL + 3))
    printf "[%s%s] %3d%%      " "$(printf '%*s' $filled '' | tr ' ' '#')" "$(printf '%*s' $empty '')" "$percent"
}

# End progress bar (auto-closes, no keypress)
# Usage: show_progress_end "Done!" [wait_ms]
show_progress_end() {
    local final_message="${1:-Done!}"
    local wait_ms="${2:-500}"
    
    # Show 100% complete
    show_progress_update "$final_message" 100
    
    # Brief pause so user sees completion
    # Integer arithmetic only: bc is not a dependency of this project
    sleep "$(printf '%d.%03d' $((wait_ms / 1000)) $((wait_ms % 1000)))"
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
