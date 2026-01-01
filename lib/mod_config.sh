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
    
    if [[ -f "$target_path" && "$silent" == "0" ]]; then
        if ! confirm "File '$target_filename' already exists in $ce_folder. Overwrite?" "n"; then
            return 0
        fi
    fi
    
    # 1. Copy file to the correct CE folder
    mkdir -p "$(dirname "$target_path")"
    cp "$source_xml" "$target_path"
    
    # 2. Add to cfgeconomycore.xml using Python for correct CE block
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
