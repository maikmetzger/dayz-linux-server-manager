#!/usr/bin/env bash
# =============================================================================
# DayZ RCON Wrapper
# =============================================================================
# Wrapper around lib/be_rcon.py to simplify connecting to instances
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Load Libraries
for lib in colors tui menu dialogs utils docker instance; do
    source "${SCRIPT_DIR}/lib/${lib}.sh"
done

init_user_identity

# =============================================================================
# Helpers
# =============================================================================
get_rcon_details() {
    local inst_dir="$1"
    local marker="${inst_dir}/.dayz-instance"
    [[ -f "${marker}" ]] || return 1
    
    local dz_port
    dz_port="$(marker_get "${marker}" "DZ_PORT")"
    [[ -n "${dz_port}" ]] || return 1
    
    local rcon_port=$((dz_port + 3))
    
    local be_cfg="${inst_dir}/data/config/BEServer_x64.cfg"
    [[ -f "${be_cfg}" ]] || return 1
    
    local rcon_pass
    # Extract RConPassword from config using simple grep/awk, removing comments if any
    rcon_pass=$(grep -E '^\s*RConPassword' "${be_cfg}" | awk '{$1=""; print $0}' | xargs)
    [[ -n "${rcon_pass}" ]] || return 1
    
    echo "${rcon_port}"
    echo "${rcon_pass}"
}

run_rcon() {
    local inst_dir="$1"
    local cmd="${2:-}"
    
    if [[ ! -d "${inst_dir}" ]]; then
        die "Instance directory not found: ${inst_dir}"
    fi
    
    local marker="${inst_dir}/.dayz-instance"
    local container_name
    container_name="$(marker_get "${marker}" "CONTAINER_NAME")"
    [[ -n "${container_name}" ]] || die "Could not determine container name."

    if ! get_container_status "$container_name" | grep -q "RUNNING"; then
        die "Container $container_name is not running. Start it first."
    fi
    
    mapfile -t details < <(get_rcon_details "${inst_dir}")
    if [[ ${#details[@]} -lt 2 ]]; then
        die "Could not determine RCON details for ${inst_dir} (Missing config or port?)"
    fi
    
    local port="${details[0]}"
    local pass="${details[1]}"
    local host="127.0.0.1"
    
    local python_src="${SCRIPT_DIR}/lib/be_rcon.py"
    [[ -f "${python_src}" ]] || die "Missing RCON client script: ${python_src}"
    
    # Copy script to container
    $DOCKER cp "${python_src}" "${container_name}:/tmp/rcon_client.py"
    
    # Check if python3 is inside container (simple check)
    if ! $DOCKER exec "${container_name}" which python3 >/dev/null 2>&1; then
        die "python3 not found inside container. Please rebuild container to include python3."
    fi
    
    if [[ -n "${cmd}" ]]; then
        $DOCKER exec "${container_name}" python3 /tmp/rcon_client.py --host "${host}" --port "${port}" --password "${pass}" --command "${cmd}"
    else
        # Interactive mode needs -it
        $DOCKER exec -it "${container_name}" python3 /tmp/rcon_client.py --host "${host}" --port "${port}" --password "${pass}"
    fi
    
    # Clean up (optional, but good practice if we run often)
    $DOCKER exec "${container_name}" rm -f /tmp/rcon_client.py
}

main_menu() {
    while true; do
        draw_header "DayZ RCON Console"
        
        local scan_root="${invoking_home}/servers"
        mapfile -t markers < <(discover_instances_under "${scan_root}")
        
        if [[ ${#markers[@]} -eq 0 ]]; then
            show_message "No instances found in ${scan_root}"
            exit 0
        fi
        
        local -a items=() paths=()
        for m in "${markers[@]}"; do
            local n d
            n="$(marker_get "${m}" "INSTANCE_NAME")"
            d="$(dirname "${m}")"
            items+=("${n} ($d)")
            paths+=("$d")
        done
        items+=("Exit")
        
        if run_menu items "Select Instance to Connect"; then
            if [[ $MENU_RESULT -eq ${#paths[@]} ]]; then
                exit 0
            fi
            
            local chosen="${paths[$MENU_RESULT]}"
            printf "%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
            run_rcon "${chosen}"
            
            printf "\n%s%sConnection closed. Press Enter...%s" "$DIM" "$BOLD" "$RESET"
            read -rsn1
        else
            exit 0
        fi
    done
}

# =============================================================================
# Usage: ./rcon.sh [instance_path] [command]
# =============================================================================
if [[ $# -gt 0 ]]; then
    run_rcon "$1" "${2:-}"
else
    main_menu
fi
