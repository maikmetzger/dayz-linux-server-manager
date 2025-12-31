#!/usr/bin/env bash
# =============================================================================
# DayZ Docker Server Manager - Pure Bash TUI
# =============================================================================
# Arrow-key navigation, no external dependencies (no dialog/whiptail)
# DayZ Theme: Black background, Red accents
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# ANSI Colors - DayZ Theme (Black/Blood Red #b20000)
# -----------------------------------------------------------------------------
ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"

# Colors (24-bit true color for #b20000 = RGB 178,0,0)
BLACK="${ESC}[30m"
RED="${ESC}[38;2;178;0;0m"          # #b20000
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
WHITE="${ESC}[37m"
GRAY="${ESC}[90m"

# Backgrounds
BG_BLACK="${ESC}[40m"
BG_RED="${ESC}[48;2;178;0;0m"       # #b20000
BG_DARKGRAY="${ESC}[100m"

# Cursor control
HIDE_CURSOR="${ESC}[?25l"
SHOW_CURSOR="${ESC}[?25h"
CLEAR_SCREEN="${ESC}[2J${ESC}[H"
CLEAR_LINE="${ESC}[2K"

# Move cursor
move_to() { printf "${ESC}[%d;%dH" "$1" "$2"; }
move_up() { printf "${ESC}[%dA" "${1:-1}"; }
move_down() { printf "${ESC}[%dB" "${1:-1}"; }

# -----------------------------------------------------------------------------
# Terminal Setup
# -----------------------------------------------------------------------------
TERM_ROWS=24
TERM_COLS=80

get_term_size() {
    TERM_ROWS=$(tput lines 2>/dev/null || echo 24)
    TERM_COLS=$(tput cols 2>/dev/null || echo 80)
}

