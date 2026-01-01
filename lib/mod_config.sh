#!/usr/bin/env bash
# =============================================================================
# DayZ Mod Config Editor
# =============================================================================
# Extensible config editor for mod configuration files in profile folder.
# Supports multiple file formats via pluggable handler registry.
# Requires: lib/tui.sh, lib/dialogs.sh
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_MOD_CONFIG_LOADED:-}" ]] && return 0
_DAYZ_MOD_CONFIG_LOADED=1

# lib/mod_config.sh
MOD_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${MOD_CONFIG_LIB_DIR}/file_browser.sh"

# =============================================================================
# File Type Handler Registry (Specialized for Mod Configs)
# =============================================================================
# Maps file extensions to handler types.
declare -A FILE_TYPE_HANDLERS=(
    ["json"]="raw"
    ["xml"]="xml"
    ["cfg"]="raw"
    ["txt"]="raw"
    ["md"]="raw"
    ["log"]="raw"
)

# Get handler type for a file
get_file_handler() {
    local file="$1"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    echo "${FILE_TYPE_HANDLERS[$ext]:-raw}"
}

# =============================================================================
# Specialized Mod Config Actions
# =============================================================================

# Handler called when a file is selected in mod_folder_browser
mod_config_on_select() {
    local path="$1"
    local name=$(basename "$path")
    local dir=$(dirname "$path")
    local parent_name=$(basename "$dir")
    
    if [[ -d "$path" ]]; then
        # Recursive navigation into sub-folders
        fb_browse_dir "$path" "Mod Config Editor" "ROOT > Mod Configs > $parent_name" "mod_config_on_select" "all"
        return
    fi
    
    local handler=$(get_file_handler "$path")
    
    case "$handler" in
        xml)  xml_edit_file "$path" "$parent_name / $name" ;;
        *)    fb_edit_file_nano "$path" "$parent_name / $name" ;;
    esac
}

# XML Edit Placeholder
xml_edit_file() {
    local file="$1"
    local title="${2:-XML Editor}"
    show_message "XML editing coming soon. Use types.xml editor for loot files." "Info"
}

# =============================================================================
# Mod Config Browsers (Wrappers around file_browser.sh)
# =============================================================================

# Main entry point - Browse mod config folders in profile directory
mod_config_browser() {
    local profile_dir="$1"
    
    if [[ ! -d "$profile_dir" ]]; then
        show_message "Profile directory not found: $profile_dir" "Error"
        return 1
    fi
    
    # Use generic browser in folder mode with system folder ignore pattern
    local ignore="^(storage_|DataCache|users)$"
    fb_browse_dir "$profile_dir" "Mod Config Editor" "ROOT" "mod_folder_browser" "folders" "$ignore"
}

# Browse files within a mod config folder
mod_folder_browser() {
    local folder="$1"
    [[ ! -d "$folder" ]] && return 0
    
    local folder_name=$(basename "$folder")
    fb_browse_dir "$folder" "Mod Config Editor" "ROOT > Mod Configs" "mod_config_on_select" "all"
}
