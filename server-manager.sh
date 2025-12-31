#!/usr/bin/env bash
# =============================================================================
# DayZ Docker Server Manager - TUI Edition
# =============================================================================
# A responsive Text User Interface for managing DayZ Docker instances
# Uses dialog (preferred) or whiptail (fallback)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# TUI Backend Detection
# -----------------------------------------------------------------------------
TUI_CMD=""
if command -v dialog &>/dev/null; then
    TUI_CMD="dialog"
elif command -v whiptail &>/dev/null; then
    TUI_CMD="whiptail"
else
    echo "Error: Neither 'dialog' nor 'whiptail' found."
    echo "Install with: sudo apt-get install dialog"
    exit 1
fi

# -----------------------------------------------------------------------------
# DayZ Color Theme (Black/Red)
# -----------------------------------------------------------------------------
setup_dialog_theme() {
    # Only for dialog (whiptail doesn't support custom colors well)
    [[ "$TUI_CMD" != "dialog" ]] && return
    
    # Create temporary dialogrc with DayZ theme
    DIALOGRC_FILE=$(mktemp)
    trap "rm -f $DIALOGRC_FILE" EXIT
    
    cat > "$DIALOGRC_FILE" << 'DIALOGRC'
# DayZ Theme - Black & Red
# Attribute: (foreground, background, highlight)

# Screen (background behind dialogs)
screen_color = (WHITE,BLACK,ON)

# Shadow
shadow_color = (BLACK,BLACK,OFF)

# Dialog box
dialog_color = (WHITE,BLACK,OFF)

# Title
title_color = (RED,BLACK,ON)

# Border
border_color = (RED,BLACK,ON)

# Button (inactive)
button_inactive_color = (WHITE,BLACK,OFF)

# Button (active/selected) - RED background
button_active_color = (WHITE,RED,ON)

# Button key (hotkey letter)
button_key_inactive_color = (RED,BLACK,ON)
button_key_active_color = (WHITE,RED,ON)

# Button label
button_label_inactive_color = (WHITE,BLACK,ON)
button_label_active_color = (WHITE,RED,ON)

# Input box
inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = (RED,BLACK,ON)

# Searchbox
searchbox_color = (WHITE,BLACK,OFF)
searchbox_title_color = (RED,BLACK,ON)
searchbox_border_color = (RED,BLACK,ON)

# Position indicator
position_indicator_color = (RED,BLACK,ON)

# Menu box
menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = (RED,BLACK,ON)

# Item (inactive)
item_color = (WHITE,BLACK,OFF)

# Item (selected) - RED background
item_selected_color = (WHITE,RED,ON)

# Tag (menu item key)
tag_color = (RED,BLACK,ON)
tag_selected_color = (WHITE,RED,ON)
tag_key_color = (RED,BLACK,ON)
tag_key_selected_color = (WHITE,RED,ON)

# Checklist/radiolist
check_color = (WHITE,BLACK,OFF)
check_selected_color = (WHITE,RED,ON)

# Gauge
gauge_color = (RED,BLACK,ON)

# Text for textbox/msgbox
textbox_color = (WHITE,BLACK,OFF)
textbox_border_color = (RED,BLACK,ON)

# Form
form_active_text_color = (WHITE,BLACK,ON)
form_text_color = (WHITE,BLACK,OFF)
form_item_readonly_color = (WHITE,BLACK,OFF)

# Use shadows
use_shadow = OFF

# Use colors
use_colors = ON
DIALOGRC
    
    export DIALOGRC="$DIALOGRC_FILE"
}

setup_dialog_theme

# -----------------------------------------------------------------------------
# Terminal Size & Responsive Layout
# -----------------------------------------------------------------------------
get_term_size() {
    TERM_ROWS=$(tput lines 2>/dev/null || echo 24)
    TERM_COLS=$(tput cols 2>/dev/null || echo 80)
    # Ensure minimum size
    [[ $TERM_ROWS -lt 20 ]] && TERM_ROWS=20
    [[ $TERM_COLS -lt 60 ]] && TERM_COLS=60
    # Dialog dimensions with padding
    DLG_HEIGHT=$((TERM_ROWS - 4))
    DLG_WIDTH=$((TERM_COLS - 6))
    DLG_MENU_HEIGHT=$((DLG_HEIGHT - 8))
    DLG_LIST_HEIGHT=$((DLG_HEIGHT - 10))
}

