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
    
    # Create all 4 CE folders (extensible - add new folders here)
    local -a ce_folders=(
        "${mission_path}/CustomCE/types"
        "${mission_path}/CustomCE/spawnabletypes"
        "${mission_path}/CustomCE/events"
        "${mission_path}/CustomCE/eventspawns"
    )
    for folder in "${ce_folders[@]}"; do
        mkdir -p "$folder"
    done
    
    if [[ ! -f "$core_xml" ]]; then
        # Create a complete economycore with all CE sections
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
	<ce folder="CustomCE/spawnabletypes">
	</ce>
	<ce folder="CustomCE/events">
	</ce>
	<ce folder="CustomCE/eventspawns">
	</ce>
</economycore>
EOF
    fi
}

# Link an existing CustomCE file to cfgeconomycore.xml
# Args: instance_dir, target_filename, ce_type (types|spawnabletypes|events|eventspawns)
link_modular_xml() {
    local instance_dir="$1"
    local target_filename="$2"
    local ce_type="${3:-types}"  # Default to 'types' for backward compatibility
    
    local mission_path=$(get_mission_path "$instance_dir")
    [[ -z "$mission_path" ]] && return 1
    
    setup_modular_loot "$mission_path"
    local core_xml="${mission_path}/cfgeconomycore.xml"
    
    # Map ce_type to folder path
    local ce_folder="CustomCE/${ce_type}"
    
    python3 <<EOF
import xml.etree.ElementTree as ET
import sys

core_path = "$core_xml"
file_to_add = "$target_filename"
ce_type = "$ce_type"
ce_folder = "$ce_folder"

try:
    tree = ET.parse(core_path)
    root = tree.getroot()
    
    # Find the correct CE block by folder attribute
    ce_node = None
    for ce in root.findall('ce'):
        if ce.get('folder') == ce_folder:
            ce_node = ce
            break
    
    # If no matching CE block, create one
    if ce_node is None:
        ce_node = ET.SubElement(root, 'ce', {'folder': ce_folder})
    
    # Check if file already exists in any CE block
    exists = False
    for ce in root.findall('ce'):
        for f in ce.findall('file'):
            if f.get('name') == file_to_add:
                exists = True
                break
        if exists:
            break
            
    if not exists:
        new_file = ET.SubElement(ce_node, 'file', {'name': file_to_add, 'type': ce_type})
        if hasattr(ET, 'indent'):
            ET.indent(tree, space="\t", level=0)
        tree.write(core_path, encoding='UTF-8', xml_declaration=True)
except Exception as e:
    sys.exit(1)
EOF
}


# Register a loot XML as a modular include
register_modular_loot() {
    local instance_dir="$1"
    local source_xml="$2"
    local mod_name="$3"
    local silent="${4:-0}"
    
    local mission_path
    if ! mission_path=$(get_mission_path "$instance_dir"); then
        [[ "$silent" == "0" ]] && show_message "Could not find mission path in serverDZ.cfg" "Error"
        return 1
    fi
    
    setup_modular_loot "$mission_path"
    
    # Auto-detect CE file type (types, spawnabletypes, events, eventspawns)
    local ce_type
    ce_type=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" detect-ce-type "$source_xml" 2>/dev/null)
    
    # Fallback to 'types' if detection fails or unknown format
    if [[ -z "$ce_type" ]]; then
        [[ "$silent" == "0" ]] && show_message "Could not detect CE type for '$source_xml'. Assuming 'types'." "Warning"
        ce_type="types"
    fi
    
    local core_xml="${mission_path}/cfgeconomycore.xml"
    local bname=$(basename "$source_xml")
    local target_filename="${mod_name}_${bname}"
    # Clean target name for FS safety
    target_filename=$(echo "$target_filename" | tr -cd '[:alnum:]_.-')
    
    # Route to the correct CE folder based on detected type
    local ce_folder="CustomCE/${ce_type}"
    local target_path="${mission_path}/${ce_folder}/${target_filename}"
    
    # Original snapshot path for merge tracking (Phase 3-4)
    local originals_folder="${mission_path}/${ce_folder}/.originals"
    local original_path="${originals_folder}/${target_filename}"
    
    if [[ -f "$target_path" && "$silent" == "0" ]]; then
        if ! confirm "File '$target_filename' already exists in $ce_folder. Overwrite?" "n"; then
            return 0
        fi
    fi
    
    # 1. Copy file to the correct CE folder (user's working copy)
    mkdir -p "$(dirname "$target_path")"
    cp "$source_xml" "$target_path"
    
    # 2. Save original snapshot for merge tracking (only if not exists or overwriting)
    #    This snapshot is compared against workshop updates to detect changes
    mkdir -p "$originals_folder"
    cp "$source_xml" "$original_path"
    
    # 3. Add to cfgeconomycore.xml using Python for correct CE block
    python3 <<EOF
import xml.etree.ElementTree as ET
import sys

core_path = "$core_xml"
file_to_add = "$target_filename"
ce_type = "$ce_type"
ce_folder = "$ce_folder"

try:
    tree = ET.parse(core_path)
    root = tree.getroot()
    
    # Find the correct CE block by folder attribute
    ce_node = None
    for ce in root.findall('ce'):
        if ce.get('folder') == ce_folder:
            ce_node = ce
            break
    
    # If no matching CE block, create one
    if ce_node is None:
        ce_node = ET.SubElement(root, 'ce', {'folder': ce_folder})
    
    # Check if file already exists in any CE block
    exists = False
    for ce in root.findall('ce'):
        for f in ce.findall('file'):
            if f.get('name') == file_to_add:
                exists = True
                break
        if exists:
            break
            
    if not exists:
        new_file = ET.SubElement(ce_node, 'file', {'name': file_to_add, 'type': ce_type})
        
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
    
    if [[ "$silent" == "0" ]]; then
        show_message "Registered $target_filename in cfgeconomycore.xml (${ce_type})" "Success"
    fi
}

