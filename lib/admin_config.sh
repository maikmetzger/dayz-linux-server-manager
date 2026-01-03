#!/usr/bin/env bash
# =============================================================================
# DayZ Admin Configuration Manager
# =============================================================================
# Manages admin Steam64 IDs and passwords for VPPAdminTools, COT, ZomBerry,
# Expansion, serverDZ.cfg, and RCON.
# Requires: lib/tui.sh, lib/dialogs.sh, lib/mods.sh
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_ADMIN_CONFIG_LOADED:-}" ]] && return 0
_DAYZ_ADMIN_CONFIG_LOADED=1

# lib/admin_config.sh
ADMIN_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ADMIN_CONFIG_LIB_DIR}/utils.sh"
source "${ADMIN_CONFIG_LIB_DIR}/colors.sh"
source "${ADMIN_CONFIG_LIB_DIR}/dialogs.sh"
source "${ADMIN_CONFIG_LIB_DIR}/tui.sh"
source "${ADMIN_CONFIG_LIB_DIR}/mods.sh"
source "${ADMIN_CONFIG_LIB_DIR}/players.sh"

# =============================================================================
# Admin Tool Registry
# =============================================================================
# Format: "workshop_id|name|config_relative_path|format_type"
# format_type: text_list (one ID per line), json_dir (JSON files per player), json_array (JSON with array)

declare -a ADMIN_TOOL_PATTERNS=(
    "1828439124|VPPAdminTools|VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt|text_list"
    "1564026768|Community Online Tools|PermissionsFramework/Players|json_dir"
    "1582756848|ZomBerry|Zomberry/admins.cfg|text_list"
    "2116151222|DayZ Expansion|ExpansionMod/Settings/PermissionsSettings.json|json_array"
)

# VPP password file path (relative to profile)
VPP_CREDENTIALS_PATH="VPPAdminTools/Permissions/credentials.txt"

# Steam username cache (in-memory)
declare -A STEAM_NAME_CACHE=()

# =============================================================================
# Steam Username Lookup
# =============================================================================

# Get Steam username from Steam64 ID (via community profile scraping)
# Usage: name=$(get_steam_username "76561198012345678")
get_steam_username() {
    local steam_id="$1"
    
    # Check cache first
    if [[ -n "${STEAM_NAME_CACHE[$steam_id]:-}" ]]; then
        echo "${STEAM_NAME_CACHE[$steam_id]}"
        return 0
    fi
    
    # Try to scrape Steam community profile
    local name=""
    if command -v curl &>/dev/null; then
        local response
        response=$(curl -s --max-time 3 "https://steamcommunity.com/profiles/${steam_id}/?xml=1" 2>/dev/null || true)
        
        if [[ -n "$response" ]]; then
            # Extract <steamID> from XML (the display name)
            name=$(echo "$response" | grep -oP '<steamID><!\[CDATA\[\K[^\]]+' | head -1 || true)
        fi
    fi
    
    # Fallback to short ID if lookup failed
    [[ -z "$name" ]] && name="${steam_id: -6}"
    
    # Cache the result
    STEAM_NAME_CACHE["$steam_id"]="$name"
    
    echo "$name"
}

# =============================================================================
# Validation Functions
# =============================================================================

# Validate Steam64 ID format (17 digits starting with 7656119)
# Usage: validate_steam64 "76561198012345678" && echo "Valid"
validate_steam64() {
    local id="$1"
    [[ "$id" =~ ^7656119[0-9]{10}$ ]]
}

# =============================================================================
# Detection Functions
# =============================================================================