# Recalculate on each menu display
get_term_size

# -----------------------------------------------------------------------------
# Docker Detection
# -----------------------------------------------------------------------------
DOCKER="docker"
if ! command -v docker &>/dev/null; then
    $TUI_CMD --msgbox "Error: Docker not found.\n\nPlease install Docker first." 10 50
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    if command -v sudo &>/dev/null && sudo docker info &>/dev/null 2>&1; then
        DOCKER="sudo docker"
    else
        $TUI_CMD --msgbox "Error: Cannot connect to Docker daemon.\n\nTry: sudo $0" 10 50
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
        cached=$(grep "^${mod_id}|" "$MOD_CACHE_FILE" 2>/dev/null | cut -d'|' -f2-)
        if [[ -n "$cached" ]]; then
            echo "$cached"
            return
        fi
    fi
    
    # Fetch from Steam API
    local response name
    if command -v curl &>/dev/null; then
        response=$(curl -s --max-time 5 -X POST \
            "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
            -d "itemcount=1" \
            -d "publishedfileids[0]=${mod_id}" 2>/dev/null || true)
        
        if command -v jq &>/dev/null && [[ -n "$response" ]]; then
            name=$(echo "$response" | jq -r '.response.publishedfiledetails[0].title // empty' 2>/dev/null || true)
        elif [[ -n "$response" ]]; then
            # Fallback: grep for title in JSON
            name=$(echo "$response" | grep -oP '"title"\s*:\s*"\K[^"]+' | head -1 || true)
        fi
    fi
    
    # Use ID as fallback name
    [[ -z "$name" ]] && name="Mod #${mod_id}"
    
    # Cache the result
    echo "${mod_id}|${name}" >> "$MOD_CACHE_FILE" 2>/dev/null || true
    
    echo "$name"
}

