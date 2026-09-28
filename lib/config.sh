#!/usr/bin/env bash
# =============================================================================
# DayZ Config Editor - TUI Wrapper
# =============================================================================
# Provides file selection, category navigation, and inline editing for
# DayZ server configuration files.
# =============================================================================

# Ensure script directory is set (should be sourced from server-manager.sh)
[[ -z "${SCRIPT_DIR:-}" ]] && SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# =============================================================================
# Config Registry
# =============================================================================
# Format: "parser|relative_path|icon|label"

# Helper to find types.xml within mpmissions
find_types_xml() {
    local inst_dir="$1"
    local mission_path=$(get_mission_path "$inst_dir")
    
    if [[ -n "$mission_path" ]]; then
        # 1. Standard DB location
        local p="${mission_path}/db/types.xml"
        [[ -f "$p" ]] && { echo "$p"; return; }
        
        # 2. Search anywhere inside mission folder
        local m_search
        m_search=$(find "$mission_path" -name "types.xml" -type f 2>/dev/null | head -n 1)
        [[ -n "$m_search" ]] && { echo "$m_search"; return; }
    fi
    
    # Global search fallback (increased depth for complex server layouts)
    find "${inst_dir}" -maxdepth 8 -name "types.xml" -type f 2>/dev/null | head -n 1
}

# =============================================================================
# Category Definitions for serverDZ.cfg
# =============================================================================
# Use simple keys (no emojis) for reliable associative array lookup
declare -A SERVERDZ_CATEGORIES=(
    ["General"]="hostname,description,maxPlayers,password,passwordAdmin,instanceId,motd,motdInterval"
    ["Security"]="verifySignatures,BattlEye,forceSameBuild,allowFilePatching,disableMultiAccountMitigation,speedhackDetection"
    ["Gameplay"]="disable3rdPerson,disableCrosshair,enableCfgGameplayFile,lightingConfig,disablePersonalLight,disableBaseDamage,disableContainerDamage,disableRespawnDialog,shotValidation"
    ["Network"]="steamQueryPort,clientPort,guaranteedUpdates,loginQueueConcurrentPlayers,loginQueueMaxPlayers,pingWarning,pingCritical,MaxPing,serverFpsWarning,simulatedPlayersBatch,multithreadedReplication"
    ["Time"]="serverTime,serverTimeAcceleration,serverTimePersistent,serverNightTimeAcceleration"
    ["Persistence"]="storeHouseStateDisabled,storageAutoFix,lootHistory"
    ["Voice"]="disableVoN,vonCodecQuality"
    ["Logging"]="logFile,timeStampFormat,logAverageFps,logMemory,logPlayers,enableDebugMonitor,adminLogPlayerHitsOnly,adminLogPlacement,adminLogBuildActions,adminLogPlayerList"
    ["NetworkRange"]="networkRangeClose,networkRangeNear,networkRangeFar,networkRangeDistantEffect,defaultVisibility,defaultObjectViewDistance"
    ["NetworkBatch"]="networkObjectBatchLogSlow,networkObjectBatchEnforceBandwidthLimits,networkObjectBatchUseEstimatedBandwidth,networkObjectBatchUseDynamicMaximumBandwidth,networkObjectBatchBandwidthLimit,networkObjectBatchCompute,networkObjectBatchSendCreate,networkObjectBatchSendDelete"
)

# Display names with icons (pipe-delimited for column alignment)
declare -A SERVERDZ_CATEGORY_DISPLAY=(
    ["General"]="🏠|General"
    ["Security"]="🔒|Security"
    ["Gameplay"]="🎮|Gameplay"
    ["Time"]="⏱️|Time & Weather"
    ["Network"]="🌐|Network"
    ["Persistence"]="💾|Persistence"
    ["Voice"]="🎤|Voice Chat"
    ["Logging"]="📝|Logging"
    ["NetworkRange"]="📡|Network Range"
    ["NetworkBatch"]="📦|Network Batch"
)

# Order for category display (simple keys)
SERVERDZ_CATEGORY_ORDER=(
    "General"
    "Security"
    "Gameplay"
    "Time"
    "Network"
    "Persistence"
    "Voice"
    "Logging"
    "NetworkRange"
    "NetworkBatch"
)

