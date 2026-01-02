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
source "${MOD_CONFIG_LIB_DIR}/utils.sh"
source "${MOD_CONFIG_LIB_DIR}/colors.sh"
source "${MOD_CONFIG_LIB_DIR}/file_browser.sh"
source "${MOD_CONFIG_LIB_DIR}/dialogs.sh"
source "${MOD_CONFIG_LIB_DIR}/tui.sh"

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
    local force_type="${5:-}"
    
    local mission_path
    if ! mission_path=$(get_mission_path "$instance_dir"); then
        [[ "$silent" == "0" ]] && show_message "Could not find mission path in serverDZ.cfg" "Error"
        return 1
    fi
    
    setup_modular_loot "$mission_path"
    
    # Auto-detect or use forced CE file type
    local ce_type="$force_type"
    if [[ -z "$ce_type" ]]; then
        ce_type=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" detect-ce-type "$source_xml" 2>/dev/null)
        
        # Fallback to 'types' if detection fails or unknown format
        if [[ -z "$ce_type" ]]; then
            # Only warn if not silent and it doesn't look like a standard types file
            if [[ "$silent" == "0" ]]; then
                local b=$(basename "$source_xml")
                if [[ "$b" != *"types"* ]]; then
                    show_message "Could not detect CE type for '$b'. Assuming 'types'." "Warning"
                fi
            fi
            ce_type="types"
        fi
    fi
    
    local core_xml="${mission_path}/cfgeconomycore.xml"
    local bname=$(basename "$source_xml")
    
    local target_filename
    if [[ "$mod_name" == "LOCAL" || "$mod_name" == "ORPHAN" ]]; then
        target_filename="$bname"
    else
        target_filename="${mod_name}_${bname}"
    fi

    # Clean target name for FS safety
    target_filename=$(echo "$target_filename" | tr -cd '[:alnum:]_.-')
    
    # Route to the correct CE folder based on detected type
    local ce_folder="CustomCE/${ce_type}"
    local target_path="${mission_path}/${ce_folder}/${target_filename}"
    
    # Original snapshot path for merge tracking (Phase 3-4)
    local originals_folder="${mission_path}/${ce_folder}/.originals"
    local original_path="${originals_folder}/${target_filename}"
    
    local skip_copy=0
    if [[ -f "$target_path" && "$silent" == "0" ]]; then
        if ! confirm "File '$target_filename' already exists in $ce_folder. Overwrite?" "n"; then
            echo "Skipping overwrite, but will ensure it is linked in XML."
            skip_copy=1
        fi
    fi
    
    # 1. Copy file to the correct CE folder (user's working copy)
    if [[ "$skip_copy" -eq 0 ]]; then
        mkdir -p "$(dirname "$target_path")"
        cp "$source_xml" "$target_path"
    fi
    
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
    
    # Export vars for Python (heredoc is quoted to prevent shell issues)
    export UNREGISTER_CORE_PATH="$core_xml"
    export UNREGISTER_FILENAME="$target_filename"
    
    # Remove from cfgeconomycore.xml (searches ALL CE blocks with case-insensitive match)
    python3 <<'PYTHON_UNREGISTER'
import xml.etree.ElementTree as ET
import sys
import os

core_path = os.environ.get('UNREGISTER_CORE_PATH')
file_to_rem = os.environ.get('UNREGISTER_FILENAME')

try:
    tree = ET.parse(core_path)
    root = tree.getroot()
    
    # Search all CE blocks for the file (case-insensitive)
    rem_count = 0
    file_to_rem_lower = file_to_rem.lower().strip()
    for ce_node in root.findall('ce'):
        for f in list(ce_node.findall('file')):
            fname = f.get('name', '')
            if fname.lower().strip() == file_to_rem_lower:
                ce_node.remove(f)
                rem_count += 1
                sys.stderr.write(f"DEBUG: Removed '{fname}' from cfgeconomycore.xml\n")
    
    if rem_count > 0:
        if hasattr(ET, 'indent'):
            ET.indent(tree, space="\t", level=0)
        tree.write(core_path, encoding='UTF-8', xml_declaration=True)
        print("Success")
    else:
        sys.stderr.write(f"DEBUG: No match found for '{file_to_rem}' in cfgeconomycore.xml\n")
        print("NotFound")
except Exception as e:
    sys.stderr.write(f"DEBUG: Error in unregister: {e}\n")
    print(f"Error: {e}")
    sys.exit(1)