# Check if admin tool mod is installed (in mods.txt or servermods.txt)
# Usage: is_admin_tool_installed "1708571078" "$inst_dir"
is_admin_tool_installed() {
    local mod_id="$1"
    local inst_dir="$2"
    
    local mods_file="${inst_dir}/data/config/mods.txt"
    local servermods_file="${inst_dir}/data/config/servermods.txt"
    
    # Check if mod ID exists (enabled, not commented)
    if [[ -f "$mods_file" ]] && grep -qE "^[[:space:]]*${mod_id}[[:space:]]*$" "$mods_file" 2>/dev/null; then
        return 0
    fi
    if [[ -f "$servermods_file" ]] && grep -qE "^[[:space:]]*${mod_id}[[:space:]]*$" "$servermods_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get list of installed admin tools
# Usage: tools=$(get_installed_admin_tools "$inst_dir")
# Returns: pipe-delimited list "mod_id|name|config_path|format"
get_installed_admin_tools() {
    local inst_dir="$1"
    local result=""
    
    for pattern in "${ADMIN_TOOL_PATTERNS[@]}"; do
        IFS='|' read -r mod_id name config_path format <<< "$pattern"
        if is_admin_tool_installed "$mod_id" "$inst_dir"; then
            echo "$pattern"
        fi
    done
}

# =============================================================================
# VPPAdminTools Functions
# =============================================================================

# Get VPP SuperAdmins list
# Usage: admins=$(get_vpp_admins "$profile_dir")
get_vpp_admins() {
    local profile_dir="$1"
    local file="${profile_dir}/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt"
    
    if [[ -f "$file" ]]; then
        grep -E '^[0-9]+$' "$file" 2>/dev/null || true
    fi
}

# Add admin to VPP
# Usage: add_vpp_admin "$profile_dir" "76561198012345678"
add_vpp_admin() {
    local profile_dir="$1"
    local steam_id="$2"
    local dir="${profile_dir}/VPPAdminTools/Permissions/SuperAdmins"
    local file="${dir}/SuperAdmins.txt"
    
    mkdir -p "$dir"
    
    # Check if already exists
    if [[ -f "$file" ]] && grep -qE "^${steam_id}$" "$file" 2>/dev/null; then
        return 0  # Already exists
    fi
    
    echo "$steam_id" >> "$file"
}

# Remove admin from VPP
# Usage: remove_vpp_admin "$profile_dir" "76561198012345678"
remove_vpp_admin() {
    local profile_dir="$1"
    local steam_id="$2"
    local file="${profile_dir}/VPPAdminTools/Permissions/SuperAdmins/SuperAdmins.txt"
    
    if [[ -f "$file" ]]; then
        sed -i "/^${steam_id}$/d" "$file"
    fi
}

# Get VPP password
# Usage: password=$(get_vpp_password "$profile_dir")
get_vpp_password() {
    local profile_dir="$1"
    local file="${profile_dir}/${VPP_CREDENTIALS_PATH}"
    
    if [[ -f "$file" ]]; then
        head -n 1 "$file" 2>/dev/null || true
    fi
}

# Set VPP password
# Usage: set_vpp_password "$profile_dir" "MyPassword"
set_vpp_password() {
    local profile_dir="$1"
    local password="$2"
    local dir="${profile_dir}/VPPAdminTools/Permissions"
    local file="${dir}/credentials.txt"
    
    mkdir -p "$dir"
    echo "$password" > "$file"
}

# =============================================================================
# ZomBerry Functions
# =============================================================================

# Get ZomBerry admins list
get_zomberry_admins() {
    local profile_dir="$1"
    local file="${profile_dir}/Zomberry/admins.cfg"
    
    if [[ -f "$file" ]]; then
        grep -E '^[0-9]+$' "$file" 2>/dev/null || true
    fi
}

# Add admin to ZomBerry
add_zomberry_admin() {
    local profile_dir="$1"
    local steam_id="$2"
    local dir="${profile_dir}/Zomberry"
    local file="${dir}/admins.cfg"
    
    mkdir -p "$dir"
    
    if [[ -f "$file" ]] && grep -qE "^${steam_id}$" "$file" 2>/dev/null; then
        return 0
    fi
    
    echo "$steam_id" >> "$file"
}

# Remove admin from ZomBerry
remove_zomberry_admin() {
    local profile_dir="$1"
    local steam_id="$2"
    local file="${profile_dir}/Zomberry/admins.cfg"
    
    if [[ -f "$file" ]]; then
        sed -i "/^${steam_id}$/d" "$file"
    fi
}

# =============================================================================
# Community Online Tools (COT) Functions
# =============================================================================

# Get COT admins (Steam64 IDs from JSON filenames with Admin role)
get_cot_admins() {
    local profile_dir="$1"
    local dir="${profile_dir}/PermissionsFramework/Players"
    
    if [[ ! -d "$dir" ]]; then
        return
    fi
    
    # List JSON files and check if they have Admin role
    for json_file in "$dir"/*.json; do
        [[ -f "$json_file" ]] || continue
        local filename=$(basename "$json_file" .json)
        
        # Check if file contains Admin role
        if grep -qiE '"(RoleName|Roles)".*[:\[].*"Admin"' "$json_file" 2>/dev/null; then
            echo "$filename"
        fi
    done
}

# Add admin to COT (create JSON file)
add_cot_admin() {
    local profile_dir="$1"
    local steam_id="$2"
    local dir="${profile_dir}/PermissionsFramework/Players"
    local file="${dir}/${steam_id}.json"
    
    mkdir -p "$dir"
    
    # Create admin JSON file
    cat > "$file" << EOF
{
    "Steam64ID": "${steam_id}",
    "RoleName": "Admin"
}
EOF
}

# Remove admin from COT (delete or reset JSON file)
remove_cot_admin() {
    local profile_dir="$1"
    local steam_id="$2"
    local file="${profile_dir}/PermissionsFramework/Players/${steam_id}.json"
    
    if [[ -f "$file" ]]; then
        # Reset to Everyone role instead of deleting
        cat > "$file" << EOF
{
    "Steam64ID": "${steam_id}",
    "RoleName": "Everyone"
}
EOF
    fi
}

# =============================================================================
# DayZ Expansion Functions
# =============================================================================

# Get Expansion admins from JSON
get_expansion_admins() {
    local profile_dir="$1"
    local file="${profile_dir}/ExpansionMod/Settings/PermissionsSettings.json"
    
    if [[ -f "$file" ]]; then
        python3 -c "
import json
try:
    with open('$file', 'r') as f:
        data = json.load(f)
    for admin in data.get('Admins', []):
        print(admin)
except: pass
" 2>/dev/null
    fi
}

# Add admin to Expansion
add_expansion_admin() {
    local profile_dir="$1"
    local steam_id="$2"
    local dir="${profile_dir}/ExpansionMod/Settings"
    local file="${dir}/PermissionsSettings.json"
    
    mkdir -p "$dir"
    
    python3 << EOF
import json
import os

file_path = '$file'
steam_id = '$steam_id'

data = {"EnablePermissions": 1, "Admins": []}

if os.path.exists(file_path):
    try:
        with open(file_path, 'r') as f:
            data = json.load(f)
    except: pass

if 'Admins' not in data:
    data['Admins'] = []

if steam_id not in data['Admins']:
    data['Admins'].append(steam_id)

with open(file_path, 'w') as f:
    json.dump(data, f, indent=2)
EOF
}

# Remove admin from Expansion
remove_expansion_admin() {
    local profile_dir="$1"
    local steam_id="$2"
    local file="${profile_dir}/ExpansionMod/Settings/PermissionsSettings.json"
    
    if [[ -f "$file" ]]; then
        python3 << EOF
import json

file_path = '$file'
steam_id = '$steam_id'

try:
    with open(file_path, 'r') as f:
        data = json.load(f)
    
    if 'Admins' in data and steam_id in data['Admins']:
        data['Admins'].remove(steam_id)
        
        with open(file_path, 'w') as f:
            json.dump(data, f, indent=2)
except: pass
EOF
    fi
}

# =============================================================================
# serverDZ.cfg Admin Password Functions
# =============================================================================

# Get DayZ admin password from serverDZ.cfg
get_dayz_admin_password() {
    local config_dir="$1"
    local file="${config_dir}/serverDZ.cfg"
    
    if [[ -f "$file" ]]; then
        grep -oP 'passwordAdmin\s*=\s*"\K[^"]*' "$file" 2>/dev/null || true
    fi
}

# Set DayZ admin password in serverDZ.cfg
set_dayz_admin_password() {
    local config_dir="$1"
    local password="$2"
    local file="${config_dir}/serverDZ.cfg"
    
    if [[ -f "$file" ]]; then
        if grep -qE '^passwordAdmin\s*=' "$file"; then
            sed -i "s/^passwordAdmin\s*=.*/passwordAdmin = \"${password}\";/" "$file"
        else
            echo "passwordAdmin = \"${password}\";" >> "$file"
        fi
    fi
}

# =============================================================================
# BEServer RCON Password Functions
# =============================================================================

# Get RCON password from BEServer_x64.cfg
get_rcon_password() {
    local config_dir="$1"
    local file="${config_dir}/BEServer_x64.cfg"
    
    if [[ -f "$file" ]]; then
        # Use awk to extract password (same as rcon.sh)
        grep "^RConPassword" "$file" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo ""
    fi
}

# Set RCON password in BEServer_x64.cfg
set_rcon_password() {
    local config_dir="$1"
    local password="$2"
    local file="${config_dir}/BEServer_x64.cfg"
    
    # Create file if it doesn't exist
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        echo "RConPassword ${password}" > "$file"
        return 0
    fi
    
    if grep -qE '^RConPassword' "$file"; then
        sed -i "s/^RConPassword.*/RConPassword ${password}/" "$file"
    else
        echo "RConPassword ${password}" >> "$file"
    fi
}

# =============================================================================
# Generic Admin Functions (by tool type)
# =============================================================================

# Get admins for a specific tool
# Usage: admins=$(get_tool_admins "$profile_dir" "VPPAdminTools")
get_tool_admins() {
    local profile_dir="$1"
    local tool_name="$2"
    
    case "$tool_name" in
        "VPPAdminTools") get_vpp_admins "$profile_dir" ;;
        "Community Online Tools") get_cot_admins "$profile_dir" ;;
        "ZomBerry") get_zomberry_admins "$profile_dir" ;;
        "DayZ Expansion") get_expansion_admins "$profile_dir" ;;
    esac
}

