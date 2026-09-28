#!/usr/bin/env bash
# =============================================================================
# DayZ Server Scripts - Instance Management
# =============================================================================
# Instance discovery, selection, and marker handling
# Requires: lib/utils.sh, lib/docker.sh
# =============================================================================

# Prevent double-sourcing
[[ -n "${_DAYZ_INSTANCE_LOADED:-}" ]] && return 0
_DAYZ_INSTANCE_LOADED=1

# -----------------------------------------------------------------------------
# Instance State
# -----------------------------------------------------------------------------

# Arrays of discovered instances
declare -a INSTANCE_DIRS=()
declare -a INSTANCE_NAMES=()
declare -a INSTANCE_CONTAINERS=()

# Currently selected instance
SELECTED_DIR=""
SELECTED_NAME=""
SELECTED_CONTAINER=""

# -----------------------------------------------------------------------------
# Instance Discovery
# -----------------------------------------------------------------------------

# Discover instances by scanning for .dayz-instance markers
# Usage: discover_instances_under "/home/user/servers"
# Returns: paths to marker files, one per line
discover_instances_under() {
    local root="$1"
    [[ -d "${root}" ]] || return 0
    find "${root}" -maxdepth 3 -type f -name ".dayz-instance" -print 2>/dev/null || true
}

# Scan for instances and populate INSTANCE_* arrays
# Uses SEARCH_ROOT or defaults to ~/servers
scan_instances() {
    INSTANCE_DIRS=()
    INSTANCE_NAMES=()
    INSTANCE_CONTAINERS=()
    
    local search_root="${SEARCH_ROOT:-${INVOKING_HOME:-$HOME}/servers}"
    
    # Resolve the real path to avoid duplicates from symlinks
    search_root="$(cd "$search_root" 2>/dev/null && pwd -P || echo "$search_root")"
    
    [[ -d "$search_root" ]] || return 0
    
    # Track seen directories to avoid duplicates
    local -A seen_dirs=()
    
    while IFS= read -r marker; do
        [[ -f "$marker" ]] || continue
        
        local dir name container real_dir
        dir="$(dirname "$marker")"
        real_dir="$(cd "$dir" 2>/dev/null && pwd -P || echo "$dir")"
        
        # Skip if we've already seen this directory
        [[ -n "${seen_dirs[$real_dir]:-}" ]] && continue
        seen_dirs["$real_dir"]=1
        
        name="$(grep '^INSTANCE_NAME=' "$marker" 2>/dev/null | cut -d= -f2- | tr -d '"')"
        [[ -z "$name" ]] && name="$(basename "$dir")"
        container="dayz-${name}"
        
        INSTANCE_DIRS+=("$dir")
        INSTANCE_NAMES+=("$name")
        INSTANCE_CONTAINERS+=("$container")
    done < <(find "$search_root" -maxdepth 3 -name ".dayz-instance" 2>/dev/null || true)
}

# -----------------------------------------------------------------------------
# Preset Collection
# -----------------------------------------------------------------------------
# Used by installer to collect settings from existing instances

# Preset variables
preset_name=""
preset_dir=""
preset_host_net=""
preset_dz_port=""
preset_query_port=""
preset_extra_params=""

# Collect presets from a directory
# Usage: collect_presets_from_dir "/home/user/servers/dayz-server1"
collect_presets_from_dir() {
    local dir="$1"
    
    preset_dir="${dir}"
    preset_name=""
    preset_host_net=""
    preset_dz_port=""
    preset_query_port=""
    preset_extra_params=""
    
    if [[ -f "${dir}/.dayz-instance" ]]; then
        preset_name="$(marker_get "${dir}/.dayz-instance" "INSTANCE_NAME")"
        preset_host_net="$(marker_get "${dir}/.dayz-instance" "HOST_NETWORK")"
        preset_dz_port="$(marker_get "${dir}/.dayz-instance" "DZ_PORT")"
        preset_query_port="$(marker_get "${dir}/.dayz-instance" "DZ_QUERY_PORT")"
    fi
    
    if [[ -f "${dir}/.env" ]]; then
        preset_name="${preset_name:-$(dotenv_get "${dir}/.env" "INSTANCE_NAME" || true)}"
        preset_dz_port="${preset_dz_port:-$(dotenv_get "${dir}/.env" "DZ_PORT" || true)}"
        preset_query_port="${preset_query_port:-$(dotenv_get "${dir}/.env" "DZ_QUERY_PORT" || true)}"
        preset_extra_params="$(dotenv_get "${dir}/.env" "DZ_EXTRA_PARAMS" || true)"
    fi
    
    preset_name="${preset_name:-$(basename "${dir}")}"
}

# Collect presets from a container
# Usage: collect_presets_from_container "dayz-server1"
collect_presets_from_container() {
    local container="$1"
    local inst_name="${container#dayz-}"
    local wd
    wd="$(compose_workdir_for_container "${container}")"
    
    preset_name="${inst_name}"
    preset_dir=""
    preset_host_net=""
    preset_dz_port=""
    preset_query_port=""
    preset_extra_params=""
    
    if [[ -n "${wd}" && -d "${wd}" ]]; then
        collect_presets_from_dir "${wd}"
        preset_name="${inst_name}"
    fi
}