PYTHON_UNREGISTER
}

# -----------------------------------------------------------------------------
# CE Ignore List Management
# Files in this list won't trigger "found unlinked files" prompts during sync
# -----------------------------------------------------------------------------

# Get path to the ignore list JSON file
get_ce_ignore_file() {
    local inst_dir="$1"
    local mission_path
    mission_path=$(get_mission_path "$inst_dir" 2>/dev/null)
    echo "${mission_path}/CustomCE/.ce_ignored.json"
}

# Check if a file is in the ignore list
# Usage: is_ce_ignored "$inst_dir" "mod_id" "filename"
is_ce_ignored() {
    local inst_dir="$1"
    local mod_id="$2"
    local filename="$3"
    local ignore_file
    ignore_file=$(get_ce_ignore_file "$inst_dir")
    
    if [[ ! -f "$ignore_file" ]]; then
        return 1  # Not ignored
    fi
    
    python3 -c "
import json, sys
try:
    with open('$ignore_file', 'r') as f:
        data = json.load(f)
    key = f'${mod_id}|${filename}'.lower()
    if key in [x.lower() for x in data.get('ignored', [])]:
        sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
"
}

# Add a file to the ignore list
# Usage: add_ce_ignore "$inst_dir" "mod_id" "filename"
add_ce_ignore() {
    local inst_dir="$1"
    local mod_id="$2"
    local filename="$3"
    local ignore_file
    ignore_file=$(get_ce_ignore_file "$inst_dir")
    
    python3 -c "
import json, os
ignore_file = '$ignore_file'
mod_id = '$mod_id'
filename = '$filename'
key = f'{mod_id}|{filename}'

data = {'ignored': []}
if os.path.exists(ignore_file):
    try:
        with open(ignore_file, 'r') as f:
            data = json.load(f)
    except: pass

if 'ignored' not in data:
    data['ignored'] = []

if key not in data['ignored']:
    data['ignored'].append(key)

os.makedirs(os.path.dirname(ignore_file), exist_ok=True)
with open(ignore_file, 'w') as f:
    json.dump(data, f, indent=2)
print('Added')
"
}

# Remove a file from the ignore list
# Usage: remove_ce_ignore "$inst_dir" "mod_id" "filename"
remove_ce_ignore() {
    local inst_dir="$1"
    local mod_id="$2"
    local filename="$3"
    local ignore_file
    ignore_file=$(get_ce_ignore_file "$inst_dir")
    
    if [[ ! -f "$ignore_file" ]]; then
        return
    fi
    
    python3 -c "
import json
ignore_file = '$ignore_file'
mod_id = '$mod_id'
filename = '$filename'
key = f'{mod_id}|{filename}'

try:
    with open(ignore_file, 'r') as f:
        data = json.load(f)
    
    if 'ignored' in data and key in data['ignored']:
        data['ignored'].remove(key)
        with open(ignore_file, 'w') as f:
            json.dump(data, f, indent=2)
        print('Removed')
except: pass
"
}

