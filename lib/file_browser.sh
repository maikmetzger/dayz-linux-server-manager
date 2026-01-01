#!/usr/bin/env bash
# =============================================================================
# DayZ Script File Browser Library
# =============================================================================
# Reusable TUI component for browsing directories and managing files.
# Requires: lib/tui.sh, lib/dialogs.sh
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_FILE_BROWSER_LOADED:-}" ]] && return 0
_DAYZ_FILE_BROWSER_LOADED=1

# Debug Logging
FB_DEBUG_LOG="/tmp/dayz_debug.log"
fb_log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] FILE_BROWSER: $*" >> "$FB_DEBUG_LOG"
}
fb_log "Library loaded"

# =============================================================================
# Configuration & Constants
# =============================================================================

declare -A FB_TYPE_ICONS=(
    ["json"]="📋"
    ["xml"]="📄"
    ["cfg"]="⚙️"
    ["txt"]="📝"
    ["md"]="📝"
    ["log"]="📝"
    ["bak"]="🔄"
    ["folder"]="📁"
    ["file"]="📄"
)

# =============================================================================
# Helper Functions
# =============================================================================

# Get icon for file or folder
fb_get_icon() {
    local path="$1"
    if [[ -d "$path" ]]; then
        echo "${FB_TYPE_ICONS[folder]}"
    else
        local ext="${path##*.}"
        ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
        echo "${FB_TYPE_ICONS[$ext]:-${FB_TYPE_ICONS[file]}}"
    fi
}

# =============================================================================
# File Operations
# =============================================================================

# Tail a file (live view)
fb_tail_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        show_message "File not found: $path" "Error"
        return 1
    fi
    
    printf "%s%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
    printf "%s--- Tailing %s (Ctrl+C to stop) ---%s\n" "$CYAN$BOLD" "$(basename "$path")" "$RESET"
    tail -n 50 -f "$path" || true
    printf "%s" "$HIDE_CURSOR"
}

# Edit a file with nano (includes auto-backup)
fb_edit_file_nano() {
    local file="$1"
    local title="${2:-Text Editor}"
    
    if [[ ! -f "$file" ]]; then
        show_message "File not found: $file" "Error"
        return 1
    fi
    
    # Display file content preview
    printf "%s%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
    printf "%s%s ═══ %s ═══ %s\n" "$RED$BOLD" "" "$title" "$RESET"
    printf "%s%s Press 'e' to edit with nano (auto-bak), 'q' to go back %s\n\n" "$DIM" "" "$RESET"
    
    head -30 "$file" 2>/dev/null
    printf "\n%s[Press 'e' to edit, 'q' to quit]%s" "$DIM" "$RESET"
    
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            'e'|'E')
                cp "$file" "${file}.bak"
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
# Core Browser Component
# =============================================================================

