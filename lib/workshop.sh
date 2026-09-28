#!/usr/bin/env bash
# =============================================================================
# DayZ Workshop Browser - TUI Library
# =============================================================================
# Provides high-fidelity Steam Workshop discovery and mod installation.
# Also provides version tracking for mod update detection.
# =============================================================================

# =============================================================================
# Version Tracking Infrastructure (Phase 1)
# =============================================================================
# These functions store and retrieve mod version information to detect updates.
# Version is stored as Steam's `time_updated` timestamp from the API.
# =============================================================================

# Cache settings

# Debug trace of workshop fetches. Not under /tmp: a predictable path there
# could be pre-created by another local user.
WORKSHOP_DEBUG_LOG="${WORKSHOP_DEBUG_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/dayz-docker-hub/workshop_debug.log}"
mkdir -p "$(dirname "$WORKSHOP_DEBUG_LOG")" 2>/dev/null || true

# get_mod_local_version - Retrieve the stored version timestamp for a mod
#
# Usage: local_version=$(get_mod_local_version "$mod_id" "$workshop_dir")
#
# Returns: Unix timestamp of installed version, or "0" if not found
get_mod_local_version() {
    local mod_id="$1"
    local workshop_dir="$2"
    local mod_path="${workshop_dir}/${mod_id}"
    local version_file="${mod_path}/.installed_version"
    
    if [[ -f "$version_file" ]]; then
        cat "$version_file"
    elif [[ -d "$mod_path" ]]; then
        # Fallback to directory mtime if folder exists but no tracking file
        # Use stat (macOS/Linux compatible if possible, otherwise use perl/python)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            stat -f %m "$mod_path" 2>/dev/null || echo "0"
        else
            stat -c %Y "$mod_path" 2>/dev/null || echo "0"
        fi
    else
        echo "0"
    fi
}

# format_timestamp_as_date - Convert Unix timestamp to human-readable date
#
# Usage: date_str=$(format_timestamp_as_date "$timestamp")
#
# Returns: Date string like "Jan 01" or "Dec 15"
format_timestamp_as_date() {
    local timestamp="$1"
    
    if [[ "$timestamp" == "0" || -z "$timestamp" ]]; then
        echo "-"
        return
    fi
    
    # Use date command to format (portable across Linux/macOS)
    if date --version &>/dev/null 2>&1; then
        # GNU date (Linux)
        date -d "@$timestamp" "+%b %d" 2>/dev/null || echo "-"
    else
        # BSD date (macOS)
        date -r "$timestamp" "+%b %d" 2>/dev/null || echo "-"
    fi
}

# =============================================================================
# Update Check Functions (Phase 1 - Caching Infrastructure)
# =============================================================================

# get_update_cache_file - Get path to update cache file for an instance
#
# Usage: cache_file=$(get_update_cache_file "$instance_dir")
get_update_cache_file() {
    local instance_dir="$1"
    echo "${instance_dir}/data/state/update_cache.json"
}

# check_all_mod_updates - Check for updates on all mods in an instance
#
# Usage: check_all_mod_updates "$instance_dir" "$workshop_dir" "$mods_file" "$servermods_file"
#
# Writes result to cache file and outputs JSON to stdout
check_all_mod_updates() {
    local instance_dir="$1"
    local workshop_dir="$2"
    local mods_file="$3"
    local servermods_file="$4"
    
    local cache_file
    cache_file=$(get_update_cache_file "$instance_dir")
    
    # Ensure state directory exists
    mkdir -p "$(dirname "$cache_file")"
    
    # Build JSON of {mod_id: local_version}
    local -A local_versions=()
    
    # Get all mod IDs
    local all_ids
    all_ids=$(get_all_mod_ids "$mods_file" "$servermods_file" 2>/dev/null || true)
    
    if [[ -z "$all_ids" ]]; then
        echo '{"mods": {}, "update_count": 0, "checked_at": '"$(date +%s)"'}'
        return
    fi
    
    # Build local versions map
    local versions_json="{"
    local first=1
    while IFS= read -r mod_id; do
        [[ -z "$mod_id" ]] && continue
        local local_ver
        local_ver=$(get_mod_local_version "$mod_id" "$workshop_dir")
        if [[ $first -eq 1 ]]; then
            first=0
        else
            versions_json+=","
        fi
        versions_json+="\"$mod_id\":$local_ver"
    done <<< "$all_ids"
    versions_json+="}"
    
    # Call Python backend
    local result
    result=$(python3 "${SCRIPT_DIR}/lib/workshop_search.py" --check-updates "$versions_json" 2>/dev/null)
    
    if [[ -n "$result" && "$result" != "null" ]]; then
        echo "$result" > "$cache_file"
        echo "$result"
    else
        # Return cached if API fails
        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
        else
            echo '{"mods": {}, "update_count": 0, "checked_at": 0, "error": "API failed"}'
        fi
    fi
}

# get_cached_update_info - Get update info from cache without API call
#
# Usage: info=$(get_cached_update_info "$instance_dir")
get_cached_update_info() {
    local instance_dir="$1"
    local cache_file
    cache_file=$(get_update_cache_file "$instance_dir")
    
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
    else
        echo '{"mods": {}, "update_count": 0, "checked_at": 0}'
    fi
}

