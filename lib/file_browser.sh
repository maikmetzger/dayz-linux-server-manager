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
    ["rpt"]="📜"
    ["adm"]="🛡️"
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
    
    # Check file size (safeguard for large logs)
    local size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    local size_mb=$((size / 1048576))
    
    # Display file content preview
    printf "%s%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
    printf "%s%s ═══ %s ═══ %s\n" "$RED$BOLD" "" "$title" "$RESET"
    
    if [[ $size_mb -ge 1 ]]; then
        printf "%s%s WARNING: Large file (%d MB). Previewing first 50 lines only.%s\n" "$YELLOW$BOLD" "⚠️" "$size_mb" "$RESET"
    fi
    printf "%s%s Press 'e' to edit (auto-bak), 'l' to tail, 'q' to go back %s\n\n" "$DIM" "" "$RESET"
    
    head -50 "$file" 2>/dev/null
    printf "\n%s[e:Edit  l:Tail  q:Back]%s" "$DIM" "$RESET"
    
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            'e'|'E')
                cp "$file" "${file}.bak"
                nano "$file"
                break
                ;;
            'l'|'L')
                fb_tail_file "$file"
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

# The _fb_* helpers run inside fb_browse_dir and use its locals (bash dynamic
# scoping): dir, dir_name, title, breadcrumb_prefix, on_select_cmd, mode,
# ignore_pattern, filter, selected, count, needs_refresh and the item arrays
# items, item_paths, item_sizes, item_mtimes, item_btimes, item_counts.

# Rebuild the (filtered, sorted) entry list and its metadata
_fb_scan_dir() {
    items=(".."); item_paths=("")
    local -a find_args=("$dir" -mindepth 1 -maxdepth 1)
    [[ "$mode" == "folders" ]] && find_args+=(-type d)
    local p name
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        name="${p##*/}"
        [[ "$name" == .* ]] && continue                                       # hidden
        [[ -n "$ignore_pattern" && "$name" =~ $ignore_pattern ]] && continue  # system folders
        [[ -n "$filter" && ! "$name" =~ $filter ]] && continue                # user search
        items+=("$name")
        item_paths+=("$p")
    done < <(find "${find_args[@]}" -print 2>/dev/null | sort)
    _fb_scan_meta
}

