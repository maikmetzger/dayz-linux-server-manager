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
    local silent="${4:-0}"
    
    local mission_path
    if ! mission_path=$(get_mission_path "$instance_dir"); then
        [[ "$silent" == "0" ]] && show_message "Could not find mission path in serverDZ.cfg" "Error"
        return 1
    fi
    
    setup_modular_loot "$mission_path"
    
    local core_xml="${mission_path}/cfgeconomycore.xml"
    local bname=$(basename "$source_xml")
    local target_filename="${mod_name}_${bname}"
    # Clean target name for FS safety
    target_filename=$(echo "$target_filename" | tr -cd '[:alnum:]_.-')
    local target_path="${mission_path}/CustomCE/types/${target_filename}"
    
    if [[ -f "$target_path" && "$silent" == "0" ]]; then
        if ! confirm "Loot file '$target_filename' already exists. Overwrite?" "n"; then
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
    
    if [[ "$silent" == "0" ]]; then
        show_message "Registered $target_filename in cfgeconomycore.xml" "Success"
    fi
}

# Unregister a modular include
unregister_modular_loot() {
    local instance_dir="$1"
    local target_filename="$2"
    
    local mission_path=$(get_mission_path "$instance_dir")
    [[ -z "$mission_path" ]] && return 1
    
    local core_xml="${mission_path}/cfgeconomycore.xml"
    local target_path="${mission_path}/CustomCE/types/${target_filename}"
    
    # 1. Remove file
    rm -f "$target_path"
    
    # 2. Remove from cfgeconomycore.xml
    python3 <<EOF
import xml.etree.ElementTree as ET
import sys

core_path = "$core_xml"
file_to_rem = "$target_filename"

try:
    tree = ET.parse(core_path)
    root = tree.getroot()
    ce_node = root.find('ce')
    if ce_node is not None:
        rem_count = 0
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
        
        local -a items=()     # Display string
        local -a src_paths=() # workshop path
        local -a smod_names=()
        local -a sfile_names=()
        local -a states=()    # 0=unlinked, 1=linked
        
        local mission_path=$(get_mission_path "$inst_dir")
        local custom_ce="${mission_path}/CustomCE/types"
        
        # Get currently linked files for status
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
                
                # Check if it's a types file (no name filter, rely on content)
                if [[ $(python3 "${SCRIPT_DIR}/lib/xml_parser.py" is-types "$xml_file" 2>/dev/null) == "true" ]]; then
                    local bname=$(basename "$xml_file")
                    local target_name="${mname}_${bname}"
                    # Clean target name for FS safety
                    target_name=$(echo "$target_name" | tr -cd '[:alnum:]_.-')
                    
                    src_paths+=("$xml_file")
                    smod_names+=("$mname")
                    sfile_names+=("$bname")
                    
                    echo "[$(date +%T)] MGR: Found XML: $bname -> Standard: $target_name" >> "${SCRIPT_DIR}/loot_manager.log"
                    
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
                fi
            done < <(find "$mod_path" -maxdepth 6 -name "*.xml" -type f 2>/dev/null)
        done

        # 1b. Add Orphans (Files in CustomCE that don't match our scan)
        if [[ -d "$custom_ce" ]]; then
            while IFS= read -r ce_file; do
                [[ -z "$ce_file" ]] && continue
                local ce_bname=$(basename "$ce_file")
                
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
                    local owner="UNKNOWN/OLD"
                    for ((j=0; j<${#mod_ids[@]}; j++)); do
                        local mn=$(get_mod_name "${mod_ids[$j]}")
                        local mn_clean=$(echo "$mn" | tr -cd '[:alnum:]_.-')
                        if [[ "$ce_norm" == "${mn_clean}"* ]]; then
                            owner="STRAY ($mn)"
                            break
                        fi
                    done
                    
                    echo "[$(date +%T)] MGR: Flagged as Orphan: $ce_bname (Probable Owner: $owner)" >> "${SCRIPT_DIR}/loot_manager.log"
                    src_paths+=("ORPHAN")
                    smod_names+=("$owner")
                    sfile_names+=("$ce_bname")
                    states+=(2) # Orphaned/Stray
                else
                    echo "[$(date +%T)] MGR: File $ce_bname matched to active mod scan." >> "${SCRIPT_DIR}/loot_manager.log"
                fi
            done < <(find "$custom_ce" -name "*.xml" -type f 2>/dev/null | sort)
        fi
        
        local count=${#src_paths[@]}
        if [[ $count -eq 0 ]]; then
            show_message "No mod loot definitions found. Ensure mods are synced." "Info"
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
        printf "  %-12s %-30s %-30s" "STATUS" "MOD NAME" "FILE NAME"
        
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
            local color="$WHITE"
            if [[ ${states[$idx]} -eq 1 ]]; then
                status_str="[  LINKED  ]"
                color="$GRN"
            elif [[ ${states[$idx]} -eq 2 ]]; then
                status_str="[ ORPHANED ]"
                color="$RED"
            fi
            
            move_to $row 1
            if [[ $idx -eq $selection ]]; then
                printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
                move_to $row 3
                printf "%-12s %-30s %-30s" "$status_str" "${smod_names[$idx]}" "${sfile_names[$idx]}"
                printf "%s" "$RESET"
            else
                move_to $row 3
                printf "%s%-12s%s %-30s %-30s" "$color" "$status_str" "$RESET" "${smod_names[$idx]}" "${sfile_names[$idx]}"
            fi
        done
        
        # Footer
        move_to $((TERM_ROWS - 1)) 1
        local footer=" [↑↓] Navigate   [Enter] Toggle Link   [v] View XML   [q] Back"
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
            
            if [[ "$src" == "ORPHAN" ]]; then
                local p="${mission_path}/CustomCE/types/${fn}"
                [[ -f "$p" ]] && config_xml_editor "$inst_dir" "$p" "types" "$container"
            else
                [[ -f "$src" ]] && config_xml_editor "$inst_dir" "$src" "types" "N/A"
            fi
        elif [[ "$key" == "" ]]; then
            local midx=$selection
            local src="${src_paths[$midx]}"
            local mn="${smod_names[$midx]}"
            local fn="${sfile_names[$midx]}"
            local tn="${mn}_${fn}"
            tn=$(echo "$tn" | tr -cd '[:alnum:]_.-')
            
            if [[ ${states[$midx]} -eq 0 ]]; then
                # Use silent mode (1) for instant toggle in manager
                register_modular_loot "$inst_dir" "$src" "$mn" 1
            elif [[ ${states[$midx]} -eq 1 ]]; then
                # We still confirm unlinking as it's destructive (removes your edits)
                if confirm "Unlink modular loot '$tn'? (This deletes the custom XML file)" "n"; then
                    unregister_modular_loot "$inst_dir" "$tn"
                fi
            else
                # Orphaned - Simple delete
                if confirm "File '$fn' is orphaned and not found in any active mod. Delete it?" "y"; then
                    unregister_modular_loot "$inst_dir" "$fn"
                    show_message "Deleted orphaned file." "Success"
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
