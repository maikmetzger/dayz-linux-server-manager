#!/usr/bin/env bash
# =============================================================================
# DayZ Docker Server Manager - Pure Bash TUI
# =============================================================================
# Arrow-key navigation, no external dependencies (no dialog/whiptail)
# DayZ Theme: Black background, Red accents
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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
# User Identity & Paths
# -----------------------------------------------------------------------------
# Determine the real invoking user (not root when running via sudo)
# DAYZ_USER is our custom variable that survives sudo; SUDO_USER is set by sudo itself
INVOKING_USER="${DAYZ_USER:-${SUDO_USER:-${LOGNAME:-$USER}}}"

# Try multiple methods to find the correct home directory
get_user_home() {
    local user="$1"
    
    # Method 0: Use DAYZ_HOME if set (passed from installer)
    [[ -n "${DAYZ_HOME:-}" && -d "${DAYZ_HOME:-}" ]] && { echo "$DAYZ_HOME"; return 0; }
    
    # Method 1: getent passwd
    local home
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [[ -n "$home" && -d "$home" ]] && { echo "$home"; return 0; }
    
    # Method 2: Check common Linux home paths
    [[ -d "/home/$user" ]] && { echo "/home/$user"; return 0; }
    
    # Method 3: Use HOME if it looks valid (not /root when we expect a user)
    if [[ -n "$HOME" && -d "$HOME" && "$HOME" != "/root" ]]; then
        echo "$HOME"
        return 0
    fi
    
    # Method 4: If we're root but have SUDO_USER, check their home
    if [[ -d "/home/$SUDO_USER" ]]; then
        echo "/home/$SUDO_USER"
        return 0
    fi
    
    # Fallback to HOME
    echo "${HOME:-/tmp}"
}

INVOKING_HOME="${DAYZ_HOME:-$(get_user_home "$INVOKING_USER")}"

# Standard search root: ~/servers
SEARCH_ROOT="${INVOKING_HOME}/servers"

# Instance Lists
declare -a INSTANCE_DIRS=()
declare -a INSTANCE_NAMES=()
declare -a INSTANCE_CONTAINERS=()

# Selection State
SELECTED_DIR=""
SELECTED_NAME=""
SELECTED_CONTAINER=""