cleanup() {
    printf "%s" "$SHOW_CURSOR"
    tput sgr0 2>/dev/null || true
    stty echo 2>/dev/null || true
    printf "%s" "$CLEAR_SCREEN"
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Docker Detection
# -----------------------------------------------------------------------------
DOCKER="docker"
if ! command -v docker &>/dev/null; then
    echo "Error: Docker not found."
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    if command -v sudo &>/dev/null && sudo docker info &>/dev/null 2>&1; then
        DOCKER="sudo docker"
    else
        echo "Error: Cannot connect to Docker daemon. Try: sudo $0"
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Instance Discovery
# -----------------------------------------------------------------------------
declare -a INSTANCE_DIRS=()
declare -a INSTANCE_NAMES=()
declare -a INSTANCE_CONTAINERS=()

SELECTED_DIR=""
SELECTED_NAME=""
SELECTED_CONTAINER=""

scan_instances() {
    INSTANCE_DIRS=()
    INSTANCE_NAMES=()
    INSTANCE_CONTAINERS=()
    
    local invoking_user="${SUDO_USER:-$USER}"
    local invoking_home
    invoking_home="$(getent passwd "$invoking_user" 2>/dev/null | cut -d: -f6 || echo "$HOME")"
    local search_root="${invoking_home}/servers"
    
    [[ -d "$search_root" ]] || return 0
    
    while IFS= read -r marker; do
        [[ -f "$marker" ]] || continue
        local dir name container
        dir="$(dirname "$marker")"
        name="$(grep '^INSTANCE_NAME=' "$marker" 2>/dev/null | cut -d= -f2- | tr -d '"')"
        [[ -z "$name" ]] && name="$(basename "$dir")"
        container="dayz-${name}"
        
        INSTANCE_DIRS+=("$dir")
        INSTANCE_NAMES+=("$name")
        INSTANCE_CONTAINERS+=("$container")
    done < <(find "$search_root" -maxdepth 3 -name ".dayz-instance" 2>/dev/null || true)
}

get_container_status() {
    local container="$1"
    if $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
        echo "RUNNING"
    else
        echo "STOPPED"
    fi
}

# -----------------------------------------------------------------------------
# Mod Name Cache (Steam API)
# -----------------------------------------------------------------------------
MOD_CACHE_DIR="${HOME}/.cache/dayz-server-manager"
MOD_CACHE_FILE="${MOD_CACHE_DIR}/mod-names.cache"
mkdir -p "$MOD_CACHE_DIR" 2>/dev/null || true

get_mod_name() {
    local mod_id="$1"
    
    # Check cache first
    if [[ -f "$MOD_CACHE_FILE" ]]; then
        local cached
        cached=$(grep "^${mod_id}|" "$MOD_CACHE_FILE" 2>/dev/null | head -1 | cut -d'|' -f2-)
        if [[ -n "$cached" && "$cached" != "Mod #${mod_id}" ]]; then
            echo "$cached"
            return
        fi
    fi
    
    # Try Steam API
    local name=""
    if command -v curl &>/dev/null; then
        local response
        response=$(curl -sS --max-time 5 -X POST \
            "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
            -d "itemcount=1" \
            -d "publishedfileids[0]=${mod_id}" 2>/dev/null) || response=""
        
        if [[ -n "$response" ]]; then
            # Try jq first
            if command -v jq &>/dev/null; then
                name=$(echo "$response" | jq -r '.response.publishedfiledetails[0].title // empty' 2>/dev/null) || name=""
            fi
            
            # Fallback: parse with grep/sed if jq failed or isn't installed
            if [[ -z "$name" ]]; then
                # Look for "title":"..." pattern
                name=$(echo "$response" | grep -oP '"title"\s*:\s*"\K[^"]+' 2>/dev/null | head -1) || name=""
            fi
        fi
    fi
    
    # Use fallback if still empty
    [[ -z "$name" ]] && name="Mod #${mod_id}"
    
    # Update cache (remove old entry first)
    if [[ -f "$MOD_CACHE_FILE" ]]; then
        grep -v "^${mod_id}|" "$MOD_CACHE_FILE" > "${MOD_CACHE_FILE}.tmp" 2>/dev/null || true
        mv "${MOD_CACHE_FILE}.tmp" "$MOD_CACHE_FILE" 2>/dev/null || true
    fi
    echo "${mod_id}|${name}" >> "$MOD_CACHE_FILE" 2>/dev/null || true
    
    echo "$name"
}

# -----------------------------------------------------------------------------
# Mod List Parsing
# -----------------------------------------------------------------------------
read_mod_ids_with_status() {
    local file="$1"
    [[ -f "$file" ]] || return
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]}|disabled"
        elif [[ "$line" =~ ^[[:space:]]*([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]}|enabled"
        fi
    done < "$file"
}

# -----------------------------------------------------------------------------
# TUI Drawing Functions
# -----------------------------------------------------------------------------
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
    
    # Footer
    move_to $TERM_ROWS 1
    printf "%s%s" "$BG_DARKGRAY" "$WHITE"
    printf " ↑↓ Navigate  Enter Select  q Quit%$((TERM_COLS-38))s" ""
    printf "%s" "$RESET"
}

