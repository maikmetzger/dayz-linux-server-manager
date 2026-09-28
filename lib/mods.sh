#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Mod Management
# =============================================================================
# Steam API mod name cache, mod list parsing, dependency checking
# Requires: lib/utils.sh
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_MODS_LOADED:-}" ]] && return 0
_DAYZ_MODS_LOADED=1

# -----------------------------------------------------------------------------
# Mod Name Cache (Steam API)
# -----------------------------------------------------------------------------

MOD_CACHE_DIR="${HOME}/.cache/dayz-server-manager"
MOD_CACHE_FILE="${MOD_CACHE_DIR}/mod-names.cache"
mkdir -p "$MOD_CACHE_DIR" 2>/dev/null || true

# In-memory cache for fast lookups (associative array)
declare -A MOD_NAME_CACHE=()

# Load cache file into memory
load_mod_cache() {
    MOD_NAME_CACHE=()
    [[ -f "$MOD_CACHE_FILE" ]] || return 0
    while IFS='|' read -r mid mname; do
        [[ -n "$mid" ]] && MOD_NAME_CACHE["$mid"]="$mname"
    done < "$MOD_CACHE_FILE"
}

# Save in-memory cache to file
save_mod_cache() {
    : > "$MOD_CACHE_FILE"
    for mid in "${!MOD_NAME_CACHE[@]}"; do
        echo "${mid}|${MOD_NAME_CACHE[$mid]}" >> "$MOD_CACHE_FILE"
    done
}