# get_update_summary - Get human-readable update summary for UI
#
# Usage: summary=$(get_update_summary "$instance_dir")
#
# Returns: "(3 mod updates)" or "" if no updates
get_update_summary() {
    local instance_dir="$1"
    local cache_file
    cache_file=$(get_update_cache_file "$instance_dir")
    
    [[ -f "$cache_file" ]] || return
    
    local update_count
    update_count=$(python3 -c "import json; print(json.load(open('$cache_file')).get('update_count', 0))" 2>/dev/null || echo "0")
    
    if [[ "$update_count" -gt 0 ]]; then
        local s=""
        [[ "$update_count" -gt 1 ]] && s="s"
        echo "[NEED SYNC] (${update_count} mod update${s})"
    fi
}

# =============================================================================
# Fetch Workshop Items
# =============================================================================

# =============================================================================
# Steam Workshop: fetching
# =============================================================================

# Search results as JSON (workshop_search.py)
_fetch_workshop_items() {
    local text="$1" sort="$2" num="$3" page="$4" mode="${5:-title}" clear_flag="${6:-}"
    # shellcheck disable=SC2086  # clear_flag is "--clear" or empty
    python3 "${SCRIPT_DIR}/lib/workshop_search.py" \
        --search "$text" --sort "$sort" --num "$num" --page "$page" --mode "$mode" $clear_flag
}

# Details for one or more IDs as JSON. recursive=1 resolves the dependency
# chain, rules_path updates data/workshop_rules.json on the way.
_fetch_workshop_details() {
    local ids="$1" recursive="${2:-}" rules_path="${3:-}"
    local -a cmd=(timeout 90s python3 "${SCRIPT_DIR}/lib/workshop_search.py" --details "$ids")
    [[ "$recursive" == "1" ]] && cmd+=(--recursive)
    [[ -n "$rules_path" ]] && cmd+=(--update-rules "$rules_path")
    echo "FETCH_DETAILS: ids=$ids recursive=$recursive" >> "${WORKSHOP_DEBUG_LOG}"
    "${cmd[@]}"
}

# Search result JSON (stdin) as one row per mod for the result list:
# id|name|rating|subs_f|size|updated|desc|children|subs_raw ('|' stripped from texts)
_ws_items_to_rows() {
    python3 -c '
import sys, json, datetime
try:
    data = json.load(sys.stdin)
except ValueError:
    data = []
if not isinstance(data, list):
    data = []
for x in data:
    updated = datetime.datetime.fromtimestamp(x.get("updated", 0)).strftime("%Y-%m-%d")
    desc = x.get("description_clean", x.get("description", ""))[:500]
    desc = desc.replace("|", " ").replace("\n", " ").replace("\r", " ")
    raw_deps = x.get("dependency_names")
    if raw_deps is None:
        raw_deps = x.get("dependencies", [])
    children = ", ".join(str(d).replace("|", "") for d in raw_deps)
    name = str(x.get("name", "")).replace("|", " ")
    print("|".join(str(v) for v in (x["id"], name, x.get("rating_stars", "?"), x.get("subscribers_f", "0"),
                                    x.get("size", "0 MB"), updated, desc, children, x.get("subscribers", 0))))
'
}

# Details JSON file as "key<TAB>value" lines (images one per line). Newlines
# inside the description arrive as the two characters \n; the renderer
# expands them. Nothing is generated as shell code.
_ws_details_to_rows() {
    python3 - "$1" <<'PY_DETAILS'
import sys, json, datetime

def clean(s):
    return str(s).encode('ascii', 'ignore').decode('ascii').strip().replace('\t', ' ')

def emit(key, value):
    print(key + '\t' + clean(value).replace('\n', '\\n'))

try:
    with open(sys.argv[1], encoding='utf-8') as f:
        data = json.load(f)
    if data:
        x = data[0]
        emit('name', x.get('name', ''))
        emit('author', x.get('author', 'Unknown'))
        emit('size', x.get('size', '0B'))
        emit('subs', x.get('subscribers_f', '0'))
        emit('updated', datetime.datetime.fromtimestamp(x.get('updated', 0)).strftime('%d. %b %Y %H:%M'))
        emit('released', datetime.datetime.fromtimestamp(x.get('created', 0)).strftime('%d. %b %Y %H:%M'))
        emit('desc', x.get('description_clean', x.get('description', '')))
        emit('deps', len(x.get('dependencies', [])))
        emit('rating_stars', x.get('rating_stars', '-'))
        emit('rating_count', x.get('rating_count', '0'))
        for img in x.get('images', []):
            emit('image', img)
except Exception as e:
    print(f'PARSE ERROR: {e}', file=sys.stderr)
PY_DETAILS
}

# Dependency chain JSON (stdin) as "id|name" lines
_ws_chain_to_rows() {
    python3 -c '
import sys, json
try:
    for x in json.load(sys.stdin):
        print(str(x["id"]) + "|" + str(x.get("name", "")).replace("|", " "))
except (ValueError, KeyError, TypeError):
    pass
'
}

# =============================================================================
# Steam Workshop: browser screen
# =============================================================================
# The _ws_* helpers run inside workshop_browser (and _view_mod_details) and
# use their locals through bash dynamic scoping: items, installed_mods,
# workshop_rules, count, selection, offset, f_text/f_sort/f_limit/f_mode,
# f_changed, f_clear, current_page, fetch_count, last_fetch_limit, mods_txt,
# rules_json, instance_dir, and in the details view mod[], mimages, scroll.

