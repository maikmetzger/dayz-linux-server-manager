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


# Ensure cfgeconomycore.xml and CustomCE structure exist
setup_modular_loot() {
    local mission_path="$1"
    [[ ! -d "$mission_path" ]] && return 1
    
    local core_xml="${mission_path}/cfgeconomycore.xml"
    local custom_ce="${mission_path}/CustomCE/types"
    
    mkdir -p "$custom_ce"
    
    if [[ ! -f "$core_xml" ]]; then
        # Create a basic economycore if missing
        cat > "$core_xml" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<economycore>
	<classes>
		<rootclass name="DefaultWeapon" />
		<rootclass name="DefaultMagazine" />
		<rootclass name="Inventory_Base" />
		<rootclass name="HouseNoDestruct" reportMemoryLOD="no" />
		<rootclass name="SurvivorBase" act="character" reportMemoryLOD="no" />
		<rootclass name="DZ_LightAI" act="character" reportMemoryLOD="no" />
		<rootclass name="CarScript" act="car" reportMemoryLOD="no" />
	</classes>
	<defaults>
		<default name="log_ce_loop" value="false"/>
		<default name="save_types_startup" value="true"/>
	</defaults>
	<ce folder="CustomCE/types">
	</ce>
</economycore>
EOF
    fi
}

# Register a loot XML as a modular include
register_modular_loot() {
    local instance_dir="$1"
    local source_xml="$2"
    local mod_name="$3"
    
    local mission_path
    if ! mission_path=$(get_mission_path "$instance_dir"); then
        show_message "Could not find mission path in serverDZ.cfg" "Error"
        return 1
    fi
    
    setup_modular_loot "$mission_path"
    
    local core_xml="${mission_path}/cfgeconomycore.xml"
    local target_filename="${mod_name}_types.xml"
    local target_path="${mission_path}/CustomCE/types/${target_filename}"
    
    if [[ -f "$target_path" ]]; then
        if ! confirm "Loot file already exists in CustomCE. Overwrite?" "n"; then
            return 0
        fi
    fi
    
    # 1. Copy file
    cp "$source_xml" "$target_path"
    
    # 2. Add to cfgeconomycore.xml using Python to avoid dangerous regex
    python3 <<EOF
import xml.etree.ElementTree as ET
import sys

core_path = "$core_xml"
file_to_add = "$target_filename"

try:
    tree = ET.parse(core_path)
    root = tree.getroot()
    ce_node = root.find('ce')
    if ce_node is None:
        ce_node = ET.SubElement(root, 'ce', {'folder': 'CustomCE/types'})
    
    # Check if file already exists
    exists = False
    for f in ce_node.findall('file'):
        if f.get('name') == file_to_add:
            exists = True
            break
            
    if not exists:
        new_file = ET.SubElement(ce_node, 'file', {'name': file_to_add, 'type': 'types'})
        
        # Pretty print/indent (Python 3.9+)
        if hasattr(ET, 'indent'):
            ET.indent(tree, space="\t", level=0)
            
        tree.write(core_path, encoding='UTF-8', xml_declaration=True)
        print("Success")
    else:
        print("Already linked")
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
EOF
    
    show_message "Registered $target_filename in cfgeconomycore.xml" "Success"
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

# Smart XML Editor - Routes to types editor or raw nano
xml_edit_file() {
    local file="$1"
    local title="${2:-XML Editor}"
    
    # Check if this is a loot definition file
    local is_types
    is_types=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" is-types "$file" 2>/dev/null || echo "false")
    
    if [[ "$is_types" == "true" ]]; then
        # Route to specialized types.xml editor
        # Pass SELECTED_DIR so it can find mpmissions for modular loot
        config_xml_editor "${SELECTED_DIR:-}" "$file" "" "${SELECTED_CONTAINER:-}"
    else
        # Fallback to raw text editor for standard XMLs
        fb_edit_file_nano "$file" "$title"
    fi
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