# Add admin for a specific tool
add_tool_admin() {
    local profile_dir="$1"
    local tool_name="$2"
    local steam_id="$3"
    
    case "$tool_name" in
        "VPPAdminTools") add_vpp_admin "$profile_dir" "$steam_id" ;;
        "Community Online Tools") add_cot_admin "$profile_dir" "$steam_id" ;;
        "ZomBerry") add_zomberry_admin "$profile_dir" "$steam_id" ;;
        "DayZ Expansion") add_expansion_admin "$profile_dir" "$steam_id" ;;
    esac
}

# Remove admin for a specific tool
remove_tool_admin() {
    local profile_dir="$1"
    local tool_name="$2"
    local steam_id="$3"
    
    case "$tool_name" in
        "VPPAdminTools") remove_vpp_admin "$profile_dir" "$steam_id" ;;
        "Community Online Tools") remove_cot_admin "$profile_dir" "$steam_id" ;;
        "ZomBerry") remove_zomberry_admin "$profile_dir" "$steam_id" ;;
        "DayZ Expansion") remove_expansion_admin "$profile_dir" "$steam_id" ;;
    esac
}

# =============================================================================
# Admin Tools TUI - Main Menu
# =============================================================================

admin_tools_menu() {
    local inst_dir="$1"
    
    while true; do
        local -a items=(
            "👥|Players"
            "🚫|Ban List"
            "🔑|Passwords"
            "--------------------"
            "←|Back"
        )
        
        if ! run_menu items "Admin Tools"; then
            return
        fi
        
        local selected_item="${items[$MENU_RESULT]}"
        
        case "$selected_item" in
            "👥|Players")
                players_menu "$inst_dir"
                ;;
            "🚫|Ban List")
                ban_list_menu "$inst_dir"
                ;;
            "🔑|Passwords")
                passwords_menu "$inst_dir"
                ;;
            "←|Back"|----*)
                [[ "$selected_item" == "←|Back" ]] && return
                ;;
        esac
    done
}