# Unregister a modular include (removes from any CE block)
unregister_modular_loot() {
    local instance_dir="$1"
    local target_filename="$2"
    
    local mission_path=$(get_mission_path "$instance_dir")
    [[ -z "$mission_path" ]] && return 1
    
    echo "[$(date +%T)] MGR: Unregistering/Unlinking: $target_filename" >> "${SCRIPT_DIR}/loot_manager.log"
    
    local core_xml="${mission_path}/cfgeconomycore.xml"
    
    # Remove from cfgeconomycore.xml (searches ALL CE blocks)
    python3 <<EOF
import xml.etree.ElementTree as ET
import sys

core_path = "$core_xml"
file_to_rem = "$target_filename"

try:
    tree = ET.parse(core_path)
    root = tree.getroot()
    
    # Search all CE blocks for the file
    rem_count = 0
    for ce_node in root.findall('ce'):
        for f in ce_node.findall('file'):
            if f.get('name') == file_to_rem:
                ce_node.remove(f)
                rem_count += 1
    
    if rem_count > 0:
        if hasattr(ET, 'indent'):
            ET.indent(tree, space="\t", level=0)
        tree.write(core_path, encoding='UTF-8', xml_declaration=True)
        print("Success")
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
EOF
}

# The new Modular Loot Manager (Professional Bulk View)
modular_loot_manager() {
    local inst_dir="$1"
    local workshop_base="${inst_dir}/data/serverfiles/steamapps/workshop/content/221100"
    local mods_file="${inst_dir}/data/config/mods.txt"
    local servermods_file="${inst_dir}/data/config/servermods.txt"
    
    local selection=0
    local offset=0
    
    echo "=== Loot Manager Session: $(date) ===" > "${SCRIPT_DIR}/loot_manager.log"
    
    while true; do
        # 1. Scan everything
        local -a mod_ids=()
        while IFS= read -r line; do [[ -n "$line" ]] && mod_ids+=("$line"); done < <(get_all_mod_ids "$mods_file" "$servermods_file")
        
        local -a items=()      # Display string
        local -a src_paths=()  # workshop path
        local -a smod_names=()
        local -a sfile_names=()
        local -a sce_types=()  # CE type (types, spawnabletypes, events, eventspawns)
        local -a states=()     # 0=unlinked, 1=linked
        
        local mission_path=$(get_mission_path "$inst_dir")
        
        # Get currently linked files for status (from all CE blocks)
        local linked_files=""
        if [[ -f "${mission_path}/cfgeconomycore.xml" ]]; then
            linked_files=$(grep -o '<file name="[^"]*"' "${mission_path}/cfgeconomycore.xml" | cut -d'"' -f2)
        fi

        for mid in "${mod_ids[@]}"; do
            local mod_path="${workshop_base}/${mid}"
            [[ ! -d "$mod_path" ]] && { echo "[$(date +%T)] MGR: Skipping mod $mid - No path: $mod_path" >> "${SCRIPT_DIR}/loot_manager.log"; continue; }
            local mname=$(get_mod_name "$mid")
            echo "[$(date +%T)] MGR: Scanning Mod: $mname ($mid)" >> "${SCRIPT_DIR}/loot_manager.log"
            
            while IFS= read -r xml_file; do
                [[ -z "$xml_file" ]] && continue
                
                # Detect CE file type using unified detector (returns empty if not a CE file)
                local detected_type
                detected_type=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" detect-ce-type "$xml_file" 2>/dev/null)
                
                # Skip non-CE files
                [[ -z "$detected_type" ]] && continue
                
                local bname=$(basename "$xml_file")
                local target_name="${mname}_${bname}"
                # Clean target name for FS safety
                target_name=$(echo "$target_name" | tr -cd '[:alnum:]_.-')
                
                src_paths+=("$xml_file")
                smod_names+=("$mname")
                sfile_names+=("$bname")
                sce_types+=("$detected_type")
                
                echo "[$(date +%T)] MGR: Found $detected_type: $bname -> Standard: $target_name" >> "${SCRIPT_DIR}/loot_manager.log"
                
                # Detect if ANY version of this mod's loot is linked
                local is_linked=0
                # 1. Check exact standard name
                if echo "$linked_files" | grep -qF "$target_name"; then
                    is_linked=1
                else
                    # 2. Check "fuzzy" legacy name (spaces included)
                    local legacy_name="${mname}_${bname}"
                    if echo "$linked_files" | grep -qF "$legacy_name"; then
                        is_linked=1
                        echo "[$(date +%T)] MGR: Detected linked file with LEGACY naming: $legacy_name" >> "${SCRIPT_DIR}/loot_manager.log"
                    fi
                fi
                
                states+=($is_linked)
            done < <(find "$mod_path" -maxdepth 6 -name "*.xml" -type f 2>/dev/null)
        done

        # 1b. Add Orphans (Files in all CustomCE folders that don't match our scan)
        local -a ce_folders_to_scan=("types" "spawnabletypes" "events" "eventspawns")
        for ce_type_folder in "${ce_folders_to_scan[@]}"; do
            [[ ! -d "${mission_path}/CustomCE/${ce_type_folder}" ]] && continue
            while IFS= read -r ce_file; do
                [[ -z "$ce_file" ]] && continue
                local ce_bname=$(basename "$ce_file")
                local ce_norm=$(echo "$ce_bname" | tr -cd '[:alnum:]_.-')
                
                # Check if this filename matches our CURRENT standard name
                local matched=0
                for ((j=0; j<${#src_paths[@]}; j++)); do
                    local mn="${smod_names[$j]}"
                    local fn="${sfile_names[$j]}"
                    local expected="${mn}_${fn}"
                    # STRICT matching to the current standard
                    expected=$(echo "$expected" | tr -cd '[:alnum:]_.-')
                    
                    if [[ "$ce_bname" == "$expected" ]]; then
                        matched=1; break
                    fi
                done
                
                if [[ $matched -eq 0 ]]; then
                    # Final check: Does it start with ANY active mod name?
                    local owner="LOCAL/VAR"
                    for ((j=0; j<${#mod_ids[@]}; j++)); do
                        local mn=$(get_mod_name "${mod_ids[$j]}")
                        local mn_clean=$(echo "$mn" | tr -cd '[:alnum:]_.-')
                        if [[ "$ce_norm" == "${mn_clean}"* ]]; then
                            owner="$mn"
                            break
                        fi
                    done
                    
                    # Detect CE type for the orphan file
                    local orphan_ce_type="$ce_type_folder"
                    
                    echo "[$(date +%T)] MGR: Found local $orphan_ce_type: $ce_bname (Group: $owner)" >> "${SCRIPT_DIR}/loot_manager.log"
                    src_paths+=("LOCAL:${ce_type_folder}")
                    smod_names+=("$owner")
                    sfile_names+=("$ce_bname")
                    sce_types+=("$orphan_ce_type")
                    
                    # Detect if THIS specific file is linked
                    if echo "$linked_files" | grep -qF "$ce_bname"; then
                        states+=(1) # Linked
                    else
                        states+=(0) # Unlinked
                    fi
                else
                    echo "[$(date +%T)] MGR: File $ce_bname matched to active mod scan." >> "${SCRIPT_DIR}/loot_manager.log"
                fi
            done < <(find "${mission_path}/CustomCE/${ce_type_folder}" -name "*.xml" -type f 2>/dev/null | sort)
        done
        
        local count=${#src_paths[@]}
        if [[ $count -eq 0 ]]; then
            show_message "No mod CE definitions found. Ensure mods are synced." "Info"
            return
        fi

        # 2. Draw TUI
        get_term_size
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        move_to 1 1
        printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Modular Loot Manager - $SELECTED_NAME" "$RESET"
        
        local table_start=3
        move_to $table_start 1
        printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        
        move_to $((table_start + 1)) 1
        printf "  %-12s %-12s %-24s %-30s" "STATUS" "TYPE" "SOURCE / GROUP" "FILE NAME"
        
        move_to $((table_start + 2)) 1
        printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        
        local v_height=$((TERM_ROWS - 10))
        [[ $v_height -lt 5 ]] && v_height=5
        if [[ $selection -lt $offset ]]; then offset=$selection; fi
        if [[ $selection -ge $((offset + v_height)) ]]; then offset=$((selection - v_height + 1)); fi

        for ((i=0; i<v_height; i++)); do
            local idx=$((offset + i))
            [[ $idx -ge $count ]] && break
            
            local row=$((table_start + 3 + i))
            local status_str="[ UNLINKED ]"
            local status_color="$WHITE"
            if [[ ${states[$idx]} -eq 1 ]]; then
                status_str="[  LINKED  ]"
                status_color="$GRN"
            fi
            
            # CE Type formatting
            local ce_type="${sce_types[$idx]:-types}"
            local type_str
            local type_color="$CYN"
            case "$ce_type" in
                types)          type_str="[TYPES]     "; type_color="$CYN" ;;
                spawnabletypes) type_str="[SPAWNABLE] "; type_color="$MAG" ;;
                events)         type_str="[EVENTS]    "; type_color="$YLW" ;;
                eventspawns)   type_str="[EVENTPOS]  "; type_color="$BLU" ;;
                *)              type_str="[OTHER]     "; type_color="$WHITE" ;;
            esac
            
            move_to $row 1
            if [[ $idx -eq $selection ]]; then
                printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
                move_to $row 3
                printf "%-12s %-12s %-24s %-30s" "$status_str" "$type_str" "${smod_names[$idx]:0:24}" "${sfile_names[$idx]:0:30}"
                printf "%s" "$RESET"
            else
                move_to $row 3
                printf "%s%-12s%s %s%-12s%s %-24s %-30s" "$status_color" "$status_str" "$RESET" "$type_color" "$type_str" "$RESET" "${smod_names[$idx]:0:24}" "${sfile_names[$idx]:0:30}"
            fi
        done
        
        # Footer
        move_to $((TERM_ROWS - 1)) 1
        local footer=" [↑↓] Navigate   [Enter] Toggle   [v] View   [d] Delete   [q] Back"
        printf "%s%s%-$((TERM_COLS-1))s%s" "$BG_DARKGRAY" "$WHITE" "$footer" "$RESET"
        
        # 3. Handle Input
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 seq || true
            case "$seq" in
                "[A") [[ $selection -gt 0 ]] && ((selection--)) ;;
                "[B") [[ $selection -lt $((count - 1)) ]] && ((selection++)) ;;
            esac
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            return
        elif [[ "$key" == "v" || "$key" == "V" ]]; then
            local midx=$selection
            local src="${src_paths[$midx]}"
            local fn="${sfile_names[$midx]}"
            local ct="${sce_types[$midx]:-types}"
            
            if [[ "$src" == LOCAL:* ]]; then
                # Extract CE type from LOCAL:folder format
                local local_ce_type="${src#LOCAL:}"
                local p="${mission_path}/CustomCE/${local_ce_type}/${fn}"
                [[ -f "$p" ]] && config_xml_editor "$inst_dir" "$p" "$ct" "$container"
            else
                [[ -f "$src" ]] && config_xml_editor "$inst_dir" "$src" "$ct" "N/A"
            fi
        elif [[ "$key" == "d" || "$key" == "D" ]]; then
            local midx=$selection
            local src="${src_paths[$midx]}"
            local fn="${sfile_names[$midx]}"
            local ct="${sce_types[$midx]:-types}"
            
            # Determine the actual file path
            local p
            if [[ "$src" == LOCAL:* ]]; then
                local local_ce_type="${src#LOCAL:}"
                p="${mission_path}/CustomCE/${local_ce_type}/${fn}"
            else
                # Check if a registered copy exists in the appropriate CE folder
                local mn="${smod_names[$midx]}"
                local tn="${mn}_${fn}"
                tn=$(echo "$tn" | tr -cd '[:alnum:]_.-')
                p="${mission_path}/CustomCE/${ct}/${tn}"
            fi
            
            if [[ -f "$p" ]]; then
                if confirm "Delete physical file '$(basename "$p")'?" "n"; then
                    unregister_modular_loot "$inst_dir" "$(basename "$p")" # Unlink it first
                    rm -f "$p"
                    show_message "Deleted $(basename "$p")" "Success"
                fi
            else
                show_message "This is a workshop source file, cannot delete." "Warning"
            fi
        elif [[ "$key" == "" ]]; then
            local midx=$selection
            local src="${src_paths[$midx]}"
            local mn="${smod_names[$midx]}"
            local fn="${sfile_names[$midx]}"
            local ct="${sce_types[$midx]:-types}"
            local tn="${mn}_${fn}"
            tn=$(echo "$tn" | tr -cd '[:alnum:]_.-')
            
            if [[ ${states[$midx]} -eq 1 ]]; then
                # LINKED -> Unlink (Non-destructive)
                local target_to_unlink="$fn"
                [[ "$src" != LOCAL:* ]] && target_to_unlink="$tn"
                
                if confirm "Unlink '$target_to_unlink' from economy? (Keeps physical file)" "y"; then
                    unregister_modular_loot "$inst_dir" "$target_to_unlink"
                    show_message "Unlinked $target_to_unlink" "Success"
                fi
            else
                # UNLINKED -> Link it!
                if confirm "Link '$fn' ($ct) to your economy?" "y"; then
                    if [[ "$src" == LOCAL:* ]]; then
                        local local_ce_type="${src#LOCAL:}"
                        link_modular_xml "$inst_dir" "$fn" "$local_ce_type"
                    else
                        register_modular_loot "$inst_dir" "$src" "$mn" 1 # Silent, auto-detects type
                    fi
                    show_message "Linked $fn ($ct)" "Success"
                fi
            fi
            # Implicitly re-loops and re-scans
        fi
    done
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

# =============================================================================
# CE File Detection Functions (Phase 3-4)
# =============================================================================

# get_linked_ce_files - Get list of CE files linked in cfgeconomycore.xml
#
# Usage: get_linked_ce_files "$instance_dir"
#
# Output: JSON array to stdout with file info
get_linked_ce_files() {
    local instance_dir="$1"
    local mission_path
    mission_path=$(get_mission_path "$instance_dir") || return 1
    
    local core_xml="${mission_path}/cfgeconomycore.xml"
    [[ ! -f "$core_xml" ]] && echo "[]" && return 0
    
    python3 <<EOF
import xml.etree.ElementTree as ET
import json
import os

mission_path = "$mission_path"
core_path = "$core_xml"

try:
    tree = ET.parse(core_path)
    root = tree.getroot()
    
    files = []
    for ce in root.findall('ce'):
        folder = ce.get('folder', '')
        for f in ce.findall('file'):
            name = f.get('name', '')
            ce_type = f.get('type', 'types')
            full_path = os.path.join(mission_path, folder, name)
            original_path = os.path.join(mission_path, folder, '.originals', name)
            
            files.append({
                "name": name,
                "folder": folder,
                "ce_type": ce_type,
                "path": full_path,
                "original_path": original_path,
                "exists": os.path.exists(full_path),
                "has_original": os.path.exists(original_path)
            })
    
    print(json.dumps(files))
except Exception as e:
    print('[]')
EOF
}

# scan_mods_for_ce_files - Find all CE XML files in installed mods
#
# Usage: scan_mods_for_ce_files "$instance_dir" "$workshop_dir"
#
# Output: JSON array to stdout
#   [{"mod_id": "123", "file": "/path/to.xml", "ce_type": "types", "status": "new|linked|changed"}]
scan_mods_for_ce_files() {
    local instance_dir="$1"
    local workshop_dir="$2"
    
    local mission_path
    mission_path=$(get_mission_path "$instance_dir") || return 1
    
    # Get list of installed mod IDs
    local mods_file="${instance_dir}/data/config/mods.txt"
    local servermods_file="${instance_dir}/data/config/servermods.txt"
    
    # Get already linked files for status checking
    local linked_json
    linked_json=$(get_linked_ce_files "$instance_dir")
    
    python3 <<EOF
import os
import json
import subprocess
import sys

workshop_dir = "$workshop_dir"
instance_dir = "$instance_dir"
mods_file = "$mods_file"
servermods_file = "$servermods_file"
linked_json = '''$linked_json'''
script_dir = "${SCRIPT_DIR}"

# Parse linked files
linked = {f['name']: f for f in json.loads(linked_json)}

# Get all mod IDs from files
mod_ids = set()
for f in [mods_file, servermods_file]:
    if os.path.exists(f):
        with open(f) as fp:
            for line in fp:
                mid = line.strip().split('|')[0].strip()
                if mid.isdigit():
                    mod_ids.add(mid)

results = []

for mod_id in sorted(mod_ids):
    mod_folder = os.path.join(workshop_dir, mod_id)
    if not os.path.isdir(mod_folder):
        continue
    
    # Find XML files in mod
    for root, dirs, files in os.walk(mod_folder):
        for fname in files:
            if not fname.lower().endswith('.xml'):
                continue
            
            fpath = os.path.join(root, fname)
            
            # Detect CE type using xml_parser
            try:
                result = subprocess.run(
                    ['python3', os.path.join(script_dir, 'lib', 'xml_parser.py'), 'detect-ce-type', fpath],
                    capture_output=True, text=True, timeout=5
                )
                ce_type = result.stdout.strip()
                if not ce_type:
                    continue  # Not a CE file
            except:
                continue
            
            # Check status
            status = "new"
            expected_name = f"{mod_id}_{fname}"  # ModID_filename convention
            
            # Also check legacy naming (ModName_filename)
            for linked_name, linked_info in linked.items():
                # Check if this workshop file is already linked (by mod ID prefix or filename match)
                if linked_name.startswith(f"{mod_id}_") or linked_name.endswith(f"_{fname}"):
                    if linked_info.get('has_original'):
                        status = "linked"
                        # TODO: Compare to detect changes
                    else:
                        status = "linked"
                    break
            
            results.append({
                "mod_id": mod_id,
                "file_path": fpath,
                "filename": fname,
                "ce_type": ce_type,
                "status": status
            })

print(json.dumps(results))
EOF
}

# check_ce_file_update - Check if a linked CE file has updates from workshop
#
# Usage: result=$(check_ce_file_update "$workshop_file" "$local_file" "$original_file")
#
# Returns: JSON with diff info
check_ce_file_update() {
    local workshop_file="$1"
    local local_file="$2"
    local original_file="${3:-}"
    
    if [[ ! -f "$workshop_file" ]]; then
        echo '{"error": "Workshop file not found"}'
        return 1
    fi
    
    if [[ ! -f "$local_file" ]]; then
        echo '{"error": "Local file not found"}'
        return 1
    fi
    
    # Use Python diff-ce command
    python3 "${SCRIPT_DIR}/lib/xml_parser.py" diff-ce "$workshop_file" "$local_file"
}

# =============================================================================
# Phase 4: Backup and Merge System
# =============================================================================

# CE_BACKUP_DIR - Get backup directory for CE files
get_ce_backup_dir() {
    local instance_dir="$1"
    local mission_path
    mission_path=$(get_mission_path "$instance_dir") || return 1
    echo "${mission_path}/CustomCE/.backups"
}

# backup_ce_file - Create timestamped backup of CE file before modification
#
# Usage: backup_ce_file "$instance_dir" "$ce_file_path" "$reason"
#
# Returns: Path to backup file on success
backup_ce_file() {
    local instance_dir="$1"
    local ce_file="$2"
    local reason="${3:-manual}"
    
    if [[ ! -f "$ce_file" ]]; then
        echo ""
        return 1
    fi
    
    local backup_dir
    backup_dir=$(get_ce_backup_dir "$instance_dir") || return 1
    mkdir -p "$backup_dir"
    
    local basename
    basename=$(basename "$ce_file")
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="${basename%.xml}_${timestamp}_${reason}.xml"
    local backup_path="${backup_dir}/${backup_name}"
    
    cp "$ce_file" "$backup_path"
    
    # Log the action
    log_ce_action "$instance_dir" "backup" "$basename" "Created backup: $backup_name"
    
    echo "$backup_path"
}

# list_ce_backups - List all backups for a CE file
#
# Usage: list_ce_backups "$instance_dir" "$ce_filename"
#
# Output: JSON array of backups
list_ce_backups() {
    local instance_dir="$1"
    local ce_filename="$2"
    
    local backup_dir
    backup_dir=$(get_ce_backup_dir "$instance_dir") || { echo "[]"; return; }
    
    if [[ ! -d "$backup_dir" ]]; then
        echo "[]"
        return
    fi
    
    # Strip .xml extension for matching
    local base="${ce_filename%.xml}"
    
    python3 <<EOF
import os
import json
import re
from datetime import datetime

backup_dir = "$backup_dir"
base = "$base"

backups = []
pattern = re.compile(rf'^{re.escape(base)}_(\d{{8}}_\d{{6}})_(\w+)\.xml$')

if os.path.isdir(backup_dir):
    for f in sorted(os.listdir(backup_dir), reverse=True):
        m = pattern.match(f)
        if m:
            ts_str = m.group(1)
            reason = m.group(2)
            try:
                dt = datetime.strptime(ts_str, '%Y%m%d_%H%M%S')
                backups.append({
                    "filename": f,
                    "path": os.path.join(backup_dir, f),
                    "timestamp": ts_str,
                    "timestamp_human": dt.strftime('%Y-%m-%d %H:%M:%S'),
                    "reason": reason,
                    "size": os.path.getsize(os.path.join(backup_dir, f))
                })
            except: pass

print(json.dumps(backups[:20]))  # Limit to most recent 20
EOF
}

# restore_ce_backup - Restore a CE file from backup
#
# Usage: restore_ce_backup "$instance_dir" "$backup_path" "$target_path"
#
# Creates a backup of current state before restoring
restore_ce_backup() {
    local instance_dir="$1"
    local backup_path="$2"
    local target_path="$3"
    
    if [[ ! -f "$backup_path" ]]; then
        echo "Backup file not found: $backup_path" >&2
        return 1
    fi
    
    # Create a backup of current state before restoring
    if [[ -f "$target_path" ]]; then
        backup_ce_file "$instance_dir" "$target_path" "prerestore" >/dev/null
    fi
    
    cp "$backup_path" "$target_path"
    
    local basename
    basename=$(basename "$target_path")
    log_ce_action "$instance_dir" "restore" "$basename" "Restored from: $(basename "$backup_path")"
    
    echo "Restored successfully"
}

# log_ce_action - Log CE file actions for audit trail
#
# Usage: log_ce_action "$instance_dir" "$action" "$filename" "$message"
log_ce_action() {
    local instance_dir="$1"
    local action="$2"
    local filename="$3"
    local message="$4"
    
    local log_dir="${instance_dir}/data/state"
    mkdir -p "$log_dir"
    
    local log_file="${log_dir}/ce_audit.log"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[${timestamp}] ${action^^}: ${filename} - ${message}" >> "$log_file"
}

# merge_ce_file - Merge workshop updates into local CE file with backup
#
# Usage: result=$(merge_ce_file "$instance_dir" "$workshop_file" "$local_file" "$original_file")
#
# Returns: JSON merge result
merge_ce_file() {
    local instance_dir="$1"
    local workshop_file="$2"
    local local_file="$3"
    local original_file="${4:-}"
    
    if [[ ! -f "$workshop_file" ]]; then
        echo '{"success": false, "error": "Workshop file not found"}'
        return 1
    fi
    
    if [[ ! -f "$local_file" ]]; then
        echo '{"success": false, "error": "Local file not found"}'
        return 1
    fi
    
    # Create backup before merge
    local backup_path
    backup_path=$(backup_ce_file "$instance_dir" "$local_file" "premerge")
    
    if [[ -z "$backup_path" ]]; then
        echo '{"success": false, "error": "Failed to create backup"}'
        return 1
    fi
    
    # Perform merge using Python
    local result
    if [[ -n "$original_file" && -f "$original_file" ]]; then
        result=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" merge-ce "$workshop_file" "$local_file" --original "$original_file")
    else
        result=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" merge-ce "$workshop_file" "$local_file")
    fi
    
    local basename
    basename=$(basename "$local_file")
    
    # Log the merge
    local added removed
    added=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('added',[])))" 2>/dev/null || echo "0")
    log_ce_action "$instance_dir" "merge" "$basename" "Merged: +${added} items, backup: $(basename "$backup_path")"
    
    echo "$result"
}

