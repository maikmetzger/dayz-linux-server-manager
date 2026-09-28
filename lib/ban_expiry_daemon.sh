#!/bin/bash
# =============================================================================
# DayZ Ban Expiry Daemon (In-Container)
# =============================================================================
# Runs inside the Docker container alongside the DayZ server.
# Checks for expired bans every minute and removes them automatically.
#
# This replaces the host-based systemd timer approach for cleaner architecture.
# =============================================================================

set -uo pipefail

# Configuration (can be overridden via environment variables)
CHECK_INTERVAL="${DZ_BAN_EXPIRY_INTERVAL:-60}"
BANS_JSON="${DZ_STATE:-/dayz/state}/players/bans.json"
BANS_TXT="${DZ_SERVERFILES:-/dayz/serverfiles}/battleye/bans.txt"
LIB_DIR="${DZ_LIB_DIR:-/dayz/lib}"
LOG_PREFIX="[ban-expiry]"

# RCON settings (optional, for reloading bans)
RCON_HOST="127.0.0.1"
RCON_PORT="${DZ_RCON_PORT:-2305}"

# =============================================================================
# Logging
# =============================================================================

log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} INFO: $*"
}

log_warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} WARN: $*" >&2
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} ERROR: $*" >&2
}

# =============================================================================
# Ban Expiry Check
# =============================================================================

check_and_remove_expired_bans() {
    # Check if bans.json exists
    if [[ ! -f "$BANS_JSON" ]]; then
        return 0  # No bans file, nothing to do
    fi

    # Check if ban_manager.py exists
    if [[ ! -f "${LIB_DIR}/ban_manager.py" ]]; then
        log_error "ban_manager.py not found at ${LIB_DIR}/ban_manager.py"
        return 1
    fi

    # Find expired bans
    local expired_result
    if ! expired_result=$(python3 "${LIB_DIR}/ban_manager.py" --file "$BANS_JSON" expired 2>&1); then
        # A crashing helper is not "nothing expired"
        log_error "ban_manager.py expired failed: ${expired_result}"
        return 1
    fi

    if [[ -z "$expired_result" ]]; then
        return 0
    fi

    # Extract expired GUIDs
    local expired_guids
    expired_guids=$(echo "$expired_result" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for ban in data.get("bans", []):
        guid = ban.get("guid", "")
        if guid:
            print(guid)
except:
    pass
' 2>/dev/null)

    if [[ -z "$expired_guids" ]]; then
        return 0  # No expired bans
    fi

    log_info "Found expired bans, processing..."

    local removed_count=0

    # Remove each expired GUID from bans.txt
    while IFS= read -r guid; do
        if [[ -n "$guid" ]]; then
            log_info "Removing expired ban: $guid"

            # Remove GUID from bans.txt (direct file access, no docker exec)
            if [[ -f "$BANS_TXT" ]]; then
                grep -v "^${guid}" "$BANS_TXT" > "${BANS_TXT}.tmp" 2>/dev/null || true
                mv "${BANS_TXT}.tmp" "$BANS_TXT" 2>/dev/null || true
            fi

            removed_count=$((removed_count + 1))
        fi
    done <<< "$expired_guids"

    # Remove expired bans from bans.json
    python3 "${LIB_DIR}/ban_manager.py" --file "$BANS_JSON" cleanup >/dev/null 2>&1 \
        || log_warn "ban_manager.py cleanup failed, bans.json still lists the expired bans"

    # Reload bans via RCON if be_rcon.py is available
    if [[ -f "${LIB_DIR}/be_rcon.py" ]] && [[ -n "${RCON_PASSWORD:-}" ]]; then
        log_info "Reloading bans via RCON..."
        local reload_json
        if reload_json=$(python3 "${LIB_DIR}/be_rcon.py" --host "$RCON_HOST" --port "$RCON_PORT" \
                --password-env RCON_PASSWORD --action loadbans 2>&1) \
           && [[ "$reload_json" == *'"success": true'* ]]; then
            log_info "Bans reloaded via RCON"
        else
            log_warn "loadBans via RCON failed, bans.txt changes apply at the next restart: ${reload_json}"
        fi
    fi

    log_info "Done - removed ${removed_count} expired ban(s)"
}

# =============================================================================
# Signal Handling
# =============================================================================

shutdown_daemon() {
    log_info "Shutting down ban expiry daemon..."
    exit 0
}

trap shutdown_daemon SIGTERM SIGINT SIGHUP

# =============================================================================
# Main Loop
# =============================================================================

main() {
    log_info "Ban expiry daemon starting (interval: ${CHECK_INTERVAL}s)"
    log_info "Watching: $BANS_JSON"

    # Initial delay to let server start
    sleep 10

    while true; do
        check_and_remove_expired_bans || true
        sleep "$CHECK_INTERVAL"
    done
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