# Defaults for reference
declare -A SERVERDZ_DEFAULTS=(
    ["hostname"]="EXAMPLE NAME"
    ["description"]="Some description"
    ["password"]=""
    ["passwordAdmin"]=""
    ["enableWhitelist"]="0"
    ["disableBanlist"]="0"
    ["disablePrioritylist"]="0"
    ["maxPlayers"]="60"
    ["verifySignatures"]="2"
    ["forceSameBuild"]="1"
    ["disableVoN"]="0"
    ["vonCodecQuality"]="20"
    ["disable3rdPerson"]="0"
    ["disableCrosshair"]="0"
    ["serverTime"]="SystemTime"
    ["serverTimeAcceleration"]="1"
    ["serverNightTimeAcceleration"]="1"
    ["serverTimePersistent"]="0"
    ["guaranteedUpdates"]="1"
    ["loginQueueConcurrentPlayers"]="5"
    ["loginQueueMaxPlayers"]="500"
    ["instanceId"]="1"
    ["storageAutoFix"]="1"
    ["respawnTime"]="5"
    ["motd"]=""
    ["motdInterval"]="1"
    ["timeStampFormat"]="Short"
    ["logAverageFps"]="1"
    ["logMemory"]="1"
    ["logPlayers"]="1"
    ["logFile"]="server_console.log"
    ["adminLogPlayerHitsOnly"]="0"
    ["adminLogPlacement"]="0"
    ["adminLogBuildActions"]="0"
    ["adminLogPlayerList"]="0"
    ["disableMultiAccountMitigation"]="0"
    ["enableDebugMonitor"]="1"
    ["steamQueryPort"]="2305"
    ["allowFilePatching"]="1"
    ["simulatedPlayersBatch"]="20"
    ["multithreadedReplication"]="1"
    ["speedhackDetection"]="1"
    ["networkRangeClose"]="20"
    ["networkRangeNear"]="150"
    ["networkRangeFar"]="1000"
    ["networkRangeDistantEffect"]="4000"
    ["networkObjectBatchLogSlow"]="5"
    ["networkObjectBatchEnforceBandwidthLimits"]="1"
    ["networkObjectBatchUseEstimatedBandwidth"]="0"
    ["networkObjectBatchUseDynamicMaximumBandwidth"]="1"
    ["networkObjectBatchBandwidthLimit"]="0.8"
    ["networkObjectBatchCompute"]="1000"
    ["networkObjectBatchSendCreate"]="10"
    ["networkObjectBatchSendDelete"]="10"
    ["defaultVisibility"]="1375"
    ["defaultObjectViewDistance"]="1375"
    ["lightingConfig"]="0"
    ["disablePersonalLight"]="1"
    ["disableBaseDamage"]="0"
    ["disableContainerDamage"]="0"
    ["disableRespawnDialog"]="0"
    ["pingWarning"]="200"
    ["pingCritical"]="250"
    ["MaxPing"]="300"
    ["serverFpsWarning"]="15"
    ["shotValidation"]="1"
    ["clientPort"]="2304"
)

