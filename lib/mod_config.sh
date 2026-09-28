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
# Loot Manager debug log lives in the user's state dir, not in the repo
LOOT_MANAGER_LOG="${LOOT_MANAGER_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/dayz-docker-hub/loot_manager.log}"
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

    # Never link a file the server cannot parse: one broken CE file stops CE loading
    if ! python3 - "$source_xml" <<'PY_VALIDATE' 2>/dev/null
import re, sys, xml.etree.ElementTree as ET
with open(sys.argv[1], 'rb') as f:
    data = f.read()
try:
    ET.fromstring(data)
except ET.ParseError:
    # a bare fragment (<type> without <types>) is fine once wrapped
    body = re.sub(rb'^\s*<\?xml[^>]*\?>', b'', data)
    ET.fromstring(b'<r>' + body + b'</r>')
PY_VALIDATE
    then
        echo "Error: '$source_xml' is not well-formed XML, not linked" >&2
        [[ "$silent" == "0" ]] && show_message "'$(basename "$source_xml")' is not valid XML and was not linked." "Error"
        return 1
    fi
    
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
    python3 - "$core_xml" "$target_filename" "$ce_type" "$ce_folder" <<'EOF'
import xml.etree.ElementTree as ET
import sys

core_path, file_to_add, ce_type, ce_folder = sys.argv[1:5]

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
    
    # Already linked in this CustomCE block? Other blocks (e.g. a user-added
    # db block listing the vanilla types.xml) must not count as a duplicate.
    exists = any(f.get('name') == file_to_add for f in ce_node.findall('file'))

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
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        [[ "$silent" == "0" ]] && show_message "Could not register $target_filename in cfgeconomycore.xml" "Error"
        return $rc
    fi
    if [[ "$silent" == "0" ]]; then
        show_message "Registered $target_filename in cfgeconomycore.xml (${ce_type})" "Success"
    fi
    return 0
}

# Unregister a modular include (removes from any CE block)
unregister_modular_loot() {
    local instance_dir="$1"
    local target_filename="$2"
    
    local mission_path=$(get_mission_path "$instance_dir")
    [[ -z "$mission_path" ]] && return 1
    
    echo "[$(date +%T)] MGR: Unregistering/Unlinking: $target_filename" >> "$LOOT_MANAGER_LOG"
    
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
    # Without a mission the path would degrade to /CustomCE at the filesystem root
    mission_path=$(get_mission_path "$inst_dir" 2>/dev/null) || return 1
    echo "${mission_path}/CustomCE/.ce_ignored.json"
}

# Add a file to the ignore list
# Usage: add_ce_ignore "$inst_dir" "mod_id" "filename"
add_ce_ignore() {
    local inst_dir="$1"
    local mod_id="$2"
    local filename="$3"
    local ignore_file
    ignore_file=$(get_ce_ignore_file "$inst_dir") || { show_message "Mission folder not found. Check 'template' in serverDZ.cfg." "Error"; return 1; }

    # Values travel as arguments: file names come from mod folders and may contain quotes
    python3 - "$ignore_file" "$mod_id" "$filename" <<'PY_ADD_IGNORE'
import json, os, sys
ignore_file, mod_id, filename = sys.argv[1], sys.argv[2], sys.argv[3]
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
PY_ADD_IGNORE
}

# Remove a file from the ignore list
# Usage: remove_ce_ignore "$inst_dir" "mod_id" "filename"
remove_ce_ignore() {
    local inst_dir="$1"
    local mod_id="$2"
    local filename="$3"
    local ignore_file
    ignore_file=$(get_ce_ignore_file "$inst_dir") || return 1
    
    if [[ ! -f "$ignore_file" ]]; then
        return
    fi
    
    python3 - "$ignore_file" "$mod_id" "$filename" <<'PY_REMOVE_IGNORE'
import json, sys
ignore_file, mod_id, filename = sys.argv[1], sys.argv[2], sys.argv[3]
key = f'{mod_id}|{filename}'

try:
    with open(ignore_file, 'r') as f:
        data = json.load(f)
    
    if 'ignored' in data and key in data['ignored']:
        data['ignored'].remove(key)
        with open(ignore_file, 'w') as f:
            json.dump(data, f, indent=2)
        print('Removed')
except (OSError, ValueError) as e:
    print(f'WARN: {e}', file=sys.stderr)
PY_REMOVE_IGNORE
}