# Scans mods for CE files and returns structured data
# The new Modular Loot Manager (Professional Bulk View)
# Uses scan_dayz_ce_files_python to get data
modular_loot_dashboard() {
    local inst_dir="$1"
    
    
    local selection=0
    local offset=0
    
    echo "=== Loot Manager Session: $(date) ===" > "${SCRIPT_DIR}/loot_manager.log"
    
    # Error trap for debugging - catches which line causes exit
    trap 'echo "[CRASH] Line $LINENO: $BASH_COMMAND" >> "${SCRIPT_DIR}/loot_manager.log"' ERR
    
    # helper to parse JSON array to bash arrays
    parse_scan_result() {
        local json="$1"
        # Reset arrays
        src_paths=()
        smod_ids=()
        smod_names=()
        sfile_names=()
        sce_types=()
        states=()
        slinked_names=()
        smodified=()
        signored=()
        
        while IFS='|' read -r sp mid mn fn ct st ln md; do
            [[ -z "$sp" ]] && continue
            src_paths+=("$sp")
            smod_ids+=("$mid")
            smod_names+=("$mn")
            sfile_names+=("$fn")
            sce_types+=("$ct")
            states+=("$st")
            slinked_names+=("$ln")
            smodified+=("$md")
            signored+=(0)  # Will be checked after
        done < <(echo "$json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for i in data:
        st = 1 if i.get('status') == 'linked' else 0
        ln = i.get('linked_filename', '')
        md = 1 if i.get('modified', False) else 0
        print(f\"{i['file_path']}|{i['mod_id']}|{i.get('mod_name', 'mod_' + i['mod_id'])}|{i['filename']}|{i.get('ce_type', 'types')}|{st}|{ln}|{md}\")
except: pass
")
    }
    
    # Check ignore status for all parsed files
    check_ignore_status() {
        local ignore_file
        ignore_file=$(get_ce_ignore_file "$inst_dir")
        
        if [[ ! -f "$ignore_file" ]]; then
            return
        fi
        
        local ignored_list
        ignored_list=$(python3 -c "
import json
try:
    with open('$ignore_file', 'r') as f:
        data = json.load(f)
    for item in data.get('ignored', []):
        print(item.lower())
except: pass
" 2>/dev/null)
        
        for ((i=0; i<${#smod_ids[@]}; i++)); do
            local key="${smod_ids[$i]}|${sfile_names[$i]}"
            if echo "$ignored_list" | grep -qi "^${key}$" 2>/dev/null; then
                signored[$i]=1
            fi
        done
    }

    while true; do
        # 1. Scan everything (calls the Python implementation)
        echo "[DEBUG] 1. Starting scan..." >> "${SCRIPT_DIR}/loot_manager.log"
        local ce_result
        local workshop_path="${inst_dir}/data/serverfiles/steamapps/workshop/content/221100"
        if [[ ! -d "$workshop_path" ]]; then workshop_path="${inst_dir}/serverfiles/steamapps/workshop/content/221100"; fi
        echo "[DEBUG] 2. Workshop path: $workshop_path" >> "${SCRIPT_DIR}/loot_manager.log"
        
        ce_result=$(scan_dayz_ce_files_python "$inst_dir" "$workshop_path" 2>>"${SCRIPT_DIR}/loot_manager.log" | tail -n 1)
        echo "[DEBUG] 3. Scan done, result length: ${#ce_result}" >> "${SCRIPT_DIR}/loot_manager.log"
        
        if [[ -z "$ce_result" ]]; then ce_result="[]"; fi

        # 2. Parse result into arrays
        echo "[DEBUG] 4. Parsing results..." >> "${SCRIPT_DIR}/loot_manager.log"
        local -a src_paths smod_ids smod_names sfile_names sce_types states slinked_names smodified signored
        parse_scan_result "$ce_result"
        echo "[DEBUG] 5. Parse done, count: ${#src_paths[@]}" >> "${SCRIPT_DIR}/loot_manager.log"
        
        # 3. Check ignore status for each file
        check_ignore_status
        echo "[DEBUG] 6. Ignore check done" >> "${SCRIPT_DIR}/loot_manager.log"
        
        local count=${#src_paths[@]}
        if [[ $count -eq 0 ]]; then
            show_message "No mod CE definitions detected." "Info"
            # Fallback to manual browse if empty
            mod_config_browser "$inst_dir/data/config" 
            return
        fi

        # 3. Draw TUI
        echo "[DEBUG] 7. Drawing TUI, count=$count" >> "${SCRIPT_DIR}/loot_manager.log"
        get_term_size
        echo "[DEBUG] 8. Term size: ${TERM_ROWS}x${TERM_COLS}" >> "${SCRIPT_DIR}/loot_manager.log"
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        move_to 1 1
        printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Modular Loot Manager - $SELECTED_NAME" "$RESET"
        
        local table_start=3
        move_to $table_start 1
        printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        
        move_to $((table_start + 1)) 1
        printf "  %-12s %-3s %-10s %-12s %-24s %-28s" "STATUS" "MOD" "TYPE" "WORKSHOP ID" "SOURCE / GROUP" "FILE NAME"
        
        move_to $((table_start + 2)) 1
        printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        
        local v_height=$((TERM_ROWS - 10))
        [[ $v_height -lt 5 ]] && v_height=5
        if [[ $selection -lt $offset ]]; then offset=$selection; fi
        if [[ $selection -ge $((offset + v_height)) ]]; then offset=$((selection - v_height + 1)); fi

        echo "[DEBUG] 9. Starting row loop, v_height=$v_height, offset=$offset" >> "${SCRIPT_DIR}/loot_manager.log"
        for ((i=0; i<v_height; i++)); do
            local idx=$((offset + i))
            [[ $idx -ge $count ]] && break
            
            # Debug: log each row being drawn
            echo "[DEBUG] 10. Drawing row i=$i idx=$idx ce_type=${sce_types[$idx]:-unknown}" >> "${SCRIPT_DIR}/loot_manager.log"
            
            local row=$((table_start + 3 + i))
            local status_str="[ UNLINKED ]"
            local status_color="$WHITE"
            local row_dim=""
            
            # Check ignored status first (overrides unlinked display)
            if [[ ${signored[$idx]:-0} -eq 1 ]]; then
                status_str="[ IGNORED  ]"
                status_color="$DIM"
                row_dim="$DIM"
            elif [[ ${states[$idx]} -eq 1 ]]; then
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
                eventspawns)    type_str="[EVENTPOS]  "; type_color="$BLU" ;;
                randompresets)  type_str="[PRESETS]   "; type_color="$GRN" ;;
                eventgroups)    type_str="[GROUPS]    "; type_color="$RED" ;;
                *)              type_str="[OTHER]     "; type_color="$WHITE" ;;
            esac
            
            # Modified indicator
            local mod_str="   "
            local mod_color="$WHITE"
            if [[ ${smodified[$idx]:-0} -eq 1 ]]; then
                mod_str="[*]"
                mod_color="$YLW"
            fi
            
            move_to $row 1
            if [[ $idx -eq $selection ]]; then
                printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
                move_to $row 3
                printf "%-12s %3s %-10s %-12s %-24s %-28s" "$status_str" "$mod_str" "$type_str" "${smod_ids[$idx]:0:12}" "${smod_names[$idx]:0:24}" "${sfile_names[$idx]:0:28}"
                printf "%s" "$RESET"
            else
                move_to $row 3
                printf "%s%s%-12s%s %s%3s%s %s%-10s%s %-12s %-24s %-28s%s" "$row_dim" "$status_color" "$status_str" "$RESET$row_dim" "$mod_color" "$mod_str" "$RESET$row_dim" "$type_color" "$type_str" "$RESET$row_dim" "${smod_ids[$idx]:0:12}" "${smod_names[$idx]:0:24}" "${sfile_names[$idx]:0:28}" "$RESET"
            fi
        done
        
        # Footer
        move_to $((TERM_ROWS - 1)) 1
        local footer=" [Enter] Edit   [L] Link   [I] Ignore   [r] Rollback   [d] Delete   [q] Back"
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
        elif [[ "$key" == "r" || "$key" == "R" ]]; then
             local midx=$selection
             local fn="${sfile_names[$midx]}"
             
             # Call Rollback UI (Phase 4)
             local target_xml="${inst_dir}/serverfiles/mpmissions/dayzOffline.chernarusplus/CustomCE/${sce_types[$midx]}/${smod_names[$midx]}_${fn}"
             # Fix path resolution (quick hack, ideally use get_mission_path)
             # But prompt_rollback expects args...
             show_rollback_menu "$inst_dir" "${smod_names[$midx]}_${fn}" "$(get_mission_path "$inst_dir")/CustomCE/${sce_types[$midx]}/${smod_names[$midx]}_${fn}"
             
        elif [[ "$key" == "d" || "$key" == "D" ]]; then
            local midx=$selection
            local src="${src_paths[$midx]}"
            local fn="${sfile_names[$midx]}"
            local m_id="${smod_ids[$midx]}"
            local ct="${sce_types[$midx]:-types}"
            
            # Determine target filename
            local tn="${m_id}_${fn}"
            [[ "$m_id" == "LOCAL" ]] && tn="$fn"
            
            # Use actual linked name if it exists (handles cleaned/legacy names)
            if [[ -n "${slinked_names[$midx]}" ]]; then tn="${slinked_names[$midx]}"; fi
            
            local cleaned_tn=$(echo "$tn" | tr -cd '[:alnum:]_.-')
            local p="$(get_mission_path "$inst_dir")/CustomCE/${ct}/${tn}"
            
            # Fallback checks for path robustnes
            if [[ ! -f "$p" && -f "$(get_mission_path "$inst_dir")/CustomCE/${ct}/${cleaned_tn}" ]]; then p="$(get_mission_path "$inst_dir")/CustomCE/${ct}/${cleaned_tn}"; fi
            if [[ ! -f "$p" && -f "$(get_mission_path "$inst_dir")/CustomCE/types/${tn}" ]]; then p="$(get_mission_path "$inst_dir")/CustomCE/types/${tn}"; fi
            
            if [[ -f "$p" ]]; then
                if confirm "Delete physical file '$(basename "$p")'?" "n"; then
                    unregister_modular_loot "$inst_dir" "$(basename "$p")"
                    rm -f "$p"
                    show_message "Deleted $(basename "$p")" "Success"
                fi
            else
                show_message "File does not exist: $(basename "$p")" "Warning"
            fi
        elif [[ "$key" == "l" || "$key" == "L" ]]; then
            # Toggle Link/Unlink
            local midx=$selection
            local src="${src_paths[$midx]}"
            local mn="${smod_ids[$midx]}"
            local fn="${sfile_names[$midx]}"
            local ct="${sce_types[$midx]:-types}"
            
            if [[ ${states[$midx]} -eq 1 ]]; then
                # LINKED -> Unlink
                local target_to_unlink="${smod_ids[$midx]}_${fn}"
                [[ "${smod_ids[$midx]}" == "LOCAL" ]] && target_to_unlink="$fn"
                
                # Use ACTUAL linked filename if detected
                if [[ -n "${slinked_names[$midx]}" ]]; then
                    target_to_unlink="${slinked_names[$midx]}"
                fi
                
                if confirm "Unlink '$fn' from ${smod_names[$midx]}?" "y"; then
                    unregister_modular_loot "$inst_dir" "$target_to_unlink"
                fi
            else
                # UNLINKED -> Link
                # If ignored, auto-remove from ignore list when linking
                if [[ ${signored[$midx]:-0} -eq 1 ]]; then
                    remove_ce_ignore "$inst_dir" "${smod_ids[$midx]}" "$fn"
                fi
                
                # Check for merge-only types that can't be linked via cfgeconomycore
                if [[ "$ct" == "randompresets" || "$ct" == "eventgroups" ]]; then
                    show_message "$(cat <<EOF
$fn cannot be linked automatically.

cfgrandompresets.xml and cfgeventgroups.xml must be 
MERGED into the existing file at:
  db/cfgrandompresets.xml
  db/cfgeventgroups.xml

This is a DayZ limitation - these files cannot be 
included via cfgeconomycore.xml like types.xml.

Manual merge required for now.
(Automatic merge support coming in Phase 2)
EOF
)" "Merge Required"
                elif confirm "Link '$fn' from ${smod_names[$midx]}?" "y"; then
                     register_modular_loot "$inst_dir" "$src" "${smod_ids[$midx]}" 1 "$ct"
                fi
            fi
        elif [[ "$key" == "i" || "$key" == "I" ]]; then
            # Toggle Ignore status
            local midx=$selection
            local mid="${smod_ids[$midx]}"
            local fn="${sfile_names[$midx]}"
            
            # Can only ignore UNLINKED files
            if [[ ${states[$midx]} -eq 1 ]]; then
                show_message "Cannot ignore linked files. Unlink first." "Warning"
            elif [[ ${signored[$midx]:-0} -eq 1 ]]; then
                # Currently ignored -> Un-ignore
                remove_ce_ignore "$inst_dir" "$mid" "$fn"
            else
                # Not ignored -> Add to ignore list
                add_ce_ignore "$inst_dir" "$mid" "$fn"
            fi
        elif [[ "$key" == "" ]]; then
            # Edit File
            local midx=$selection
            local fn="${sfile_names[$midx]}"
            local ct="${sce_types[$midx]:-types}"
            
            # Determine target for editing
            local target_edit_path="${src_paths[$midx]}" # Default: workshop source
            if [[ ${states[$midx]} -eq 1 ]]; then
                # If linked, edit the ACTIVE copy in CustomCE
                local m_id="${smod_ids[$midx]}"
                local tn="${m_id}_${fn}"
                if [[ "$m_id" == "LOCAL" ]]; then tn="$fn"; fi
                if [[ -n "${slinked_names[$midx]}" ]]; then tn="${slinked_names[$midx]}"; fi
                
                local cleaned_tn=$(echo "$tn" | tr -cd '[:alnum:]_.-')
                target_edit_path="$(get_mission_path "$inst_dir")/CustomCE/${ct}/${tn}"
                
                # Check cleaned name or 'types' folder as fallback
                if [[ ! -f "$target_edit_path" && -f "$(get_mission_path "$inst_dir")/CustomCE/${ct}/${cleaned_tn}" ]]; then
                    target_edit_path="$(get_mission_path "$inst_dir")/CustomCE/${ct}/${cleaned_tn}"
                fi
                if [[ ! -f "$target_edit_path" && -f "$(get_mission_path "$inst_dir")/CustomCE/types/${tn}" ]]; then
                    target_edit_path="$(get_mission_path "$inst_dir")/CustomCE/types/${tn}"
                fi
                
                # FINAL FALLBACK: If it's linked but we can't find the copy, edit the source!
                if [[ ! -f "$target_edit_path" ]]; then
                    target_edit_path="${src_paths[$midx]}"
                fi
            fi
            
            if [[ -f "$target_edit_path" ]]; then
                xml_edit_file "$target_edit_path" "Edit ${fn}"
            else
                show_message "File not found for editing: $(basename "$target_edit_path") (Src: $fn)" "Error"
            fi
        fi
    done
}

# =============================================================================
# Specialized Mod Config Actions (Wrappers)
# =============================================================================

mod_config_on_select() {
    local path="$1"
    local name=$(basename "$path")
    local dir=$(dirname "$path")
    local parent_name=$(basename "$dir")
    
    if [[ -d "$path" ]]; then
        fb_browse_dir "$path" "Mod Config Editor" "ROOT > Mod Configs > $parent_name" "mod_config_on_select" "all"
        return
    fi
    
    local handler=$(get_file_handler "$path")
    case "$handler" in
        xml)  xml_edit_file "$path" "$parent_name / $name" ;;
        *)    fb_edit_file_nano "$path" "$parent_name / $name" ;;
    esac
}

