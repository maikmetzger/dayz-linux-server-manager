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

# =============================================================================
# File Type Handler Registry
# =============================================================================
# Maps file extensions to handler types.
# To add a new format: Add entry here + implement handler function below.
declare -A FILE_TYPE_HANDLERS=(
    ["json"]="json"
    ["xml"]="xml"
    ["cfg"]="cfg"
    ["txt"]="raw"
    ["md"]="raw"
    ["log"]="raw"
)

# Icons for file types
declare -A FILE_TYPE_ICONS=(
    ["json"]="📋"
    ["xml"]="📄"
    ["cfg"]="⚙️"
    ["raw"]="📝"
    ["folder"]="📁"
)

# =============================================================================
# File Type Detection
# =============================================================================

# Get handler type for a file based on extension
# Usage: handler=$(get_file_handler "config.json")
get_file_handler() {
    local file="$1"
    local ext="${file##*.}"
    ext="${ext,,}"  # lowercase
    echo "${FILE_TYPE_HANDLERS[$ext]:-raw}"
}

# Get icon for file or folder
# Usage: icon=$(get_file_icon "config.json")
get_file_icon() {
    local path="$1"
    if [[ -d "$path" ]]; then
        echo "${FILE_TYPE_ICONS[folder]}"
    else
        local handler=$(get_file_handler "$path")
        echo "${FILE_TYPE_ICONS[$handler]:-📄}"
    fi
}

# =============================================================================
# File Editors
# =============================================================================

# JSON Editor - Key-value editing for JSON files
json_edit_file() {
    local file="$1"
    local title="${2:-JSON Editor}"
    
    if [[ ! -f "$file" ]]; then
        show_message "File not found: $file" "Error"
        return 1
    fi
    
    # Use Python to parse and present JSON as editable key-value pairs
    local temp_file=$(mktemp)
    
    # Parse JSON to flat key-value format
    python3 -c "
import json
import sys

def flatten(obj, prefix=''):
    items = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            new_key = f'{prefix}.{k}' if prefix else k
            items.extend(flatten(v, new_key))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            new_key = f'{prefix}[{i}]'
            items.extend(flatten(v, new_key))
    else:
        items.append((prefix, obj))
    return items

try:
    with open('$file', 'r') as f:
        content = f.read()
        # Strip JS-style comments for parsing
        import re
        content = re.sub(r'//.*$', '', content, flags=re.MULTILINE)
        content = re.sub(r'/\*.*?\*/', '', content, flags=re.DOTALL)
        data = json.loads(content)
    
    for key, val in flatten(data):
        print(f'{key}|{val}')
except Exception as e:
    print(f'ERROR|{e}', file=sys.stderr)
    sys.exit(1)
" > "$temp_file" 2>/dev/null
    
    if [[ $? -ne 0 ]]; then
        show_message "Failed to parse JSON file" "Error"
        rm -f "$temp_file"
        return 1
    fi
    
    # Read into arrays for TUI display
    local -a keys=() values=()
    while IFS='|' read -r key val; do
        keys+=("$key")
        values+=("$val")
    done < "$temp_file"
    rm -f "$temp_file"
    
    if [[ ${#keys[@]} -eq 0 ]]; then
        show_message "No editable values found in JSON" "Info"
        return 0
    fi
    
    # TUI for editing (using existing table editor pattern)
    _json_table_editor "$file" keys values "$title"
}

# JSON Table Editor TUI
_json_table_editor() {
    local file="$1"
    local -n _keys=$2
    local -n _values=$3
    local title="$4"
    
    local selected=0
    local count=${#_keys[@]}
    local dirty=0
    local start_row=0
    
    while true; do
        get_term_size
        printf "%s" "$CLEAR_SCREEN"
        draw_header "$title"
        
        # Calculate visible rows
        local max_rows=$((TERM_ROWS - 6))
        [[ $selected -lt $start_row ]] && start_row=$selected
        [[ $selected -ge $((start_row + max_rows)) ]] && start_row=$((selected - max_rows + 1))
        
        # Draw table
        local row=3
        for ((i=start_row; i<count && i<start_row+max_rows; i++)); do
            move_to $row 2
            if [[ $i -eq $selected ]]; then
                printf "%s%s▶ %-35s %s%s" "$BG_RED" "$WHITE$BOLD" "${_keys[$i]:0:35}" "${_values[$i]:0:40}" "$RESET"
            else
                printf "  %-35s %s" "${_keys[$i]:0:35}" "${_values[$i]:0:40}"
            fi
            ((row++))
        done
        
        # Footer
        move_to $TERM_ROWS 1
        local status=""
        [[ $dirty -eq 1 ]] && status="[MODIFIED] "
        printf "%s%s %s↑↓ Navigate  Enter Edit  [S] Save  [Q] Back%*s%s" "$BG_DARKGRAY" "$WHITE" "$status" "$((TERM_COLS - 50))" "" "$RESET"
        
        # Input
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') [[ $selected -gt 0 ]] && ((selected--)) ;;
                    '[B') [[ $selected -lt $((count-1)) ]] && ((selected++)) ;;
                esac
                ;;
            '')  # Enter - edit value
                local current_val="${_values[$selected]}"
                local new_val
                new_val=$(read_input "New value for ${_keys[$selected]}:" "$current_val" "Edit Value")
                if [[ -n "$new_val" && "$new_val" != "$current_val" ]]; then
                    _values[$selected]="$new_val"
                    dirty=1
                fi
                ;;
            's'|'S')
                if [[ $dirty -eq 1 ]]; then
                    _json_save_changes "$file" _keys _values
                    dirty=0
                    show_message "Changes saved" "Saved"
                fi
                ;;
            'q'|'Q')
                if [[ $dirty -eq 1 ]]; then
                    if confirm "Discard unsaved changes?" "n"; then
                        return 0
                    fi
                else
                    return 0
                fi
                ;;
        esac
    done
}