# =============================================================================
# Workshop Folder Browser - Navigate mod folders to view README and docs
# =============================================================================
workshop_folder_browser() {
    local base_dir="$1"        # Workshop path for the mod (e.g., /path/workshop/221100/123456)
    local mod_name="$2"        # Mod name for display
    local mod_id="$3"          # Mod ID for display
    local current_dir="${4:-$base_dir}"  # Current browsing directory
    
    local selection=0
    local offset=0
    
    while true; do
        # Get directory contents
        local -a items=()
        local -a item_types=()
        local -a item_sizes=()
        
        # Add parent directory if not at base
        if [[ "$current_dir" != "$base_dir" ]]; then
            items+=("..")
            item_types+=("dir")
            item_sizes+=("-")
        fi
        
        # List directories first, then files
        while IFS= read -r -d '' entry; do
            [[ -z "$entry" ]] && continue
            local name=$(basename "$entry")
            [[ "$name" == "." || "$name" == ".." ]] && continue
            
            if [[ -d "$entry" ]]; then
                items+=("$name/")
                item_types+=("dir")
                item_sizes+=("-")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
        
        while IFS= read -r -d '' entry; do
            [[ -z "$entry" ]] && continue
            local name=$(basename "$entry")
            items+=("$name")
            item_types+=("file")
            # Get human-readable file size
            local size=$(du -h "$entry" 2>/dev/null | cut -f1)
            item_sizes+=("${size:-?}")
        done < <(find "$current_dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
        
        local count=${#items[@]}
        [[ $count -eq 0 ]] && { show_message "Empty folder" "Info"; return; }
        
        # Calculate relative path for display
        local rel_path="${current_dir#$base_dir}"
        [[ -z "$rel_path" ]] && rel_path="/"
        
        # Draw TUI
        get_term_size
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        move_to 1 1
        printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Workshop Browser: $mod_name ($mod_id)" "$RESET"
        
        move_to 2 1
        printf "%s Path: %s%s" "$DIM" "$rel_path" "$RESET"
        
        move_to 3 1
        printf "%s%s%*s%s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
        printf "%s" "$RESET"
        
        local v_height=$((TERM_ROWS - 8))
        [[ $v_height -lt 5 ]] && v_height=5
        if [[ $selection -lt $offset ]]; then offset=$selection; fi
        if [[ $selection -ge $((offset + v_height)) ]]; then offset=$((selection - v_height + 1)); fi
        
        for ((i=0; i<v_height; i++)); do
            local idx=$((offset + i))
            [[ $idx -ge $count ]] && break
            
            local row=$((4 + i))
            local name="${items[$idx]}"
            local ftype="${item_types[$idx]}"
            local fsize="${item_sizes[$idx]}"
            
            # Icon based on type
            local icon="📄"
            local color="$WHITE"
            if [[ "$ftype" == "dir" ]]; then
                icon="📁"
                color="$CYN"
            elif [[ "$name" == *.md || "$name" == *.txt || "$name" == *README* ]]; then
                icon="📝"
                color="$GRN"
            elif [[ "$name" == *.xml ]]; then
                icon="📋"
                color="$YLW"
            fi
            
            move_to $row 1
            if [[ $idx -eq $selection ]]; then
                printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
                move_to $row 2
                printf " %s  %-50s %8s" "$icon" "${name:0:50}" "$fsize"
                printf "%s" "$RESET"
            else
                printf " %s  %s%-50s%s %8s" "$icon" "$color" "${name:0:50}" "$RESET" "$fsize"
            fi
        done
        
        # Footer
        move_to $((TERM_ROWS - 1)) 1
        printf "%s%s%-$((TERM_COLS-1))s%s" "$BG_DARKGRAY" "$WHITE" " [Enter] Open/View   [q] Back" "$RESET"
        
        # Handle input
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 seq || true
            case "$seq" in
                "[A") [[ $selection -gt 0 ]] && selection=$((selection - 1)) ;;
                "[B") [[ $selection -lt $((count - 1)) ]] && selection=$((selection + 1)) ;;
            esac
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            return
        elif [[ "$key" == "" ]]; then  # Enter key
            local selected="${items[$selection]}"
            local selected_type="${item_types[$selection]}"
            
            if [[ "$selected" == ".." ]]; then
                # Go up
                current_dir=$(dirname "$current_dir")
                selection=0
                offset=0
            elif [[ "$selected_type" == "dir" ]]; then
                # Enter directory
                current_dir="$current_dir/${selected%/}"
                selection=0
                offset=0
            else
                # View file
                local file_path="$current_dir/$selected"
                view_file_content "$file_path" "$selected"
            fi
        fi
    done
}