# prompt_ce_merge - Interactive TUI prompt for CE file merge
#
# Usage: prompt_ce_merge "$instance_dir" "$mod_id" "$workshop_file" "$local_file" "$original_file"
#
# Returns: 0 if user chose to merge/skip, 1 if cancelled
prompt_ce_merge() {
    local instance_dir="$1"
    local mod_id="$2"
    local workshop_file="$3"
    local local_file="$4"
    local original_file="${5:-}"
    
    local basename
    basename=$(basename "$local_file")
    
    # Get diff info
    local diff_result
    diff_result=$(check_ce_file_update "$workshop_file" "$local_file")
    
    local added removed modified
    added=$(echo "$diff_result" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('added',[])))" 2>/dev/null || echo "0")
    removed=$(echo "$diff_result" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('removed',[])))" 2>/dev/null || echo "0")
    modified=$(echo "$diff_result" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('modified',[])))" 2>/dev/null || echo "0")
    
    # Build menu items
    local -a items=(
        "🔀|Merge (add new items, preserve your edits)"
        "📥|Replace (overwrite with workshop version)"
        "⏭️|Skip (keep your current version)"
        "👁️|View Diff Details"
        "--------------------"
        "❌|Cancel"
    )
    
    local title="CE Update: ${basename} (Mod ${mod_id})"
    local selection=0
    
    while true; do
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        
        # Header
        move_to 1 1
        printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "$title" "$RESET"
        
        # Diff summary
        move_to 3 2
        printf "%sChanges detected:%s" "$BOLD" "$RESET"
        move_to 4 4
        printf "%s+%d new items%s  %s-%d removed%s  %s~%d modified%s" \
            "$GREEN" "$added" "$RESET" \
            "$RED" "$removed" "$RESET" \
            "$YELLOW" "$modified" "$RESET"
        
        move_to 6 2
        printf "%sChoose action:%s" "$DIM" "$RESET"
        
        # Menu items
        local row=8
        for i in "${!items[@]}"; do
            move_to $row 4
            local item="${items[$i]}"
            
            if [[ "$item" == ----* ]]; then
                printf "%s%s%s" "$DIM" "────────────────────────" "$RESET"
            elif [[ $i -eq $selection ]]; then
                printf "%s%s ▶ %s %s" "$BG_RED" "$WHITE$BOLD" "${item#*|}" "$RESET"
            else
                local icon="${item%%|*}"
                local label="${item#*|}"
                printf "   %s %s" "$icon" "$label"
            fi
            ((row++))
        done
        
        # Read key
        read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq
                case "$seq" in
                    '[A') ((selection > 0)) && ((selection--)) ;;
                    '[B') ((selection < ${#items[@]} - 1)) && ((selection++)) ;;
                esac
                # Skip separators
                while [[ "${items[$selection]}" == "----"* && $selection -gt 0 ]]; do ((selection--)); done
                while [[ "${items[$selection]}" == "----"* && $selection -lt $((${#items[@]} - 1)) ]]; do ((selection++)); done
                ;;
            '')
                local selected_item="${items[$selection]}"
                case "$selected_item" in
                    "🔀|"*)
                        # Merge
                        local result
                        result=$(merge_ce_file "$instance_dir" "$workshop_file" "$local_file" "$original_file")
                        local success
                        success=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
                        if [[ "$success" == "True" ]]; then
                            show_message "Merged successfully! +${added} items added." "Merge"
                        else
                            show_message "Merge failed. Check backup in .backups/" "Error"
                        fi
                        return 0
                        ;;
                    "📥|"*)
                        # Replace
                        if confirm "This will OVERWRITE your local changes. Continue?" "n"; then
                            backup_ce_file "$instance_dir" "$local_file" "prereplace" >/dev/null
                            cp "$workshop_file" "$local_file"
                            log_ce_action "$instance_dir" "replace" "$basename" "Replaced with workshop version"
                            show_message "Replaced with workshop version. Backup saved." "Replace"
                        fi
                        return 0
                        ;;
                    "⏭️|"*)
                        # Skip
                        log_ce_action "$instance_dir" "skip" "$basename" "User skipped update"
                        return 0
                        ;;
                    "👁️|"*)
                        # View diff
                        printf "%s" "$CLEAR_SCREEN"
                        move_to 1 1
                        printf "%s%s Diff Details: %s %s\n" "$BG_RED" "$WHITE$BOLD" "$basename" "$RESET"
                        echo ""
                        echo "$diff_result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'Added ({len(d.get(\"added\",[]))}):')
for x in d.get('added',[])[:10]: print(f'  + {x}')
if len(d.get('added',[])) > 10: print(f'  ... and {len(d.get(\"added\",[]))-10} more')
print(f'\\nRemoved ({len(d.get(\"removed\",[]))}):')
for x in d.get('removed',[])[:10]: print(f'  - {x}')
if len(d.get('removed',[])) > 10: print(f'  ... and {len(d.get(\"removed\",[]))-10} more')
print(f'\\nModified ({len(d.get(\"modified\",[]))}):')
for x in d.get('modified',[])[:10]: print(f'  ~ {x}')
if len(d.get('modified',[])) > 10: print(f'  ... and {len(d.get(\"modified\",[]))-10} more')
"
                        echo ""
                        read -rp "Press Enter to continue..."
                        ;;
                    "❌|"*)
                        return 1
                        ;;
                esac
                ;;
            'q'|'Q')
                return 1
                ;;
        esac
    done
}