# Descriptions/Memos (Truncated for column, detail view available)
declare -A SERVERDZ_MEMOS=(
    ["hostname"]="Server name displayed in browser"
    ["description"]="Displayed in browser details (max 255 chars)"
    ["password"]="Connection password (leave empty for public)"
    ["passwordAdmin"]="RCON/Admin password"
    ["enableWhitelist"]="Enable whitelist (value 0-1)"
    ["disableBanlist"]="Disable ban.txt (0=use banlist)"
    ["disablePrioritylist"]="Disable priority.txt (0=use prioritylist)"
    ["maxPlayers"]="Maximum concurrent players"
    ["verifySignatures"]="Verify .pbos against .bisign (2=recommended)"
    ["forceSameBuild"]="Allow only same .exe revision (value 0-1)"
    ["disableVoN"]="Disable Voice over Network (value 0-1)"
    ["vonCodecQuality"]="VoN codec quality (0-20)"
    ["disable3rdPerson"]="Toggle 3rd person (0=enabled, 1=1st person only)"
    ["disableCrosshair"]="Toggle crosshair (0=enabled, 1=disabled)"
    ["serverTime"]="Initial time (SystemTime or YYYY/MM/DD/HH/MM)"
    ["serverTimeAcceleration"]="Time multiplier (0.1-64)"
    ["serverNightTimeAcceleration"]="Night multiplier (multiplies acceleration)"
    ["serverTimePersistent"]="Save time state on shutdown (value 0-1)"
    ["guaranteedUpdates"]="Communication protocol (use 1)"
    ["loginQueueConcurrentPlayers"]="Max logins processing concurrently"
    ["loginQueueMaxPlayers"]="Max players in waiting queue"
    ["instanceId"]="Unique instance ID for storage folders"
    ["storageAutoFix"]="Auto-replace corrupted persistence files (value 0-1)"
    ["respawnTime"]="Delay before respawn (seconds)"
    ["motd"]="Message of the Day"
    ["motdInterval"]="Seconds between MOTD messages"
    ["timeStampFormat"]="Log format (Full/Short)"
    ["logAverageFps"]="Log average FPS (needs -doLogs)"
    ["logMemory"]="Log memory usage (needs -doLogs)"
    ["logPlayers"]="Log player count (needs -doLogs)"
    ["logFile"]="Console log filename"
    ["adminLogPlayerHitsOnly"]="Log only player hits (0=all hits)"
    ["adminLogPlacement"]="Log placement actions (traps/tents)"
    ["adminLogBuildActions"]="Log basebuilding (build/dismantle)"
    ["adminLogPlayerList"]="Log player list every 5 min"
    ["disableMultiAccountMitigation"]="Disable console multi-account checks"
    ["enableDebugMonitor"]="Show debug window on client (0-1)"
    ["steamQueryPort"]="Steam query port (fixes visibility issues)"
    ["allowFilePatching"]="Allow clients with -filePatching"
    ["simulatedPlayersBatch"]="Max players simulated per frame"
    ["multithreadedReplication"]="Enable multithreaded replication (0-1)"
    ["speedhackDetection"]="Detection level (1 strict - 10 benevolent)"
    ["networkRangeClose"]="Bubble for close objects (meters, default 20)"
    ["networkRangeNear"]="Bubble for near inventory items (m, default 150)"
    ["networkRangeFar"]="Bubble for far objects (m, default 1000)"
    ["networkRangeDistantEffect"]="Bubble for effects (m, default 4000)"
    ["networkObjectBatchLogSlow"]="Log slow bubbles > N seconds"
    ["networkObjectBatchEnforceBandwidthLimits"]="Enable bandwidth limiter (0-1)"
    ["networkObjectBatchUseEstimatedBandwidth"]="Bandwidth method (0=actual, 1=estimated)"
    ["networkObjectBatchUseDynamicMaximumBandwidth"]="Dynamic max bandwidth (0=hard limit)"
    ["networkObjectBatchBandwidthLimit"]="Bandwidth limit value"
    ["networkObjectBatchCompute"]="Objects checked per frame"
    ["networkObjectBatchSendCreate"]="Max objects sent for creation"
    ["networkObjectBatchSendDelete"]="Max objects sent for deletion"
    ["defaultVisibility"]="Max terrain render distance (meters)"
    ["defaultObjectViewDistance"]="Max object render distance (meters)"
    ["lightingConfig"]="Lighting (0=bright, 1=dark, 2=Sakhal)"
    ["disablePersonalLight"]="Disable personal light (1=disabled)"
    ["disableBaseDamage"]="Disable fence/tower damage (1=disabled)"
    ["disableContainerDamage"]="Disable tent/barrel damage (1=disabled)"
    ["disableRespawnDialog"]="Disable respawn dialog (1=random spawn)"
    ["pingWarning"]="Yellow ping warning threshold (ms)"
    ["pingCritical"]="Red ping warning threshold (ms)"
    ["MaxPing"]="Kick player threshold (ms)"
    ["serverFpsWarning"]="Yellow FPS warning threshold"
    ["shotValidation"]="Enable shot validation (0-1)"
    ["clientPort"]="Force client connection port"
)