# View file content in a simple pager
view_file_content() {
    local file_path="$1"
    local file_name="$2"
    
    # Check if file is viewable
    local ext="${file_name##*.}"
    ext="${ext,,}"  # lowercase
    
    case "$ext" in
        md|txt|cfg|ini|json|xml|html)
            # Text file - show in pager
            ;;
        *)
            # Check if it's text by looking at content
            if ! file "$file_path" 2>/dev/null | grep -qi "text"; then
                show_message "Cannot view binary file: $file_name" "Warning"
                return
            fi
            ;;
    esac
    
    local offset=0
    local -a lines=()
    
    # Read file into array
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines+=("$line")
    done < "$file_path"
    
    local total_lines=${#lines[@]}
    
    while true; do
        get_term_size
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        
        # Header
        move_to 1 1
        printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Viewing: $file_name" "$RESET"
        
        move_to 2 1
        printf "%s Line %d-%d of %d%s" "$DIM" "$((offset + 1))" "$((offset + TERM_ROWS - 5))" "$total_lines" "$RESET"
        
        # Content area
        local v_height=$((TERM_ROWS - 5))
        for ((i=0; i<v_height; i++)); do
            local line_idx=$((offset + i))
            [[ $line_idx -ge $total_lines ]] && break
            
            move_to $((3 + i)) 1
            # Truncate long lines
            printf "%.${TERM_COLS}s" "${lines[$line_idx]}"
        done
        
        # Footer
        move_to $((TERM_ROWS - 1)) 1
        printf "%s%s%-$((TERM_COLS-1))s%s" "$BG_DARKGRAY" "$WHITE" " [↑/↓] Scroll   [PgUp/PgDn] Page   [q] Back" "$RESET"
        
        # Handle input
        IFS= read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 seq || true
            # Last valid offset; a file shorter than the window must never go negative
            local max_offset=$(( total_lines > v_height ? total_lines - v_height : 0 ))
            case "$seq" in
                "[A") [[ $offset -gt 0 ]] && offset=$((offset - 1)) ;;
                "[B") [[ $offset -lt $max_offset ]] && offset=$((offset + 1)) ;;
                "[5") offset=$((offset - v_height)); [[ $offset -lt 0 ]] && offset=0 ;;  # Page Up
                "[6") offset=$((offset + v_height)); [[ $offset -gt $max_offset ]] && offset=$max_offset ;;  # Page Down
            esac
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            return
        fi
    done
}

# Scans mods for CE files and returns structured data
# The new Modular Loot Manager (Professional Bulk View)
# Uses scan_ce_files to get data (one 0x1F separated row per file, see lib/ce_scanner.py)
# Parse the CE scan JSON into the shared arrays (src_paths, smod_ids, states, ...).
# Top-level on purpose: cleanup_mod_ce_files needs it too, not only the dashboard.
parse_scan_result() {
    local rows="$1"
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
    
    # Keep the loop variables local: with bash's dynamic scoping an unqualified
    # read would overwrite a caller's 'mid' (e.g. the mod being removed).
    local sp mid mn fn ct st ln md ig
    while IFS=$'\x1f' read -r sp mid mn fn ct st ln md ig; do
        [[ -z "$sp" ]] && continue
        src_paths+=("$sp")
        smod_ids+=("$mid")
        smod_names+=("$mn")
        sfile_names+=("$fn")
        sce_types+=("$ct")
        states+=("$st")
        slinked_names+=("$ln")
        smodified+=("$md")
        signored+=("${ig:-0}")
    done <<< "$rows"
}

# Name under which the selected file is (or would be) linked in CustomCE
# Usage: tn=$(_loot_linked_name "$midx")
_loot_linked_name() {
    local midx="$1"
    if [[ -n "${slinked_names[$midx]}" ]]; then
        echo "${slinked_names[$midx]}"
    elif [[ "${smod_ids[$midx]}" == "LOCAL" ]]; then
        echo "${sfile_names[$midx]}"
    else
        echo "${smod_ids[$midx]}_${sfile_names[$midx]}"
    fi
}

# Path of the linked copy of a CE file, with the fallbacks older versions
# produced (cleaned name, types/ folder). Prints the first candidate that
# exists, otherwise the primary path.
# Usage: p=$(_loot_linked_copy_path "$inst_dir" "$ce_type" "$linked_name")
_loot_linked_copy_path() {
    local inst_dir="$1" ct="$2" tn="$3"
    local mission cleaned p
    mission=$(get_mission_path "$inst_dir")
    cleaned=$(echo "$tn" | tr -cd '[:alnum:]_.-')
    for p in "${mission}/CustomCE/${ct}/${tn}" "${mission}/CustomCE/${ct}/${cleaned}" "${mission}/CustomCE/types/${tn}"; do
        if [[ -f "$p" ]]; then echo "$p"; return 0; fi
    done
    echo "${mission}/CustomCE/${ct}/${tn}"
}