scan_instances() {
    INSTANCE_DIRS=()
    INSTANCE_NAMES=()
    INSTANCE_CONTAINERS=()
    
    # Use a single, canonical search root
    # Resolve the real path to avoid duplicates from symlinks or different representations
    local search_root
    search_root="$(cd "$SEARCH_ROOT" 2>/dev/null && pwd -P || echo "$SEARCH_ROOT")"
    
    [[ -d "$search_root" ]] || return 0
    
    # Track seen directories to avoid duplicates
    local -A seen_dirs=()
    
    while IFS= read -r marker; do
        [[ -f "$marker" ]] || continue
        
        local dir name container real_dir
        dir="$(dirname "$marker")"
        real_dir="$(cd "$dir" 2>/dev/null && pwd -P || echo "$dir")"
        
        # Skip if we've already seen this directory
        [[ -n "${seen_dirs[$real_dir]:-}" ]] && continue
        seen_dirs["$real_dir"]=1
        
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

# In-memory cache for fast lookups (associative array)
declare -A MOD_NAME_CACHE=()

# Load cache file into memory
load_mod_cache() {
    MOD_NAME_CACHE=()
    [[ -f "$MOD_CACHE_FILE" ]] || return 0
    while IFS='|' read -r mid mname; do
        [[ -n "$mid" ]] && MOD_NAME_CACHE["$mid"]="$mname"
    done < "$MOD_CACHE_FILE"
}

# Save in-memory cache to file
save_mod_cache() {
    : > "$MOD_CACHE_FILE" 2>/dev/null || return
    for mid in "${!MOD_NAME_CACHE[@]}"; do
        echo "${mid}|${MOD_NAME_CACHE[$mid]}" >> "$MOD_CACHE_FILE"
    done
}

get_mod_name() {
    local mod_id="$1"
    
    # Check in-memory cache first (fast!)
    if [[ -n "${MOD_NAME_CACHE[$mod_id]:-}" && "${MOD_NAME_CACHE[$mod_id]}" != "Mod #${mod_id}" ]]; then
        echo "${MOD_NAME_CACHE[$mod_id]}"
        return
    fi
    
    # Try Steam API (only if not cached)
    local name=""
    if command -v curl &>/dev/null; then
        local response
        response=$(curl -sS --max-time 3 -X POST \
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
    
    # Update in-memory cache
    MOD_NAME_CACHE["$mod_id"]="$name"
    
    echo "$name"
}

# Load cache on startup
load_mod_cache

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
    local selection=0
    while true; do
        scan_instances
        
        # Build menu items with status
        local -a items=()
        if [[ ${#INSTANCE_NAMES[@]} -gt 0 ]]; then
            for i in "${!INSTANCE_NAMES[@]}"; do
                local name="${INSTANCE_NAMES[$i]}"
                local container="${INSTANCE_CONTAINERS[$i]}"
                local status
                status="$(get_container_status "$container")"
                
                local status_icon="${RED}○${RESET}"
                [[ "$status" == "RUNNING" ]] && status_icon="${GREEN}●${RESET}"
                
                items+=("$status_icon $name [$status]")
            done
            items+=("--------------------")
        else
            items+=("No instances found.")
            items+=("--------------------")
        fi
        
        items+=("✨ Install/Manage Instances")
        items+=("❌ Quit")
        
        if run_menu items "DayZ Server Manager - Select Instance" $selection; then
            selection=$MENU_RESULT
            local idx=$MENU_RESULT
            local count=${#INSTANCE_NAMES[@]}
            
            if [[ ${#INSTANCE_NAMES[@]} -gt 0 ]]; then
                if [[ $idx -lt $count ]]; then
                    SELECTED_DIR="${INSTANCE_DIRS[$idx]}"
                    SELECTED_NAME="${INSTANCE_NAMES[$idx]}"
                    SELECTED_CONTAINER="${INSTANCE_CONTAINERS[$idx]}"
                return # Successfully selected, return to main
                fi
                # Adjust for separator
                idx=$((idx - 1))
            else
                # Adjust for "No instances" + separator
                idx=$((idx - 2))
            fi
            
            # The adjusted index now maps to:
            # count = Installer
            # count + 1 = Quit
            
            if [[ $idx -eq $count ]]; then
                # Installer
             if [[ -f "${SCRIPT_DIR}/install-dayz-docker.sh" ]]; then
                 # Preserve user identity for the installer using custom vars (sudo overwrites SUDO_USER)
                 export DAYZ_USER="$INVOKING_USER"
                 export DAYZ_HOME="$INVOKING_HOME"
                 
                 # Check access
                     if ! groups | grep -q "\\bdocker\\b"; then
                         if confirm "Installer requires root/docker privileges. Run with sudo?" "y"; then
                             printf "%s" "$SHOW_CURSOR"
                             exec sudo -E bash "${SCRIPT_DIR}/install-dayz-docker.sh"
                         fi
                     fi
                 
                 printf "%s" "$SHOW_CURSOR"
                 exec bash "${SCRIPT_DIR}/install-dayz-docker.sh"
             else
                 show_message "install-dayz-docker.sh not found."
                 # Loop back
             fi
            elif [[ $idx -eq $((count + 1)) ]]; then
                exit 0
            fi
        else
            exit 0
        fi
    done
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

# -----------------------------------------------------------------------------
# Dependency Rules (Heuristic)
# Format: "DependentID:RequiredID:ModName"
# -----------------------------------------------------------------------------
DEPENDENCY_RULES=(
    # Community Framework (CF) is required by almost everything
    "1564026768:1559212036:CF" # COT -> CF
    "1708571078:1559212036:CF" # VPPAdminTools -> CF
    "2411613529:1559212036:CF" # Dabs Framework -> CF
    "2116151222:1559212036:CF" # Expansion-Core -> CF
    "2275832136:1559212036:CF" # DayZ-Editor -> CF
    
    # Dabs Framework is required by Editor and Expansion
    "2116151222:2411613529:Dabs Framework" # Expansion-Core -> Dabs
    "2275832136:2411613529:Dabs Framework" # DayZ-Editor -> Dabs
    
    # Expansion Core is required by Expansion Modules
    "2116157322:2116151222:Expansion-Core" # Licensed
    "2116177301:2116151222:Expansion-Core" # Vehicles
    "2116153160:2116151222:Expansion-Core" # Market
    "2116176696:2116151222:Expansion-Core" # Quests
    "2116166431:2116151222:Expansion-Core" # AI
    "2116161408:2116151222:Expansion-Core" # Chat
    "2116155694:2116151222:Expansion-Core" # SpawnSelection
)

check_mod_dependencies() {
    local mod_id="$1"
    local -a all_ids=("${@:2}") # passed as array
    
    local my_index=-1
    # Find my index
    for i in "${!all_ids[@]}"; do
        if [[ "${all_ids[$i]}" == "$mod_id" ]]; then
            my_index=$i
            break
        fi
    done
    [[ $my_index -eq -1 ]] && return 0
    
    for rule in "${DEPENDENCY_RULES[@]}"; do
        # Use bash parameter expansion instead of echo|cut (no subshells!)
        local dep_id="${rule%%:*}"
        local rest="${rule#*:}"
        local req_id="${rest%%:*}"
        local req_name="${rest#*:}"
        
        if [[ "$mod_id" == "$dep_id" ]]; then
            # Verify requirement exists and is loaded BEFORE this mod
            local req_index=-1
            for j in "${!all_ids[@]}"; do
                if [[ "${all_ids[$j]}" == "$req_id" ]]; then
                    req_index=$j
                    break
                fi
            done
            
            if [[ $req_index -eq -1 ]]; then
                echo "Missing dependency: $req_name ($req_id)"
                return 1
            elif [[ $req_index -gt $my_index ]]; then
                echo "Wrong Order! Must be below $req_name"
                return 1
            fi
        fi
    done
    return 0
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
    } | awk '!seen[$0]++' | grep -E '^[0-9]+$'
}

move_line_up() {
    local file="$1"
    local pattern="$2"
    [[ -f "$file" ]] || return 1
    
    local line_num
    line_num=$(grep -n "$pattern" "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true)
    
    [[ -z "$line_num" || "$line_num" -le 1 ]] && return 0
    
    local prev_line=$((line_num - 1))
    
    # Read file into array
    mapfile -t lines < "$file"
    
    # Swap using 0-based index
    local idx=$((line_num - 1))
    local prev_idx=$((prev_line - 1))
    
    local temp="${lines[$idx]}"
    lines[$idx]="${lines[$prev_idx]}"
    lines[$prev_idx]="$temp"
    
    # Write back
    printf "%s\n" "${lines[@]}" > "$file"
}

move_line_down() {
    local file="$1"
    local pattern="$2"
    [[ -f "$file" ]] || return 1
    
    local line_num
    line_num=$(grep -n "$pattern" "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true)
    
    # Count lines
    local total_lines
    total_lines=$(wc -l < "$file")
    
    [[ -z "$line_num" || "$line_num" -ge "$total_lines" ]] && return 0
    
    local next_line=$((line_num + 1))
    
    # Read file into array
    mapfile -t lines < "$file"
    
    # Swap using 0-based index
    local idx=$((line_num - 1))
    local next_idx=$((next_line - 1))
    
    local temp="${lines[$idx]}"
    lines[$idx]="${lines[$next_idx]}"
    lines[$next_idx]="$temp"
    
    # Write back
    printf "%s\n" "${lines[@]}" > "$file"
}

move_mod_up() {
    local mod_id="$1"
    local f1="$2"
    local f2="$3"
    local pattern="^[[:space:]]*#\?[[:space:]]*${mod_id}[[:space:]]*$"
    
    move_line_up "$f1" "$pattern"
    move_line_up "$f2" "$pattern"
}

move_mod_down() {
    local mod_id="$1"
    local f1="$2"
    local f3="$3"
    local pattern="^[[:space:]]*#\?[[:space:]]*${mod_id}[[:space:]]*$"
    
    move_line_down "$f1" "$pattern"
    move_line_down "$f3" "$pattern"
}

mod_manager() {
    local mods_file="${SELECTED_DIR}/data/config/mods.txt"
    local servermods_file="${SELECTED_DIR}/data/config/servermods.txt"
    
    [[ -f "$mods_file" ]] || touch "$mods_file"
    [[ -f "$servermods_file" ]] || touch "$servermods_file"
    
    local selected=0
    local dirty=0
    
    local needs_rebuild=1
    local -a mod_ids=()
    local -a mod_names=()
    local -a mod_types=()
    local -a mod_warnings=()
    
    while true; do
        
        # Only rebuild arrays when data has changed
        if [[ $needs_rebuild -eq 1 ]]; then
            mod_ids=()
            mod_names=()
            mod_types=()
            mod_warnings=()
            
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
            
            # Pre-calculate dependency warnings (expensive, do once)
            for i in "${!mod_ids[@]}"; do
                local mid="${mod_ids[$i]}"
                local mtype="${mod_types[$i]}"
                local warn=""
                if [[ "$mtype" != "disabled" ]]; then
                    warn="$(check_mod_dependencies "$mid" "${mod_ids[@]}" 2>/dev/null || true)"
                fi
                mod_warnings+=("$warn")
            done
            
            needs_rebuild=0
        fi
        
        local mod_count=${#mod_ids[@]}
        local total_items=$((mod_count + 4))  # mods + Add + Sync + FixMods + Back
        
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
            # Truncate name to fit between name col and id col
            local max_name_len=$((col_id - col_name - 2))
            [[ ${#mname} -gt $max_name_len ]] && mname="${mname:0:$((max_name_len-3))}..."
            
            local mtype="${mod_types[$i]}"
            local status_icon type_label type_short
            case "$mtype" in
                both)     status_icon="✓"; type_label="[C+S]"; type_short="C+S" ;;
                client)   status_icon="✓"; type_label="[Cli]"; type_short="Cli" ;;
                server)   status_icon="✓"; type_label="[Srv]"; type_short="Srv" ;;
                disabled) status_icon="✗"; type_label="[Off]"; type_short="Off" ;;
            esac
            
            # Use pre-calculated dependency warning
            if [[ -n "${mod_warnings[$i]:-}" ]]; then
                status_icon="⚠️"
            fi
            
            move_to $row 1
            if [[ $i -eq $selected ]]; then
                # Selected row - full red background
                printf "%s%s" "$BG_RED" "$WHITE$BOLD"
                
                # Column 1: Status (Arrow + Icon)
                # Fixed spacing: " (arrow) (icon)  "
                move_to $row $col_status
                printf "▶ %s" "$status_icon"
                
                # Column 2: Name
                move_to $row $col_name
                printf "%s" "$mname"
                
                # Column 3: ID
                move_to $row $col_id
                printf "%s" "$mid"
                
                # Column 4: Type
                move_to $row $col_type
                printf "[%s]" "$type_short"
                
                # Fill remaining space to end of line with red bg
                local current_pos=$((col_type + 5))
                local fill_len=$((TERM_COLS - current_pos + 1))
                if [[ $fill_len -gt 0 ]]; then
                    move_to $row $current_pos
                    printf "%*s" "$fill_len" ""
                fi
                
                printf "%s" "$RESET"
            else
                # Unselected row
                
                # Column 1: Status (Icon only)
                move_to $row $col_status
                if [[ "$mtype" == "disabled" ]]; then
                    printf "  %s%s%s" "$RED" "$status_icon" "$RESET"
                else
                    printf "  %s%s%s" "$GREEN" "$status_icon" "$RESET"
                fi
                
                # Column 2: Name
                move_to $row $col_name
                printf "%s" "$mname"
                
                # Column 3: ID
                move_to $row $col_id
                printf "%s%s%s" "$DIM" "$mid" "$RESET"
                
                # Column 4: Type
                move_to $row $col_type
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
        local actions=("[A] Add" "[S] Sync" "[F] FixMods" "[Q] Back")
        local action_indices=(0 1 2 3)
        
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
        move_to $((TERM_ROWS-1)) 1
        if [[ $selected -lt $mod_count ]]; then
             local sel_mid="${mod_ids[$selected]}"
             local sel_warn
             sel_warn="$(check_mod_dependencies "$sel_mid" "${mod_ids[@]}" || true)"
             if [[ -n "$sel_warn" ]]; then
                 printf "%s%s WARN: %s %s" "$BG_RED" "$WHITE$BOLD" "$sel_warn" "$RESET"
             else
                 printf "%s" "$CLEAR_LINE"
             fi
        fi

        move_to $TERM_ROWS 1
        printf "%s%s ↑↓ Select   U/D Move   Enter Toggle   A Add   S Sync   F FixMods   Q Back%*s%s" "$BG_DARKGRAY" "$WHITE" "$((TERM_COLS - 75))" "" "$RESET"
        
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
            'u'|'U'|'+')
                if [[ $selected -gt 0 && $selected -lt $mod_count ]]; then
                     local mid="${mod_ids[$selected]}"
                     move_mod_up "$mid" "$mods_file" "$servermods_file"
                     selected=$((selected - 1))
                     dirty=1; needs_rebuild=1
                fi
                continue
                ;;
            'd'|'D'|'-')
                if [[ $selected -lt $((mod_count - 1)) ]]; then
                     local mid="${mod_ids[$selected]}"
                     move_mod_down "$mid" "$mods_file" "$servermods_file"
                     selected=$((selected + 1))
                     dirty=1; needs_rebuild=1
                fi
                continue
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
                    dirty=1; needs_rebuild=1
                elif [[ $selected -eq $mod_count ]]; then
                    # Add
                    local new_id
                    new_id=$(read_input "Enter Steam Workshop ID:" "" "Add Workshop Mod")
                    if [[ "$new_id" =~ ^[0-9]+$ ]]; then
                        if ! is_mod_in_file "$new_id" "$mods_file" && ! is_mod_in_file "$new_id" "$servermods_file"; then
                            echo "$new_id" >> "$mods_file"
                            show_message "Added mod $new_id as [Client]" "Mod Added"
                            dirty=1; needs_rebuild=1
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
                        run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                    fi
                elif [[ $selected -eq $((mod_count + 2)) ]]; then
                    # FixMods
                    local status
                    status="$(get_container_status "$SELECTED_CONTAINER")"
                    if [[ "$status" != "RUNNING" ]]; then
                        show_message "Container must be running to fix mods"
                    else
                         if confirm "Fix casing & sync all keys. Continue?" "y"; then
                            local cmd='find /dayz/serverfiles/steamapps/workshop/content/221100 -depth | while read p; do d="$(dirname "$p")"; f="$(basename "$p")"; new_f="${f,,}"; [[ "$f" != "$new_f" ]] && mv -T "$p" "$d/$new_f"; done; echo "Fixed workshop casing."; find /dayz/serverfiles/keys -depth | while read p; do d="$(dirname "$p")"; f="$(basename "$p")"; new_f="${f,,}"; [[ "$f" != "$new_f" ]] && mv -T "$p" "$d/$new_f"; done; echo "Fixed keys casing."; find /dayz/serverfiles/steamapps/workshop/content/221100 -type f -name "*.bikey" -exec cp -f {} /dayz/serverfiles/keys/ \; ; echo "Keys re-synced."'
                            run_with_output "Fixing Mods (Casing & Keys)..." $DOCKER exec "$SELECTED_CONTAINER" bash -c "$cmd"
                        fi
                    fi
                elif [[ $selected -eq $((mod_count + 3)) ]]; then
                    # Back
                    if [[ $dirty -eq 1 ]]; then
                        if confirm "Mods changed. Run Sync now?" "y"; then
                            local status
                            status="$(get_container_status "$SELECTED_CONTAINER")"
                            if [[ "$status" != "RUNNING" ]]; then
                                show_message "Container must be running to sync"
                            else
                                run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                            fi
                        fi
                    fi
                    save_mod_cache
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
                        dirty=1
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
                    run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                fi
                ;;
            'f'|'F')
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running to fix mods"
                else
                     if confirm "Fix casing & re-sync keys? (Deep Clean)" "y"; then
                        local cmd='find /dayz/serverfiles/steamapps/workshop/content/221100 -depth | while read p; do d="$(dirname "$p")"; f="$(basename "$p")"; new_f="${f,,}"; [[ "$f" != "$new_f" ]] && mv -T "$p" "$d/$new_f"; done; echo "Fixed workshop casing."; find /dayz/serverfiles/keys -depth | while read p; do d="$(dirname "$p")"; f="$(basename "$p")"; new_f="${f,,}"; [[ "$f" != "$new_f" ]] && mv -T "$p" "$d/$new_f"; done; echo "Fixed keys casing."; find /dayz/serverfiles/steamapps/workshop/content/221100 -type f -name "*.bikey" -exec cp -f {} /dayz/serverfiles/keys/ \; ; echo "Keys re-synced."'
                        
                        run_with_output "Fixing Mods (Deep Clean)..." $DOCKER exec "$SELECTED_CONTAINER" bash -c "$cmd"
                    fi
                fi
                ;;
            'q'|'Q')
                if [[ $dirty -eq 1 ]]; then
                    if confirm "Mods changed. Run Sync now?" "y"; then
                        local status
                        status="$(get_container_status "$SELECTED_CONTAINER")"
                        if [[ "$status" != "RUNNING" ]]; then
                            show_message "Container must be running to sync"
                        else
                            run_with_output "Syncing All Mods" $DOCKER exec "$SELECTED_CONTAINER" bash -c "/dayz/run.sh sync-mods && /dayz/run.sh sync-servermods"
                        fi
                    fi
                fi
                return
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Wipe Menu
# -----------------------------------------------------------------------------
wipe_menu() {
    local storage_root="${SELECTED_DIR}/data/serverfiles/mpmissions"
    # Try to find storage_1
    local storage_dir
    storage_dir=$(find "${storage_root}" -name "storage_1" -type d -print -quit 2>/dev/null || true)
    
    if [[ -z "$storage_dir" ]]; then
        show_message "Could not find storage_1 directory in ${storage_root}" "Error"
        return
    fi

    # Try to find economy.xml (usually in ../db/economy.xml relative to storage_1 parent map dir)
    local mission_dir
    mission_dir="$(dirname "$storage_dir")"
    local economy_file="${mission_dir}/db/economy.xml"

    local -a states=(0 0 0 0) # Players, Vehicles, Bases, Loot
    local selection=0
    
    while true; do
        draw_header "Wipe Server Data - $SELECTED_NAME"
        
        local -a items=()
        if [[ ${states[0]} -eq 1 ]]; then items+=(" [x] 👤 Wipe Players (players.db)"); else items+=(" [ ] 👤 Wipe Players (players.db)"); fi
        if [[ ${states[1]} -eq 1 ]]; then items+=(" [x] 🚗 Wipe Vehicles (vehicles.bin)"); else items+=(" [ ] 🚗 Wipe Vehicles (vehicles.bin)"); fi
        if [[ ${states[2]} -eq 1 ]]; then items+=(" [x] 🏰 Wipe Bases (persistence/data)"); else items+=(" [ ] 🏰 Wipe Bases (persistence/data)"); fi
        if [[ ${states[3]} -eq 1 ]]; then items+=(" [x] 🎒 Wipe Loot (economy reset)"); else items+=(" [ ] 🎒 Wipe Loot (economy reset)"); fi
        
        items+=("--------------------")
        items+=("💀 EXECUTE SELECTED WIPE(S)")
        items+=("❌ Cancel / Back")
        
        if run_menu items "Select Data to Wipe (Enter to Toggle)" $selection; then
            selection=$MENU_RESULT
            case $MENU_RESULT in
                0) states[0]=$((1 - states[0])) ;;
                1) states[1]=$((1 - states[1])) ;;
                2) states[2]=$((1 - states[2])) ;;
                3) states[3]=$((1 - states[3])) ;;
                4) ;; # Separator
                5) # Execute
                    local count=$((states[0] + states[1] + states[2] + states[3]))
                    if [[ $count -eq 0 ]]; then
                        show_message "No items selected." "Error"
                        continue
                    fi
                    
                    if confirm "Wipe ${count} categories? This cannot be undone!" "n"; then
                        printf "%s" "$SHOW_CURSOR"
                        
                        # 1. Players
                        if [[ ${states[0]} -eq 1 ]]; then
                            rm -f "${storage_dir}/players.db" "${storage_dir}/players.db-journal"
                        fi
                        
                        # 2. Vehicles
                        if [[ ${states[1]} -eq 1 ]]; then
                            rm -f "${storage_dir}/vehicles.bin" "${storage_dir}/vehicles.bin-journal"
                        fi

                        # 3. Bases (and included Loot in data/)
                        if [[ ${states[2]} -eq 1 ]]; then
                             # Wiping bases essentially means clearing the data folder
                             if [[ -d "${storage_dir}/data" ]]; then
                                 rm -rf "${storage_dir}/data"/*
                             fi
                        fi

                        # 4. Loot Only (Context dependent)
                        if [[ ${states[3]} -eq 1 ]]; then
                            # If Bases were ALSO wiped, loot is already gone via data/ folder deletion.
                            # If Bases NOT wiped, we need to try the economy toggle trick or warn.
                            if [[ ${states[2]} -eq 0 ]]; then
                                if [[ -f "$economy_file" ]]; then
                                    # Perform Soft Wipe Sequence
                                    # Requires server stop
                                    local was_running=0
                                    if [[ "$(get_container_status "$SELECTED_CONTAINER")" == "RUNNING" ]]; then
                                        was_running=1
                                        echo "Stopping server for loot wipe..."
                                        $DOCKER stop "$SELECTED_CONTAINER" >/dev/null
                                    fi
                                    
                                    # Backup economy.xml
                                    cp "$economy_file" "${economy_file}.bak"
                                    
                                    # Set dynamic load=0
                                    sed -i 's/dynamic init="1" load="1"/dynamic init="1" load="0"/g' "$economy_file"
                                    
                                    echo "Starting server to clear loot (Wait 60s)..."
                                    $DOCKER start "$SELECTED_CONTAINER" >/dev/null
                                    sleep 60
                                    
                                    echo "Stopping server..."
                                    $DOCKER stop "$SELECTED_CONTAINER" >/dev/null
                                    
                                    # Restore setting
                                    sed -i 's/dynamic init="1" load="0"/dynamic init="1" load="1"/g' "$economy_file"
                                    
                                    if [[ $was_running -eq 1 ]]; then
                                        echo "Restarting server..."
                                        $DOCKER start "$SELECTED_CONTAINER" >/dev/null
                                    fi
                                else
                                    show_message "Cannot wipe loot separately: economy.xml not found." "Warning"
                                fi
                            fi
                        fi
                        
                        show_message "Wipe Complete." "Success"
                        states=(0 0 0 0)
                    fi
                    ;;
                6) return ;;
            esac
        else
            return
        fi
    done
}

# -----------------------------------------------------------------------------
# Main Menu
# -----------------------------------------------------------------------------
main_menu() {
    local selection=0
    while true; do
        local status
        status="$(get_container_status "$SELECTED_CONTAINER")"
        
        local status_text="${RED}STOPPED${RESET}"
        [[ "$status" == "RUNNING" ]] && status_text="${GREEN}● RUNNING${RESET}"
        
        local -a items=(
            "▶️  Start Server"
            "⏹️  Stop Server"
            "🔄 Restart Server"
            "--------------------"
            "⚒️  Mod Manager"
            "🧹 Wipe Server Data"
            "📜 View Logs"
            "💻 Enter Shell"
            "--------------------"
            "⬆️  Update Server"
            "--------------------"
            "← Switch Instance"
        )
        
        if ! run_menu items "DayZ: $SELECTED_NAME [$status_text]" $selection; then
            exit 0
        fi
        
        selection=$MENU_RESULT
        
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
            4) # Mod Manager
                mod_manager
                ;;
            5) # Wipe Data
                wipe_menu
                ;;
            6) # View Logs
                trap : INT
                run_with_output "Live Logs (Ctrl+C to stop)" $DOCKER logs -f --tail=100 "$SELECTED_CONTAINER"
                trap - INT
                ;;
            7) # Shell
                if [[ "$status" != "RUNNING" ]]; then
                    show_message "Container must be running."
                else
                    printf "%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
                    $DOCKER exec -it "$SELECTED_CONTAINER" /bin/bash || echo "Container not running"
                    read -rp "Press Enter to continue..."
                    printf "%s" "$HIDE_CURSOR"
                fi
                ;;
            8) # Separator
                ;;
            9) # Update Server
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
            11) # Switch Instance
                return
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
    
    local selection=0
    
    while true; do
        select_instance
        main_menu
    done
}

main "$@"