# Save JSON changes back to file
_json_save_changes() {
    local file="$1"
    local -n _keys=$2
    local -n _values=$3
    
    # Build JSON from flat key-value pairs
    python3 -c "
import json
import re
import sys

keys = '''$(printf '%s\n' "${_keys[@]}")'''.strip().split('\n')
values = '''$(printf '%s\n' "${_values[@]}")'''.strip().split('\n')

def unflatten(items):
    result = {}
    for key, val in items:
        parts = re.split(r'\.|\[(\d+)\]', key)
        parts = [p for p in parts if p]
        
        current = result
        for i, part in enumerate(parts[:-1]):
            next_part = parts[i + 1]
            if next_part.isdigit():
                current = current.setdefault(part, [])
            else:
                current = current.setdefault(part, {})
            if isinstance(current, list):
                idx = int(part)
                while len(current) <= idx:
                    current.append({} if not parts[i+2:] or not parts[i+2].isdigit() else [])
                current = current[idx]
        
        # Set final value with type conversion
        final_key = parts[-1]
        if val.lower() == 'true':
            val = True
        elif val.lower() == 'false':
            val = False
        elif val.isdigit():
            val = int(val)
        else:
            try:
                val = float(val)
            except:
                pass
        
        if isinstance(current, list):
            idx = int(final_key)
            while len(current) <= idx:
                current.append(None)
            current[idx] = val
        else:
            current[final_key] = val
    
    return result

items = list(zip(keys, values))
data = unflatten(items)

with open('$file', 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null
}

# XML Edit - Delegate to existing xml_parser.py
xml_edit_file() {
    local file="$1"
    local title="${2:-XML Editor}"
    
    # Use existing types.xml editor for now
    # TODO: Generic XML key-value editor
    show_message "XML editing coming soon. Use types.xml editor for loot files." "Info"
}

# CFG Edit - Delegate to existing config_parser.py
cfg_edit_file() {
    local file="$1"
    local title="${2:-CFG Editor}"
    
    # Reuse config_table_editor from config.sh
    if [[ -f "$file" ]]; then
        # Call existing CFG parser
        config_table_editor "$file" "" "" "" "$title"
    else
        show_message "File not found: $file" "Error"
    fi
}

# Raw Text Editor - Simple view/edit
raw_edit_file() {
    local file="$1"
    local title="${2:-Text Editor}"
    
    if [[ ! -f "$file" ]]; then
        show_message "File not found: $file" "Error"
        return 1
    fi
    
    # Display file content with basic editing
    printf "%s%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
    printf "%s%s ═══ %s ═══ %s\n" "$RED$BOLD" "" "$title" "$RESET"
    printf "%s%s Press 'e' to edit with nano, 'q' to go back %s\n\n" "$DIM" "" "$RESET"
    
    # Show file preview (first 30 lines)
    head -30 "$file" 2>/dev/null
    
    printf "\n%s[Press 'e' to edit, 'q' to quit]%s" "$DIM" "$RESET"
    
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            'e'|'E')
                nano "$file"
                break
                ;;
            'q'|'Q')
                break
                ;;
        esac
    done
    
    printf "%s" "$HIDE_CURSOR"
}

# =============================================================================
# Folder/File Browser UI
# =============================================================================