# Validation Rules (Format: type[:min[-max]])
# Types: int, float, bool (0/1), string
declare -A SERVERDZ_VALIDATION=(
    ["hostname"]="string:1-255"
    ["description"]="string:0-255"
    ["password"]="string:0-32"
    ["passwordAdmin"]="string:0-32"
    ["enableWhitelist"]="bool"
    ["disableBanlist"]="bool"
    ["disablePrioritylist"]="bool"
    ["maxPlayers"]="int:1-127"
    ["verifySignatures"]="int:0-2"
    ["forceSameBuild"]="bool"
    ["disableVoN"]="bool"
    ["vonCodecQuality"]="int:0-30"
    ["disable3rdPerson"]="bool"
    ["disableCrosshair"]="bool"
    ["serverTime"]="string"
    ["serverTimeAcceleration"]="float:0.1-64"
    ["serverNightTimeAcceleration"]="float:0.1-64"
    ["serverTimePersistent"]="bool"
    ["guaranteedUpdates"]="int:1-1"
    ["loginQueueConcurrentPlayers"]="int:1-100"
    ["loginQueueMaxPlayers"]="int:1-2000"
    ["instanceId"]="int:1-255"
    ["storageAutoFix"]="bool"
    ["respawnTime"]="int:0-3600"
    ["motd"]="string"
    ["motdInterval"]="int:1-3600"
    ["BattlEye"]="bool"
    ["steamQueryPort"]="int:1024-65535"
    ["allowFilePatching"]="bool"
    ["adminLogPlayerHitsOnly"]="bool"
    ["adminLogPlacement"]="bool"
    ["adminLogBuildActions"]="bool"
    ["adminLogPlayerList"]="bool"
    ["disableMultiAccountMitigation"]="bool"
    ["enableDebugMonitor"]="bool"
    ["timeStampFormat"]="enum:Short,Full"
    ["logAverageFps"]="int:1-3600"
    ["logMemory"]="int:1-3600"
    ["logPlayers"]="int:1-3600"
    ["multithreadedReplication"]="bool"
    ["speedhackDetection"]="int:1-10"
    ["networkRangeClose"]="int:1-10000"
    ["networkRangeNear"]="int:1-10000"
    ["networkRangeFar"]="int:1-10000"
    ["networkRangeDistantEffect"]="int:1-10000"
    ["networkObjectBatchEnforceBandwidthLimits"]="bool"
    ["defaultVisibility"]="int:100-10000"
    ["defaultObjectViewDistance"]="int:100-10000"
    ["lightingConfig"]="int:0-2"
    ["disablePersonalLight"]="bool"
    ["disableBaseDamage"]="bool"
    ["disableContainerDamage"]="bool"
    ["disableRespawnDialog"]="bool"
    ["pingWarning"]="int:0-2000"
    ["pingCritical"]="int:0-2000"
    ["MaxPing"]="int:0-2000"
    ["serverFpsWarning"]="int:11-200"
    ["shotValidation"]="bool"
    ["clientPort"]="int:1024-65535"
)

# =============================================================================
# Category Definitions for BEServer_x64.cfg
# =============================================================================
declare -A BESERVER_CATEGORIES=(
    ["RCON"]="RConPassword,RConPort,RestrictRCon"
)
declare -A BESERVER_CATEGORY_DISPLAY=(
    ["RCON"]="🔐|RCON Settings"
)
BESERVER_CATEGORY_ORDER=("RCON")

declare -A BESERVER_DEFAULTS=(
    ["RConPassword"]=""
    ["RConPort"]="2302"
    ["RestrictRCon"]="1"
)

declare -A BESERVER_MEMOS=(
    ["RConPassword"]="Password for Remote Admin (RCON)"
    ["RConPort"]="Port for RCON connections (usually GamePort)"
    ["RestrictRCon"]="Restrict RCON to whitelisted IPs (1=yes)"
)

declare -A BESERVER_VALIDATION=(
    ["RConPassword"]="string:0-32"
    ["RConPort"]="int:1024-65535"
    ["RestrictRCon"]="bool"
)

# =============================================================================
# Python Parser Wrapper
# =============================================================================
# Executes the config_parser.py in the container

config_parser_exec() {
    local container="$1"
    shift
    local args=("$@")
    
    local parser_script="${SCRIPT_DIR}/lib/config_parser.py"
    [[ -f "${parser_script}" ]] || { echo '{"status":"error","message":"Parser script not found"}'; return 0; }
    
    # Disable exit on error for docker commands
    set +e
    
    # Copy the parser and the helper module it imports (fileutil.py) into
    # the container; python resolves imports relative to the script's folder.
    local fileutil_script="${SCRIPT_DIR}/lib/fileutil.py"
    $DOCKER cp "${parser_script}" "${container}:/tmp/config_parser.py" 2>/dev/null \
        && $DOCKER cp "${fileutil_script}" "${container}:/tmp/fileutil.py" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        set -e
        echo '{"status":"error","message":"Failed to copy parser to container. Is the container running?"}'
        return 0
    fi
    
    # Execute in container
    local output
    output=$($DOCKER exec "${container}" python3 /tmp/config_parser.py "${args[@]}" 2>&1)
    local exit_code=$?
    
    set -e
    
    if [[ $exit_code -ne 0 ]]; then
        echo "{\"status\":\"error\",\"message\":\"Parser failed: ${output}\"}"
        return 0
    fi
    
    echo "$output"
}