# =============================================================================
# Passwords Menu (Admin IDs & Passwords)
# =============================================================================

passwords_menu() {
    local inst_dir="$1"
    local profile_dir="${inst_dir}/data/profile"
    local config_dir="${inst_dir}/data/config"
    
    while true; do
        local -a items=()
        local -a tool_data=()
        
        # Add installed admin tools
        local has_tools=0
        for pattern in "${ADMIN_TOOL_PATTERNS[@]}"; do
            IFS='|' read -r mod_id name config_path format <<< "$pattern"
            if is_admin_tool_installed "$mod_id" "$inst_dir"; then
                has_tools=1
                local admin_count=0
                local admins
                admins=$(get_tool_admins "$profile_dir" "$name")
                [[ -n "$admins" ]] && admin_count=$(echo "$admins" | wc -l)
                
                local status_icon="⚠"
                [[ $admin_count -gt 0 ]] && status_icon="✓"
                
                items+=("${status_icon}|${name} (${admin_count} admins)")
                tool_data+=("$pattern")
            fi
        done
        
        # Separator if we have mod tools
        if [[ $has_tools -eq 1 ]]; then
            items+=("--------------------")
            tool_data+=("")
        fi
        
        # Always show base DayZ and RCON options
        local dayz_pw
        dayz_pw=$(get_dayz_admin_password "$config_dir")
        local dayz_status="⚠"
        [[ -n "$dayz_pw" ]] && dayz_status="✓"
        items+=("${dayz_status}|DayZ Admin Password")
        tool_data+=("DAYZ_ADMIN")
        
        local rcon_pw
        rcon_pw=$(get_rcon_password "$config_dir")
        local rcon_status="⚠"
        [[ -n "$rcon_pw" ]] && rcon_status="✓"
        items+=("${rcon_status}|RCON Password")
        tool_data+=("RCON")
        
        items+=("--------------------")
        items+=("←|Back")
        tool_data+=("")
        tool_data+=("")
        
        if ! run_menu items "Passwords - Admin IDs & Server Passwords"; then
            return
        fi
        
        local selected_item="${items[$MENU_RESULT]}"
        local selected_data="${tool_data[$MENU_RESULT]}"
        
        if [[ "$selected_item" == "←|Back" || "$selected_item" == ----* ]]; then
            [[ "$selected_item" == "←|Back" ]] && return
            continue
        fi
        
        # Handle selection
        case "$selected_data" in
            "DAYZ_ADMIN")
                admin_password_dialog "$config_dir" "DayZ Admin" "dayz"
                ;;
            "RCON")
                admin_password_dialog "$config_dir" "RCON" "rcon"
                ;;
            *)
                if [[ -n "$selected_data" ]]; then
                    IFS='|' read -r mod_id name config_path format <<< "$selected_data"
                    admin_tool_submenu "$inst_dir" "$name" "$format"
                fi
                ;;
        esac
    done
}