# Main entry point - Browse mod config folders in profile directory
# Usage: mod_config_browser "/path/to/profile"
mod_config_browser() {
    local profile_dir="$1"
    
    if [[ ! -d "$profile_dir" ]]; then
        show_message "Profile directory not found: $profile_dir" "Error"
        return 1
    fi
    
    # Get list of folders (mod configs)
    local -a folders=()
    while IFS= read -r -d '' folder; do
        local name=$(basename "$folder")
        # Skip hidden folders and some known non-config folders
        [[ "$name" == .* ]] && continue
        [[ "$name" == "storage_"* ]] && continue
        [[ "$name" == "DataCache" ]] && continue
        [[ "$name" == "users" ]] && continue
        folders+=("$folder")
    done < <(find "$profile_dir" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    
    if [[ ${#folders[@]} -eq 0 ]]; then
        show_message "No mod config folders found in profile directory" "Info"
        return 0
    fi
    
    local selected=0
    local count=${#folders[@]}
    
    while true; do
        get_term_size
        printf "%s" "$CLEAR_SCREEN"
        draw_header "Mod Configs"
        
        # Draw folder list
        local row=3
        for ((i=0; i<count && row<TERM_ROWS-2; i++)); do
            local name=$(basename "${folders[$i]}")
            local file_count=$(find "${folders[$i]}" -maxdepth 1 -type f 2>/dev/null | wc -l)
            
            move_to $row 2
            if [[ $i -eq $selected ]]; then
                printf "%s%s▶ 📁 %-40s (%d files)%s" "$BG_RED" "$WHITE$BOLD" "$name" "$file_count" "$RESET"
            else
                printf "  📁 %-40s (%d files)" "$name" "$file_count"
            fi
            ((row++))
        done
        
        # Footer
        move_to $TERM_ROWS 1
        printf "%s%s ↑↓ Navigate  Enter Open  [Q] Back%*s%s" "$BG_DARKGRAY" "$WHITE" "$((TERM_COLS - 40))" "" "$RESET"
        
        # Input
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') [[ $selected -gt 0 ]] && ((selected--)) ;;
                    '[B') [[ $selected -lt $((count-1)) ]] && ((selected++)) ;;
                esac
                ;;
            '')  # Enter - open folder
                mod_folder_browser "${folders[$selected]}"
                ;;
            'q'|'Q')
                return 0
                ;;
        esac
    done
}

# Browse files within a mod config folder
mod_folder_browser() {
    local folder="$1"
    local folder_name=$(basename "$folder")
    
    # Get list of files
    local -a files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$folder" -maxdepth 1 -type f -print0 | sort -z)
    
    if [[ ${#files[@]} -eq 0 ]]; then
        show_message "No config files found in $folder_name" "Info"
        return 0
    fi
    
    local selected=0
    local count=${#files[@]}
    
    while true; do
        get_term_size
        printf "%s" "$CLEAR_SCREEN"
        draw_header "$folder_name"
        
        # Draw file list
        local row=3
        for ((i=0; i<count && row<TERM_ROWS-2; i++)); do
            local name=$(basename "${files[$i]}")
            local icon=$(get_file_icon "${files[$i]}")
            local size=$(stat -c%s "${files[$i]}" 2>/dev/null || stat -f%z "${files[$i]}" 2>/dev/null || echo "?")
            
            # Human readable size
            local size_str
            if [[ "$size" =~ ^[0-9]+$ ]]; then
                if [[ $size -gt 1048576 ]]; then
                    size_str="$(echo "scale=1; $size/1048576" | bc)M"
                elif [[ $size -gt 1024 ]]; then
                    size_str="$(echo "scale=1; $size/1024" | bc)K"
                else
                    size_str="${size}B"
                fi
            else
                size_str="?"
            fi
            
            move_to $row 2
            if [[ $i -eq $selected ]]; then
                printf "%s%s▶ %s %-40s %6s%s" "$BG_RED" "$WHITE$BOLD" "$icon" "$name" "$size_str" "$RESET"
            else
                printf "  %s %-40s %6s" "$icon" "$name" "$size_str"
            fi
            ((row++))
        done
        
        # Footer
        move_to $TERM_ROWS 1
        printf "%s%s ↑↓ Navigate  Enter Edit  [Q] Back%*s%s" "$BG_DARKGRAY" "$WHITE" "$((TERM_COLS - 40))" "" "$RESET"
        
        # Input
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') [[ $selected -gt 0 ]] && ((selected--)) ;;
                    '[B') [[ $selected -lt $((count-1)) ]] && ((selected++)) ;;
                esac
                ;;
            '')  # Enter - edit file
                local file="${files[$selected]}"
                local handler=$(get_file_handler "$file")
                local name=$(basename "$file")
                
                case "$handler" in
                    xml)  xml_edit_file "$file" "$folder_name / $name" ;;
                    # JSON/CFG use nano - complex parsers don't work well for mod configs
                    *)    raw_edit_file "$file" "$folder_name / $name" ;;
                esac
                ;;
            'q'|'Q')
                return 0
                ;;
        esac
    done
}