# One table row of the loot dashboard (reads the caller's s* arrays)
# Usage: _loot_draw_row ROW IDX IS_SELECTED(0/1)
_loot_draw_row() {
    local row="$1" idx="$2" is_selected="$3"
    local ce_type="${sce_types[$idx]:-types}"
    local type_str type_color
    case "$ce_type" in
        types)          type_str="[TYPES]     "; type_color="$CYN" ;;
        spawnabletypes) type_str="[SPAWNABLE] "; type_color="$MAG" ;;
        events)         type_str="[EVENTS]    "; type_color="$YLW" ;;
        eventspawns)    type_str="[EVENTPOS]  "; type_color="$BLU" ;;
        randompresets)  type_str="[PRESETS]   "; type_color="$GRN" ;;
        eventgroups)    type_str="[GROUPS]    "; type_color="$RED" ;;
        *)              type_str="[OTHER]     "; type_color="$WHITE" ;;
    esac

    local status_str status_color row_dim=""
    if [[ ${states[$idx]} -eq 1 ]]; then
        status_str="[  LINKED  ]"; status_color="$GRN"
        is_merge_only_type "$ce_type" && { status_str="[  MERGED  ]"; status_color="$CYN"; }
    elif [[ ${signored[$idx]:-0} -eq 1 ]]; then
        status_str="[ IGNORED  ]"; status_color="$DIM"; row_dim="$DIM"
    else
        status_str="[ UNLINKED ]"; status_color="$WHITE"
        is_merge_only_type "$ce_type" && status_str="[ UNMERGED ]"
    fi

    local mod_str="   " mod_color="$WHITE"
    [[ ${smodified[$idx]:-0} -eq 1 ]] && { mod_str="[*]"; mod_color="$YLW"; }

    move_to "$row" 1
    if [[ $is_selected -eq 1 ]]; then
        printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
        move_to "$row" 3
        printf "%-12s %3s %-10s %-12s %-24s %-28s" "$status_str" "$mod_str" "$type_str" "${smod_ids[$idx]:0:12}" "${smod_names[$idx]:0:24}" "${sfile_names[$idx]:0:28}"
        printf "%s" "$RESET"
    else
        move_to "$row" 3
        printf "%s%s%-12s%s %s%3s%s %s%-10s%s %-12s %-24s %-28s%s" "$row_dim" "$status_color" "$status_str" "$RESET$row_dim" "$mod_color" "$mod_str" "$RESET$row_dim" "$type_color" "$type_str" "$RESET$row_dim" "${smod_ids[$idx]:0:12}" "${smod_names[$idx]:0:24}" "${sfile_names[$idx]:0:28}" "$RESET"
    fi
}

# Header, table and footer of the loot dashboard. Reads the caller's s*
# arrays, selection and count, and keeps offset so the selection is visible.
_loot_draw_screen() {
    get_term_size
    printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
    move_to 1 1
    printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Modular Loot Manager - $SELECTED_NAME" "$RESET"

    local table_start=3
    move_to $table_start 1
    printf "%s%s%*s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"
    move_to $((table_start + 1)) 1
    printf "  %-12s %-3s %-10s %-12s %-24s %-28s" "STATUS" "MOD" "TYPE" "WORKSHOP ID" "SOURCE / GROUP" "FILE NAME"
    move_to $((table_start + 2)) 1
    printf "%s%s%*s" "$DIM" "$RED" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"

    local v_height=$((TERM_ROWS - 10))
    [[ $v_height -lt 5 ]] && v_height=5
    [[ $selection -lt $offset ]] && offset=$selection
    [[ $selection -ge $((offset + v_height)) ]] && offset=$((selection - v_height + 1))

    local i idx is_selected
    for ((i=0; i<v_height; i++)); do
        idx=$((offset + i))
        [[ $idx -ge $count ]] && break
        is_selected=0; [[ $idx -eq $selection ]] && is_selected=1
        _loot_draw_row $((table_start + 3 + i)) "$idx" "$is_selected"
    done

    move_to $((TERM_ROWS - 1)) 1
    local footer=" [Enter] Edit   [L] Link   [B] Browse   [I] Ignore   [r] Rollback   [d] Delete   [q] Back"
    printf "%s%s%-$((TERM_COLS-1))s%s" "$BG_DARKGRAY" "$WHITE" "$footer" "$RESET"
}

# [r] Rollback menu for the linked copy of the selected file
_loot_key_rollback() {
    local inst_dir="$1" midx="$2"
    # Linked files are named <mod_id>_<file> (see register_modular_loot);
    # prefer the name the scan reported.
    local linked_fn="${slinked_names[$midx]:-}"
    [[ -z "$linked_fn" ]] && linked_fn=$(echo "${smod_ids[$midx]}_${sfile_names[$midx]}" | tr -cd '[:alnum:]_.-')
    show_rollback_menu "$inst_dir" "$linked_fn" "$(get_mission_path "$inst_dir")/CustomCE/${sce_types[$midx]}/${linked_fn}"
}