# Parse JSON response from config_parser.py (grep based, top-level keys and
# the values nested under "data"). Named cfg_* so it cannot collide with the
# python json_get in lib/json_helpers.sh, which only knows top-level keys.
# Usage: result=$(config_parser_exec ...) && value=$(cfg_json_get "$result" "value")
cfg_json_get() {
    local json="$1"
    local key="$2"
    
    # Grep for "key": ... up to comma or closing brace
    # Handle quoted "value" or unquoted value (numbers/bools)
    # Use || true to prevent crash if not found (due to set -o pipefail)
    local match
    match=$(echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[^,}]*" || true)
    
    # Clean up structure to extract value
    # Remove key
    local value="${match#*:}"
    # methods to trim whitespace and quotes:
    # 1. Remove leading whitespace/colon
    value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/^[[:space:]]*"//' -e 's/"$//')
    
    echo "$value"
}

cfg_json_status() {
    local json="$1"
    cfg_json_get "$json" "status"
}

cfg_json_keys() {
    local json="$1"
    # Extract keys array: ["key1", "key2"] -> key1 key2
    # Use || true to prevent crash
    echo "$json" | grep -o '"keys"[[:space:]]*:[[:space:]]*\[[^]]*\]' | \
        sed 's/.*\[\(.*\)\].*/\1/' | tr ',' '\n' | sed 's/[" ]//g' || true
}

# Sub-menu for Loot selection (Main vs Modular)
types_selection_menu() {
    local inst_dir="$1"
    local container="$2"
    local selection=0
    
    while true; do
        local -a items=()
        local -a paths=()
        
        # 0. Quick Access: Modular Manager
        items+=("🛰️|Manage Modular Loot...")
        paths+=("MANAGE_MODULAR")
        items+=("--------------------")
        paths+=("")

        # 1. Main types.xml
        local main_types=$(find_types_xml "$inst_dir")
        if [[ -n "$main_types" ]]; then
            items+=("📦|Main Economy (types.xml)")
            paths+=("$main_types")
        fi
        
        # 2. Mission Core & DB Files
        local mission_path=$(get_mission_path "$inst_dir")
        if [[ -n "$mission_path" ]]; then
            items+=("--------------------")
            paths+=("")
            
            # Core
            local core_xml="${mission_path}/cfgeconomycore.xml"
            [[ -f "$core_xml" ]] && { items+=("⚙️|Economy Core (cfgeconomycore.xml)"); paths+=("$core_xml"); }
            
            # DB Files
            for db_file in globals.xml events.xml economy.xml messages.xml; do
                local p="${mission_path}/db/${db_file}"
                [[ -f "$p" ]] && { items+=("📄|$db_file"); paths+=("$p"); }
            done
            
            # Extra Configs (cfg*.xml and others)
            local extra_cfgs=(
                "cfgspawnabletypes.xml"
                "cfgeventspawns.xml"
                "cfgrandompresets.xml"
                "cfgeventgroups.xml"
                "cfgeffectarea.xml"
                "cfgweather.xml"
                "cfgplayerspawnpoints.xml"
                "cfgignorelist.xml"
                "cfggameplay.json"
                "cfglimitsdefinition.xml"
                "mapgrouppos.xml"
                "mapgroupproto.xml"
            )
            for cfg_file in "${extra_cfgs[@]}"; do
                local p="${mission_path}/${cfg_file}"
                [[ -f "$p" ]] && { items+=("⚙️|$cfg_file"); paths+=("$p"); }
            done
        fi
        
        # 3. Core Files (Handled in main list)
        items+=("--------------------")
        paths+=("")
        
        items+=("--------------------")
        paths+=("")
        items+=("←|Back")
        paths+=("")
        
        if ! run_menu items "Select Loot Economy File" $selection; then
            return
        fi
        
        selection=$MENU_RESULT
        local selected_item="${items[$MENU_RESULT]}"
        local selected_path="${paths[$MENU_RESULT]}"
        
        if [[ "$selected_item" == "←|Back" ]]; then
            return
        elif [[ "$selected_path" == "MANAGE_MODULAR" ]]; then
            modular_loot_dashboard "$inst_dir"
            continue
        fi
        
        if [[ -n "$selected_path" ]]; then
            # Smart Routing: Loot Files -> XML Editor, Structural -> Nano
            local is_types
            is_types=$(python3 "${SCRIPT_DIR}/lib/xml_parser.py" is-types "$selected_path" 2>/dev/null || echo "false")
            
            if [[ "$is_types" == "true" ]]; then
                config_xml_editor "$inst_dir" "$selected_path" "types" "$container"
            else
                fb_edit_file_nano "$selected_path" "$(basename "$selected_path")"
            fi
        fi
    done
}