# Batch fetch mod names (more efficient)
prefetch_mod_names() {
    local -a ids=("$@")
    [[ ${#ids[@]} -eq 0 ]] && return
    
    # Build POST data
    local post_data="itemcount=${#ids[@]}"
    local i=0
    for id in "${ids[@]}"; do
        post_data+="&publishedfileids[${i}]=${id}"
        ((i++))
    done
    
    local response
    if command -v curl &>/dev/null; then
        response=$(curl -s --max-time 10 -X POST \
            "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
            -d "$post_data" 2>/dev/null || true)
        
        if command -v jq &>/dev/null && [[ -n "$response" ]]; then
            echo "$response" | jq -r '.response.publishedfiledetails[]? | "\(.publishedfileid)|\(.title // "Unknown")"' 2>/dev/null |
            while IFS='|' read -r mid mname; do
                [[ -n "$mid" && -n "$mname" ]] || continue
                if ! grep -q "^${mid}|" "$MOD_CACHE_FILE" 2>/dev/null; then
                    echo "${mid}|${mname}" >> "$MOD_CACHE_FILE"
                fi
            done
        fi
    fi
}

# -----------------------------------------------------------------------------
# Mod List Parsing
# -----------------------------------------------------------------------------
read_mod_ids() {
    local file="$1"
    [[ -f "$file" ]] || return
    awk '
        { gsub(/\r/,""); }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { print $1 }
    ' "$file" | awk '/^[0-9]+$/'
}

read_mod_ids_with_status() {
    # Returns: ID|STATUS (enabled/disabled)
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
# Instance Selector
# -----------------------------------------------------------------------------
select_instance() {
    get_term_size
    scan_instances
    
    if [[ ${#INSTANCE_NAMES[@]} -eq 0 ]]; then
        $TUI_CMD --msgbox "No DayZ instances found.\n\nRun install-dayz-docker.sh to create one." 10 50
        exit 0
    fi
    
    # Build menu items
    local -a menu_items=()
    for i in "${!INSTANCE_NAMES[@]}"; do
        local name="${INSTANCE_NAMES[$i]}"
        local container="${INSTANCE_CONTAINERS[$i]}"
        local status
        status="$(get_container_status "$container")"
        local status_icon="○"
        [[ "$status" == "RUNNING" ]] && status_icon="●"
        menu_items+=("$i" "$status_icon $name [$status]")
    done
    
    local choice
    choice=$($TUI_CMD --title "DayZ Server Manager" \
        --menu "Select an instance to manage:" \
        $DLG_HEIGHT $DLG_WIDTH $DLG_MENU_HEIGHT \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3) || exit 0
    
    SELECTED_DIR="${INSTANCE_DIRS[$choice]}"
    SELECTED_NAME="${INSTANCE_NAMES[$choice]}"
    SELECTED_CONTAINER="${INSTANCE_CONTAINERS[$choice]}"
}

# -----------------------------------------------------------------------------
# Server Control
# -----------------------------------------------------------------------------
server_start() {
    (cd "$SELECTED_DIR" && $DOCKER compose up -d) 2>&1 | 
    $TUI_CMD --title "Starting Server" --programbox $DLG_HEIGHT $DLG_WIDTH
}

server_stop() {
    (cd "$SELECTED_DIR" && $DOCKER compose stop) 2>&1 |
    $TUI_CMD --title "Stopping Server" --programbox $DLG_HEIGHT $DLG_WIDTH
}

server_restart() {
    (cd "$SELECTED_DIR" && $DOCKER compose restart) 2>&1 |
    $TUI_CMD --title "Restarting Server" --programbox $DLG_HEIGHT $DLG_WIDTH
}

view_logs() {
    # Show last 500 lines with tail
    $DOCKER logs --tail=500 "$SELECTED_CONTAINER" 2>&1 |
    $TUI_CMD --title "Container Logs (scroll with arrows, Q to quit)" \
        --scrolltext --textbox /dev/stdin $DLG_HEIGHT $DLG_WIDTH 2>/dev/null ||
    # Fallback for whiptail which doesn't support --scrolltext well
    $TUI_CMD --title "Container Logs" --msgbox "$(docker logs --tail=50 "$SELECTED_CONTAINER" 2>&1)" $DLG_HEIGHT $DLG_WIDTH
}

enter_shell() {
    clear
    echo "Entering container shell... (type 'exit' to return)"
    echo "---"
    $DOCKER exec -it "$SELECTED_CONTAINER" /bin/bash || echo "Container not running."
    echo ""
    read -rp "Press Enter to continue..."
}

# -----------------------------------------------------------------------------
# Mod Management TUI
# -----------------------------------------------------------------------------
mod_manager() {
    local mods_file="${SELECTED_DIR}/data/config/mods.txt"
    [[ -f "$mods_file" ]] || touch "$mods_file"
    
    while true; do
        get_term_size
        
        # Read mods with status
        local -a mod_data=()
        while IFS='|' read -r mid mstatus; do
            mod_data+=("$mid" "$mstatus")
        done < <(read_mod_ids_with_status "$mods_file")
        
        # Prefetch names for all mods
        local -a all_ids=()
        for ((i=0; i<${#mod_data[@]}; i+=2)); do
            all_ids+=("${mod_data[$i]}")
        done
        prefetch_mod_names "${all_ids[@]}"
        
        # Build checklist items: tag, item, status
        local -a checklist_items=()
        for ((i=0; i<${#mod_data[@]}; i+=2)); do
            local mid="${mod_data[$i]}"
            local mstatus="${mod_data[$i+1]}"
            local mname
            mname="$(get_mod_name "$mid")"
            # Truncate name if too long
            [[ ${#mname} -gt 35 ]] && mname="${mname:0:32}..."
            
            local status_char="on"
            [[ "$mstatus" == "disabled" ]] && status_char="off"
            
            # Format: ID as tag, "Name [STATUS]" as item
            local display_text
            printf -v display_text "%-38s %s" "$mname" "[$mid]"
            checklist_items+=("$mid" "$display_text" "$status_char")
        done
        
        if [[ ${#checklist_items[@]} -eq 0 ]]; then
            $TUI_CMD --title "Workshop Mods - $SELECTED_NAME" \
                --yesno "No mods configured.\n\nWould you like to add a mod?" 10 50
            if [[ $? -eq 0 ]]; then
                add_mod "$mods_file"
                continue
            else
                return
            fi
        fi
        
        # Show checklist with action buttons via extra-button
        local result
        result=$($TUI_CMD --title "Workshop Mods - $SELECTED_NAME" \
            --ok-label "Toggle" \
            --cancel-label "Back" \
            --extra-button --extra-label "Actions" \
            --checklist "Space=toggle, Enter=apply, Tab=buttons\n\n[✓]=enabled  [ ]=disabled" \
            $DLG_HEIGHT $DLG_WIDTH $DLG_LIST_HEIGHT \
            "${checklist_items[@]}" \
            3>&1 1>&2 2>&3)
        local exit_code=$?
        
        case $exit_code in
            0)  # OK - Apply toggle changes
                # result contains space-separated quoted IDs that should be enabled
                # Everything else should be disabled
                local -a enabled_ids=()
                eval "enabled_ids=($result)" 2>/dev/null || true
                
                # Rewrite mods.txt
                local tmp_file="${mods_file}.tmp"
                > "$tmp_file"
                
                for ((i=0; i<${#mod_data[@]}; i+=2)); do
                    local mid="${mod_data[$i]}"
                    local should_enable=0
                    for eid in "${enabled_ids[@]}"; do
                        [[ "$eid" == "$mid" ]] && should_enable=1 && break
                    done
                    if [[ $should_enable -eq 1 ]]; then
                        echo "$mid" >> "$tmp_file"
                    else
                        echo "# $mid" >> "$tmp_file"
                    fi
                done
                
                mv "$tmp_file" "$mods_file"
                ;;
            1)  # Cancel - Back
                return
                ;;
            3)  # Extra - Actions menu
                mod_actions_menu "$mods_file"
                ;;
        esac
    done
}

mod_actions_menu() {
    local mods_file="$1"
    
    get_term_size
    
    local choice
    choice=$($TUI_CMD --title "Mod Actions" \
        --menu "Select an action:" \
        $DLG_HEIGHT $DLG_WIDTH $DLG_MENU_HEIGHT \
        "add"       "➕ Add new mod by Workshop ID" \
        "enable"    "✓  Enable all mods" \
        "disable"   "✗  Disable all mods" \
        "sync"      "↻  Sync mods (download & link)" \
        "uninstall" "🗑  Uninstall mod files" \
        "back"      "← Back to mod list" \
        3>&1 1>&2 2>&3) || return
    
    case "$choice" in
        add)
            add_mod "$mods_file"
            ;;
        enable)
            # Enable all mods
            sed -i 's/^[[:space:]]*#[[:space:]]*\([0-9]\+\)/\1/' "$mods_file"
            $TUI_CMD --msgbox "All mods enabled." 8 40
            ;;
        disable)
            # Disable all mods
            sed -i 's/^\([0-9]\+\)/# \1/' "$mods_file"
            $TUI_CMD --msgbox "All mods disabled." 8 40
            ;;
        sync)
            sync_mods
            ;;
        uninstall)
            uninstall_mods_menu "$mods_file"
            ;;
        back)
            return
            ;;
    esac
}

add_mod() {
    local mods_file="$1"
    
    get_term_size
    
    local mod_id
    mod_id=$($TUI_CMD --title "Add Mod" \
        --inputbox "Enter Workshop ID (e.g., 1559212036):\n\nYou can find this in the Steam Workshop URL." \
        12 50 \
        3>&1 1>&2 2>&3) || return
    
    # Validate
    if [[ ! "$mod_id" =~ ^[0-9]+$ ]]; then
        $TUI_CMD --msgbox "Invalid Workshop ID: must be a number." 8 50
        return
    fi
    
    # Check if already exists
    if grep -qE "^[[:space:]]*#?[[:space:]]*${mod_id}[[:space:]]*$" "$mods_file" 2>/dev/null; then
        $TUI_CMD --msgbox "Mod $mod_id is already in the list." 8 50
        return
    fi
    
    # Fetch name and confirm
    local mod_name
    mod_name="$(get_mod_name "$mod_id")"
    
    $TUI_CMD --title "Confirm Add Mod" \
        --yesno "Add this mod?\n\nID: $mod_id\nName: $mod_name" 12 50 || return
    
    echo "$mod_id" >> "$mods_file"
    $TUI_CMD --msgbox "Mod added: $mod_name" 8 50
}

sync_mods() {
    get_term_size
    
    local status
    status="$(get_container_status "$SELECTED_CONTAINER")"
    
    if [[ "$status" != "RUNNING" ]]; then
        $TUI_CMD --msgbox "Container must be running to sync mods.\n\nStart the server first." 10 50
        return
    fi
    
    $TUI_CMD --title "Syncing Mods" --infobox "Downloading and linking mods...\nThis may take a while." 8 50
    
    $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh sync-mods 2>&1 |
    $TUI_CMD --title "Sync Progress" --programbox $DLG_HEIGHT $DLG_WIDTH
    
    $TUI_CMD --msgbox "Mod sync complete.\n\nRestart the server to apply changes." 10 50
}

uninstall_mods_menu() {
    local mods_file="$1"
    
    get_term_size
    
    # Get all mod IDs (enabled and disabled)
    local -a mod_ids=()
    while IFS='|' read -r mid _; do
        mod_ids+=("$mid")
    done < <(read_mod_ids_with_status "$mods_file")
    
    if [[ ${#mod_ids[@]} -eq 0 ]]; then
        $TUI_CMD --msgbox "No mods to uninstall." 8 40
        return
    fi
    
    # Build checklist
    local -a checklist_items=()
    for mid in "${mod_ids[@]}"; do
        local mname
        mname="$(get_mod_name "$mid")"
        [[ ${#mname} -gt 35 ]] && mname="${mname:0:32}..."
        local display_text
        printf -v display_text "%-38s %s" "$mname" "[$mid]"
        checklist_items+=("$mid" "$display_text" "off")
    done
    
    local result
    result=$($TUI_CMD --title "Uninstall Mods" \
        --ok-label "Uninstall" \
        --cancel-label "Cancel" \
        --checklist "Select mods to REMOVE from disk:\n\n⚠️  This deletes workshop files!" \
        $DLG_HEIGHT $DLG_WIDTH $DLG_LIST_HEIGHT \
        "${checklist_items[@]}" \
        3>&1 1>&2 2>&3) || return
    
    [[ -z "$result" ]] && return
    
    local -a selected_ids=()
    eval "selected_ids=($result)" 2>/dev/null || return
    
    $TUI_CMD --title "Confirm Uninstall" \
        --yesno "Uninstall ${#selected_ids[@]} mod(s)?\n\nThis will:\n- Delete workshop files\n- Remove from mods.txt" \
        12 50 || return
    
    local status
    status="$(get_container_status "$SELECTED_CONTAINER")"
    
    for mid in "${selected_ids[@]}"; do
        # Remove from list
        sed -i -E "/^[[:space:]]*#?[[:space:]]*${mid}[[:space:]]*$/d" "$mods_file"
        
        # Purge files if container running
        if [[ "$status" == "RUNNING" ]]; then
            $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh purge-mod "$mid" 2>/dev/null || true
        fi
    done
    
    $TUI_CMD --msgbox "Uninstalled ${#selected_ids[@]} mod(s)." 8 40
}

# -----------------------------------------------------------------------------
# Server Mod Manager (same as mods but for servermods.txt)
# -----------------------------------------------------------------------------
servermod_manager() {
    local mods_file="${SELECTED_DIR}/data/config/servermods.txt"
    [[ -f "$mods_file" ]] || touch "$mods_file"
    
    # Reuse mod_manager logic with different file
    local orig_file="${SELECTED_DIR}/data/config/mods.txt"
    
    # Temporarily swap for the manager
    SELECTED_DIR_MODS="$mods_file"
    
    # Similar implementation - for brevity, we'll call the same functions
    # with the servermods file
    local mods_file_backup="$mods_file"
    mod_manager_internal "$mods_file" "Server Mods"
}

mod_manager_internal() {
    local mods_file="$1"
    local title="${2:-Workshop Mods}"
    
    while true; do
        get_term_size
        
        local -a mod_data=()
        while IFS='|' read -r mid mstatus; do
            mod_data+=("$mid" "$mstatus")
        done < <(read_mod_ids_with_status "$mods_file")
        
        local -a all_ids=()
        for ((i=0; i<${#mod_data[@]}; i+=2)); do
            all_ids+=("${mod_data[$i]}")
        done
        prefetch_mod_names "${all_ids[@]}"
        
        local -a checklist_items=()
        for ((i=0; i<${#mod_data[@]}; i+=2)); do
            local mid="${mod_data[$i]}"
            local mstatus="${mod_data[$i+1]}"
            local mname
            mname="$(get_mod_name "$mid")"
            [[ ${#mname} -gt 35 ]] && mname="${mname:0:32}..."
            
            local status_char="on"
            [[ "$mstatus" == "disabled" ]] && status_char="off"
            
            local display_text
            printf -v display_text "%-38s %s" "$mname" "[$mid]"
            checklist_items+=("$mid" "$display_text" "$status_char")
        done
        
        if [[ ${#checklist_items[@]} -eq 0 ]]; then
            $TUI_CMD --title "$title - $SELECTED_NAME" \
                --yesno "No mods configured.\n\nWould you like to add one?" 10 50
            if [[ $? -eq 0 ]]; then
                add_mod "$mods_file"
                continue
            else
                return
            fi
        fi
        
        local result
        result=$($TUI_CMD --title "$title - $SELECTED_NAME" \
            --ok-label "Toggle" \
            --cancel-label "Back" \
            --extra-button --extra-label "Actions" \
            --checklist "Space=toggle, Enter=apply\n\n[✓]=enabled  [ ]=disabled" \
            $DLG_HEIGHT $DLG_WIDTH $DLG_LIST_HEIGHT \
            "${checklist_items[@]}" \
            3>&1 1>&2 2>&3)
        local exit_code=$?
        
        case $exit_code in
            0)
                local -a enabled_ids=()
                eval "enabled_ids=($result)" 2>/dev/null || true
                
                local tmp_file="${mods_file}.tmp"
                > "$tmp_file"
                
                for ((i=0; i<${#mod_data[@]}; i+=2)); do
                    local mid="${mod_data[$i]}"
                    local should_enable=0
                    for eid in "${enabled_ids[@]}"; do
                        [[ "$eid" == "$mid" ]] && should_enable=1 && break
                    done
                    if [[ $should_enable -eq 1 ]]; then
                        echo "$mid" >> "$tmp_file"
                    else
                        echo "# $mid" >> "$tmp_file"
                    fi
                done
                
                mv "$tmp_file" "$mods_file"
                ;;
            1)
                return
                ;;
            3)
                mod_actions_menu "$mods_file"
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Main Menu
# -----------------------------------------------------------------------------
main_menu() {
    while true; do
        get_term_size
        
        local status
        status="$(get_container_status "$SELECTED_CONTAINER")"
        local status_display="[STOPPED]"
        [[ "$status" == "RUNNING" ]] && status_display="[● RUNNING]"
        
        local choice
        choice=$($TUI_CMD --title "DayZ Server: $SELECTED_NAME $status_display" \
            --cancel-label "Exit" \
            --menu "Select an action:" \
            $DLG_HEIGHT $DLG_WIDTH $DLG_MENU_HEIGHT \
            "1" "▶  Start Server" \
            "2" "■  Stop Server" \
            "3" "↻  Restart Server" \
            "-" "─────────────────────────" \
            "4" "📋 View Logs" \
            "5" "💻 Enter Shell" \
            "--" "─────────────────────────" \
            "6" "🔧 Manage Mods" \
            "7" "🔧 Manage Server Mods" \
            "8" "⬆  Update Server Files" \
            "---" "─────────────────────────" \
            "9" "← Select Different Instance" \
            3>&1 1>&2 2>&3) || exit 0
        
        case "$choice" in
            1) server_start ;;
            2) server_stop ;;
            3) server_restart ;;
            4) view_logs ;;
            5) enter_shell ;;
            6) mod_manager_internal "${SELECTED_DIR}/data/config/mods.txt" "Workshop Mods" ;;
            7) mod_manager_internal "${SELECTED_DIR}/data/config/servermods.txt" "Server Mods" ;;
            8)
                local status
                status="$(get_container_status "$SELECTED_CONTAINER")"
                if [[ "$status" != "RUNNING" ]]; then
                    $TUI_CMD --msgbox "Container must be running to update." 8 50
                else
                    $DOCKER exec "$SELECTED_CONTAINER" /dayz/run.sh update-server 2>&1 |
                    $TUI_CMD --title "Updating Server" --programbox $DLG_HEIGHT $DLG_WIDTH
                fi
                ;;
            9)
                select_instance
                ;;
            -|--|---)
                # Separator selected, ignore
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------
main() {
    # Check terminal size
    if [[ $(tput lines 2>/dev/null || echo 24) -lt 20 ]] || [[ $(tput cols 2>/dev/null || echo 80) -lt 60 ]]; then
        echo "Terminal too small. Minimum size: 60x20"
        echo "Current: $(tput cols)x$(tput lines)"
        exit 1
    fi
    
    select_instance
    main_menu
}

main "$@"