# [d] Delete the linked copy of the selected file (and its registration)
_loot_key_delete() {
    local inst_dir="$1" midx="$2"
    local p
    p=$(_loot_linked_copy_path "$inst_dir" "${sce_types[$midx]:-types}" "$(_loot_linked_name "$midx")")
    if [[ ! -f "$p" ]]; then
        show_message "File does not exist: $(basename "$p")" "Warning"
        return 0
    fi
    if confirm "Delete physical file '$(basename "$p")'?" "n"; then
        unregister_modular_loot "$inst_dir" "$(basename "$p")"
        rm -f "$p"
        show_message "Deleted $(basename "$p")" "Success"
    fi
}

# [L] on an active file: unlink it, or unmerge it for merge-only types
_loot_deactivate() {
    local inst_dir="$1" midx="$2"
    local ct="${sce_types[$midx]:-types}"
    if is_merge_only_type "$ct"; then
        local target_xml
        if ! target_xml=$(ce_merge_target "$inst_dir" "$ct"); then
            show_message "Mission folder not found. Check 'template' in serverDZ.cfg." "Error"
            return 0
        fi
        unmerge_ce_file_python "$inst_dir" "$target_xml" "${smod_ids[$midx]}"
        return 0
    fi
    if confirm "Unlink '${sfile_names[$midx]}' from ${smod_names[$midx]}?" "y"; then
        unregister_modular_loot "$inst_dir" "$(_loot_linked_name "$midx")"
    fi
}

# [L] on an inactive file: link or merge it (an ignored file is un-ignored)
_loot_activate() {
    local inst_dir="$1" midx="$2"
    local ct="${sce_types[$midx]:-types}"
    local fn="${sfile_names[$midx]}"
    if [[ ${signored[$midx]:-0} -eq 1 ]]; then
        remove_ce_ignore "$inst_dir" "${smod_ids[$midx]}" "$fn"
    fi
    if is_merge_only_type "$ct"; then
        confirm "Merge entries from '$fn' into main $ct?" "y" || return 0
    else
        confirm "Link '$fn' from ${smod_names[$midx]}?" "y" || return 0
    fi
    ce_activate_file "$inst_dir" "${src_paths[$midx]}" "${smod_ids[$midx]}" "${smod_names[$midx]}" "$ct" || true
}

_loot_key_link() {
    local inst_dir="$1" midx="$2"
    if [[ ${states[$midx]} -eq 1 ]]; then
        _loot_deactivate "$inst_dir" "$midx"
    else
        _loot_activate "$inst_dir" "$midx"
    fi
}

# [b] Browse the workshop folder of the selected file's mod
_loot_key_browse() {
    local workshop_path="$1" midx="$2"
    local mid="${smod_ids[$midx]}"
    if [[ "$mid" == "LOCAL" ]]; then
        show_message "Cannot browse local/orphan files - no workshop folder" "Info"
    elif [[ -d "${workshop_path}/${mid}" ]]; then
        workshop_folder_browser "${workshop_path}/${mid}" "${smod_names[$midx]}" "$mid"
    else
        show_message "Workshop folder not found: @${mid}" "Error"
    fi
}

# [i] Toggle the ignore flag of an inactive file
_loot_key_ignore() {
    local inst_dir="$1" midx="$2"
    local mid="${smod_ids[$midx]}" fn="${sfile_names[$midx]}"
    if [[ ${states[$midx]} -eq 1 ]]; then
        show_message "Cannot ignore linked files. Unlink first." "Warning"
    elif [[ ${signored[$midx]:-0} -eq 1 ]]; then
        remove_ce_ignore "$inst_dir" "$mid" "$fn"
    else
        add_ce_ignore "$inst_dir" "$mid" "$fn"
    fi
}

# [Enter] Edit the active copy of a linked file, otherwise the workshop source
_loot_key_edit() {
    local inst_dir="$1" midx="$2"
    local fn="${sfile_names[$midx]}"
    local target="${src_paths[$midx]}"
    if [[ ${states[$midx]} -eq 1 ]]; then
        target=$(_loot_linked_copy_path "$inst_dir" "${sce_types[$midx]:-types}" "$(_loot_linked_name "$midx")")
        [[ -f "$target" ]] || target="${src_paths[$midx]}"   # copy missing: edit the source
    fi
    if [[ -f "$target" ]]; then
        xml_edit_file "$target" "Edit ${fn}"
    else
        show_message "File not found for editing: $(basename "$target") (Src: $fn)" "Error"
    fi
}

