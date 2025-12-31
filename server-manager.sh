#!/usr/bin/env bash
# =============================================================================
# DayZ Docker Server Manager - Pure Bash TUI
# =============================================================================
# Arrow-key navigation, no external dependencies (no dialog/whiptail)
# DayZ Theme: Black background, Red accents
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# ANSI Colors - DayZ Theme (Black/Red)
# -----------------------------------------------------------------------------
ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"

# Colors
BLACK="${ESC}[30m"
RED="${ESC}[31m"
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
WHITE="${ESC}[37m"
GRAY="${ESC}[90m"

# Backgrounds
BG_BLACK="${ESC}[40m"
BG_RED="${ESC}[41m"
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
    
    if [[ -f "$MOD_CACHE_FILE" ]]; then
        local cached
        cached=$(grep "^${mod_id}|" "$MOD_CACHE_FILE" 2>/dev/null | cut -d'|' -f2-)
        if [[ -n "$cached" ]]; then
            echo "$cached"
            return
        fi
    fi
    
    # Try Steam API
    local name=""
    if command -v curl &>/dev/null; then
        local response
        response=$(curl -s --max-time 3 -X POST \
            "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
            -d "itemcount=1" \
            -d "publishedfileids[0]=${mod_id}" 2>/dev/null || true)
        
        if command -v jq &>/dev/null && [[ -n "$response" ]]; then
            name=$(echo "$response" | jq -r '.response.publishedfiledetails[0].title // empty' 2>/dev/null || true)
        fi
    fi
    
    [[ -z "$name" ]] && name="Mod #${mod_id}"
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
    printf "%s" "$BG_BLACK"
    
    # Fill screen with black
    for ((i=1; i<=TERM_ROWS; i++)); do
        move_to $i 1
        printf "%${TERM_COLS}s" ""
    done
    
    # Header bar
    move_to 1 1
    printf "%s%s" "$BG_RED" "$WHITE$BOLD"
    printf " %-$((TERM_COLS-1))s" "$title"
    printf "%s" "$RESET$BG_BLACK"
    
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
    local -n items=$1
    local selected=$2
    local start_row=$3
    local start_col=$4
    local width=$5
    
    local i=0
    for item in "${items[@]}"; do
        move_to $((start_row + i)) $start_col
        
        if [[ $i -eq $selected ]]; then
            printf "%s%s ▶ %-$((width-4))s %s" "$BG_RED" "$WHITE$BOLD" "$item" "$RESET"
        else
            printf "%s   %-$((width-4))s %s" "$WHITE" "$item" "$RESET"
        fi
        ((i++))
    done
}

