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

# Debug logging setup
MOD_DEBUG_LOG="/tmp/dayz_debug.log"
mod_log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] MOD_CONFIG: $*" >> "$MOD_DEBUG_LOG"
}
mod_log "Library sourcing file_browser.sh from: $MOD_CONFIG_LIB_DIR"

source "${MOD_CONFIG_LIB_DIR}/file_browser.sh"
mod_log "file_browser.sh sourced successfully"

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
    [[ -d "$path" ]] && return # folder recursion handled by default in fb_browse_dir
    
    local handler=$(get_file_handler "$path")
    local name=$(basename "$path")
    local dir=$(dirname "$path")
    local folder_name=$(basename "$dir")
    
    case "$handler" in
        xml)  xml_edit_file "$path" "$folder_name / $name" ;;
        *)    fb_edit_file_nano "$path" "$folder_name / $name" ;;
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
    mod_log "mod_config_browser entry. profile_dir='$profile_dir'"
    
    if [[ ! -d "$profile_dir" ]]; then
        mod_log "ERROR: Profile directory not found: $profile_dir"
        show_message "Profile directory not found: $profile_dir" "Error"
        return 1
    fi
    
    # Use generic browser in folder mode with system folder ignore pattern
    local ignore="^(storage_|DataCache|users)$"
    mod_log "Calling fb_browse_dir with ignore='$ignore'"
    fb_browse_dir "$profile_dir" "Mod Config Editor" "ROOT" "mod_folder_browser" "folders" "$ignore"
    mod_log "fb_browse_dir returned"
}

# Browse files within a mod config folder
mod_folder_browser() {
    local folder="$1"
    mod_log "mod_folder_browser entry. folder='$folder'"
    [[ ! -d "$folder" ]] && return 0
    
    local folder_name=$(basename "$folder")
    mod_log "Calling fb_browse_dir for files in '$folder_name'"
    fb_browse_dir "$folder" "Mod Config Editor" "ROOT > Mod Configs" "mod_config_on_select" "all"
    mod_log "fb_browse_dir (files) returned"
}