xml_edit_file() {
    local file="$1"
    local title="${2:-XML Editor}"
    local is_types
    is_types=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" is-types "$file" 2>/dev/null || echo "false")
    
    if [[ "$is_types" == "true" ]]; then
        config_xml_editor "${SELECTED_DIR:-}" "$file" "" "${SELECTED_CONTAINER:-}"
    else
        fb_edit_file_nano "$file" "$title"
    fi
}

mod_config_browser() {
    local profile_dir="$1"
    if [[ ! -d "$profile_dir" ]]; then
        show_message "Profile directory not found: $profile_dir" "Error"
        return 1
    fi
    local ignore="^(storage_|DataCache|users)$"
    fb_browse_dir "$profile_dir" "Mod Config Editor" "ROOT" "mod_folder_browser" "folders" "$ignore"
}

mod_folder_browser() {
    local folder="$1"
    [[ ! -d "$folder" ]] && return 0
    fb_browse_dir "$folder" "Mod Config Editor" "ROOT > Mod Configs" "mod_config_on_select" "all"
}

# =============================================================================
# CE File Detection Functions (Phase 3-4)
# =============================================================================


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
    
    python3 <<PYTHON_GET_LINKED
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
    import sys
    sys.stderr.write(f"DEBUG: Python Error (get_linked): {e}\n")
    print('[]')