WS_SORT_OPTS=("trend" "mostsubscribed" "mostsubscribed_asc" "newestfirst" "lastupdated" "relevance")
WS_SORT_NAMES=("Standard (Trend)" "Subscribers (Desc)" "Subscribers (Asc)" "Newest First" "Last Updated" "Relevancy")
WS_LIMIT_OPTS=("Fill" "5" "10" "25" "50" "100")
WS_MODE_OPTS=("Title" "Author")
WS_DEFAULT_TEXT="DayZ"
WS_DEFAULT_SORT="mostsubscribed"

# Rows available for the result list (the rest is the detail pane and hints)
_ws_view_height() {
    local h=$((TERM_ROWS - 14))
    [[ $h -lt 5 ]] && h=5
    echo "$h"
}

# Sort key as shown in the detail pane
_ws_sort_label() {
    case "$1" in
        mostsubscribed)     echo "Subscribers (Desc)" ;;
        mostsubscribed_asc) echo "Subscribers (Asc)" ;;
        newestfirst)        echo "Newest First" ;;
        lastupdated)        echo "Last Updated" ;;
        relevance)          echo "Relevancy" ;;
        *)                  echo "Standard" ;;
    esac
}

# installed_mods: id -> enabled|disabled from mods.txt
_ws_load_installed() {
    installed_mods=()
    [[ -f "$mods_txt" ]] || return 0
    local mid status
    while IFS='|' read -r mid status; do
        [[ -n "$mid" ]] && installed_mods["$mid"]="$status"
    done < <(read_mod_ids_with_status "$mods_txt")
    return 0
}

# workshop_rules: id -> conflict|framework from data/workshop_rules.json
_ws_load_rules() {
    workshop_rules=()
    [[ -f "$rules_json" ]] || return 0
    local mid val
    while IFS='|' read -r mid val; do
        [[ -n "$mid" ]] && workshop_rules["$mid"]="$val"
    done < <(python3 - "$rules_json" <<'PY_RULES'
import json, sys
try:
    with open(sys.argv[1]) as fp:
        rules = json.load(fp)
except (OSError, ValueError):
    rules = {}
for mod_id in rules.get('incompatibilities', {}):
    print(f'{mod_id}|conflict')
for mod_id in rules.get('frameworks', []):
    print(f'{mod_id}|framework')
PY_RULES
    )
    return 0
}