# Modular Loot Manager: table of the CE files the enabled mods ship with
# their link/merge state, plus the actions on the selected file.
# Usage: modular_loot_dashboard "$instance_dir"
modular_loot_dashboard() {
    local inst_dir="$1"
    local selection=0
    local offset=0
    mkdir -p "$(dirname "$LOOT_MANAGER_LOG")"
    echo "=== Loot Manager Session: $(date) ===" > "$LOOT_MANAGER_LOG"

    local workshop_path="${inst_dir}/data/serverfiles/steamapps/workshop/content/221100"
    [[ -d "$workshop_path" ]] || workshop_path="${inst_dir}/serverfiles/steamapps/workshop/content/221100"

    # The scan walks every enabled mod folder, so it runs only when an action
    # may have changed something, not for every cursor movement.
    local needs_rescan=1
    local ce_result key seq midx
    local -a src_paths smod_ids smod_names sfile_names sce_types states slinked_names smodified signored
    while true; do
        if [[ $needs_rescan -eq 1 ]]; then
            echo "[DEBUG] scan: workshop=$workshop_path" >> "$LOOT_MANAGER_LOG"
            ce_result=$(scan_ce_files "$inst_dir" "$workshop_path" 2>>"$LOOT_MANAGER_LOG")
            parse_scan_result "$ce_result"
            echo "[DEBUG] scan done: ${#src_paths[@]} files" >> "$LOOT_MANAGER_LOG"
            needs_rescan=0
        fi

        local count=${#src_paths[@]}
        if [[ $count -eq 0 ]]; then
            show_message "No mod CE definitions detected." "Info"
            mod_config_browser "$inst_dir/data/config"   # fallback: manual browse
            return
        fi
        [[ $selection -ge $count ]] && selection=$((count - 1))

        _loot_draw_screen

        IFS= read -rsn1 key || return 0   # EOF (stdin closed): leave instead of looping
        needs_rescan=1  # every action below may change files; navigation resets it
        midx=$selection
        case "$key" in
            $'\x1b')
                needs_rescan=0
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    "[A") [[ $selection -gt 0 ]] && selection=$((selection - 1)) ;;
                    "[B") [[ $selection -lt $((count - 1)) ]] && selection=$((selection + 1)) ;;
                esac
                ;;
            q|Q) return ;;
            r|R) _loot_key_rollback "$inst_dir" "$midx" ;;
            d|D) _loot_key_delete "$inst_dir" "$midx" ;;
            l|L) _loot_key_link "$inst_dir" "$midx" ;;
            b|B) _loot_key_browse "$workshop_path" "$midx" ;;
            i|I) _loot_key_ignore "$inst_dir" "$midx" ;;
            "")  _loot_key_edit "$inst_dir" "$midx" ;;
            *)   needs_rescan=0 ;;
        esac
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

# find_mod_list_files - mods.txt and servermods.txt of an instance
# Looks in config/ first, then data/config/, then anywhere below the instance.
# Usage: while read -r f; do ...; done < <(find_mod_list_files "$instance_dir")
find_mod_list_files() {
    local instance_dir="$1"
    local base
    for base in "${instance_dir}/config" "${instance_dir}/data/config"; do
        if [[ -f "${base}/mods.txt" || -f "${base}/servermods.txt" ]]; then
            printf '%s\n' "${base}/mods.txt" "${base}/servermods.txt"
            return 0
        fi
    done
    local found
    found=$(find "$instance_dir" -path '*/config/mods.txt' 2>/dev/null | head -n 1) || true
    [[ -n "$found" ]] && printf '%s\n' "$found" "$(dirname "$found")/servermods.txt"
    return 0
}

# scan_ce_files - CE files of the enabled mods and their link/merge state
# Runs lib/ce_scanner.py once and prints one row per file (fields separated
# by 0x1F, see lib/rowfmt.py), which parse_scan_result turns into the s* arrays.
# Usage: result=$(scan_ce_files "$instance_dir" "$workshop_dir" [scanner options])
scan_ce_files() {
    local instance_dir="$1"
    local workshop_dir="$2"
    shift 2
    local mission_path
    mission_path=$(get_mission_path "$instance_dir") || return 1

    local -a args=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && args+=(--mods-file "$f")
    done < <(find_mod_list_files "$instance_dir")
    local ignore_file
    ignore_file=$(get_ce_ignore_file "$instance_dir") && args+=(--ignore-file "$ignore_file")

    python3 "${MOD_CONFIG_LIB_DIR}/ce_scanner.py" scan --format rows \
        --workshop-dir "$workshop_dir" --mission-path "$mission_path" \
        --instance-dir "$instance_dir" ${args[@]+"${args[@]}"} "$@"
}

# scan_new_ce_files - CE files of the enabled mods that are neither linked,
# merged nor ignored. Fills the caller's arrays ce_mod_ids, ce_mod_names,
# ce_file_paths, ce_filenames and ce_types.
# Usage: local -a ce_mod_ids ce_mod_names ce_file_paths ce_filenames ce_types
#        scan_new_ce_files "$inst_dir" "$workshop_path"
scan_new_ce_files() {
    local inst_dir="$1" workshop_path="$2"
    ce_mod_ids=(); ce_mod_names=(); ce_file_paths=(); ce_filenames=(); ce_types=()
    local sp mid mn fn ct rest
    while IFS=$'\x1f' read -r sp mid mn fn ct rest; do
        [[ -z "$sp" ]] && continue
        ce_mod_ids+=("$mid")
        ce_mod_names+=("$mn")
        ce_file_paths+=("$sp")
        ce_filenames+=("$fn")
        ce_types+=("$ct")
    done < <(scan_ce_files "$inst_dir" "$workshop_path" --only-new 2>/dev/null)
}