# Size, modified and created time of every entry with ONE stat call, files
# per folder with ONE find call (was stat/cut/find/wc per row per redraw)
_fb_scan_meta() {
    item_sizes=(); item_mtimes=(); item_btimes=(); item_counts=()
    local n=${#item_paths[@]}
    local -A index_of=()
    local i
    for ((i=1; i<n; i++)); do
        item_sizes[$i]=0; item_mtimes[$i]="-"; item_btimes[$i]="-"; item_counts[$i]=0
        index_of["${item_paths[$i]}"]=$i
    done
    [[ $n -gt 1 ]] || return 0

    local size mtime btime path
    while IFS='|' read -r size mtime btime path; do
        i="${index_of[$path]:-}"
        [[ -n "$i" ]] || continue
        item_sizes[$i]="$size"
        item_mtimes[$i]="${mtime%%.*}"    # "2026-01-02 03:04:05.123 +0000" -> "2026-01-02 03:04:05"
        item_btimes[$i]="${btime%%.*}"    # "-" when the filesystem has no birth time
    done < <(stat -c '%s|%y|%w|%n' -- "${item_paths[@]:1}" 2>/dev/null)

    local c d
    while read -r c d; do
        i="${index_of[$d]:-}"
        [[ -n "$i" ]] && item_counts[$i]="$c"
    done < <(find "$dir" -mindepth 2 -maxdepth 2 -type f -printf '%h\n' 2>/dev/null | sort | uniq -c)
    return 0
}

# Bytes as "3.1M", "1.9K" or "10B"
_fb_size_str() {
    local bytes="${1:-0}"
    if [[ $bytes -gt 1048576 ]]; then
        printf '%d.%dM' $((bytes / 1048576)) $((bytes % 1048576 * 10 / 1048576))
    elif [[ $bytes -gt 1024 ]]; then
        printf '%d.%dK' $((bytes / 1024)) $((bytes % 1024 * 10 / 1024))
    else
        printf '%dB' "$bytes"
    fi
}

# One entry at screen ROW for index I; the selected row is inverted
_fb_draw_row() {
    local i="$1" row="$2"
    local name="${items[$i]}" path="${item_paths[$i]}"
    local shown="${name:0:$((name_w-4))}"
    local prefix="  " suffix=""
    if [[ $i -eq $selected ]]; then
        prefix="${BG_RED}${WHITE}${BOLD}▶ "
        suffix="$RESET"
    fi
    move_to "$row" 2
    if [[ "$name" == ".." ]]; then
        if [[ $i -eq $selected ]]; then
            printf "%s📁 %-*s %*s%s" "$prefix" "$((name_w-3))" ".." "$((TERM_COLS - name_w - 5))" "" "$suffix"
        else
            printf "  📁 %-*s" "$((name_w-3))" ".."
        fi
    elif [[ -d "$path" ]]; then
        printf "%s📁 %-*s " "$prefix" "$((name_w-3))" "$shown"
        if [[ "$mode" == "folders" ]]; then
            printf "%-10s %-19s" "${item_counts[$i]}" "${item_mtimes[$i]}"
        else
            printf "%-8s %-19s %-19s" "${item_counts[$i]}" "-" "${item_mtimes[$i]}"
        fi
        printf "%s" "$suffix"
    else
        local icon
        icon=$(fb_get_icon "$path")
        [[ $i -eq $selected && "$name" == *.bak ]] && icon="🔄"
        printf "%s%s %-*s %-8s %-19s %-19s%s" "$prefix" "$icon" "$((name_w-3))" "$shown" \
            "$(_fb_size_str "${item_sizes[$i]}")" "${item_btimes[$i]}" "${item_mtimes[$i]}" "$suffix"
    fi
}

# Header, breadcrumb, column titles, visible rows and key help
_fb_draw() {
    printf "%s" "$CLEAR_SCREEN"
    draw_header "$title"

    move_to 2 2
    local crumb="${DIM}${breadcrumb_prefix} > ${dir_name}${RESET}"
    [[ -n "$filter" ]] && crumb+=" ${YELLOW}(Filter: $filter)${RESET}"
    printf '%s' "$crumb"

    move_to 3 2
    if [[ "$mode" == "folders" ]]; then
        name_w=$((${TERM_COLS:-80} - 45))
        [[ $name_w -lt 20 ]] && name_w=20
        printf "%s%-*s %-10s %-19s%s" "$BOLD$CYAN" "$name_w" "Folder Name" "Files" "Last Modified" "$RESET"
    else
        name_w=$((${TERM_COLS:-80} - 63))
        [[ $name_w -lt 20 ]] && name_w=20
        printf "%s%-*s %-8s %-19s %-19s%s" "$BOLD$CYAN" "$name_w" "File Name" "Size" "Created" "Modified" "$RESET"
    fi

    local max_rows=$(( ${TERM_ROWS:-24} - 6 ))
    [[ $max_rows -lt 1 ]] && max_rows=1
    local start_row=0
    [[ $selected -ge $max_rows ]] && start_row=$((selected - max_rows + 1))
    local i row=4
    for ((i=start_row; i<count && i<start_row+max_rows; i++)); do
        _fb_draw_row "$i" "$row"
        row=$((row + 1))
    done

    move_to "$TERM_ROWS" 1
    local hints="↑↓ Nav  Enter Select  [/] Search"
    [[ -n "$filter" ]] && hints="${hints}  [C] Clear"
    if _fb_can_edit; then
        hints="${hints}  [N] New  [D] Delete  [L] Tail"
        [[ "${items[$selected]}" == *.bak ]] && hints="${hints}  [R] Restore"
    fi
    printf "%s%s %s  [Q] Back%*s%s" "$BG_DARKGRAY" "$WHITE" "$hints" "$((TERM_COLS - ${#hints} - 12))" "" "$RESET"
}

# [Enter] on an entry: the handler decides, otherwise a folder is entered
_fb_key_open() {
    local path="${item_paths[$selected]}"
    if [[ -n "$on_select_cmd" ]]; then
        $on_select_cmd "$path" || true
    elif [[ -d "$path" ]]; then
        fb_browse_dir "$path" "$title" "$breadcrumb_prefix > $dir_name" "" "$mode" || true
    fi
}

# Only the "all" mode may create, delete, restore or tail entries
_fb_can_edit() {
    [[ "$mode" == "all" ]]
}

# [N] create a file or folder inside the current directory
_fb_key_new() {
    _fb_can_edit || return 0
    local type name
    type=$(read_input "Type (f=File, d=Folder):" "f" "New Item")
    case "$type" in
        f) name=$(read_input "Filename:" "" "Create File") ;;
        d) name=$(read_input "Folder name:" "" "Create Folder") ;;
        *) return 0 ;;
    esac
    [[ -n "$name" ]] || return 0
    if [[ "$name" == */* ]]; then
        show_message "The name must not contain '/'" "Error"
        return 0
    fi
    if [[ "$type" == "f" ]]; then touch "${dir}/${name}"; else mkdir -p "${dir}/${name}"; fi
}

# [D] delete the selected entry after confirmation
_fb_key_delete() {
    _fb_can_edit || return 0
    [[ "${items[$selected]}" != ".." ]] || return 0
    local path="${item_paths[$selected]}"
    if confirm "Delete '$(basename "$path")'?" "n"; then
        rm -rf "$path"
    fi
}

# [R] copy a .bak over its original
_fb_key_restore() {
    _fb_can_edit || return 0
    local path="${item_paths[$selected]}"
    [[ "$path" == *.bak ]] || return 0
    if confirm "Restore this backup? (Overwrites current file)" "n"; then
        cp -f "$path" "${path%.bak}"
        show_message "Restored to $(basename "${path%.bak}")" "Restored"
    fi
}

# [L] tail the selected file
_fb_key_tail() {
    _fb_can_edit || return 0
    [[ "${items[$selected]}" != ".." ]] || return 0
    fb_tail_file "${item_paths[$selected]}" || true
}

# Generic Directory Browser
# Usage: fb_browse_dir <dir> <title> <breadcrumb_prefix> [on_select_cmd] [mode] [ignore_pattern]
# mode: "all" (default, files and folders, editable), "folders" (only
# directories), "view" (files and folders, read-only)
fb_browse_dir() {
    local dir="$1"
    local title="$2"
    local breadcrumb_prefix="$3"
    local on_select_cmd="${4:-}"
    local mode="${5:-all}"
    local ignore_pattern="${6:-}"

    if [[ ! -d "$dir" ]]; then
        show_message "Directory not found: $dir" "Error"
        return 1
    fi

    local dir_name
    dir_name=$(basename "$dir")
    local selected=0 filter="" needs_refresh=1
    local -a items item_paths item_sizes item_mtimes item_btimes item_counts
    local count name_w key seq
    while true; do
        # the listing is rescanned after every change, not for cursor movement
        if [[ $needs_refresh -eq 1 ]]; then
            _fb_scan_dir
            needs_refresh=0
        fi
        count=${#items[@]}
        [[ $selected -ge $count ]] && selected=$((count - 1))
        [[ $selected -lt 0 ]] && selected=0

        get_term_size
        _fb_draw

        IFS= read -rsn1 key || return 0   # EOF: leave instead of looping
        needs_refresh=1
        case "$key" in
            $'\x1b')
                needs_refresh=0
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') [[ $selected -gt 0 ]] && selected=$((selected - 1)) ;;
                    '[B') [[ $selected -lt $((count-1)) ]] && selected=$((selected + 1)) ;;
                esac
                ;;
            '')  # Enter
                [[ "${items[$selected]:-}" == ".." ]] && return 0
                _fb_key_open
                ;;
            '/')
                filter=$(read_input "Search pattern (regex):" "$filter" "Filter List")
                selected=0
                ;;
            c|C) filter=""; selected=0 ;;
            n|N) _fb_key_new ;;
            d|D) _fb_key_delete ;;
            r|R) _fb_key_restore ;;
            l|L) _fb_key_tail ;;
            q|Q) return 0 ;;
            *)   needs_refresh=0 ;;
        esac
    done
}