# show_rollback_menu - TUI menu to rollback CE file from backups
#
# Usage: show_rollback_menu "$instance_dir" "$ce_filename" "$target_path"
show_rollback_menu() {
    local instance_dir="$1"
    local ce_filename="$2"
    local target_path="$3"
    
    local backups_json
    backups_json=$(list_ce_backups "$instance_dir" "$ce_filename")
    
    local backup_count
    backup_count=$(echo "$backups_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    
    if [[ "$backup_count" -eq 0 ]]; then
        show_message "No backups found for $ce_filename" "Rollback"
        return 0
    fi
    
    # Build items from JSON
    local -a items=()
    local -a paths=()
    
    while IFS= read -r line; do
        items+=("$line")
    done < <(echo "$backups_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for b in data:
    print(f\"{b['timestamp_human']} ({b['reason']})\")
")
    
    while IFS= read -r path; do
        paths+=("$path")
    done < <(echo "$backups_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for b in data:
    print(b['path'])
")
    
    items+=("--------------------")
    items+=("❌|Cancel")
    
    local selection=0
    
    if run_menu items "Rollback: $ce_filename" $selection; then
        selection=$MENU_RESULT
        
        if [[ $selection -lt ${#paths[@]} ]]; then
            local selected_path="${paths[$selection]}"
            if confirm "Restore from $(basename "$selected_path")?" "n"; then
                restore_ce_backup "$instance_dir" "$selected_path" "$target_path"
                show_message "Restored successfully!" "Rollback"
            fi
        fi
    fi
}