# ce_link_files_dialog - checklist to activate the files scan_new_ce_files found
# Usage: ce_link_files_dialog "$inst_dir" "Link CE Files - <instance>"
ce_link_files_dialog() {
    local inst_dir="$1" title="$2"
    local ce_count=${#ce_filenames[@]}
    [[ $ce_count -eq 0 ]] && return 0
    local -a ce_selected=()
    local i
    for ((i=0; i<ce_count; i++)); do ce_selected+=(1); done   # all pre-selected
    local selection=0
    while true; do
        draw_header "$title"
        local -a items=()
        for ((i=0; i<ce_count; i++)); do
            local check=" "
            [[ ${ce_selected[$i]} -eq 1 ]] && check="x"
            items+=("[$check] ${ce_mod_names[$i]} $(ce_type_label "${ce_types[$i]}") - ${ce_filenames[$i]}")
        done
        items+=("--------------------")
        items+=("✅|LINK SELECTED FILES")
        items+=("❌|Cancel / Skip All")
        run_menu items "Toggle files with Enter, then Execute" $selection || return 0
        selection=$MENU_RESULT
        if [[ $selection -lt $ce_count ]]; then
            ce_selected[$selection]=$((1 - ce_selected[$selection]))
        elif [[ $selection -eq $((ce_count + 1)) ]]; then
            _ce_activate_selected "$inst_dir"
            return 0
        elif [[ $selection -eq $((ce_count + 2)) ]]; then
            return 0
        fi
    done
}

# Activate every checked file of ce_link_files_dialog
_ce_activate_selected() {
    local inst_dir="$1"
    local i link_count=0
    for ((i=0; i<${#ce_filenames[@]}; i++)); do
        [[ ${ce_selected[$i]} -eq 1 ]] || continue
        ce_activate_file "$inst_dir" "${ce_file_paths[$i]}" "${ce_mod_ids[$i]}" "${ce_mod_names[$i]}" "${ce_types[$i]}" || continue
        link_count=$((link_count + 1))
    done
    [[ $link_count -gt 0 ]] && show_message "Linked $link_count CE file(s)!" "Success"
    return 0
}

# Merge-only CE types are merged into one mission file instead of being linked
is_merge_only_type() {
    [[ "$1" == "randompresets" || "$1" == "eventgroups" ]]
}

# Short label of a CE type for menus
ce_type_label() {
    case "$1" in
        types)          echo "[TYPES]" ;;
        spawnabletypes) echo "[SPAWNABLE]" ;;
        events)         echo "[EVENTS]" ;;
        eventspawns)    echo "[EVENTPOS]" ;;
        randompresets)  echo "[PRESETS]" ;;
        eventgroups)    echo "[GROUPS]" ;;
        *)              echo "[OTHER]" ;;
    esac
}

# ce_activate_file - make one CE file active for the mission: merge-only
# types are merged into the mission file, everything else is linked via
# cfgeconomycore.xml.
# Usage: ce_activate_file "$inst_dir" "$src" "$mod_id" "$mod_name" "$ce_type"
ce_activate_file() {
    local inst_dir="$1" src="$2" mod_id="$3" mod_name="$4" ct="$5"
    if is_merge_only_type "$ct"; then
        local target_xml
        if ! target_xml=$(ce_merge_target "$inst_dir" "$ct"); then
            show_message "Mission folder not found. Check 'template' in serverDZ.cfg." "Error"
            return 1
        fi
        merge_ce_file_python "$inst_dir" "$target_xml" "$src" "$mod_id" "$mod_name"
    else
        register_modular_loot "$inst_dir" "$src" "$mod_id" 1 "$ct"
    fi
}

# -----------------------------------------------------------------------------
# Auto-Cleanup Helper
# -----------------------------------------------------------------------------