# =============================================================================
# Admin Tool Sub-Menu (Per Tool)
# =============================================================================

admin_tool_submenu() {
    local inst_dir="$1"
    local tool_name="$2"
    local format="$3"
    local profile_dir="${inst_dir}/data/profile"
    
    while true; do
        local -a items=()
        
        # Show current admins
        local admins
        admins=$(get_tool_admins "$profile_dir" "$tool_name")
        
        items+=("➕|Add Admin Steam64 ID")
        
        # VPP-specific: password option
        if [[ "$tool_name" == "VPPAdminTools" ]]; then
            local vpp_pw
            vpp_pw=$(get_vpp_password "$profile_dir")
            local pw_status="⚠ Not Set"
            [[ -n "$vpp_pw" ]] && pw_status="✓ Set"
            items+=("🔑|Set VPP Password ($pw_status)")
        fi
        
        items+=("--------------------")
        
        # List current admins for removal (with Steam names)
        if [[ -n "$admins" ]]; then
            while IFS= read -r admin_id; do
                if [[ -n "$admin_id" ]]; then
                    local steam_name
                    steam_name=$(get_steam_username "$admin_id")
                    items+=("🗑|Remove: $admin_id ($steam_name)")
                fi
            done <<< "$admins"
        else
            items+=("  |No admins configured")
        fi
        
        items+=("--------------------")
        items+=("←|Back")
        
        if ! run_menu items "$tool_name - Admin Management"; then
            return
        fi
        
        local selected_item="${items[$MENU_RESULT]}"
        
        if [[ "$selected_item" == "←|Back" ]]; then
            return
        elif [[ "$selected_item" == ----* || "$selected_item" == "  |No admins configured" ]]; then
            continue
        elif [[ "$selected_item" == "➕|Add Admin Steam64 ID" ]]; then
            admin_add_steam_id "$profile_dir" "$tool_name"
        elif [[ "$selected_item" == "🔑|Set VPP Password"* ]]; then
            admin_vpp_password_dialog "$profile_dir"
        elif [[ "$selected_item" == "🗑|Remove:"* ]]; then
            # Extract Steam64 ID (format: "🗑|Remove: 76561198012345678 (Name)")
            local full_text="${selected_item#*Remove: }"
            local steam_id="${full_text%% (*}"  # Remove " (Name)" suffix
            local steam_name="${full_text#*\(}"
            steam_name="${steam_name%)}"
            if confirm "Remove admin '$steam_name' ($steam_id) from $tool_name?"; then
                remove_tool_admin "$profile_dir" "$tool_name" "$steam_id"
                show_message "Removed $steam_name from $tool_name" "Success"
            fi
        fi
    done
}

