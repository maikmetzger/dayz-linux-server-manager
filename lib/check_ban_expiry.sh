#!/bin/bash
# =============================================================================
# Ban Expiry Checker
# =============================================================================
# Checks bans.json for expired bans and removes them from bans.txt
# Run this periodically via cron (e.g. every minute)
#
# Usage: ./check_ban_expiry.sh <instance_dir>
# Example cron: * * * * * /path/to/check_ban_expiry.sh /home/user/servers/dayz-server1
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
    source "${SCRIPT_DIR}/utils.sh"
fi
if [[ -f "${SCRIPT_DIR}/constants.sh" ]]; then
    source "${SCRIPT_DIR}/constants.sh"
fi
if [[ -f "${SCRIPT_DIR}/json_helpers.sh" ]]; then
    source "${SCRIPT_DIR}/json_helpers.sh"
fi
if [[ -f "${SCRIPT_DIR}/rcon_lib.sh" ]]; then
    source "${SCRIPT_DIR}/rcon_lib.sh"
fi

# =============================================================================
# Main Logic
# =============================================================================

check_expired_bans() {
    local inst_dir="$1"
    
    # Validate instance directory
    if [[ ! -d "$inst_dir" ]]; then
        echo "Error: Instance directory not found: $inst_dir" >&2
        exit 1
    fi
    
    local state_dir="${inst_dir}/data/state/players"
    local bans_json="${state_dir}/bans.json"
    
    # Check if bans.json exists
    if [[ ! -f "$bans_json" ]]; then
        exit 0  # No bans to check
    fi
    
    # Get container name
    local marker="${inst_dir}/.dayz-instance"
    local container_name
    container_name="$(grep -oP 'CONTAINER_NAME=\K.*' "$marker" 2>/dev/null || echo "")"
    
    if [[ -z "$container_name" ]]; then
        echo "Error: No container found for instance" >&2
        exit 1
    fi
    
    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        exit 0  # Container not running, skip check
    fi
    
    # Get RCON connection info
    local dz_port
    dz_port=$(grep -oP 'DZ_PORT=\K[0-9]+' "$marker" 2>/dev/null || echo "2302")
    local rcon_port=$((dz_port + 3))
    
    local be_cfg="${inst_dir}/data/config/BEServer_x64.cfg"
    local rcon_pass=""
    if [[ -f "$be_cfg" ]]; then
        rcon_pass=$(grep -oP 'RConPassword\s+\K\S+' "$be_cfg" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$rcon_pass" ]]; then
        echo "Error: RCON password not found" >&2
        exit 1
    fi
    
    # Find expired bans using Python
    local expired_guids
    expired_guids=$(python3 << PYTHON_SCRIPT
import json
from datetime import datetime

bans_file = "${bans_json}"
if not bans_file:
    exit(0)

try:
    with open(bans_file, 'r') as f:
        data = json.load(f)
except:
    exit(0)

now = datetime.utcnow()
expired = []

for ban in data.get('bans', []):
    expires = ban.get('expires', 'never')
    if expires and expires != 'never' and expires != 'unknown':
        try:
            exp_dt = datetime.strptime(expires, '%Y-%m-%dT%H:%M:%SZ')
            if exp_dt <= now:
                expired.append(ban.get('guid', ''))
        except:
            pass

# Print expired GUIDs, one per line
for guid in expired:
    if guid:
        print(guid)
PYTHON_SCRIPT
    )
    
    # Process expired bans
    if [[ -z "$expired_guids" ]]; then
        exit 0  # No expired bans
    fi
    
    echo "Found expired bans, processing..."
    
    local needs_reload=false

    while IFS= read -r guid; do
        if [[ -n "$guid" ]]; then
            echo "  Removing expired ban: $guid"

            # Remove GUID from bans.txt in container
            # SECURITY: Use safe_container_remove_line to prevent command injection
            if [[ -n "${DAYZ_CONTAINER_BANS_TXT:-}" ]]; then
                safe_container_remove_line "$container_name" "$DAYZ_CONTAINER_BANS_TXT" "$guid"
            else
                # Fallback if constants not loaded
                docker exec "$container_name" sh -c 'grep -v "^$1" "$2" > "$2.tmp" 2>/dev/null || true; mv "$2.tmp" "$2" 2>/dev/null || true' _ "$guid" "/dayz/serverfiles/battleye/bans.txt" 2>/dev/null || true
            fi

            # Update bans.json - remove expired ban
            # SECURITY: Use json_file_array_remove to prevent injection
            if type json_file_array_remove &>/dev/null; then
                json_file_array_remove "$bans_json" ".bans" "guid" "$guid"
            else
                # Fallback if json_helpers not loaded
                python3 -c '
import json
import sys
try:
    bans_file = sys.argv[1]
    guid = sys.argv[2]
    with open(bans_file, "r") as f:
        data = json.load(f)
    data["bans"] = [b for b in data.get("bans", []) if b.get("guid") != guid]
    with open(bans_file, "w") as f:
        json.dump(data, f, indent=2)
except: pass
' "$bans_json" "$guid" 2>/dev/null
            fi

            needs_reload=true
        fi
    done <<< "$expired_guids"

    # Reload bans if any were removed
    if [[ "$needs_reload" == "true" ]]; then
        echo "Reloading bans..."

        # Use rcon_reload_bans if available, otherwise fallback
        if type rcon_reload_bans &>/dev/null; then
            rcon_reload_bans "$inst_dir" >/dev/null 2>&1 || true
        else
            # Fallback: Copy RCON script to container and execute
            local rcon_script="${SCRIPT_DIR}/be_rcon.py"
            if [[ -f "$rcon_script" ]]; then
                docker cp "$rcon_script" "${container_name}:/tmp/rcon_client.py" 2>/dev/null
                # SECURITY: Pass password via environment variable
                docker exec -e "RCON_PASSWORD=$rcon_pass" "$container_name" python3 /tmp/rcon_client.py \
                    --host 127.0.0.1 \
                    --port "$rcon_port" \
                    --password-env RCON_PASSWORD \
                    --action loadbans 2>/dev/null || true
            fi
        fi

        echo "Done - expired bans removed"
    fi
}

# =============================================================================
# Entry Point
# =============================================================================

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <instance_dir>"
    echo "Example: $0 /home/user/servers/dayz-server1"
    exit 1
fi

check_expired_bans "$1"
