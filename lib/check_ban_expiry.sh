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

# Source utils if available
if [[ -f "${SCRIPT_DIR}/utils.sh" ]]; then
    source "${SCRIPT_DIR}/utils.sh"
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
    
    local bans_txt="/dayz/serverfiles/battleye/bans.txt"
    local needs_reload=false
    
    while IFS= read -r guid; do
        if [[ -n "$guid" ]]; then
            echo "  Removing expired ban: $guid"
            
            # Remove GUID from bans.txt in container
            docker exec "$container_name" bash -c "sed -i '/^${guid}/d' ${bans_txt}" 2>/dev/null || true
            
            # Update bans.json - mark as expired/removed
            python3 << PYTHON_UPDATE
import json
bans_file = "$bans_json"
guid = "$guid"
try:
    with open(bans_file, 'r') as f:
        data = json.load(f)
    
    # Remove the expired ban from the list
    data['bans'] = [b for b in data.get('bans', []) if b.get('guid') != guid]
    
    with open(bans_file, 'w') as f:
        json.dump(data, f, indent=2)
except Exception as e:
    pass
PYTHON_UPDATE
            
            needs_reload=true
        fi
    done <<< "$expired_guids"
    
    # Reload bans if any were removed
    if [[ "$needs_reload" == "true" ]]; then
        echo "Reloading bans..."
        
        # Copy RCON script to container
        local rcon_script="${SCRIPT_DIR}/be_rcon.py"
        if [[ -f "$rcon_script" ]]; then
            docker cp "$rcon_script" "${container_name}:/tmp/rcon_client.py" 2>/dev/null
            docker exec -e "RCON_PASSWORD=$rcon_pass" "$container_name" python3 /tmp/rcon_client.py \
                --host 127.0.0.1 \
                --port "$rcon_port" \
                --action loadbans 2>/dev/null || true
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