# =============================================================================
# Config Editor Main Menu
# =============================================================================

# =============================================================================
# Category-based Editor (for serverDZ.cfg)
# =============================================================================

config_category_editor() {
    local container="$1"
    local config_path="$2"
    local config_id="$3"
    
    # Determine Variable Prefix
    local prefix="SERVERDZ"
    [[ "$config_id" == "BEServer" ]] && prefix="BESERVER"
    
    local cat_order_var="${prefix}_CATEGORY_ORDER"
    local cat_display_var="${prefix}_CATEGORY_DISPLAY"
    # Categories map (Category -> Keys CSV)
    local cats_var="${prefix}_CATEGORIES"
    
    while true; do
        draw_header "Config Editor"
        
        # Build menu using eval to access arrays
        local -a items=()
        local -a categories=()
        
        # Load order array
        eval "categories=(\"\${${cat_order_var}[@]}\")"
        
        # Skip category menu if only one category
        if [[ ${#categories[@]} -eq 1 ]]; then
            local only_cat="${categories[0]}"
            local keys_csv
            eval "keys_csv=\"\${${cats_var}[\$only_cat]}\""
            config_table_editor "$container" "$config_path" "$only_cat" "$keys_csv" "$prefix"
            return
        fi
        
        for cat in "${categories[@]}"; do
            local display_name
            # Load display name
            eval "display_name=\"\${${cat_display_var}[\$cat]}\""
            items+=("${display_name}")
        done
        items+=("--------------------")
        items+=("←|Back")
        
        if ! run_menu items "Select Category"; then
            return
        fi
        
        # Check if Back was selected (by content, not index)
        local selected_item="${items[$MENU_RESULT]}"
        if [[ "$selected_item" == "←|Back" || "$selected_item" == ----* ]]; then
            return
        fi
        
        local selected_cat="${categories[$MENU_RESULT]}"
        local keys_csv
        local display_name
        
        eval "keys_csv=\"\${${cats_var}[\$selected_cat]}\""
        eval "display_name=\"\${${cat_display_var}[\$selected_cat]}\""
        
        # Strip emoji from display name for title
        local clean_title
        clean_title=$(echo "$display_name" | sed 's/[^a-zA-Z0-9 ]//g' | xargs)
        
        config_table_editor "$container" "$config_path" "Settings ($clean_title)" "$keys_csv" "$prefix"
    done
}

# =============================================================================
# Flat Editor (for simple configs like BEServer)
# =============================================================================

config_flat_editor() {
    local container="$1"
    local config_path="$2"
    local config_id="$3"
    
    # Get all keys from file
    local container_path="/dayz/config/$(basename "$config_path")"
    local result
    result=$(config_parser_exec "$container" list cfg "$container_path")
    
    if [[ "$(cfg_json_status "$result")" != "ok" ]]; then
        show_message "Failed to read config: $(cfg_json_get "$result" "message")" "Error"
        return
    fi
    
    local keys_raw
    keys_raw=$(cfg_json_keys "$result")
    local keys_csv
    keys_csv=$(echo "$keys_raw" | tr '\n' ',' | sed 's/,$//')
    
    config_table_editor "$container" "$config_path" "Settings" "$keys_csv"
}

# =============================================================================
# Table Editor (Key-Value pairs)
# =============================================================================

# Values of the given keys from a getall result, one per line, in ONE process
# (cfg_json_get was one grep/sed pipeline per key on every reload).
# Usage: mapfile -t values < <(cfg_json_values "$result" "${keys[@]}")
cfg_json_values() {
    local json="$1"
    shift
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin).get("data", {})
except (ValueError, AttributeError):
    data = {}
for key in sys.argv[1:]:
    print(str(data.get(key, "")).replace("\n", " "))
' "$@"
}

# Hint for the edit prompt from a validation rule ("int:1-127" -> "(1-127)")
_cfg_validation_hint() {
    local rule="$1"
    [[ -n "$rule" ]] || return 0
    local type="${rule%%:*}" range="${rule#*:}"
    case "$type" in
        bool)           echo "(0 or 1)" ;;
        int|float|enum) echo "($range)" ;;
    esac
}