draw_box() {
    local row=$1 col=$2 height=$3 width=$4 title="${5:-}"
    
    # Top border
    move_to $row $col
    printf "%s%s┌" "$RED" "$BOLD"
    printf "─%.0s" $(seq 1 $((width-2)))
    printf "┐%s" "$RESET"
    
    # Title
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

# -----------------------------------------------------------------------------
# Menu System
# -----------------------------------------------------------------------------
# Returns selected index in MENU_RESULT
MENU_RESULT=0

draw_menu() {
    local _arr_name=$1
    local selected=$2
    local start_row=$3
    local start_col=$4
    local width=$5
    
    eval "local -a _items=(\"\${${_arr_name}[@]}\")"
    
    local i=0
    for item in "${_items[@]}"; do
        move_to $((start_row + i)) $start_col
        
        if [[ $i -eq $selected ]]; then
            # Strip ANSI color codes from selected item so BG_RED covers entire line
            local clean_item
            clean_item="${item//\\033\[*([0-9;])m/}"
            # Fallback: use sed if parameter expansion doesn't strip all codes
            clean_item=$(printf '%s' "$item" | sed $'s/\033\\[[0-9;]*m//g')
            printf "%s%s ▶ %-$((width-4))s %s" "$BG_RED" "$WHITE$BOLD" "$clean_item" "$RESET"
        else
            printf "%s   %-$((width-4))s %s" "$WHITE" "$item" "$RESET"
        fi
        ((i+=1))
    done
}

run_menu() {
    local _menu_arr_name=$1
    local title="$2"
    local selected=0
    
    eval "local count=\${#${_menu_arr_name}[@]}"
    
    [[ $count -eq 0 ]] && return 1
    
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

# -----------------------------------------------------------------------------
# Input Dialog
# -----------------------------------------------------------------------------
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
    
    # Draw box to tty
    move_to $box_row $box_col >&3
    printf "%s%s┌" "$RED" "$BOLD" >&3
    printf "─%.0s" $(seq 1 $((box_width-2))) >&3
    printf "┐%s" "$RESET" >&3
    
    # Title in box
    move_to $box_row $((box_col + 2)) >&3
    printf "%s%s %s %s" "$RED" "$BOLD" "$title" "$RESET" >&3
    
    # Sides
    for ((i=1; i<box_height-1; i++)); do
        move_to $((box_row+i)) $box_col >&3
        printf "%s│%s" "$RED" "$RESET" >&3
        move_to $((box_row+i)) $((box_col+box_width-1)) >&3
        printf "%s│%s" "$RED" "$RESET" >&3
    done
    
    # Bottom border
    move_to $((box_row+box_height-1)) $box_col >&3
    printf "%s└" "$RED" >&3
    printf "─%.0s" $(seq 1 $((box_width-2))) >&3
    printf "┘%s" "$RESET" >&3
    
    # Prompt
    move_to $((box_row + 2)) $((box_col + 3)) >&3
    printf "%s%s%s" "$WHITE" "$prompt" "$RESET" >&3
    
    # Hint
    move_to $((box_row + 4)) $((box_col + 3)) >&3
    printf "%s(Empty to cancel)%s" "$DIM" "$RESET" >&3
    
    # Input field
    move_to $((box_row + 6)) $((box_col + 3)) >&3
    printf "%s▸ %s%s" "$RED" "$RESET" "$SHOW_CURSOR" >&3
    
    exec 3>&-
    
    local input
    read -r -e -i "$default" input </dev/tty
    printf "%s" "$HIDE_CURSOR" >/dev/tty
    
    echo "$input"
}

# -----------------------------------------------------------------------------
# Confirmation Dialog
# -----------------------------------------------------------------------------
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
# Run Command with Output
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Instance Selector
# -----------------------------------------------------------------------------
select_instance() {
    scan_instances
    
    if [[ ${#INSTANCE_NAMES[@]} -eq 0 ]]; then
        show_message "No DayZ instances found. Run install-dayz-docker.sh first." "Error"
        exit 0
    fi
    
    # Build menu items with status
    local -a items=()
    for i in "${!INSTANCE_NAMES[@]}"; do
        local name="${INSTANCE_NAMES[$i]}"
        local container="${INSTANCE_CONTAINERS[$i]}"
        local status
        status="$(get_container_status "$container")"
        
        local status_icon="${RED}○${RESET}"
        [[ "$status" == "RUNNING" ]] && status_icon="${GREEN}●${RESET}"
        
        items+=("$status_icon $name [$status]")
    done
    
    if run_menu items "DayZ Server Manager - Select Instance"; then
        SELECTED_DIR="${INSTANCE_DIRS[$MENU_RESULT]}"
        SELECTED_NAME="${INSTANCE_NAMES[$MENU_RESULT]}"
        SELECTED_CONTAINER="${INSTANCE_CONTAINERS[$MENU_RESULT]}"
    else
        exit 0
    fi
}

# -----------------------------------------------------------------------------
# Unified Mod Manager - Combined view with Client/Server/Both toggle
# -----------------------------------------------------------------------------
# Mod types:
#   client - Only in mods.txt (players download this)
#   server - Only in servermods.txt (server-side only)
#   both   - In both files

get_mod_type() {
    local mod_id="$1"
    local mods_file="$2"
    local servermods_file="$3"
    
    local in_mods=0 in_servermods=0
    
    grep -qE "^[[:space:]]*${mod_id}[[:space:]]*$" "$mods_file" 2>/dev/null && in_mods=1
    grep -qE "^[[:space:]]*${mod_id}[[:space:]]*$" "$servermods_file" 2>/dev/null && in_servermods=1
    
    if [[ $in_mods -eq 1 && $in_servermods -eq 1 ]]; then
        echo "both"
    elif [[ $in_mods -eq 1 ]]; then
        echo "client"
    elif [[ $in_servermods -eq 1 ]]; then
        echo "server"
    else
        echo "disabled"
    fi
}

is_mod_in_file() {
    local mod_id="$1"
    local file="$2"
    grep -qE "^[[:space:]]*#?[[:space:]]*${mod_id}[[:space:]]*$" "$file" 2>/dev/null
}

add_mod_to_file() {
    local mod_id="$1"
    local file="$2"
    if ! grep -qE "^[[:space:]]*#?[[:space:]]*${mod_id}[[:space:]]*$" "$file" 2>/dev/null; then
        echo "$mod_id" >> "$file"
    else
        # Enable if commented
        sed -i "s/^[[:space:]]*#[[:space:]]*${mod_id}[[:space:]]*$/${mod_id}/" "$file"
    fi
}

remove_mod_from_file() {
    local mod_id="$1"
    local file="$2"
    # Comment out instead of delete
    sed -i "s/^[[:space:]]*${mod_id}[[:space:]]*$/# ${mod_id}/" "$file"
}

get_all_mod_ids() {
    local mods_file="$1"
    local servermods_file="$2"
    
    {
        awk '/^[[:space:]]*#?[[:space:]]*[0-9]+/ { gsub(/^[[:space:]]*#?[[:space:]]*/,""); gsub(/[[:space:]]*$/,""); print $1 }' "$mods_file" 2>/dev/null
        awk '/^[[:space:]]*#?[[:space:]]*[0-9]+/ { gsub(/^[[:space:]]*#?[[:space:]]*/,""); gsub(/[[:space:]]*$/,""); print $1 }' "$servermods_file" 2>/dev/null
    } | sort -u | grep -E '^[0-9]+$'
}

mod_manager() {
    local mods_file="${SELECTED_DIR}/data/config/mods.txt"
    local servermods_file="${SELECTED_DIR}/data/config/servermods.txt"
    
    [[ -f "$mods_file" ]] || touch "$mods_file"
    [[ -f "$servermods_file" ]] || touch "$servermods_file"
    
    local selected=0
    
    while true; do
        get_term_size
        
        # Get all unique mod IDs from both files
        local -a mod_ids=()
        local -a mod_names=()
        local -a mod_types=()
        
        while IFS= read -r mid; do
            [[ -z "$mid" ]] && continue
            mod_ids+=("$mid")
            
            local mname
            mname="$(get_mod_name "$mid")"
            local max_name=$((TERM_COLS - 35))
            [[ $max_name -lt 20 ]] && max_name=20
            [[ ${#mname} -gt $max_name ]] && mname="${mname:0:$((max_name-3))}..."
            mod_names+=("$mname")
            
            local mtype
            mtype="$(get_mod_type "$mid" "$mods_file" "$servermods_file")"
            mod_types+=("$mtype")
        done < <(get_all_mod_ids "$mods_file" "$servermods_file")
        
        local mod_count=${#mod_ids[@]}
        local total_items=$((mod_count + 3))  # mods + Add + Sync + Back
        
        # Clamp selection
        [[ $selected -lt 0 ]] && selected=0
        [[ $selected -ge $total_items ]] && selected=$((total_items - 1))
        
        # Draw screen
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        
        # Header bar (full width)
        move_to 1 1
        printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Mod Manager - $SELECTED_NAME" "$RESET"
        
        # Table header (row 3)
        local table_start=3
        local col_status=2
        local col_name=10
        local col_id=$((TERM_COLS - 25))
        local col_type=$((TERM_COLS - 10))
        
        move_to $table_start 1
        printf "%s%s" "$DIM" "$RED"
        printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        
        move_to $((table_start + 1)) $col_status
        printf "%s%sSTATUS%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_name
        printf "%s%sMOD NAME%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_id
        printf "%s%sWORKSHOP ID%s" "$DIM" "$WHITE" "$RESET"
        move_to $((table_start + 1)) $col_type
        printf "%s%sTYPE%s" "$DIM" "$WHITE" "$RESET"
        
        move_to $((table_start + 2)) 1
        printf "%s%s" "$DIM" "$RED"
        printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        
        # Mod rows
        local row=$((table_start + 3))
        if [[ $mod_count -eq 0 ]]; then
            move_to $row 1
            printf "%s  (No mods - press A to add)%s" "$DIM" "$RESET"
            row=$((row+1))
        fi
        for i in "${!mod_ids[@]}"; do
            local mid="${mod_ids[$i]}"
            local mname="${mod_names[$i]}"
            local mtype="${mod_types[$i]}"
            
            local status_icon type_label type_short
            case "$mtype" in
                both)     status_icon="✓"; type_label="[C+S]"; type_short="C+S" ;;
                client)   status_icon="✓"; type_label="[Cli]"; type_short="Cli" ;;
                server)   status_icon="✓"; type_label="[Srv]"; type_short="Srv" ;;
                disabled) status_icon="✗"; type_label="[Off]"; type_short="Off" ;;
            esac
            
            move_to $row 1
            if [[ $i -eq $selected ]]; then
                # Selected row - full red background with status icon
                printf "%s%s" "$BG_RED" "$WHITE$BOLD"
                printf " ▶ %s  " "$status_icon"
                printf "%-$((col_id - col_name - 2))s" "$mname"
                printf "%-14s" "$mid"
                printf "[%s]" "$type_short"
                # Fill rest of line
                local filled=$((8 + col_id - col_name - 2 + 14 + 5))
                [[ $filled -lt $TERM_COLS ]] && printf "%*s" "$((TERM_COLS - filled))" ""
                printf "%s" "$RESET"
            else
                # Normal row with colors
                if [[ "$mtype" == "disabled" ]]; then
                    printf "  %s%s%s     " "$RED" "$status_icon" "$RESET"
                else
                    printf "  %s%s%s     " "$GREEN" "$status_icon" "$RESET"
                fi
                printf "%-$((col_id - col_name - 2))s" "$mname"
                printf "%s%-14s%s" "$DIM" "$mid" "$RESET"
                case "$mtype" in
                    both)     printf "%s%s%s" "$GREEN" "$type_label" "$RESET" ;;
                    client)   printf "%s%s%s" "$YELLOW" "$type_label" "$RESET" ;;
                    server)   printf "%s%s%s" "$YELLOW" "$type_label" "$RESET" ;;
                    disabled) printf "%s%s%s" "$RED" "$type_label" "$RESET" ;;
                esac
            fi
            row=$((row+1))
        done
        
        # Separator before actions
        move_to $row 1
        printf "%s%s" "$DIM" "$RED"
        printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        ((row++))
        
        # Action bar (horizontal) - full width
        local action_row=$row
        local actions=("[A] Add" "[S] Sync" "[Q] Back")
        local action_indices=(0 1 2)  # Add=mod_count, Sync=mod_count+1, Back=mod_count+2
        
        move_to $action_row 2
        for a in "${!actions[@]}"; do
            local action_idx=$((mod_count + a))
            if [[ $selected -eq $action_idx ]]; then
                printf "%s%s ▶ %s %s" "$BG_RED" "$WHITE$BOLD" "${actions[$a]}" "$RESET"
            else
                printf "   %s   " "${actions[$a]}"
            fi
            printf "   "
        done
        
        # Footer
        move_to $TERM_ROWS 1
        printf "%s%s ↑↓ Select   Enter Toggle/Action   A Add   S Sync   Q Back%*s%s" "$BG_DARKGRAY" "$WHITE" "$((TERM_COLS - 58))" "" "$RESET"
        
        # Read input
        IFS= read -rsn1 key
        
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') if ((selected > 0)); then selected=$((selected-1)); fi ;;
                    '[B') if ((selected < total_items - 1)); then selected=$((selected+1)); fi ;;
                esac
                ;;
            '')  # Enter
                if [[ $selected -lt $mod_count ]]; then
                    # Toggle mod type
                    local mid="${mod_ids[$selected]}"
                    local mtype="${mod_types[$selected]}"
                    case "$mtype" in
                        disabled) add_mod_to_file "$mid" "$mods_file" ;;
                        client) remove_mod_from_file "$mid" "$mods_file"; add_mod_to_file "$mid" "$servermods_file" ;;
                        server) add_mod_to_file "$mid" "$mods_file"; add_mod_to_file "$mid" "$servermods_file" ;;
                        both) remove_mod_from_file "$mid" "$mods_file"; remove_mod_from_file "$mid" "$servermods_file" ;;
                    esac
                elif [[ $selected -eq $mod_count ]]; then
                    # Add
                    local new_id
                    new_id=$(read_input "Enter Steam Workshop ID:" "" "Add Workshop Mod")
                    if [[ "$new_id" =~ ^[0-9]+$ ]]; then
                        if ! is_mod_in_file "$new_id" "$mods_file" && ! is_mod_in_file "$new_id" "$servermods_file"; then
                            echo "$new_id" >> "$mods_file"
                            show_message "Added mod $new_id as [Client]" "Mod Added"
                        else
                            show_message "Mod already in list" "Already Exists"
                        fi
                    fi
                elif [[ $selected -eq $((mod_count + 1)) ]]; then
                    # Sync
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" != "RUNNING" ]]; then
                        show_message "Container must be running to sync"
                    else
                        run_with_output "Syncing Mods" $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh sync-mods
                        run_with_output "Syncing Server Mods" $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh sync-servermods
                    fi
                elif [[ $selected -eq $((mod_count + 2)) ]]; then
                    # Back
                    return
                fi
                ;;
            'a'|'A')
                local new_id
                new_id=$(read_input "Enter Steam Workshop ID:" "" "Add Workshop Mod")
                if [[ "$new_id" =~ ^[0-9]+$ ]]; then
                    if ! is_mod_in_file "$new_id" "$mods_file" && ! is_mod_in_file "$new_id" "$servermods_file"; then
                        echo "$new_id" >> "$mods_file"
                        show_message "Added mod $new_id as [Client]" "Mod Added"
                    else
                        show_message "Mod already in list" "Already Exists"
                    fi
                fi
                ;;
            's'|'S')
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to sync"
                else
                    run_with_output "Syncing Mods" $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh sync-mods
                    run_with_output "Syncing Server Mods" $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh sync-servermods
                fi
                ;;
            'q'|'Q')
                return
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Main Menu
# -----------------------------------------------------------------------------
main_menu() {
    while true; do
        local status
        status="$(get_container_status "$SELECTED_CONTAINER")"
        
        local status_text="${RED}STOPPED${RESET}"
        [[ "$status" == "RUNNING" ]] && status_text="${GREEN}● RUNNING${RESET}"
        
        local -a items=(
            "▶  Start Server"
            "■  Stop Server"
            "↻  Restart Server"
            "--------------------"
            "📋 View Logs"
            "💻 Enter Shell"
            "--------------------"
            "🔧 Manage Mods"
            "⬆  Update Server"
            "--------------------"
            "← Switch Instance"
        )
        
        if ! run_menu items "DayZ: $SELECTED_NAME [$status_text]"; then
            exit 0
        fi
        
        case $MENU_RESULT in
            0) # Start
                run_with_output "Starting Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose up -d"
                ;;
            1) # Stop
                run_with_output "Stopping Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose stop"
                ;;
            2) # Restart
                run_with_output "Restarting Server" bash -c "cd '$SELECTED_DIR' && $DOCKER compose restart"
                ;;
            3) # Separator
                ;;
            4) # Logs
                run_with_output "Container Logs" $DOCKER logs --tail=100 "$SELECTED_CONTAINER"
                ;;
            5) # Shell
                printf "%s%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
                echo "Entering container shell (type 'exit' to return)..."
                $DOCKER exec -it "$SELECTED_CONTAINER" /bin/bash || echo "Container not running"
                read -rp "Press Enter to continue..."
                printf "%s" "$HIDE_CURSOR"
                ;;
            6) # Separator
                ;;
            7) # Mod Manager (unified)
                mod_manager
                ;;
            8) # Update
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to update"
                else
                    run_with_output "Updating Server" $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh update-server
                fi
                ;;
            9) # Separator
                ;;
            10) # Switch instance
                select_instance
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------
main() {
    get_term_size
    
    if [[ $TERM_ROWS -lt 15 ]] || [[ $TERM_COLS -lt 50 ]]; then
        echo "Terminal too small. Minimum: 50x15"
        exit 1
    fi
    
    printf "%s" "$HIDE_CURSOR"
    
    select_instance
    main_menu
}

main "$@"