# Get mod name from Steam API (with caching)
# Usage: name=$(get_mod_name "1559212036")
get_mod_name() {
    local mod_id="$1"
    
    # Check in-memory cache first
    if [[ -n "${MOD_NAME_CACHE[$mod_id]:-}" ]]; then
        echo "${MOD_NAME_CACHE[$mod_id]}"
        return 0
    fi
    
    # Fetch from Steam API
    local name=""
    if command -v curl &>/dev/null; then
        local response
        response=$(curl -s --max-time 5 \
            "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
            -d "itemcount=1" \
            -d "publishedfileids[0]=$mod_id" 2>/dev/null || true)
        
        if [[ -n "$response" ]]; then
            name=$(echo "$response" | grep -o '"title":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        fi
    fi
    
    # Fallback to ID if API failed
    [[ -z "$name" ]] && name="Workshop $mod_id"
    
    # Cache the result
    MOD_NAME_CACHE["$mod_id"]="$name"
    save_mod_cache
    
    echo "$name"
}

# -----------------------------------------------------------------------------
# Mod List Parsing
# -----------------------------------------------------------------------------

# Read mod IDs with their enabled/disabled status
# Usage: while IFS='|' read -r id status; do ...; done < <(read_mod_ids_with_status "mods.txt")
read_mod_ids_with_status() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines
        [[ -z "$line" ]] && continue
        
        # Check if commented
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]}|disabled"
        elif [[ "$line" =~ ^[[:space:]]*([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]}|enabled"
        fi
    done < "$file"
}

# Get all unique mod IDs from mods.txt and servermods.txt
# Usage: get_all_mod_ids "mods.txt" "servermods.txt"
get_all_mod_ids() {
    local mods_file="$1"
    local servermods_file="$2"
    
    {
        awk '/^[[:space:]]*#?[[:space:]]*[0-9]+/ { gsub(/^[[:space:]]*#?[[:space:]]*/,""); gsub(/[[:space:]]*$/,""); print $1 }' "$mods_file" 2>/dev/null
        awk '/^[[:space:]]*#?[[:space:]]*[0-9]+/ { gsub(/^[[:space:]]*#?[[:space:]]*/,""); gsub(/[[:space:]]*$/,""); print $1 }' "$servermods_file" 2>/dev/null
    } | awk '!seen[$0]++' | grep -E '^[0-9]+$'
}

# Check if mod is in a file (enabled or disabled)
is_mod_in_file() {
    local mod_id="$1"
    local file="$2"
    grep -qE "^[[:space:]]*#?[[:space:]]*${mod_id}[[:space:]]*$" "$file" 2>/dev/null
}

# Get mod type (client, server, both, disabled)
get_mod_type() {
    local mod_id="$1"
    local mods_file="$2"
    local servermods_file="$3"
    
    local in_mods=0 in_servermods=0
    
    grep -qE "^[[:space:]]*${mod_id}[[:space:]]*$" "$mods_file" 2>/dev/null && in_mods=1
    grep -qE "^[[:space:]]*${mod_id}[[:space:]]*$" "$servermods_file" 2>/dev/null && in_servermods=1
    
    if [[ $in_mods -eq 1 && $in_servermods -eq 1 ]]; then
        echo "both"
    elif [[ $in_mods -eq 1 ]]; then
        echo "client"
    elif [[ $in_servermods -eq 1 ]]; then
        echo "server"
    else
        echo "disabled"
    fi
}

# -----------------------------------------------------------------------------
# Mod List Manipulation
# -----------------------------------------------------------------------------

# Add mod to file (or enable if commented)
add_mod_to_file() {
    local mod_id="$1"
    local file="$2"
    if ! grep -qE "^[[:space:]]*#?[[:space:]]*${mod_id}[[:space:]]*$" "$file" 2>/dev/null; then
        append_line "$file" "$mod_id"
    else
        # Enable if commented
        sed -i "s/^[[:space:]]*#[[:space:]]*${mod_id}[[:space:]]*$/${mod_id}/" "$file"
    fi
}

# Remove (comment out) mod from file
remove_mod_from_file() {
    local mod_id="$1"
    local file="$2"
    sed -i "s/^[[:space:]]*${mod_id}[[:space:]]*$/# ${mod_id}/" "$file"
}

# Fully delete mod ID from file (not just comment)
delete_mod_from_file() {
    local mod_id="$1"
    local file="$2"
    [[ -f "$file" ]] && sed -i "/^[[:space:]]*#*[[:space:]]*${mod_id}[[:space:]]*$/d" "$file"
}

# Get mod's .bikey filenames from its keys/ folder
# Usage: while read key; do ...; done < <(get_mod_bikeys "$mod_id" "$workshop_content_path")
get_mod_bikeys() {
    local mod_id="$1"
    local workshop_base="${2:-/dayz/steamapps/workshop/content/221100}"
    local keys_dir="${workshop_base}/${mod_id}/keys"
    
    if [[ -d "$keys_dir" ]]; then
        find "$keys_dir" -maxdepth 1 -name "*.bikey" -exec basename {} \; 2>/dev/null
    fi
}

# Uninstall mod completely
# - Remove from mods.txt/servermods.txt
# - Delete matching .bikey from global keys/ folder
# Returns: number of keys deleted
uninstall_mod() {
    local mod_id="$1"
    local mods_file="$2"
    local servermods_file="$3"
    local server_keys_dir="${4:-/dayz/keys}"
    local workshop_base="${5:-/dayz/steamapps/workshop/content/221100}"
    
    # 1. Remove from both files
    delete_mod_from_file "$mod_id" "$mods_file"
    delete_mod_from_file "$mod_id" "$servermods_file"
    
    # 2. Get and delete .bikey files (if mod folder exists)
    local key_count=0
    local mod_keys_dir="${workshop_base}/${mod_id}/keys"
    if [[ -d "$mod_keys_dir" ]]; then
        while IFS= read -r key; do
            if [[ -n "$key" ]]; then
                local global_key="${server_keys_dir}/${key}"
                if [[ -f "$global_key" ]]; then
                    rm -f "$global_key"
                    key_count=$((key_count + 1))
                fi
            fi
        done < <(get_mod_bikeys "$mod_id" "$workshop_base")
    fi
    
    echo "$key_count"
}

# -----------------------------------------------------------------------------
# Mod Ordering
# -----------------------------------------------------------------------------

move_line_up() {
    local file="$1"
    local pattern="$2"
    [[ -f "$file" ]] || return 1
    
    local line_num
    line_num=$(grep -n "$pattern" "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true)
    
    [[ -z "$line_num" || "$line_num" -le 1 ]] && return 0
    
    local prev_line=$((line_num - 1))
    
    mapfile -t lines < "$file"
    
    local idx=$((line_num - 1))
    local prev_idx=$((prev_line - 1))
    
    local temp="${lines[$idx]}"
    lines[$idx]="${lines[$prev_idx]}"
    lines[$prev_idx]="$temp"
    
    printf "%s\n" "${lines[@]}" > "$file"
}

move_line_down() {
    local file="$1"
    local pattern="$2"
    [[ -f "$file" ]] || return 1
    
    local line_num
    line_num=$(grep -n "$pattern" "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true)
    
    local total_lines
    total_lines=$(wc -l < "$file")
    
    [[ -z "$line_num" || "$line_num" -ge "$total_lines" ]] && return 0
    
    local next_line=$((line_num + 1))
    
    mapfile -t lines < "$file"
    
    local idx=$((line_num - 1))
    local next_idx=$((next_line - 1))
    
    local temp="${lines[$idx]}"
    lines[$idx]="${lines[$next_idx]}"
    lines[$next_idx]="$temp"
    
    printf "%s\n" "${lines[@]}" > "$file"
}

move_mod_up() {
    local mod_id="$1"
    local f1="$2"
    local f2="$3"
    local pattern="^[[:space:]]*#\?[[:space:]]*${mod_id}[[:space:]]*$"
    
    move_line_up "$f1" "$pattern"
    move_line_up "$f2" "$pattern"
}

move_mod_down() {
    local mod_id="$1"
    local f1="$2"
    local f2="$3"
    local pattern="^[[:space:]]*#\?[[:space:]]*${mod_id}[[:space:]]*$"
    
    move_line_down "$f1" "$pattern"
    move_line_down "$f2" "$pattern"
}

# -----------------------------------------------------------------------------
# Dependency Checking
# -----------------------------------------------------------------------------
# Format: "DependentID:RequiredID:ModName"

DEPENDENCY_RULES=(
    # Community Framework (CF) is required by almost everything
    "1564026768:1559212036:CF" # COT -> CF
    "1708571078:1559212036:CF" # VPPAdminTools -> CF
    "2411613529:1559212036:CF" # Dabs Framework -> CF
    "2116151222:1559212036:CF" # Expansion-Core -> CF
    "2275832136:1559212036:CF" # DayZ-Editor -> CF
    
    # Dabs Framework is required by Editor and Expansion
    "2116151222:2411613529:Dabs Framework" # Expansion-Core -> Dabs
    "2275832136:2411613529:Dabs Framework" # DayZ-Editor -> Dabs
    
    # Expansion Core is required by Expansion Modules
    "2116157322:2116151222:Expansion-Core" # Licensed
    "2116177301:2116151222:Expansion-Core" # Vehicles
    "2116153160:2116151222:Expansion-Core" # Market
    "2116176696:2116151222:Expansion-Core" # Quests
    "2116166431:2116151222:Expansion-Core" # AI
    "2116161408:2116151222:Expansion-Core" # Chat
    "2116155694:2116151222:Expansion-Core" # SpawnSelection
)

# Check if mod dependencies are satisfied
# Usage: warning=$(check_mod_dependencies "1564026768" "${mod_ids[@]}")
check_mod_dependencies() {
    local mod_id="$1"
    local -a all_ids=("${@:2}")
    
    local my_index=-1
    for i in "${!all_ids[@]}"; do
        if [[ "${all_ids[$i]}" == "$mod_id" ]]; then
            my_index=$i
            break
        fi
    done
    [[ $my_index -eq -1 ]] && return 0
    
    for rule in "${DEPENDENCY_RULES[@]}"; do
        local dep_id="${rule%%:*}"
        local rest="${rule#*:}"
        local req_id="${rest%%:*}"
        local req_name="${rest#*:}"
        
        if [[ "$mod_id" == "$dep_id" ]]; then
            local req_index=-1
            for j in "${!all_ids[@]}"; do
                if [[ "${all_ids[$j]}" == "$req_id" ]]; then
                    req_index=$j
                    break
                fi
            done
            
            if [[ $req_index -eq -1 ]]; then
                echo "Missing dependency: $req_name ($req_id)"
                return 1
            elif [[ $req_index -gt $my_index ]]; then
                echo "Wrong Order! Must be below $req_name"
                return 1
            fi
        fi
    done

    # 2. Advanced Data-Driven Rule Check (Knowledge Layer)
    check_mod_load_order "$mod_id" "${all_ids[@]}"
    return 0
}

# Initialize cache on load
load_mod_cache

# Check if a mod has its dependencies loaded before it
# Usage: warn=$(check_mod_load_order "$mod_id" "${all_ids[@]}")
check_mod_load_order() {
    local mod_id="$1"
    shift
    local -a current_ids=("$@")
    
    local rules_json="${SCRIPT_DIR}/data/workshop_rules.json"
    [[ -f "$rules_json" ]] || return 0
    
    # Get dependencies from rules
    local deps
    deps=$(python3 -c "import json, sys; r=json.load(open('$rules_json')); print(' '.join(r.get('dependencies', {}).get('$mod_id', [])))" 2>/dev/null || true)
    
    [[ -z "$deps" ]] && return 0
    
    # Check each dependency
    for dep in $deps; do
        local mod_found=0
        local dep_found=0
        local dep_index=-1
        local mod_index=-1
        
        for i in "${!current_ids[@]}"; do
            if [[ "${current_ids[$i]}" == "$dep" ]]; then
                dep_found=1
                dep_index=$i
            fi
            if [[ "${current_ids[$i]}" == "$mod_id" ]]; then
                mod_found=1
                mod_index=$i
            fi
        done
        
        if [[ $dep_found -eq 0 ]]; then
            echo "Missing: $dep"
            return 0
        fi
        
        if [[ $mod_index -lt $dep_index ]]; then
            echo "Order: $dep must be ABOVE"
            return 0
        fi
    done
}

# Check if other installed mods depend on the target mod
# Usage: blocker=$(check_reverse_dependencies "TargetID" "${all_installed_ids[@]}")
# Returns: "Dependent Mod Name" if blocked, stdout empty if safe
check_reverse_dependencies() {
    local target_id="$1"
    local -a installed_ids=("${@:2}")
    
    for rule in "${DEPENDENCY_RULES[@]}"; do
        local dep_id="${rule%%:*}"
        local rest="${rule#*:}"
        local req_id="${rest%%:*}"
        
        # If the rule says "Mod X requires Target Mod"
        # i.e. Target is a dependency for Mod X
        if [[ "$req_id" == "$target_id" ]]; then
            # Check if Mod X (dep_id) is currently installed (i.e. in the list passed to us)
            for installed in "${installed_ids[@]}"; do
                if [[ "$installed" == "$dep_id" ]]; then
                    # Block found!
                    local dep_name=$(get_mod_name "$dep_id")
                    if [[ -z "$dep_name" ]]; then dep_name="Mod $dep_id"; fi
                    echo "$dep_name"
                    return 0
                fi
            done
        fi
    done
}