# =============================================================================
# Dialogs
# =============================================================================

# Add Steam64 ID dialog
admin_add_steam_id() {
    local profile_dir="$1"
    local tool_name="$2"
    
    local steam_id
    steam_id=$(read_input "Steam64 ID (17 digits):" "" "Add Admin")
    
    if [[ -z "$steam_id" ]]; then
        return  # Cancelled/empty
    fi
    
    if ! validate_steam64 "$steam_id"; then
        show_message "Invalid Steam64 ID format.\nMust be 17 digits starting with 7656119" "Error"
        return
    fi
    
    add_tool_admin "$profile_dir" "$tool_name" "$steam_id"
    show_message "Added $steam_id to $tool_name" "Success"
}

# VPP Password dialog
admin_vpp_password_dialog() {
    local profile_dir="$1"
    
    local current_pw
    current_pw=$(get_vpp_password "$profile_dir")
    
    local new_pw
    new_pw=$(read_input "Enter new password:" "" "VPP Admin Password")
    
    if [[ -n "$new_pw" ]]; then
        set_vpp_password "$profile_dir" "$new_pw"
        show_message "VPP password updated" "Success"
    fi
}

# Generic password dialog (DayZ Admin / RCON)
admin_password_dialog() {
    local config_dir="$1"
    local label="$2"
    local type="$3"
    
    local current_pw
    if [[ "$type" == "dayz" ]]; then
        current_pw=$(get_dayz_admin_password "$config_dir")
    else
        current_pw=$(get_rcon_password "$config_dir")
    fi
    
    local new_pw
    new_pw=$(read_input "Enter new password:" "" "$label Password")
    
    if [[ -n "$new_pw" ]]; then
        if [[ "$type" == "dayz" ]]; then
            set_dayz_admin_password "$config_dir" "$new_pw"
        else
            set_rcon_password "$config_dir" "$new_pw"
        fi
        show_message "$label password updated" "Success"
    fi
}
