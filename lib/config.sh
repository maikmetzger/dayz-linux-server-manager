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
declare -A CONFIG_REGISTRY=(
    ["serverDZ"]="cfg|data/config/serverDZ.cfg|🔧|Server Settings"
    ["BEServer"]="cfg|data/config/BEServer_x64.cfg|🔐|RCON Settings"
    ["types"]="xml||📦|Loot Economy (types.xml)"
)

# Helper to find types.xml within mpmissions
find_types_xml() {
    local inst_dir="$1"
    local cfg="${inst_dir}/data/config/serverDZ.cfg"
    local template=""
    
    # 1. Try mapping via serverDZ.cfg template
    if [[ -f "$cfg" ]]; then
        template=$(grep -i '^template' "$cfg" | sed -E 's/template\s*=\s*"([^"]+)".*/\1/')
    fi
    
    if [[ -n "$template" ]]; then
        # Try both common mount structures
        local paths=(
            "${inst_dir}/data/serverfiles/mpmissions/${template}/db/types.xml"
            "${inst_dir}/data/mpmissions/${template}/db/types.xml"
            "${inst_dir}/serverfiles/mpmissions/${template}/db/types.xml"
            "${inst_dir}/mpmissions/${template}/db/types.xml"
        )
        for p in "${paths[@]}"; do
            if [[ -f "$p" ]]; then
                echo "$p"
                return
            fi
        done
    fi
    
    # 2. Global search in instance directory (limited depth for speed)
    find "${inst_dir}" -maxdepth 6 -name "types.xml" -type f 2>/dev/null | head -n 1
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
    
    # Copy script to container
    $DOCKER cp "${parser_script}" "${container}:/tmp/config_parser.py" 2>/dev/null
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

# Parse JSON response from Python
# Usage: result=$(config_parser_exec ...) && value=$(json_get "$result" "value")
json_get() {
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

json_get_status() {
    local json="$1"
    json_get "$json" "status"
}

json_get_keys() {
    local json="$1"
    # Extract keys array: ["key1", "key2"] -> key1 key2
    # Use || true to prevent crash
    echo "$json" | grep -o '"keys"[[:space:]]*:[[:space:]]*\[[^]]*\]' | \
        sed 's/.*\[\(.*\)\].*/\1/' | tr ',' '\n' | sed 's/[" ]//g' || true
}

# =============================================================================
# Config Editor Main Menu
# =============================================================================

config_editor_menu() {
    local container="$SELECTED_CONTAINER"
    local inst_dir="$SELECTED_DIR"
    
    while true; do
        draw_header "Config Editor"
        
        local -a items=()
        local -a config_ids=()
        
        for id in "${!CONFIG_REGISTRY[@]}"; do
            IFS='|' read -r fmt rel_path icon label <<< "${CONFIG_REGISTRY[$id]}"
            local full_path="${inst_dir}/${rel_path}"
            local display_name="${icon}|${label}"
            
            # Check if file exists (via host path since it's mounted)
            if [[ -f "${full_path}" ]]; then
                items+=("${display_name}")
            else
                items+=("${icon}|${label} (not found)")
            fi
            config_ids+=("$id")
        done
        
        items+=("--------------------")
        items+=("←|Back")
        
        if ! run_menu items "Select Config File"; then
            return
        fi
        
        # Check if Back was selected (by content, not index)
        local selected_item="${items[$MENU_RESULT]}"
        if [[ "$selected_item" == "←|Back" || "$selected_item" == ----* ]]; then
            return
        fi
        
        local selected_id="${config_ids[$MENU_RESULT]}"
        IFS='|' read -r fmt rel_path icon label <<< "${CONFIG_REGISTRY[$selected_id]}"
        
        local full_path=""
        if [[ -n "$rel_path" ]]; then
            full_path="${inst_dir}/${rel_path}"
        else
            # Dynamic lookup for types.xml
            full_path=$(find_types_xml "$inst_dir")
        fi
        
        if [[ -z "${full_path}" || ! -f "${full_path}" ]]; then
            show_message "File not found: ${selected_id}.xml" "Error"
            continue
        fi
        
        # Route to appropriate editor based on format/ID
        case "$fmt" in
            "xml") config_xml_editor "$container" "$full_path" "$selected_id" ;;
            *)
                case "$selected_id" in
                    "serverDZ"|"BEServer") config_category_editor "$container" "$full_path" "$selected_id" ;;
                    *) config_flat_editor "$container" "$full_path" "$selected_id" ;;
                esac
                ;;
        esac
    done
}

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
    
    if [[ "$(json_get_status "$result")" != "ok" ]]; then
        show_message "Failed to read config: $(json_get "$result" "message")" "Error"
        return
    fi
    
    local keys_raw
    keys_raw=$(json_get_keys "$result")
    local keys_csv
    keys_csv=$(echo "$keys_raw" | tr '\n' ',' | sed 's/,$//')
    
    config_table_editor "$container" "$config_path" "Settings" "$keys_csv"
}

