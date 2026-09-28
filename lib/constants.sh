#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Centralized Constants
# =============================================================================
# All hardcoded paths and magic numbers in one place for maintainability
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_CONSTANTS_LOADED:-}" ]] && return 0
_DAYZ_CONSTANTS_LOADED=1

# =============================================================================
# Container Paths (inside Docker container)
# =============================================================================
readonly DAYZ_CONTAINER_ROOT="/dayz"
readonly DAYZ_CONTAINER_SERVERFILES="${DAYZ_CONTAINER_ROOT}/serverfiles"
readonly DAYZ_CONTAINER_BATTLEYE="${DAYZ_CONTAINER_SERVERFILES}/battleye"
readonly DAYZ_CONTAINER_BANS_TXT="${DAYZ_CONTAINER_BATTLEYE}/bans.txt"
readonly DAYZ_CONTAINER_RCON_SCRIPT="/tmp/rcon_client.py"

# =============================================================================
# Host Paths (relative to instance directory)
# =============================================================================
readonly DAYZ_DATA_DIR="data"
readonly DAYZ_CONFIG_DIR="${DAYZ_DATA_DIR}/config"
readonly DAYZ_PROFILE_DIR="${DAYZ_DATA_DIR}/profile"
readonly DAYZ_STATE_DIR="${DAYZ_DATA_DIR}/state"
readonly DAYZ_PLAYERS_STATE_DIR="${DAYZ_STATE_DIR}/players"

# Config files
readonly DAYZ_SERVER_CFG="serverDZ.cfg"
readonly DAYZ_BE_CFG="BEServer_x64.cfg"
readonly DAYZ_MODS_TXT="mods.txt"
readonly DAYZ_SERVERMODS_TXT="servermods.txt"

# Instance marker
readonly DAYZ_INSTANCE_MARKER=".dayz-instance"

# =============================================================================
# Network Constants
# =============================================================================
readonly RCON_PORT_OFFSET=3
readonly DAYZ_DEFAULT_PORT=2302
readonly DAYZ_DEFAULT_MAX_PLAYERS=60

# =============================================================================
# Ban System Constants
# =============================================================================
readonly BAN_PERMANENT_MARKER=-1

# =============================================================================
# Helper Functions
# =============================================================================

# Get full path to config directory for an instance
# Usage: config_dir=$(get_config_dir "$inst_dir")
get_config_dir() {
    local inst_dir="$1"
    echo "${inst_dir}/${DAYZ_CONFIG_DIR}"
}

# Get full path to profile directory for an instance
# Usage: profile_dir=$(get_profile_dir "$inst_dir")
get_profile_dir() {
    local inst_dir="$1"
    echo "${inst_dir}/${DAYZ_PROFILE_DIR}"
}

# Get full path to state directory for an instance
# Usage: state_dir=$(get_state_dir "$inst_dir")
get_state_dir() {
    local inst_dir="$1"
    echo "${inst_dir}/${DAYZ_STATE_DIR}"
}

# Get full path to players state directory for an instance
# Usage: players_state_dir=$(get_players_state_dir "$inst_dir")
get_players_state_dir() {
    local inst_dir="$1"
    echo "${inst_dir}/${DAYZ_PLAYERS_STATE_DIR}"
}

# Get full path to serverDZ.cfg for an instance
# Usage: server_cfg=$(get_server_cfg "$inst_dir")
get_server_cfg() {
    local inst_dir="$1"
    echo "${inst_dir}/${DAYZ_CONFIG_DIR}/${DAYZ_SERVER_CFG}"
}

# Get full path to BEServer_x64.cfg for an instance
# Usage: be_cfg=$(get_be_cfg "$inst_dir")
get_be_cfg() {
    local inst_dir="$1"
    echo "${inst_dir}/${DAYZ_CONFIG_DIR}/${DAYZ_BE_CFG}"
}

# Get instance marker path
# Usage: marker=$(get_instance_marker "$inst_dir")
get_instance_marker() {
    local inst_dir="$1"
    echo "${inst_dir}/${DAYZ_INSTANCE_MARKER}"
}
