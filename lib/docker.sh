#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Docker Utilities
# =============================================================================
# Docker detection, wrappers, and helper functions
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_DOCKER_LOADED:-}" ]] && return 0
_DAYZ_DOCKER_LOADED=1

# -----------------------------------------------------------------------------
# Docker Detection
# -----------------------------------------------------------------------------

# Docker command (may be "docker" or "sudo docker")
DOCKER="docker"

# Docker command as array (for installer which uses array syntax)
declare -a DOCKER_ARR=(docker)

# Detect and configure Docker access
# Sets DOCKER and DOCKER_ARR variables
# Returns: 0 on success, 1 on failure
detect_docker() {
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    
    if docker info &>/dev/null 2>&1; then
        DOCKER="docker"
        DOCKER_ARR=(docker)
        return 0
    fi
    
    if command -v sudo &>/dev/null && sudo docker info &>/dev/null 2>&1; then
        DOCKER="sudo docker"
        DOCKER_ARR=(sudo docker)
        return 0
    fi
    
    return 1
}

# Select docker wrapper based on permissions
# Used by installer after potential group changes
select_docker_wrapper() {
    if docker info &>/dev/null 2>&1; then
        DOCKER_ARR=(docker)
        return 0
    elif sudo docker info &>/dev/null 2>&1; then
        DOCKER_ARR=(sudo docker)
        return 0
    fi
    return 1
}

# Require docker to be available, exit if not
require_docker() {
    if ! detect_docker; then
        echo "Error: Cannot connect to Docker daemon. Try: sudo $0" >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Container Helpers
# -----------------------------------------------------------------------------

# Get container status
# Usage: status=$(get_container_status "dayz-server1")
# Returns: "RUNNING" or "STOPPED"
get_container_status() {
    local container="$1"
    if $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
        echo "RUNNING"
    else
        echo "STOPPED"
    fi
}

# List all DayZ containers
# Returns: container names, one per line
list_dayz_containers() {
    ${DOCKER_ARR[*]} ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^dayz-[A-Za-z0-9][A-Za-z0-9-]{0,31}$' || true
}

# Get compose working directory for a container
# Usage: dir=$(compose_workdir_for_container "dayz-server1")
compose_workdir_for_container() {
    local container="$1"
    ${DOCKER_ARR[*]} inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "${container}" 2>/dev/null || true
}

# Check if directory looks like a compose project
# Usage: if container_has_compose_dir "/path/to/dir"; then ...
container_has_compose_dir() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 1
    [[ -f "${dir}/docker-compose.yml" || -f "${dir}/.dayz-instance" ]] || return 1
    return 0
}