PYTHON_GET_LINKED
}

# Scans mods for CE files and returns structured data (Python based)
scan_dayz_ce_files_python() {
    local instance_dir="$1"
    local workshop_dir="$2"
    
    local mission_path
    mission_path=$(get_mission_path "$instance_dir") || return 1
    
    # Locate mods.txt (Root or Data)
    local mods_file="${instance_dir}/config/mods.txt"
    if [[ ! -f "$mods_file" && -f "${instance_dir}/data/config/mods.txt" ]]; then
        mods_file="${instance_dir}/data/config/mods.txt"
    fi
     
    local servermods_file="${instance_dir}/config/servermods.txt"
    if [[ ! -f "$servermods_file" && -f "${instance_dir}/data/config/servermods.txt" ]]; then
        servermods_file="${instance_dir}/data/config/servermods.txt"
    fi
    

    # Fallback to finding it
    if [[ ! -f "$mods_file" ]]; then
        local found
        found=$(find "$instance_dir" -name "mods.txt" 2>/dev/null | grep "/config/mods.txt" | head -n 1)
        if [[ -n "$found" ]]; then
            mods_file="$found"
            # Assuming servermods is sibling
            servermods_file="$(dirname "$found")/servermods.txt"
        fi
    fi

    # DEBUG: Print detected paths to stderr (log)
    >&2 echo "DEBUG: scan_dayz_ce_files_python"
    >&2 echo "DEBUG: instance_dir=$instance_dir"
    >&2 echo "DEBUG: mission_path=$mission_path"
    >&2 echo "DEBUG: mods_file=$mods_file"
    >&2 echo "DEBUG: servermods_file=$servermods_file"
    >&2 echo "DEBUG: workshop_dir=$workshop_dir"

    # Get already linked files for status checking
    local linked_json
    linked_json=$(get_linked_ce_files "$instance_dir")
    
    # Pass variables to Python env
    export DAYZ_WORKSHOP_DIR="$workshop_dir"
    export DAYZ_MODS_FILE="$mods_file"
    export DAYZ_SERVERMODS_FILE="$servermods_file"
    export DAYZ_LINKED_JSON="$linked_json"
    export DAYZ_SCRIPT_DIR="$SCRIPT_DIR"
    export DAYZ_MISSION_PATH="$mission_path"
    
    python3 <<'PYTHON_CE_SCAN'
import os
import json
import sys

# Load Env Vars
workshop_dir = os.environ.get('DAYZ_WORKSHOP_DIR')
mods_file = os.environ.get('DAYZ_MODS_FILE')
servermods_file = os.environ.get('DAYZ_SERVERMODS_FILE')
linked_json = os.environ.get('DAYZ_LINKED_JSON')
script_dir = os.environ.get('DAYZ_SCRIPT_DIR')
mission_path = os.environ.get('DAYZ_MISSION_PATH')

# Import xml_parser for fast detection
sys.path.append(os.path.join(script_dir, 'lib'))
try:
    import xml_parser
except ImportError:
    # Fallback if import fails (should not happen)
    xml_parser = None

# Parse linked files
try:
    linked = {f['name']: f for f in json.loads(linked_json)}
except:
    linked = {}

# Get all mod IDs from files
mod_ids = set()
mod_name_map = {} # Populated after mod_ids collected

for f in [mods_file, servermods_file]:
    if f and os.path.exists(f):
        with open(f, errors='ignore') as fp:
            for line in fp:
                mid = line.strip().split('|')[0].strip()
                if mid.isdigit():
                    mod_ids.add(mid)

def get_mod_name(workshop_dir, mod_id):
    meta_path = os.path.join(workshop_dir, mod_id, 'meta.cpp')
    if os.path.exists(meta_path):
        try:
            with open(meta_path, 'r', errors='ignore') as f:
                import re
                match = re.search(r'name\s*=\s*"([^"]+)"', f.read())
                if match: return match.group(1)
        except: pass
    return mod_id

mod_name_map = {mid: get_mod_name(workshop_dir, mid) for mid in mod_ids}

results = []
scanned_files = set() # To track which files we found in mods, to identify orphans later

# 1. SCAN MODS
for mod_id in sorted(mod_ids):
    mod_folder = os.path.join(workshop_dir, mod_id)
    if not os.path.isdir(mod_folder):
        continue
    
    # Find XML files in mod
    for root, dirs, files in os.walk(mod_folder):
        for fname in files:
            lfn = fname.lower()
            # 1. Skip core files and non-CE XMLs
            if lfn in ['cfgeconomycore.xml', 'mod.xml', 'meta.cpp', 'meta.bin', 'meta.cpp.xml']: continue
            if not lfn.endswith('.xml'): continue
            
            fpath = os.path.join(root, fname)
            
            # 2. Detect CE type with expert fallback
            ce_type = ""
            if xml_parser:
                try:
                    res = xml_parser.detect_ce_type(fpath)
                    if res: ce_type = res['ce_type']
                except: pass
            
            if not ce_type:
                if 'randompresets' in lfn: ce_type = 'randompresets'
                elif 'eventgroups' in lfn: ce_type = 'eventgroups'
                elif 'spawnable' in lfn: ce_type = 'spawnabletypes'
                elif 'eventspawns' in lfn or 'eventpos' in lfn: ce_type = 'eventspawns'
                elif 'events' in lfn: ce_type = 'events'
                elif 'types' in lfn: ce_type = 'types'
                else:
                    # Skip common non-loot files found in mods (e.g. info, setup, core folders)
                    rel_p = root.lower()
                    if 'setup' in rel_p or 'info' in rel_p or 'core' in rel_p: continue
                    ce_type = 'types' # Default fallback
            
            # 3. Check status - MOD-AWARE matching
            # Priority: 1) ModID_filename, 2) Exact filename match
            status = "new"
            linked_name = ""
            is_linked = False
            
            search_name = fname.lower().strip()
            # Cleaned version of workshop filename
            search_name_cfn = "".join(x for x in search_name if x.isalnum() or x in "._-")
            # Expected linked name pattern: ModID_filename
            expected_linked = f"{mod_id}_{search_name_cfn}".lower()
            
            for ln in linked:
                ln_orig = ln
                lnl = ln.lower().strip()
                # A: BEST MATCH - ModID prefix matches exactly
                if lnl == expected_linked or lnl == f"{mod_id}_{search_name}".lower():
                    is_linked = True; linked_name = ln_orig; break
                # B: Exact filename match (for mods that link directly without prefix)
                if lnl == search_name or lnl == search_name_cfn:
                    is_linked = True; linked_name = ln_orig; break
            
            # Only if no mod-specific match, check if there's a generic prefix match
            # This catches legacy files where a different prefix was used
            if not is_linked:
                for ln in linked:
                    ln_orig = ln
                    lnl = ln.lower().strip()
                    if "_" in lnl:
                        parts = lnl.split("_", 1)
                        prefix = parts[0]
                        suffix = parts[1]
                        # Only match if suffix equals our filename AND prefix looks like a mod ID or known name
                        if (suffix == search_name or suffix == search_name_cfn):
                            # Check if this linked file is already claimed by its own mod
                            # Skip if the prefix is a different mod ID
                            if prefix.isdigit() and prefix != mod_id:
                                continue  # This linked file belongs to a different mod
                            is_linked = True; linked_name = ln_orig; break
            
            if is_linked:
                status = "linked"
            
            # Check if file is modified (compare against original snapshot)
            is_modified = False
            if is_linked and linked_name:
                # Get linked file info from linked dict
                li = linked.get(linked_name, {})
                linked_path = li.get('path', '')
                original_path = li.get('original_path', '')
                if linked_path and original_path and os.path.exists(linked_path) and os.path.exists(original_path):
                    try:
                        import hashlib
                        def file_hash(fp):
                            with open(fp, 'rb') as f:
                                return hashlib.md5(f.read()).hexdigest()
                        if file_hash(linked_path) != file_hash(original_path):
                            is_modified = True
                    except: pass
            
            results.append({
                "mod_id": mod_id,
                "mod_name": mod_name_map.get(mod_id, mod_id),
                "file_path": fpath,
                "filename": fname,
                "ce_type": ce_type,
                "status": status,
                "linked_filename": linked_name,
                "modified": is_modified
            })
            
            # Track for orphan detection
            scanned_files.add(fname)
            if linked_name: scanned_files.add(linked_name)

# 2. SCAN ORPHANS (Local files in CustomCE not from mods)
# We need to skip:
# - Files we already scanned from workshop
# - Files that are linked (in cfgeconomycore.xml) - these are managed by us or the mod
# - Files with mod ID prefixes that match known mod IDs
ce_folders = ["types", "spawnabletypes", "events", "eventspawns", "randompresets", "eventgroups"]
for folder in ce_folders:
    dir_path = os.path.join(mission_path, "CustomCE", folder)
    if not os.path.isdir(dir_path): continue
    for root, dirs, files in os.walk(dir_path):
        for fname in files:
            lfn = fname.lower()
            if not lfn.endswith('.xml'): continue
            if ".originals" in root or ".backups" in root: continue
            if lfn in ['cfgeconomycore.xml', 'mod.xml', 'meta.cpp', 'meta.bin']: continue
            
            # If we already saw this file in mod scan, skip
            if fname in scanned_files: continue
            
            # If file is already in cfgeconomycore.xml (linked), skip it
            if fname in linked: continue
            
            # Check if this file looks like one we registered (ModID_filename pattern)
            # Skip if it starts with a known mod ID prefix
            is_registered = False
            for mid in mod_ids:
                if fname.startswith(f"{mid}_"):
                    is_registered = True
                    break
            if is_registered: continue
            
            # This is a truly local/orphan file not mapped to any active mod
            results.append({
                "mod_id": "LOCAL",
                "mod_name": "[ Manual / Local ]",
                "file_path": os.path.join(root, fname),
                "filename": fname,
                "ce_type": folder,
                "status": "unlinked",
                "linked_filename": ""
            })

print(json.dumps(results))
PYTHON_CE_SCAN
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