# Fetch the current page into items[] (shows a badge while Steam answers)
_ws_fetch_page() {
    _ws_load_installed
    _ws_load_rules
    fetch_count=$(_ws_view_height)
    [[ "$f_limit" != "Fill" ]] && fetch_count=$f_limit

    count=0
    _draw_workshop_screen
    move_to $((TERM_ROWS / 2)) $((TERM_COLS / 2 - 10))
    printf "%s%s Fetching Workshop Data (%s)... %s" "$BG_RED" "$WHITE$BOLD" "$fetch_count" "$RESET"

    local mode="title" clear_arg="" json line
    [[ "$f_mode" == "Author" ]] && mode="author"
    [[ $f_clear -eq 1 ]] && clear_arg="--clear"
    json=$(_fetch_workshop_items "$f_text" "$f_sort" "$fetch_count" "$current_page" "$mode" "$clear_arg") || json="[]"
    f_clear=0

    items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(printf '%s' "$json" | _ws_items_to_rows)
    if [[ "$f_sort" == "mostsubscribed_asc" && ${#items[@]} -gt 0 ]]; then
        # Steam has no ascending sort: order locally by the raw subscriber count (field 9)
        local -a sorted=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && sorted+=("$line")
        done < <(printf '%s\n' "${items[@]}" | sort -t'|' -k9,9n)
        items=("${sorted[@]}")
    fi
    count=${#items[@]}
    [[ $selection -ge $count ]] && selection=$((count > 0 ? count - 1 : 0))
    last_fetch_limit=$fetch_count
    f_changed=0
}

# Full-width dashed line at ROW (dim red)
_ws_draw_rule() {
    local line
    printf -v line '%*s' "$TERM_COLS" ''
    move_to "$1" 1
    printf "%s%s%s%s" "$DIM" "$RED" "${line// /-}" "$RESET"
}

# One result row at screen ROW for items index IDX (uses the col_*/w_* layout of the caller)
_ws_draw_list_row() {
    local idx="$1" row="$2"
    local mid mname mrating msubs msize mdate mdesc mchildren _
    IFS='|' read -r mid mname mrating msubs msize mdate mdesc mchildren _ <<< "${items[$idx]}"

    local style="$WHITE" status_mark=" "
    [[ -n "${installed_mods[$mid]:-}" ]] && { style="$GRN"; status_mark="✓"; }
    [[ "${workshop_rules[$mid]:-}" == "conflict" ]] && { style="$RED"; status_mark="!"; }
    [[ "${workshop_rules[$mid]:-}" == "framework" && "$style" == "$WHITE" ]] && style="$YLW"
    move_to "$row" 1
    if [[ $idx -eq $selection ]]; then
        style="$BG_RED$WHITE$BOLD"
        printf "%s%*s%s" "$BG_RED" "$TERM_COLS" "" "$RESET"
    fi

    local d_name="$mname"
    [[ ${#d_name} -ge $((w_name-4)) ]] && d_name="${d_name:0:$((w_name-6))}.."
    local d_stars=" ? "
    if [[ "$mrating" =~ ^[0-5]$ ]]; then
        d_stars="$mrating/5"
        [[ "$mrating" == "0" ]] && d_stars=" - "
    fi

    local cell rest
    for cell in "$col_stat:$w_stat:$status_mark" "$col_name:$((w_name-2)):$d_name" "$col_id:$w_id:$mid" \
                "$col_size:$w_size:$msize" "$col_stars:$w_stars:$d_stars" "$col_subs:$w_subs:$msubs" "$col_date:10:$mdate"; do
        rest="${cell#*:}"
        move_to "$row" "${cell%%:*}"
        printf "%s%-*s" "$style" "${rest%%:*}" "${rest#*:}"
    done
    printf "%s" "$RESET"
}

# Dependencies, sort status and description of the selected result
_ws_draw_detail_pane() {
    local footer_row="$1"
    _ws_draw_rule "$footer_row"
    [[ $count -gt 0 ]] || return 0
    local mid mname mrating msubs msize mdate mdesc mchildren _
    IFS='|' read -r mid mname mrating msubs msize mdate mdesc mchildren _ <<< "${items[$selection]:-}"

    move_to $((footer_row + 1)) 2
    printf "%sDependencies:%s" "$YLW" "$RESET"
    local sort_str="Sorted By: $(_ws_sort_label "$f_sort")"
    local sort_col=$((TERM_COLS - ${#sort_str} - 1))
    [[ $sort_col -lt 20 ]] && sort_col=20
    move_to $((footer_row + 1)) $sort_col
    printf "%s%s%s" "$CYN" "$sort_str" "$RESET"

    local width=$((TERM_COLS - 6)) i
    local -a dep_lines=() desc_lines=()
    mapfile -t dep_lines < <(fold -s -w "$width" <<< "${mchildren:-None (Direct)}")
    local d_row=$((footer_row + 2)) shown=0
    for ((i=0; i<${#dep_lines[@]} && i<2; i++)); do   # at most two lines of dependencies
        move_to $((d_row + i)) 4
        printf "%s%s%s" "$WHITE" "${dep_lines[$i]}" "$RESET"
        shown=$((shown + 1))
    done

    local desc_row=$((d_row + shown))
    move_to $desc_row 2
    printf "%sDescription:%s" "$YLW" "$RESET"
    local clean_desc="${mdesc//$'\n'/ }"
    while [[ "$clean_desc" == *"  "* ]]; do clean_desc="${clean_desc//  / }"; done
    mapfile -t desc_lines < <(fold -s -w "$width" <<< "$clean_desc")
    local max_row=$((TERM_ROWS - 2))
    for ((i=0; i<${#desc_lines[@]}; i++)); do
        [[ $((desc_row + 1 + i)) -le $max_row ]] || break
        move_to $((desc_row + 1 + i)) 4
        printf "%s%s%s" "$DIM$WHITE" "${desc_lines[$i]}" "$RESET"
    done
}

# Whole browser screen: header, query line, result table, detail pane, hints
_draw_workshop_screen() {
    get_term_size
    printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
    move_to 1 1
    printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Steam Workshop Browser - DayZ" "$RESET"
    move_to 2 2
    printf "%sQuery: %-30s %sSort: %s%-15s %sPage: %s%d %s" \
        "$YLW" "${WHITE}${f_text:-None}" "$YLW" "$WHITE" "$f_sort" "$YLW" "$WHITE" "$current_page" "$RESET"

    local table_start=3
    _ws_draw_rule $table_start
    local col_stat=2 w_stat=2
    local col_name=$((col_stat + w_stat + 1)) w_name=38
    local col_id=$((col_name + w_name)) w_id=12
    local col_size=$((col_id + w_id)) w_size=9
    local col_stars=$((col_size + w_size)) w_stars=7
    local col_subs=$((col_stars + w_stars)) w_subs=14
    local col_date=$((col_subs + w_subs)) w_date=12
    local col rest
    for col in "$col_name:$w_name:NAME" "$col_id:$w_id:ID" "$col_size:$w_size:SIZE" "$col_stars:$w_stars:RATING" \
               "$col_subs:$w_subs:SUBSCRIBERS" "$col_date:$w_date:UPDATED"; do
        rest="${col#*:}"
        move_to $((table_start + 1)) "${col%%:*}"
        printf "%s%s%-*s%s" "$DIM" "$WHITE" "${rest%%:*}" "${rest#*:}" "$RESET"
    done
    _ws_draw_rule $((table_start + 2))

    local start_row=$((table_start + 3)) v_height i
    v_height=$(_ws_view_height)
    if [[ $count -eq 0 ]]; then
        move_to $start_row 2
        printf "%s(No results found for this query)%s" "$DIM" "$RESET"
    fi
    for ((i=0; i<v_height && offset+i<count; i++)); do
        _ws_draw_list_row $((offset + i)) $((start_row + i))
    done
    _ws_draw_detail_pane $((start_row + v_height + 1))

    move_to $((TERM_ROWS - 1)) 1
    local footer_text=" [↑↓] Nav  [←→] Pag  [Enter] Inst  [f] Search  [ Space ] Details  [c] Reset  [q] Back"
    local pad_len=$((TERM_COLS - ${#footer_text}))
    [[ $pad_len -lt 0 ]] && pad_len=0
    printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer_text" "$pad_len" "" "$RESET"
}

# =============================================================================
# Steam Workshop: details view
# =============================================================================

# Details of one mod from Steam into mod[] and mimages[] (defaults on failure)
_ws_fetch_details() {
    local mid="$1"
    mod=([name]="Loading..." [author]="Unknown" [size]="0B" [subs]="0" [updated]="-" [released]="-"
         [desc]="Loading..." [deps]="0" [rating_stars]="-" [rating_count]="0")
    mimages=()
    local tmp_json key value
    tmp_json=$(mktemp "${TMPDIR:-/tmp}/workshop_details_XXXXXX")
    _fetch_workshop_details "$mid" > "$tmp_json" 2>> "${WORKSHOP_DEBUG_LOG}" \
        || echo "DETAILS: fetch failed for $mid" >> "${WORKSHOP_DEBUG_LOG}"
    while IFS=$'\t' read -r key value; do
        case "$key" in
            image) mimages+=("$value") ;;
            ?*)    mod["$key"]="$value" ;;
        esac
    done < <(_ws_details_to_rows "$tmp_json" 2>> "${WORKSHOP_DEBUG_LOG}")
    rm -f "$tmp_json"
}

# Is the mod an enabled entry of a mod list file?
_ws_mod_listed() {
    [[ -f "$2" ]] && grep -qE "^[[:space:]]*${1}([[:space:]|]|$)" "$2"
}

# Install/sync dates and list membership of the mod on this instance (mod[installed|synced|type])
_ws_local_details() {
    local mid="$1" instance_dir="$2" mods_txt="$3"
    mod[installed]="-"; mod[synced]="-"; mod[type]="Not Installed"
    local ws_dir dates
    for ws_dir in "$instance_dir/serverfiles/steamapps/workshop/content/221100" \
                  "$instance_dir/data/serverfiles/steamapps/workshop/content/221100"; do
        [[ -d "$ws_dir/$mid" ]] || continue
        dates=$(python3 "${SCRIPT_DIR}/lib/mod_status.py" --dates "$ws_dir/$mid" 2>>"${WORKSHOP_DEBUG_LOG}") || dates="-|-"
        mod[installed]="${dates%%|*}"
        mod[synced]="${dates#*|}"
        break
    done
    local in_client=0 in_server=0
    _ws_mod_listed "$mid" "$mods_txt" && in_client=1
    _ws_mod_listed "$mid" "$(dirname "$mods_txt")/servermods.txt" && in_server=1
    if (( in_client && in_server )); then mod[type]="Client+Server"
    elif (( in_server )); then mod[type]="Server Mod"
    elif (( in_client )); then mod[type]="Client Mod"
    fi
}

# *bold* and _italic_ markup as ANSI (was two sed processes per line per redraw)
_ws_style_line() {
    local line="$1" out=""
    while [[ "$line" =~ ^([^*]*)\*([^*]*)\*(.*)$ ]]; do
        out+="${BASH_REMATCH[1]}${WHITE}${BOLD}${BASH_REMATCH[2]}${RESET}"
        line="${BASH_REMATCH[3]}"
    done
    line="$out$line"
    out=""
    while [[ "$line" =~ ^([^_]*)_([^_]*)_(.*)$ ]]; do
        out+="${BASH_REMATCH[1]}${ITALIC}${BASH_REMATCH[2]}${RESET}"
        line="${BASH_REMATCH[3]}"
    done
    printf '%s' "$out$line"
}

# Metadata box (left): id, authors, size, subs, type, dates, rating, deps, install state
_ws_draw_meta_box() {
    local meta_width=40
    local -a authors=()
    local a
    IFS=',' read -ra authors <<< "${mod[author]}"
    for a in "${!authors[@]}"; do
        authors[$a]="${authors[$a]#"${authors[$a]%%[! ]*}"}"   # trim leading spaces
    done
    [[ ${#authors[@]} -gt 0 ]] || authors=("Unknown")

    # 10 fixed lines + 1 padding + 2 borders, the rest for authors
    local num_authors=${#authors[@]} display_authors=${#authors[@]}
    local meta_height=$((13 + num_authors))
    local max_meta_height=$((TERM_ROWS - 5))
    if [[ $meta_height -gt $max_meta_height ]]; then
        meta_height=$max_meta_height
        display_authors=$((max_meta_height - 13))
    fi
    local show_more_msg=""
    if [[ $num_authors -gt $display_authors ]]; then
        display_authors=$((display_authors - 1))   # last line says how many more
        show_more_msg="... and $((num_authors - display_authors)) more"
    fi
    draw_box 3 2 $meta_height $meta_width "Metadata"

    move_to 5 4; printf "%sID       :%s %s" "$DIM" "$RESET" "$mid"
    move_to 6 4; printf "%sAuthor(s):%s" "$DIM" "$RESET"
    local row=6 i
    for ((i=0; i<display_authors; i++)); do
        move_to $row 15; printf "%s" "${authors[$i]:0:22}"
        row=$((row + 1))
    done
    if [[ -n "$show_more_msg" ]]; then
        move_to $row 15; printf "%s%s%s" "$DIM" "$show_more_msg" "$RESET"
        row=$((row + 1))
    fi
    local rating="? (${mod[rating_count]})"
    [[ "${mod[rating_stars]}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && rating="${mod[rating_stars]}/5 (${mod[rating_count]})"
    local field
    for field in "Size     :${mod[size]}" "Subs     :${mod[subs]}" "Type     :${mod[type]}" "Updated  :${mod[updated]}" \
                 "Released :${mod[released]}" "Rating   :$rating" "Deps     :${mod[deps]}" \
                 "Installed:${mod[installed]}" "Synced   :${mod[synced]}"; do
        move_to $row 4; printf "%s%s:%s %s" "$DIM" "${field%%:*}" "$RESET" "${field#*:}"
        row=$((row + 1))
    done
}

# Description box (right) with paging; keeps the caller's scroll inside the text
_ws_draw_desc_box() {
    local desc_col=$((40 + 4))
    local desc_width=$((TERM_COLS - desc_col - 2))
    local desc_height=$((TERM_ROWS - 6))
    [[ $desc_width -gt 20 ]] || return 0
    draw_box 3 $desc_col $desc_height $desc_width "Description" "$RED"

    local -a lines=()
    mapfile -t lines < <(printf '%b\n' "${mod[desc]}" | fold -s -w $((desc_width - 2)))
    local view_height=$((desc_height - 3))   # keep off the bottom border
    local total_lines=${#lines[@]}
    local max_scroll=$(( ((total_lines - 1) / view_height) * view_height ))
    [[ $max_scroll -lt 0 ]] && max_scroll=0
    [[ $scroll -gt $max_scroll ]] && scroll=$max_scroll

    local i idx line
    for ((i=0; i<view_height && scroll+i<total_lines; i++)); do
        idx=$((scroll + i))
        line="${lines[$idx]}"
        move_to $((5 + i)) $((desc_col + 2))
        if [[ "$line" == ">> "* ]]; then
            printf "%s%s%s" "$RED$BOLD" "${line//>>/}" "$RESET"   # header line
        else
            _ws_style_line "$line"
        fi
    done
    if [[ $total_lines -gt $view_height ]]; then
        local p_str=" Page $(( scroll / view_height + 1 ))/$(( (total_lines + view_height - 1) / view_height )) "
        move_to $((3 + desc_height - 1)) $((desc_col + (desc_width / 2) - (${#p_str} / 2)))
        printf "%s%s%s" "$BG_DARKGRAY" "$p_str" "$RESET"
    fi
}

# Whole details screen for mod id $1 (reads mod[], scroll)
_draw_workshop_details_screen() {
    local mid="$1"
    get_term_size
    printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
    move_to 1 1
    printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_BLUE" "$WHITE$BOLD" "Mod Details: ${mod[name]}" "$RESET"
    if [[ ${#mod[name]} -gt $((TERM_COLS-14)) ]]; then
        move_to 1 14; printf "%s%s" "$BG_BLUE" "${mod[name]:0:$((TERM_COLS-15))}..."
    fi
    move_to 2 1
    printf "%sSteam: https://steamcommunity.com/sharedfiles/filedetails/?id=%s%s" "$DIM" "$mid" "$RESET"
    _ws_draw_meta_box
    _ws_draw_desc_box
    move_to "$TERM_ROWS" 1
    local footer=" [Enter] Install  [b] Steam  [↑↓] Img  [←→] Page  [ Space ] Back "
    printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer" $((TERM_COLS - ${#footer})) "" "$RESET"
}

# [i] image URLs of the mod in a scrollable pane
_ws_images_pane() {
    if [[ ${#mimages[@]} -eq 0 ]]; then
        show_message "No images available" "Info"
        return 0
    fi
    local img_scroll=0 img_view_height=$((TERM_ROWS - 6)) row i ik is
    while true; do
        printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
        move_to 1 1
        printf "%s%s Images (%d) - [↑/↓] Scroll  [Q/Space] Return %s%s" "$BG_RED" "$WHITE$BOLD" "${#mimages[@]}" "${ESC}[K" "$RESET"
        draw_box 3 2 $((TERM_ROWS - 4)) $((TERM_COLS - 3)) "Image URLs" "$RED"
        row=5
        for ((i=img_scroll; i<${#mimages[@]} && row < TERM_ROWS - 2; i++)); do
            move_to $row 4
            printf "%s[%02d] %s%s" "$WHITE" "$((i+1))" "${mimages[$i]}" "$RESET"
            row=$((row + 1))
        done
        IFS= read -rsn1 ik || return 0
        case "$ik" in
            $'\x1b')
                read -rsn2 -t 0.1 is || return 0
                case "$is" in
                    "[A") [[ $img_scroll -gt 0 ]] && img_scroll=$((img_scroll - 1)) ;;
                    "[B") [[ $img_scroll -lt $((${#mimages[@]} - img_view_height)) ]] && img_scroll=$((img_scroll + 1)) ;;
                esac
                ;;
            q|Q|" ") return 0 ;;
        esac
    done
}

# [b] open the Steam page in a browser, or show the URL
_ws_open_steam_page() {
    local url="https://steamcommunity.com/sharedfiles/filedetails/?id=$1"
    if command -v open &>/dev/null; then open "$url" || true
    elif command -v xdg-open &>/dev/null; then xdg-open "$url" &>/dev/null &
    else show_message "URL: $url" "Link"
    fi
}

# Details view of one mod. Returns 10 when the user chose to install it.
# Usage: _view_mod_details "$mod_id" "$instance_dir" "$mods_txt" "$rules_json"
_view_mod_details() {
    local mid="$1" instance_dir="$2" mods_txt="$3"
    echo "STARTING DETAILS for $mid" > "${WORKSHOP_DEBUG_LOG}"
    move_to $((TERM_ROWS / 2)) $((TERM_COLS / 2 - 10))
    printf "%s%s Fetching Full Details... %s" "$BG_BLUE" "$WHITE$BOLD" "$RESET"
    local -A mod=()
    local -a mimages=()
    _ws_fetch_details "$mid"
    _ws_local_details "$mid" "$instance_dir" "$mods_txt"

    local scroll=0 view_height k s
    while true; do
        _draw_workshop_details_screen "$mid"
        view_height=$((TERM_ROWS - 9))   # rows of the description box (see _ws_draw_desc_box)
        IFS= read -rsn1 k || return 0
        case "$k" in
            $'\x1b')
                read -rsn2 -t 0.1 s || return 0   # bare Escape closes
                case "$s" in
                    "[D") scroll=$((scroll - view_height)); [[ $scroll -lt 0 ]] && scroll=0 ;;
                    "[C") scroll=$((scroll + view_height)) ;;
                esac
                ;;
            q|Q|" ") return 0 ;;
            b|B) _ws_open_steam_page "$mid" ;;
            i|I) _ws_images_pane ;;
            "")  return 10 ;;
        esac
    done
}

# =============================================================================
# Steam Workshop: filter dialog and browser loop
# =============================================================================

# Search/sort/limit/mode dialog on the namerefs given as arguments.
# Returns 0 when a value changed, 2 after "Reset All Defaults", 1 on Escape.
_draw_workshop_filter_dialog() {
    local -n _fn=$1 _fs=$2 _fl=$3 _fm=$4
    local d_width=60 d_height=14
    local d_row=$(( (TERM_ROWS - d_height) / 2 ))
    local d_col=$(( (TERM_COLS - d_width) / 2 ))
    local d_sel=0 i k s cur_sort style
    while true; do
        draw_box $d_row $d_col $d_height $d_width "Search Workshop"
        cur_sort="Trend"
        for i in "${!WS_SORT_OPTS[@]}"; do [[ "${WS_SORT_OPTS[$i]}" == "$_fs" ]] && cur_sort="${WS_SORT_NAMES[$i]}"; done
        local -a rows=("Search: [$(printf '%-38s' "${_fn:0:38}")]" "Sort  : < $(printf '%-36s' "$cur_sort") >"
                       "Limit : < $(printf '%-36s' "$_fl") >" "Mode  : < $(printf '%-36s' "$_fm") >" "[ Reset All Defaults ]")
        for i in "${!rows[@]}"; do
            style="$WHITE"; [[ $d_sel -eq $i ]] && style="$RED$BOLD"
            move_to $((d_row + 2 + i * 2)) $((d_col + 2))
            printf "%s%s%s" "$style" "${rows[$i]}" "$RESET"
        done
        move_to $((d_row + 13)) $((d_col + 2))
        printf "[ Enter ] Edit Select  [ Esc ] Close Apply"

        IFS= read -rsn1 k || return 1
        if [[ "$k" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 s || return 1
            case "$s" in
                "[A") [[ $d_sel -gt 0 ]] && d_sel=$((d_sel - 1)) ;;
                "[B") [[ $d_sel -lt 4 ]] && d_sel=$((d_sel + 1)) ;;
            esac
        elif [[ "$k" == "" ]]; then
            case $d_sel in
                0) _fn=$(read_input "Global Search Term" "$_fn" "Search"); return 0 ;;
                1) if run_menu WS_SORT_NAMES "Select Workshop Sort"; then _fs="${WS_SORT_OPTS[$MENU_RESULT]}"; return 0; fi ;;
                2) if run_menu WS_LIMIT_OPTS "Select Items Per Page"; then _fl="${WS_LIMIT_OPTS[$MENU_RESULT]}"; return 0; fi ;;
                3) if run_menu WS_MODE_OPTS "Select Search Mode"; then _fm="${WS_MODE_OPTS[$MENU_RESULT]}"; return 0; fi ;;
                4) _fn="$WS_DEFAULT_TEXT"; _fs="$WS_DEFAULT_SORT"; _fl="Fill"; _fm="Title"; return 2 ;;
            esac
        fi
    done
}

# Show page N from the top; the next loop iteration fetches it
_ws_goto_page() {
    current_page="$1"
    selection=0
    offset=0
    f_changed=1
}

_ws_reset_filters() {
    f_text="$WS_DEFAULT_TEXT"; f_sort="$WS_DEFAULT_SORT"; f_limit="Fill"; f_mode="Title"
    f_clear=1
    _ws_goto_page 1
}

# [f] filter dialog; a change or reset reloads page 1 without the cache
_ws_key_filter() {
    local d_res=0
    _draw_workshop_filter_dialog f_text f_sort f_limit f_mode || d_res=$?
    if [[ $d_res -eq 0 || $d_res -eq 2 ]]; then
        f_clear=1
        _ws_goto_page 1
    fi
}

# Terminal height changed in Fill mode: keep the first visible item on screen
_ws_handle_resize() {
    local new_height
    new_height=$(_ws_view_height)
    if [[ "$f_limit" == "Fill" && $new_height -ne $last_fetch_limit && $last_fetch_limit -gt 0 ]]; then
        local global_idx=$(( (current_page - 1) * last_fetch_limit ))
        f_clear=1
        _ws_goto_page $(( global_idx / new_height + 1 ))
    fi
}

# [Space]/[o] details of the selected result; Enter there installs it
_ws_key_details() {
    [[ $count -gt 0 ]] || return 0
    local mid rest rc=0
    IFS='|' read -r mid rest <<< "${items[$selection]}"
    _view_mod_details "$mid" "$instance_dir" "$mods_txt" "$rules_json" || rc=$?
    [[ $rc -eq 10 ]] && _ws_install_selected
    return 0
}

# Put the confirmed mods into mods.txt: frameworks on top of the load order
# (when wanted), everything else appended. Uses to_install_ids/names and
# frameworks_found of the caller.
_ws_add_to_list() {
    local summary="${to_install_names[*]}"
    [[ ${#to_install_names[@]} -gt 3 ]] && summary="${to_install_names[0]}, ${to_install_names[1]} and $(( ${#to_install_names[@]} - 2 )) more"
    local msg="Install ${#to_install_ids[@]} mod(s): ${summary}"
    [[ ${#to_install_ids[@]} -gt 1 ]] && msg="Mod has dependencies. Install ${#to_install_ids[@]} mods: ${summary}"
    confirm "$msg" "y" || return 0

    local frameworks_on_top=0
    if [[ ${#frameworks_found[@]} -gt 0 ]] && confirm "Move frameworks (${frameworks_found[*]}) to top of load order?" "y"; then
        frameworks_on_top=1
    fi
    local -a top=() bottom=()
    local i
    for i in "${!to_install_ids[@]}"; do
        if [[ $frameworks_on_top -eq 1 && "${workshop_rules[${to_install_ids[$i]}]:-}" == "framework" ]]; then
            top+=("${to_install_ids[$i]}")
        else
            bottom+=("${to_install_ids[$i]}")
        fi
    done
    if [[ ${#top[@]} -gt 0 ]]; then
        { printf '%s\n' "${top[@]}"; cat "$mods_txt" 2>/dev/null; } > "${mods_txt}.tmp" && mv "${mods_txt}.tmp" "$mods_txt"
    fi
    for i in ${bottom[@]+"${bottom[@]}"}; do append_line "$mods_txt" "$i"; done
    touch "${instance_dir}/data/config/.needs_sync"   # Mod Manager shows [SYNC NEEDED]
    f_changed=1
    show_message "Mod(s) added to your list. Run 'Sync' to download." "Added"
}

# [Enter] add the selected mod and its missing dependencies to mods.txt
_ws_install_selected() {
    [[ $count -gt 0 ]] || return 0
    local mid rest
    IFS='|' read -r mid rest <<< "${items[$selection]}"
    if [[ -n "${installed_mods[$mid]:-}" ]]; then
        show_message "This mod is already in your list." "Info"
        return 0
    fi
    echo "INSTALL: Starting for $mid" > "${WORKSHOP_DEBUG_LOG}"
    local chain_json
    chain_json=$(_fetch_workshop_details "$mid" "1" "$rules_json") || chain_json=""
    if [[ -z "$chain_json" ]]; then
        show_message "Failed to fetch dependencies (timeout or network error)." "Error"
        return 0
    fi
    _ws_load_rules   # the recursive fetch may have added frameworks/conflicts
    local -a to_install_ids=() to_install_names=() frameworks_found=()
    local cid cname
    while IFS='|' read -r cid cname; do
        [[ -n "$cid" && -z "${installed_mods[$cid]:-}" ]] || continue
        to_install_ids+=("$cid")
        to_install_names+=("$cname")
        [[ "${workshop_rules[$cid]:-}" == "framework" ]] && frameworks_found+=("$cname")
    done < <(printf '%s' "$chain_json" | _ws_chain_to_rows 2>> "${WORKSHOP_DEBUG_LOG}")
    echo "INSTALL: ${#to_install_ids[@]} mod(s) to add" >> "${WORKSHOP_DEBUG_LOG}"
    if [[ ${#to_install_ids[@]} -eq 0 ]]; then
        show_message "This mod (and dependencies) are already in your list." "Info"
        return 0
    fi
    _ws_add_to_list
}

# Steam Workshop browser: search, page, view details and add mods to mods.txt
# Usage: workshop_browser "$instance_dir"
workshop_browser() {
    local instance_dir="$1"
    local mods_txt="${instance_dir}/data/config/mods.txt"
    local rules_json="${SCRIPT_DIR}/data/workshop_rules.json"
    local f_text="$WS_DEFAULT_TEXT" f_sort="$WS_DEFAULT_SORT" f_limit="Fill" f_mode="Title" current_page=1
    local selection=0 offset=0 f_changed=1 f_clear=0 count=0 fetch_count=0 last_fetch_limit=0
    local -a items=()
    local -A installed_mods=() workshop_rules=()
    local v_height key seq rc
    while true; do
        if [[ $f_changed -eq 1 ]]; then _ws_fetch_page; fi
        v_height=$(_ws_view_height)
        [[ $selection -lt $offset ]] && offset=$selection
        [[ $selection -ge $((offset + v_height)) ]] && offset=$((selection - v_height + 1))
        _draw_workshop_screen

        # the 2 s timeout lets Fill mode react to a resized terminal
        rc=0
        IFS= read -rsn1 -t 2 key || rc=$?
        if [[ $rc -gt 128 ]]; then _ws_handle_resize; continue; fi
        [[ $rc -eq 0 ]] || return 0   # EOF: leave instead of looping
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1 seq || continue   # bare Escape
                case "$seq" in
                    "[A") [[ $selection -gt 0 ]] && selection=$((selection - 1)) ;;
                    "[B") [[ $selection -lt $((count - 1)) ]] && selection=$((selection + 1)) ;;
                    "[C") if [[ $count -gt 0 ]]; then _ws_goto_page $((current_page + 1)); fi ;;
                    "[D") if [[ $current_page -gt 1 ]]; then _ws_goto_page $((current_page - 1)); fi ;;
                esac
                ;;
            q|Q)     return 0 ;;
            f|F)     _ws_key_filter ;;
            c|C)     _ws_reset_filters ;;
            o|O|" ") _ws_key_details ;;
            "")      _ws_install_selected ;;
        esac
    done
}