# =============================================================================
# Table Editor (Key-Value pairs)
# =============================================================================

config_table_editor() {
    local container="$1"
    local config_path="$2"
    local title="$3"
    local keys_csv="$4"
    local prefix="${5:-SERVERDZ}" # Default to SERVERDZ if not provided
    
    local container_path="/dayz/config/$(basename "$config_path")"
    local filename
    filename="$(basename "$config_path")"
    
    # Parse keys
    IFS=',' read -ra keys <<< "$keys_csv"
    
    # Setup Variable Names for Lookup
    local defaults_var="${prefix}_DEFAULTS"
    local memos_var="${prefix}_MEMOS"
    local validation_var="${prefix}_VALIDATION"
    
    local selection=0
    local scroll_offset=0
    
    while true; do
        # Fetch current values
        local result
        result=$(config_parser_exec "$container" getall cfg "$container_path")
        
        if [[ "$(json_get_status "$result")" != "ok" ]]; then
            show_message "Failed to read config: $(json_get "$result" "message")" "Error"
            return
        fi
        
        # Parse values into array
        local -a values=()
        for key in "${keys[@]}"; do
            local val
            val=$(json_get "$result" "$key")
            values+=("$val")
        done
        
        # Calculate Layout
        get_term_size
        local table_start=3
        
        # Column Definitions (3-column layout: KEY | VALUE | DEFAULT)
        # Memo is shown only in footer now
        local col_key=2
        local w_key=34
        
        local col_val=$((col_key + w_key))
        local w_val=25
        
        local col_def=$((col_val + w_val))
        local w_def=20
        
        local col_memo=$((col_def + w_def))
        # Memo gets remaining width
        
        local max_rows=$((TERM_ROWS - table_start - 5)) 

        # Input Loop
        while true; do
             # Handle scrolling
            if [[ $selection -lt $scroll_offset ]]; then
                scroll_offset=$selection
            elif [[ $selection -ge $((scroll_offset + max_rows)) ]]; then
                scroll_offset=$((selection - max_rows + 1))
            fi
            
            # Draw UI
            printf "%s%s" "$HIDE_CURSOR" "$CLEAR_SCREEN"
            
            # 1. Header Bar
            move_to 1 1
            printf "%s%s %-$((TERM_COLS-1))s%s" "$BG_RED" "$WHITE$BOLD" "Config Editor - $filename - $title" "$RESET"
            
            # 2. Table Header
            move_to $table_start 1
            printf "%s%s" "$DIM" "$RED"
            printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
            printf "%s" "$RESET"
            
            move_to $((table_start + 1)) $col_key
            printf "%s%s%-*s%s" "$DIM" "$WHITE" "$w_key" "KEY" "$RESET"
            move_to $((table_start + 1)) $col_val
            printf "%s%s%-*s%s" "$DIM" "$WHITE" "$w_val" "VALUE" "$RESET"
            move_to $((table_start + 1)) $col_def
            printf "%s%s%-*s%s" "$DIM" "$WHITE" "$w_def" "DEFAULT" "$RESET"
            move_to $((table_start + 1)) $col_memo
            printf "%s%sMEMO%s" "$DIM" "$WHITE" "$RESET"
            
            move_to $((table_start + 2)) 1
            printf "%s%s" "$DIM" "$RED"
            printf "%*s" "$TERM_COLS" "" | tr ' ' '-'
            printf "%s" "$RESET"
            
            # 3. Rows
            local row=$((table_start + 3))
            local count=${#keys[@]}
            
            local current_memo=""
            
            for (( i=scroll_offset; i<count && i<(scroll_offset + max_rows); i++ )); do
                local key="${keys[$i]}"
                local val="${values[$i]}"
                local default
                local memo
                
                # Dynamic Lookup via eval
                eval "default=\"\${${defaults_var}[\$key]:-}\""
                eval "memo=\"\${${memos_var}[\$key]:-}\""
                
                # Truncate visuals
                local d_key="$key"
                [[ ${#d_key} -ge $((w_key-2)) ]] && d_key="${d_key:0:$((w_key-4))}.."
                
                local d_val="$val"
                if [[ -z "$d_val" ]]; then
                    # Check if key actually exists in file or is just missing
                    # If parsed value is empty string, it could be either
                    # For now, use "(not set)" to indicate it's not in the file
                    d_val="(not set)"
                fi
                [[ ${#d_val} -ge $((w_val-2)) ]] && d_val="${d_val:0:$((w_val-4))}.."
                
                local d_def="$default"
                [[ ${#d_def} -ge $((w_def-2)) ]] && d_def="${d_def:0:$((w_def-4))}.."
                
                # Memo (remaining width)
                local w_memo=$((TERM_COLS - col_memo - 1))
                local d_memo="$memo"
                [[ ${#d_memo} -ge $w_memo ]] && d_memo="${d_memo:0:$((w_memo-2))}.."
                
                # Capture current selection memo for footer
                [[ $i -eq $selection ]] && current_memo="$memo"
                
                move_to $row 1
                if [[ $i -eq $selection ]]; then
                    # Selected Row
                    printf "%s%s%*s" "$BG_RED" "$WHITE$BOLD" "$TERM_COLS" ""
                    move_to $row $col_key
                    printf "▶ %s" "$d_key"
                    move_to $row $col_val
                    printf "%s" "$d_val"
                    move_to $row $col_def
                    printf "%s" "$d_def"
                    move_to $row $col_memo
                    printf "%s" "$d_memo"
                    printf "%s" "$RESET"
                else
                    # Normal Row
                    move_to $row $col_key
                    printf "  %s" "$d_key"
                    move_to $row $col_val
                    # Color based on value state
                    if [[ "$d_val" == "(not set)" ]]; then
                        printf "%s%s" "$YELLOW" "$d_val"
                    elif [[ "$d_val" == "(empty)" ]]; then
                        printf "%s%s" "$DIM" "$d_val"
                    else
                        printf "%s%s" "$WHITE" "$d_val"
                    fi
                    move_to $row $col_def
                    printf "%s%s" "$DIM" "$d_def"
                    move_to $row $col_memo
                    printf "%s%s" "$DIM" "$d_memo"
                    printf "%s" "$RESET"
                fi
                ((row++))
            done
            
            # 4. Description Bar (Full memo at bottom)
            if [[ -n "$current_memo" ]]; then
                move_to $((TERM_ROWS - 2)) 1
                printf "%s%sℹ️  %s%s" "$RESET" "$BOLD" "$current_memo" "$RESET"
            fi
            
            # 5. Footer
            move_to $((TERM_ROWS - 1)) 1
            local footer_text=" [Enter] Edit   [q] Back"
            local pad_len=$((TERM_COLS - ${#footer_text}))
            printf "%s%s%s%*s%s" "$BG_DARKGRAY" "$WHITE" "$footer_text" "$pad_len" "" "$RESET"
            
            # Input Handling
            IFS= read -rsn1 key
            case "$key" in
                $'\x1b')
                    read -rsn2 -t 0.1 seq || true
                    case "$seq" in
                        '[A') 
                            if [[ $selection -gt 0 ]]; then
                                selection=$((selection - 1))
                            fi
                            ;;
                        '[B') 
                            if [[ $selection -lt $((count - 1)) ]]; then
                                selection=$((selection + 1))
                            fi
                            ;;
                    esac
                    ;;
                '') # Enter - Edit
                    break # Break inner loop to edit
                    ;;
                'q'|'Q')
                    return # Exit function
                    ;;
            esac
        done
        
        # Edit Action
        local selected_key="${keys[$selection]}"
        local current_val="${values[$selection]}"
        [[ "$current_val" == "(empty)" ]] && current_val=""
        
        # Validation Hint (Dynamic Lookup)
        local valid_rule
        eval "valid_rule=\"\${${validation_var}[\$selected_key]:-}\""
        
        local hint=""
        local type="string"
        if [[ -n "$valid_rule" ]]; then
            type="${valid_rule%%:*}"
            local range="${valid_rule#*:}"
            case "$type" in
                "bool") hint="(0 or 1)" ;;
                "int"|"float") hint="($range)" ;;
                "enum") hint="($range)" ;;
            esac
        fi
        
        local new_val
        new_val=$(read_input "Edit $selected_key $hint" "$current_val" "$title")
        
        if [[ -n "$new_val" ]]; then
            # Validation Warning
            if [[ "$type" == "bool" ]]; then
                if [[ "$new_val" != "0" && "$new_val" != "1" ]]; then
                     show_message "Warning: $selected_key expects 0 or 1" "Validation"
                fi
            fi
            
            if [[ "$new_val" != "$current_val" ]]; then
                local set_result
                set_result=$(config_parser_exec "$container" set cfg "$container_path" "$selected_key" "$new_val")
                if [[ "$(json_get_status "$set_result")" != "ok" ]]; then
                    local msg
                    msg=$(json_get "$set_result" "message")
                    [[ -z "$msg" ]] && msg="Raw: $set_result"
                    show_message "Failed to save: $msg" "Error"
                fi
            fi
        fi
    done
}