# Generic Directory Browser
# Usage: fb_browse_dir <dir> <title> <breadcrumb_prefix> [on_select_cmd] [mode] [ignore_pattern]
# mode: "all" (default), "folders"
fb_browse_dir() {
    local dir="$1"
    local title="$2"
    local breadcrumb_prefix="$3"
    local on_select_cmd="${4:-}"
    local mode="${5:-all}"
    local ignore_pattern="${6:-}"
    
    fb_log "fb_browse_dir started: dir='$dir', title='$title', mode='$mode'"
    
    if [[ ! -d "$dir" ]]; then
        fb_log "ERROR: Directory not found: $dir"
        show_message "Directory not found: $dir" "Error"
        return 1
    fi
    
    local selected=0
    local dir_name=$(basename "$dir")
    fb_log "dir_name: $dir_name"
    
    while true; do
        fb_log "Loop iteration start. selected=$selected"
        # 1. Refresh list
        local -a items=("..")
        local -a item_paths=("")
        
        # Build find arguments
        local -a find_args=("$dir" -mindepth 1 -maxdepth 1)
        [[ "$mode" == "folders" ]] && find_args+=(-type d)
        
        fb_log "Running find: ${find_args[@]}"
        # Use find -print and handle spaces, avoiding sort -z for BusyBox compatibility
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            local name=$(basename "$p")
            # Filter hidden and ignored patterns
            [[ "$name" == .* ]] && continue
            if [[ -n "$ignore_pattern" ]] && [[ "$name" =~ "$ignore_pattern" ]]; then
                continue
            fi
            
            items+=("$name")
            item_paths+=("$p")
        done < <(find "${find_args[@]}" -print 2>/dev/null | sort)
        
        local count=${#items[@]}
        fb_log "Items found: $count"
        [[ $selected -ge $count ]] && selected=$((count - 1))
        [[ $selected -lt 0 ]] && selected=0

        # 2. Draw UI
        get_term_size
        printf "%s" "$CLEAR_SCREEN"
        draw_header "$title"
        
        # Breadcrumbs
        move_to 2 2
        printf "%s%s > %s%s" "$DIM" "$breadcrumb_prefix" "$dir_name" "$RESET"
        
        # Column Headers
        move_to 3 2
        local name_w
        if [[ "$mode" == "folders" ]]; then
            name_w=$((TERM_COLS - 45))
            [[ $name_w -lt 20 ]] && name_w=20
            printf "%s%s%-*s %-10s %-19s%s" "$BOLD$CYAN" "" "$name_w" "Folder Name" "Files" "Last Modified" "$RESET"
        else
            name_w=$((TERM_COLS - 65))
            [[ $name_w -lt 20 ]] && name_w=20
            printf "%s%s%-*s %-8s %-19s %-19s%s" "$BOLD$CYAN" "" "$name_w" "File Name" "Size" "Created" "Modified" "$RESET"
        fi

        # Draw List
        local row=4
        local max_rows=$((TERM_ROWS - 6))
        local start_row=0
        [[ $selected -ge $max_rows ]] && start_row=$((selected - max_rows + 1))

        for ((i=start_row; i<count && i<start_row+max_rows; i++)); do
            local name="${items[$i]}"
            local path="${item_paths[$i]}"
            move_to $row 2
            
            if [[ "$name" == ".." ]]; then
                if [[ $i -eq $selected ]]; then
                    printf "%s%s▶ 📁 %-*s %*s%s" "$BG_RED" "$WHITE$BOLD" "$((name_w-3))" ".." "$((TERM_COLS - name_w - 5))" "" "$RESET"
                else
                    printf "  📁 %-*s" "$((name_w-3))" ".."
                fi
            elif [[ -d "$path" ]]; then
                # Folder Row - Get latest modification in folder
                local mod_time="-"
                # Portable way to get latest modified file's time
                # Using stat on the directory itself as a fallback if find fails
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    mod_time=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$path" 2>/dev/null || echo "-")
                else
                    mod_time=$(stat -c "%y" "$path" 2>/dev/null | cut -d'.' -f1 || echo "-")
                fi
                
                local file_count=$(find "$path" -maxdepth 1 -type f 2>/dev/null | wc -l)
                
                if [[ $i -eq $selected ]]; then
                    printf "%s%s▶ 📁 %-*s %-10s %-19s%s" "$BG_RED" "$WHITE$BOLD" "$((name_w-3))" "${name:0:$((name_w-4))}" "$file_count" "$mod_time" "$RESET"
                else
                    printf "  📁 %-*s %-10s %-19s" "$((name_w-3))" "${name:0:$((name_w-4))}" "$file_count" "$mod_time"
                fi
            else
                # File Row
                local icon=$(fb_get_icon "$path")
                local size_raw=$(stat -c%s "$path" 2>/dev/null || echo "0")
                local mtime=$(stat -c%y "$path" 2>/dev/null | cut -d'.' -f1)
                local btime=$(stat -c%w "$path" 2>/dev/null | cut -d'.' -f1)
                [[ "$btime" == "-" ]] && btime="-"
                
                # Human readable size
                local size_str
                if [[ $size_raw -gt 1048576 ]]; then
                    size_str="$(echo "scale=1; $size_raw/1048576" | bc)M"
                elif [[ $size_raw -gt 1024 ]]; then
                    size_str="$(echo "scale=1; $size_raw/1024" | bc)K"
                else
                    size_str="${size_raw}B"
                fi
                
                if [[ $i -eq $selected ]]; then
                    [[ "$name" == *.bak ]] && icon="🔄"
                    printf "%s%s▶ %s %-*s %-8s %-19s %-19s%s" "$BG_RED" "$WHITE$BOLD" "$icon" "$((name_w-3))" "${name:0:$((name_w-4))}" "$size_str" "$btime" "$mtime" "$RESET"
                else
                    printf "  %s %-*s %-8s %-19s %-19s" "$icon" "$((name_w-3))" "${name:0:$((name_w-4))}" "$size_str" "$btime" "$mtime"
                fi
            fi
            ((row++))
        done

        # Footer
        move_to $TERM_ROWS 1
        local hints="↑↓ Nav  Enter Select"
        if [[ "$mode" != "folders" ]]; then
            hints="${hints}  [N] New  [D] Delete  [L] Tail"
            [[ "${items[$selected]}" == *.bak ]] && hints="${hints}  [R] Restore"
        fi
        printf "%s%s %s  [Q] Back%*s%s" "$BG_DARKGRAY" "$WHITE" "$hints" "$((TERM_COLS - ${#hints} - 12))" "" "$RESET"

        # 3. Input
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') [[ $selected -gt 0 ]] && ((selected--)) ;;
                    '[B') [[ $selected -lt $((count-1)) ]] && ((selected++)) ;;
                esac
                ;;
            '') # Enter
                if [[ "${items[$selected]}" == ".." ]]; then
                    return 0
                fi
                local path="${item_paths[$selected]}"
                if [[ -n "$on_select_cmd" ]]; then
                    # Call user provided handler
                    $on_select_cmd "$path"
                elif [[ -d "$path" ]]; then
                    # Recurse if no handler
                    fb_browse_dir "$path" "$title" "$breadcrumb_prefix > $dir_name" "" "$mode"
                fi
                ;;
            'n'|'N')
                [[ "$mode" == "folders" ]] && continue
                local new_name
                new_name=$(read_input "New filename:" "" "Create File")
                [[ -n "$new_name" ]] && touch "${dir}/${new_name}"
                ;;
            'd'|'D')
                [[ "$mode" == "folders" ]] && continue
                if [[ "${items[$selected]}" != ".." ]]; then
                    local path="${item_paths[$selected]}"
                    if confirm "Delete '$(basename "$path")'?" "n"; then
                        rm -rf "$path"
                    fi
                fi
                ;;
            'r'|'R')
                [[ "$mode" == "folders" ]] && continue
                local path="${item_paths[$selected]}"
                if [[ "$path" == *.bak ]]; then
                    local orig="${path%.bak}"
                    if confirm "Restore this backup? (Overwrites current file)" "n"; then
                        cp -f "$path" "$orig"
                        show_message "Restored to $(basename "$orig")" "Restored"
                    fi
                fi
                ;;
            'l'|'L')
                [[ "$mode" == "folders" ]] && continue
                if [[ "${items[$selected]}" != ".." ]]; then
                    fb_tail_file "${item_paths[$selected]}"
                fi
                ;;
            'q'|'Q')
                return 0
                ;;
        esac
    done
}