# ---- config table: drawing ---------------------------------------------------
# The _cfg_editor_* helpers run inside config_table_editor and use its locals:
# keys, values, count, selection, scroll_offset, the cfg_defaults/cfg_memos/
# cfg_validation namerefs and the layout variables set by _cfg_editor_layout.

# Column layout: KEY | VALUE | DEFAULT | MEMO (rest of the line)
_cfg_editor_layout() {
    table_start=3
    col_key=2
    w_key=34
    col_val=$((col_key + w_key))
    w_val=25
    col_def=$((col_val + w_val))
    w_def=20
    col_memo=$((col_def + w_def))
    w_memo=$((TERM_COLS - col_memo - 1))
    max_rows=$((TERM_ROWS - table_start - 5))
}

# Cell text cut to max_len characters with ".."
_cfg_cell() {
    local text="$1" max_len="$2"
    [[ ${#text} -ge $max_len ]] && text="${text:0:$((max_len - 2))}.."
    printf '%s' "$text"
}

# Full-width dashed line at ROW
_cfg_editor_draw_rule() {
    move_to "$1" 1
    printf "%s%s" "$DIM" "$RED"
    printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
    printf "%s" "$RESET"
}

# One table row for key index $1 at screen row $2
_cfg_editor_draw_row() {
    local i="$1" row="$2"
    local key="${keys[$i]}"
    local val="${values[$i]}"
    [[ "${key,,}" == *password* && -n "$val" ]] && val="********"   # never print passwords
    local d_key d_val d_def d_memo
    d_key=$(_cfg_cell "$key" $((w_key - 2)))
    d_val=$(_cfg_cell "${val:-(not set)}" $((w_val - 2)))
    d_def=$(_cfg_cell "${cfg_defaults[$key]:-}" $((w_def - 2)))
    d_memo=$(_cfg_cell "${cfg_memos[$key]:-}" "$w_memo")

    move_to "$row" 1
    if [[ $i -eq $selection ]]; then
        printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
        move_to "$row" $col_key;  printf "▶ %s" "$d_key"
        move_to "$row" $col_val;  printf "%s" "$d_val"
        move_to "$row" $col_def;  printf "%s" "$d_def"
        move_to "$row" $col_memo; printf "%s" "$d_memo"
    else
        local val_color="$WHITE"
        [[ "$d_val" == "(not set)" ]] && val_color="$YELLOW"
        [[ "$d_val" == "(empty)" ]] && val_color="$DIM"
        move_to "$row" $col_key;  printf "  %s" "$d_key"
        move_to "$row" $col_val;  printf "%s%s" "$val_color" "$d_val"
        move_to "$row" $col_def;  printf "%s%s" "$DIM" "$d_def"
        move_to "$row" $col_memo; printf "%s%s" "$DIM" "$d_memo"
    fi
    printf "%s" "$RESET"
}

# Header, column titles, visible rows, full memo of the selected key, footer
_cfg_editor_draw() {
    local screen_title="$1"
    printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
    move_to 1 1
    printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "$screen_title" "$RESET"

    _cfg_editor_draw_rule $table_start
    local col c w label
    for col in "$col_key:$w_key:KEY" "$col_val:$w_val:VALUE" "$col_def:$w_def:DEFAULT"; do
        IFS=: read -r c w label <<< "$col"
        move_to $((table_start + 1)) "$c"
        printf "%s%s%-*s%s" "$DIM" "$WHITE" "$w" "$label" "$RESET"
    done
    move_to $((table_start + 1)) $col_memo
    printf "%s%sMEMO%s" "$DIM" "$WHITE" "$RESET"
    _cfg_editor_draw_rule $((table_start + 2))

    local i row=$((table_start + 3))
    for (( i=scroll_offset; i<count && i<(scroll_offset + max_rows); i++ )); do
        _cfg_editor_draw_row "$i" "$row"
        row=$((row + 1))
    done

    local memo="${cfg_memos[${keys[$selection]}]:-}"
    if [[ -n "$memo" ]]; then
        move_to $((TERM_ROWS - 2)) 1
        printf "%s%sℹ️  %s%s" "$RESET" "$BOLD" "$memo" "$RESET"
    fi

    move_to $((TERM_ROWS - 1)) 1
    local footer_text=" [Enter] Edit   [q] Back"
    printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer_text" $((TERM_COLS - ${#footer_text})) "" "$RESET"
}

# ---- config table: editing ---------------------------------------------------

# Ask for a new value of the selected key and write it into the container
_cfg_editor_edit_selected() {
    local container="$1" parser_format="$2" container_path="$3" title="$4"
    local key="${keys[$selection]}"
    local current_val="${values[$selection]}"
    [[ "$current_val" == "(empty)" ]] && current_val=""
    local rule="${cfg_validation[$key]:-}"
    local hint
    hint=$(_cfg_validation_hint "$rule")
    local secret_flag=""
    [[ "${key,,}" == *password* ]] && secret_flag="secret"

    local new_val
    # shellcheck disable=SC2086  # secret_flag is intentionally unquoted (empty = no 4th arg)
    new_val=$(read_input "Edit $key $hint" "$current_val" "$title" $secret_flag)
    [[ -n "$new_val" ]] || return 0
    if [[ "${rule%%:*}" == "bool" && "$new_val" != "0" && "$new_val" != "1" ]]; then
        show_message "Warning: $key expects 0 or 1" "Validation"
    fi
    [[ "$new_val" != "$current_val" ]] || return 0

    local set_result msg
    set_result=$(config_parser_exec "$container" set "$parser_format" "$container_path" "$key" "$new_val")
    if [[ "$(cfg_json_status "$set_result")" != "ok" ]]; then
        msg=$(cfg_json_get "$set_result" "message")
        show_message "Failed to save: ${msg:-Raw: $set_result}" "Error"
    fi
    return 0
}

# Table editor for one config file inside the container: KEY | VALUE |
# DEFAULT | MEMO, Enter edits the selected key, values are re-read after
# every edit. prefix selects the SERVERDZ_* or BESERVER_* lookup tables.
# Usage: config_table_editor "$container" "$config_path" "Title" "key1,key2" [PREFIX]
config_table_editor() {
    local container="$1" config_path="$2" title="$3" keys_csv="$4"
    local prefix="${5:-SERVERDZ}"
    local filename container_path
    filename="$(basename "$config_path")"
    container_path="/dayz/config/${filename}"
    local parser_format="cfg"
    [[ "$prefix" == "BESERVER" ]] && parser_format="beserver"

    local -a keys values
    IFS=',' read -ra keys <<< "$keys_csv"
    local count=${#keys[@]}
    local -n cfg_defaults="${prefix}_DEFAULTS" cfg_memos="${prefix}_MEMOS" cfg_validation="${prefix}_VALIDATION"

    local selection=0 scroll_offset=0 key seq result
    local table_start col_key w_key col_val w_val col_def w_def col_memo w_memo max_rows
    while true; do
        result=$(config_parser_exec "$container" getall "$parser_format" "$container_path")
        if [[ "$(cfg_json_status "$result")" != "ok" ]]; then
            show_message "Failed to read config: $(cfg_json_get "$result" "message")" "Error"
            return
        fi
        mapfile -t values < <(cfg_json_values "$result" "${keys[@]}")
        get_term_size
        _cfg_editor_layout

        # navigate until Enter (edit) or q
        while true; do
            if [[ $selection -lt $scroll_offset ]]; then
                scroll_offset=$selection
            elif [[ $selection -ge $((scroll_offset + max_rows)) ]]; then
                scroll_offset=$((selection - max_rows + 1))
            fi
            _cfg_editor_draw "Config Editor - $filename - $title"

            IFS= read -rsn1 key || return 0   # EOF: leave instead of looping
            case "$key" in
                $'\x1b')
                    read -rsn2 -t 0.1 seq || true
                    case "$seq" in
                        '[A') if [[ $selection -gt 0 ]]; then selection=$((selection - 1)); fi ;;
                        '[B') if [[ $selection -lt $((count - 1)) ]]; then selection=$((selection + 1)); fi ;;
                    esac
                    ;;
                '')  break ;;
                q|Q) return 0 ;;
            esac
        done
        _cfg_editor_edit_selected "$container" "$parser_format" "$container_path" "$title"
    done
}