# Unlink/Unmerge all CE files for a specific mod
# Usage: cleanup_mod_ce_files "$instance_dir" "$mod_id"
cleanup_mod_ce_files() {
    local inst_dir=$1
    local target_mod_id=$2
    local workshop_path="${3:-}"
    
    if [[ -z "$workshop_path" ]]; then
        workshop_path="${inst_dir}/data/serverfiles/steamapps/workshop/content/221100"
        [[ ! -d "$workshop_path" ]] && workshop_path="${inst_dir}/serverfiles/steamapps/workshop/content/221100"
    fi
    
    # 1. Scan for current status
    local ce_result
    ce_result=$(scan_ce_files "$inst_dir" "$workshop_path" 2>/dev/null)
    
    # 2. Parse into global arrays (smod_ids, states, etc)
    parse_scan_result "$ce_result"
    
    local count=0
    
    # 3. Iterate and process matches
    for i in "${!smod_ids[@]}"; do
        local mid="${smod_ids[$i]}"
        local st="${states[$i]}"
        
        # Only process files for this mod that are LINKED/MERGED (st=1)
        if [[ "$mid" == "$target_mod_id" && "$st" -eq 1 ]]; then
            local fn="${sfile_names[$i]}"
            local ct="${sce_types[$i]:-types}"
            local ln="${slinked_names[$i]}"
            
            # Helper label
            local action_label="Unlink"
            if [[ "$ct" == "randompresets" || "$ct" == "eventgroups" ]]; then action_label="Unmerge"; fi
            
            # Prompt user
            if confirm "${action_label} '${fn}'?" "y"; then
                # Check for merge-only types
                if [[ "$ct" == "randompresets" || "$ct" == "eventgroups" ]]; then
                    local target_xml
                    if ! target_xml=$(ce_merge_target "$inst_dir" "$ct"); then
                        show_message "Mission folder not found. Check 'template' in serverDZ.cfg." "Error"
                        continue
                    fi
                    
                    unmerge_ce_file_python "$inst_dir" "$target_xml" "$mid"
                    count=$((count + 1))
                else
                    # Standard Unlink
                    local target_to_unlink="${mid}_${fn}"
                    if [[ -n "$ln" ]]; then target_to_unlink="$ln"; fi
                    
                    unregister_modular_loot "$inst_dir" "$target_to_unlink"
                    count=$((count + 1))
                fi
            else
                echo "Skipped ${fn}"
            fi
        fi
    done
    
    if [[ $count -gt 0 ]]; then
        echo "Auto-cleaned $count CE files for mod $target_mod_id"
    fi
}


# =============================================================================
# Merge Tracking Wrappers (Phase 2)
# =============================================================================

# Resolve the merge target for merge-only CE types inside the active mission.
# The vanilla files live in the mission root (cfgrandompresets.xml,
# cfgeventgroups.xml), not in db/: a merge into db/ is never read by the server.
# Usage: target_xml=$(ce_merge_target "$inst_dir" "$ce_type") || <no mission found>
ce_merge_target() {
    local inst_dir="$1" ce_type="$2"
    local mission_path
    mission_path=$(get_mission_path "$inst_dir") || return 1
    local target_file="cfgrandompresets.xml"
    [[ "$ce_type" == "eventgroups" ]] && target_file="cfgeventgroups.xml"
    echo "${mission_path}/${target_file}"
}

# merge_ce_file_python "$inst_dir" "$target_xml" "$source_xml" "$mod_id" "$mod_name"
merge_ce_file_python() {
    local inst_dir="$1"
    local target_xml="$2"
    local source_xml="$3"
    local mod_id="$4"
    local mod_name="$5"
    
    # 1. Check collisions
    local collisions
    collisions=$(python3 "${SCRIPT_DIR}/lib/merge_tracking.py" check_collisions "$source_xml" "$target_xml" 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 2 ]]; then
        show_message "Merge conflict detected!\nSome entries in this mod already exist in the target file." "Warning"
        if ! confirm "Proceed anyway? (Duplicates might cause errors)" "n"; then
            return 1
        fi
    elif [[ $exit_code -ne 0 ]]; then
        show_message "Error checking collisions:\n$collisions" "Error"
        return 1
    fi
    
    # 2. Perform Inject
    local output
    output=$(python3 "${SCRIPT_DIR}/lib/merge_tracking.py" inject "$target_xml" "$source_xml" "$mod_id" "$mod_name" "$inst_dir" 2>&1)
    if [[ $? -eq 0 ]]; then
        show_message "Successfully merged entries!\n$output" "Success"
        return 0
    else
        show_message "Merge failed:\n$output" "Error"
        return 1
    fi
}

# unmerge_ce_file_python "$inst_dir" "$target_xml" "$mod_id"
unmerge_ce_file_python() {
    local inst_dir="$1"
    local target_xml="$2"
    local mod_id="$3"
    
    if confirm "Remove all merged entries for this mod?" "y"; then
        local output
        output=$(python3 "${SCRIPT_DIR}/lib/merge_tracking.py" remove "$target_xml" "$mod_id" "$inst_dir" 2>&1)
        if [[ $? -eq 0 ]]; then
            show_message "Successfully unmerged entries!\n$output" "Success"
            return 0
        else
            show_message "Unmerge failed:\n$output" "Error"
            return 1
        fi
    fi
    return 1
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
    
    python3 - "$backup_dir" "$base" <<'EOF'
import os
import json
import re
import sys
from datetime import datetime

backup_dir, base = sys.argv[1], sys.argv[2]

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