run_menu() {
    local -n menu_items=$1
    local title="$2"
    local selected=0
    local count=${#menu_items[@]}
    
    [[ $count -eq 0 ]] && return 1
    
    printf "%s%s" "$HIDE_CURSOR" "$BG_BLACK"
    
    while true; do
        get_term_size
        draw_header "$title"
        
        # Draw menu box
        local box_height=$((count + 4))
        local box_width=$((TERM_COLS - 10))
        local box_row=$(( (TERM_ROWS - box_height) / 2 ))
        local box_col=$(( (TERM_COLS - box_width) / 2 ))
        
        draw_box $box_row $box_col $box_height $box_width
        draw_menu menu_items $selected $((box_row + 2)) $((box_col + 2)) $((box_width - 4))
        
        # Read key
        IFS= read -rsn1 key
        
        case "$key" in
            $'\x1b')  # Escape sequence
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') ((selected > 0)) && ((selected--)) ;;  # Up
                    '[B') ((selected < count-1)) && ((selected++)) ;;  # Down
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
    
    get_term_size
    draw_header "Input"
    
    local box_width=60
    local box_height=7
    local box_row=$(( (TERM_ROWS - box_height) / 2 ))
    local box_col=$(( (TERM_COLS - box_width) / 2 ))
    
    draw_box $box_row $box_col $box_height $box_width
    
    move_to $((box_row + 2)) $((box_col + 3))
    printf "%s%s%s" "$WHITE" "$prompt" "$RESET"
    
    move_to $((box_row + 4)) $((box_col + 3))
    printf "%s" "$SHOW_CURSOR"
    
    local input
    read -r -e -i "$default" input
    printf "%s" "$HIDE_CURSOR"
    
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
# Mod Manager
# -----------------------------------------------------------------------------
mod_manager() {
    local mods_file="${SELECTED_DIR}/data/config/mods.txt"
    local title_prefix="$1"
    [[ "$1" == "server" ]] && mods_file="${SELECTED_DIR}/data/config/servermods.txt"
    
    [[ -f "$mods_file" ]] || touch "$mods_file"
    
    while true; do
        # Read mods
        local -a mod_ids=()
        local -a mod_statuses=()
        local -a mod_names=()
        
        while IFS='|' read -r mid mstatus; do
            mod_ids+=("$mid")
            mod_statuses+=("$mstatus")
            local mname
            mname="$(get_mod_name "$mid")"
            [[ ${#mname} -gt 30 ]] && mname="${mname:0:27}..."
            mod_names+=("$mname")
        done < <(read_mod_ids_with_status "$mods_file")
        
        # Build display items
        local -a items=()
        for i in "${!mod_ids[@]}"; do
            local icon="✗"
            local color="$RED"
            if [[ "${mod_statuses[$i]}" == "enabled" ]]; then
                icon="✓"
                color="$GREEN"
            fi
            items+=("$color$icon$RESET ${mod_names[$i]} [${mod_ids[$i]}]")
        done
        
        items+=("────────────────────────────────")
        items+=("${GREEN}+${RESET} Add mod")
        items+=("${YELLOW}↻${RESET} Sync all mods")
        items+=("← Back")
        
        local title="${title_prefix^} Mods - $SELECTED_NAME"
        if ! run_menu items "$title"; then
            return
        fi
        
        local mod_count=${#mod_ids[@]}
        
        if [[ $MENU_RESULT -lt $mod_count ]]; then
            # Toggle mod
            local mid="${mod_ids[$MENU_RESULT]}"
            local mstatus="${mod_statuses[$MENU_RESULT]}"
            
            if [[ "$mstatus" == "enabled" ]]; then
                sed -i "s/^[[:space:]]*${mid}[[:space:]]*$/# ${mid}/" "$mods_file"
            else
                sed -i "s/^[[:space:]]*#[[:space:]]*${mid}[[:space:]]*$/${mid}/" "$mods_file"
            fi
        elif [[ $MENU_RESULT -eq $((mod_count + 1)) ]]; then
            # Add mod
            local new_id
            new_id=$(read_input "Enter Workshop ID:")
            if [[ "$new_id" =~ ^[0-9]+$ ]]; then
                if ! grep -qE "^[[:space:]]*#?[[:space:]]*${new_id}[[:space:]]*$" "$mods_file" 2>/dev/null; then
                    echo "$new_id" >> "$mods_file"
                    show_message "Added mod $new_id"
                else
                    show_message "Mod already in list"
                fi
            elif [[ -n "$new_id" ]]; then
                show_message "Invalid Workshop ID"
            fi
        elif [[ $MENU_RESULT -eq $((mod_count + 2)) ]]; then
            # Sync mods
            local status
            status="$(get_container_status "$SELECTED_CONTAINER")"
            if [[ "$status" != "RUNNING" ]]; then
                show_message "Container must be running to sync"
            else
                run_with_output "Syncing Mods" $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh sync-mods
            fi
        else
            return
        fi
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
            "────────────────────"
            "📋 View Logs"
            "💻 Enter Shell"
            "────────────────────"
            "🔧 Manage Mods"
            "🔧 Manage Server Mods"
            "⬆  Update Server"
            "────────────────────"
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
            7) # Mods
                mod_manager "workshop"
                ;;
            8) # Server Mods
                mod_manager "server"
                ;;
            9) # Update
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to update"
                else
                    run_with_output "Updating Server" $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh update-server
                fi
                ;;
            10) # Separator
                ;;
            11) # Switch instance
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