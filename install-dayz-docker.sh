#!/usr/bin/env bash
# =============================================================================
# DayZ Docker Server Installer
# =============================================================================
# Creates and manages DayZ server instances in Docker containers
# Supports both interactive TUI wizard and CLI mode
# =============================================================================

set -euo pipefail
IFS=$'\n\t'
trap 'echo "ERROR: failed on line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH_SRC="${SCRIPT_DIR}/run.sh"

# =============================================================================
# Load Libraries
# =============================================================================
for lib in colors tui menu dialogs utils docker instance; do
    source "${SCRIPT_DIR}/lib/${lib}.sh"
done

# Set up cleanup trap
trap cleanup EXIT

# =============================================================================
# User Identity & Permission Setup
# =============================================================================
init_user_identity
invoking_user="$INVOKING_USER"
invoking_home="$INVOKING_HOME"

PUID="$(id -u "${invoking_user}")"
PGID="$(id -g "${invoking_user}")"

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then SUDO="sudo"; fi

DOCKER_GROUP_ADDED_THIS_RUN=0

# =============================================================================
# Additional Installer-Specific Prompts
# =============================================================================
prompt_default() {
    local msg="$1" def="$2"
    read -r -p "${msg} [${def}]: " ans || true
    echo "${ans:-$def}"
}

prompt_yn() {
    local msg="$1" def="$2"
    local prompt
    [[ "${def}" == "Y" || "${def}" == "y" ]] && prompt="[Y/n]" || prompt="[y/N]"
    while true; do
        read -r -p "${msg} ${prompt}: " ans || true
        ans="${ans:-$def}"
        case "${ans}" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) info "Answer y or n." ;;
        esac
    done
}

require_root_or_sudo() {
    [[ "${EUID}" -eq 0 || -n "${SUDO}" ]] || die "Root privileges required. Re-run with sudo."
}

# =============================================================================
# Docker Socket Permission Check
# =============================================================================
require_sudo_for_docker_socket() {
    if ! is_cmd docker; then return 0; fi
    if docker info >/dev/null 2>&1; then return 0; fi

    if is_cmd sudo && sudo docker info >/dev/null 2>&1; then
        cat >&2 <<EOF
${YLW}WARN:${C0} Docker is installed but your current shell user cannot access the Docker daemon socket.

What you must do:
  Re-run this installer with sudo:
    sudo $0

Alternative (then you can run without sudo):
  Refresh group membership: newgrp docker
  then re-run: $0
EOF
        exit 1
    fi

    die "Docker is installed but not reachable. Check: sudo systemctl status docker"
}

# =============================================================================
# Docker Installation (Installer-Specific)
# =============================================================================
ensure_docker() {
    step "Step: Docker check / install"

    if is_cmd docker && docker info >/dev/null 2>&1; then
        ok "Docker OK: $(docker --version 2>/dev/null || true)"
    else
        warn "Docker not found or daemon not reachable."
        if ! prompt_yn "Install Docker Engine + Compose plugin now?" "Y"; then
            die "Docker required. Install it, then re-run."
        fi

        require_root_or_sudo

        source /etc/os-release || true
        case "${ID:-}" in ubuntu|debian) ;; *) die "Auto Docker install supported only on Ubuntu/Debian." ;; esac

        info "Installing Docker..."
        run_arr ${SUDO} apt-get update -y
        run_arr ${SUDO} apt-get install -y ca-certificates curl gnupg
        run_arr ${SUDO} install -m 0755 -d /etc/apt/keyrings
        run_arr ${SUDO} curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
        run_arr ${SUDO} chmod a+r /etc/apt/keyrings/docker.asc

        arch="$(${SUDO} dpkg --print-architecture)"
        codename="${VERSION_CODENAME:-noble}"

        run_shell "echo 'deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${codename} stable' | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null"
        run_arr ${SUDO} apt-get update -y
        run_arr ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        run_arr ${SUDO} systemctl enable --now docker

        if prompt_yn "Add user '${invoking_user}' to docker group (avoids sudo; requires re-login)?" "Y"; then
            run_arr ${SUDO} usermod -aG docker "${invoking_user}"
            DOCKER_GROUP_ADDED_THIS_RUN=1
            warn "User '${invoking_user}' was added to the 'docker' group."
            warn "This does NOT apply until you log out/in (or run: newgrp docker)."
        fi
    fi

    docker compose version >/dev/null 2>&1 || die "docker compose plugin missing."
    select_docker_wrapper || die "Docker installed but not usable (permission/daemon issue)."

    ok "Docker Compose plugin OK: $(docker compose version 2>/dev/null || true)"
    ok "Using docker wrapper: ${DOCKER_ARR[*]}"
}

# =============================================================================
# UFW Configuration
# =============================================================================
run_sudo_arr() {
    if [[ -n "${SUDO}" ]]; then
        run_arr sudo "$@"
    else
        run_arr "$@"
    fi
}

ufw_allow_with_comment_fallback() {
    local rule="$1" comment="$2"
    if run_sudo_arr ufw allow "${rule}" comment "${comment}"; then
        return 0
    fi
    warn "ufw rule with comment failed; retrying without comment."
    run_sudo_arr ufw allow "${rule}"
}

configure_ufw() {
    local port="$1" query="$2" inst_dir="$3"
    is_cmd ufw || { warn "ufw not installed; skipping firewall rules."; return 0; }

    step "Step: Firewall (UFW) rules"
    
    local missing=0
    local port_rule="${port}:$((port+3))/udp"
    local query_rule="${query}/udp"
    
    if ${SUDO} ufw status | grep -q "${port_rule}"; then
        info "Rule exists for Game Ports: ${port_rule}"
    else
        missing=1
        info "MISSING Rule for Game Ports: ${port_rule}"
    fi
    
    if ${SUDO} ufw status | grep -q "${query_rule}"; then
        info "Rule exists for Query Port: ${query_rule}"
    else
        missing=1
        info "MISSING Rule for Query Port: ${query_rule}"
    fi

    if [[ $missing -eq 0 ]]; then
        ok "All firewall rules are already present."
        return 0
    fi
    
    info "New rules will be recorded in: ${inst_dir}/UFW_RULES.txt"
    
    if ! prompt_yn "Add MISSING UFW rules now?" "Y"; then
        warn "Skipping UFW changes."; return 0
    fi

    require_root_or_sudo
    mkdir -p "${inst_dir}"

    cat > "${inst_dir}/UFW_RULES.txt" <<EOF
DayZ UFW rules for this instance

1) UDP ${port}:$((port+3))
   Purpose: DayZ server base game port range (base +0..+3)

2) UDP ${query}
   Purpose: Steam query port (steamQueryPort in serverDZ.cfg)
EOF
    chmod 600 "${inst_dir}/UFW_RULES.txt" || true

    ufw_allow_with_comment_fallback "${port_rule}" "DayZ game ports (base +0..+3)"
    ufw_allow_with_comment_fallback "${query_rule}" "DayZ Steam query port"

    ${SUDO} ufw status | grep -qi "Status: active" && ok "UFW active; rules applied." || warn "UFW inactive; rules added but not active."
}

# =============================================================================
# Instance Deletion
# =============================================================================
delete_instance_dir() {
    local inst_dir="$1"
    local marker="${inst_dir}/.dayz-instance"
    [[ -f "${marker}" ]] || die "No instance marker at: ${marker}"

    local name container_name
    name="$(marker_get "${marker}" "INSTANCE_NAME")"
    container_name="$(marker_get "${marker}" "CONTAINER_NAME")"
    [[ -n "${name}" ]] || name="$(basename "${inst_dir}")"
    [[ -n "${container_name}" ]] || container_name="dayz-${name}"

    step "Step: Delete instance"
    warn "You are about to DELETE this DayZ instance:"
    warn "  Instance name:   ${name}"
    warn "  Container name:  ${container_name}"
    warn "  Directory:       ${inst_dir}"

    if ! prompt_yn "Continue with deletion?" "N"; then
        warn "Deletion cancelled."
        return 1
    fi

    local confirm_input=""
    read -r -p "Type the instance name '${name}' to confirm: " confirm_input || true
    [[ "${confirm_input}" == "${name}" ]] || die "Confirmation did not match. Aborting."

    if [[ -f "${inst_dir}/docker-compose.yml" ]]; then
        run_in_dir "${inst_dir}" "${DOCKER_ARR[@]}" compose down --remove-orphans || true
    fi

    if "${DOCKER_ARR[@]}" ps -a --format '{{.Names}}' | grep -qx "${container_name}"; then
        run_arr "${DOCKER_ARR[@]}" rm -f "${container_name}"
    fi

    if rm -rf "${inst_dir}" 2>/dev/null; then
        :
    else
        warn "Direct rm failed (permissions). Retrying with sudo."
        run_arr ${SUDO:+"$SUDO"} rm -rf "${inst_dir}"
    fi

    ok "Deleted instance '${name}'."
}

delete_container_only() {
    local container="$1"

    step "Step: Delete container"
    warn "You are about to DELETE the container:"
    warn "  ${container}"
    if ! prompt_yn "Continue with deletion?" "N"; then
        warn "Deletion cancelled."
        return 1
    fi

    local confirm_input=""
    read -r -p "Type DELETE to confirm: " confirm_input || true
    [[ "${confirm_input}" == "DELETE" ]] || die "Confirmation did not match. Aborting."

    local workdir=""
    workdir="$(compose_workdir_for_container "${container}")"

    if [[ -n "${workdir}" && -d "${workdir}" && -f "${workdir}/docker-compose.yml" ]]; then
        run_in_dir "${workdir}" "${DOCKER_ARR[@]}" compose down --remove-orphans || true
    fi

    if "${DOCKER_ARR[@]}" ps -a --format '{{.Names}}' | grep -qx "${container}"; then
        run_arr "${DOCKER_ARR[@]}" rm -f "${container}"
    fi

    if [[ -n "${workdir}" ]] && container_has_compose_dir "${workdir}"; then
        warn "Compose working directory detected: ${workdir}"
        if prompt_yn "Delete that directory as well?" "Y"; then
            if rm -rf "${workdir}" 2>/dev/null; then :
            else run_arr ${SUDO:+"$SUDO"} rm -rf "${workdir}"; fi
            ok "Deleted directory: ${workdir}"
        else
            warn "Directory kept: ${workdir}"
        fi
    fi

    ok "Deleted container '${container}'."
}

# =============================================================================
# Instance Creation
# =============================================================================
create_instance() {
    local inst_dir="$1" name="$2"
    local container_name="dayz-${name}"
    local use_host_net="$3" dz_port="$4" query_port="$5"
    local steam_user="$6" steam_pass="$7" extra_params="$8"
    local sync_on_start="$9" update_on_start="${10}"
    local rcon_pass="${11}"

    step "Step: Creating instance files"
    info "Instance directory: ${inst_dir}"
    info "Container name:      ${container_name}"

    if "${DOCKER_ARR[@]}" ps -a --format '{{.Names}}' | grep -qx "${container_name}"; then
        die "Container '${container_name}' already exists."
    fi
    [[ -e "${inst_dir}/.dayz-instance" ]] && die "Marker exists in ${inst_dir}. Use update mode or choose a new directory."

    mkdir -p "${inst_dir}/data/serverfiles" "${inst_dir}/data/config" "${inst_dir}/data/profile" "${inst_dir}/data/state" "${inst_dir}/data/backups"
    chmod 700 "${inst_dir}/data" "${inst_dir}/data/config" "${inst_dir}/data/state" || true

    [[ -f "${RUN_SH_SRC}" ]] || die "Missing ${RUN_SH_SRC}. Put run.sh next to install-dayz-docker.sh."
    cp -f "${RUN_SH_SRC}" "${inst_dir}/run.sh"
    chmod +x "${inst_dir}/run.sh"
    sed -i 's/\r$//' "${inst_dir}/run.sh"

    local admin_pw
    admin_pw="$(prompt_default "Set passwordAdmin for serverDZ.cfg" "CHANGEME_ADMIN_PASSWORD")"

    write_file "${inst_dir}/data/config/serverDZ.cfg" \
"hostname = \"DayZ ${name}\";
password = \"\";
passwordAdmin = \"${admin_pw}\";
maxPlayers = 30;
verifySignatures = 2;
forceSameBuild = 1;
persistent = 1;
instanceId = 1;

steamQueryPort = ${query_port};

class Missions { class DayZ { template = \"dayzOffline.chernarusplus\"; }; };
"
    chmod 600 "${inst_dir}/data/config/serverDZ.cfg"

    if [[ -z "${rcon_pass}" ]]; then
        rcon_pass="CHANGEME_RCON_$(date +%s)"
    fi

    write_file "${inst_dir}/data/config/BEServer_x64.cfg" \
"RConPassword ${rcon_pass}
RConPort $((dz_port+3))
RestrictRCon 1
"
    chmod 600 "${inst_dir}/data/config/BEServer_x64.cfg"

    [[ -f "${inst_dir}/data/config/mods.txt" ]] || write_file "${inst_dir}/data/config/mods.txt" "# one Workshop ID per line\n"
    [[ -f "${inst_dir}/data/config/servermods.txt" ]] || write_file "${inst_dir}/data/config/servermods.txt" "# one Workshop ID per line\n"
    chmod 600 "${inst_dir}/data/config/mods.txt" "${inst_dir}/data/config/servermods.txt" || true

    write_file "${inst_dir}/Dockerfile" \
"FROM debian:bullseye-slim
ARG PUID=1000
ARG PGID=1000
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \\
&& apt-get install -y --no-install-recommends \\
    ca-certificates curl jq \\
    lib32gcc-s1 libstdc++6 libcurl4 \\
    libtbb2 \\
    procps iproute2 \\
    tini tar gzip unzip \\
    python3 \\
&& rm -rf /var/lib/apt/lists/*
RUN groupadd -g \${PGID} dayz \\
&& useradd -u \${PUID} -g \${PGID} -m -d /dayz dayz \\
&& mkdir -p /dayz /opt/steamcmd \\
&& chown -R dayz:dayz /dayz /opt/steamcmd
RUN curl -fsSL \"https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz\" -o /tmp/steamcmd.tar.gz \\
&& tar -xzf /tmp/steamcmd.tar.gz -C /opt/steamcmd \\
&& rm -f /tmp/steamcmd.tar.gz \\
&& chmod -R a+rX /opt/steamcmd \\
&& chmod +x /opt/steamcmd/steamcmd.sh \\
&& find /opt/steamcmd -type f -name steamcmd -exec chmod +x {} \\; || true \\
&& chown -R dayz:dayz /opt/steamcmd
ENV STEAMCMD=/opt/steamcmd/steamcmd.sh
ENV HOME=/dayz
WORKDIR /dayz
USER dayz
ENTRYPOINT [\"/usr/bin/tini\",\"--\"]
"

    write_file "${inst_dir}/.env" \
"PUID=${PUID}
PGID=${PGID}
INSTANCE_NAME=$(env_quote "${name}")
CONTAINER_NAME=$(env_quote "dayz-${name}")

APPID=223350
WORKSHOP_APPID=221100

DZ_PORT=${dz_port}
DZ_QUERY_PORT=${query_port}
DZ_EXTRA_PARAMS=$(env_quote "${extra_params}")

STEAM_USER=$(env_quote "${steam_user}")
STEAM_PASS=$(env_quote "${steam_pass}")

DZ_SYNC_ON_START=${sync_on_start}
DZ_UPDATE_ON_START=${update_on_start}
"
    chmod 600 "${inst_dir}/.env"

    local restart_policy="on-failure:5"

    if [[ "${use_host_net}" == "yes" ]]; then
        write_file "${inst_dir}/docker-compose.yml" \
"services:
  dayz:
    build:
      context: .
      args:
        PUID: \${PUID}
        PGID: \${PGID}
    container_name: \${CONTAINER_NAME}
    restart: ${restart_policy}
    network_mode: host
    stop_signal: SIGINT
    stop_grace_period: 90s
    user: \"\${PUID}:\${PGID}\"
    environment:
      HOME: /dayz
      APPID: \${APPID}
      WORKSHOP_APPID: \${WORKSHOP_APPID}
      STEAM_USER: \${STEAM_USER}
      STEAM_PASS: \${STEAM_PASS}
      DZ_PORT: \${DZ_PORT}
      DZ_QUERY_PORT: \${DZ_QUERY_PORT}
      DZ_EXTRA_PARAMS: \${DZ_EXTRA_PARAMS}
      DZ_SYNC_ON_START: \${DZ_SYNC_ON_START}
      DZ_UPDATE_ON_START: \${DZ_UPDATE_ON_START}
      DZ_SERVERFILES: /dayz/serverfiles
      DZ_CONFIG_DIR: /dayz/config
      DZ_PROFILE: /dayz/profile
      DZ_STATE: /dayz/state
    ulimits:
      nofile:
        soft: 100000
        hard: 100000
    volumes:
      - ./data/serverfiles:/dayz/serverfiles
      - ./data/config:/dayz/config
      - ./data/profile:/dayz/profile
      - ./data/state:/dayz/state
      - ./data/backups:/dayz/backups
      - ./run.sh:/dayz/run.sh:ro
    command: [\"/dayz/run.sh\",\"foreground\"]
    healthcheck:
      test: [\"CMD-SHELL\",\"pgrep -f DayZServer >/dev/null || exit 1\"]
      interval: 30s
      timeout: 30s
      retries: 3
"
    else
        write_file "${inst_dir}/docker-compose.yml" \
"services:
  dayz:
    build:
      context: .
      args:
        PUID: \${PUID}
        PGID: \${PGID}
    container_name: \${CONTAINER_NAME}
    restart: ${restart_policy}
    stop_signal: SIGINT
    stop_grace_period: 90s
    user: \"\${PUID}:\${PGID}\"
    ports:
      - \"\${DZ_PORT}:\${DZ_PORT}/udp\"
      - \"$((dz_port+1)):$((dz_port+1))/udp\"
      - \"$((dz_port+2)):$((dz_port+2))/udp\"
      - \"$((dz_port+3)):$((dz_port+3))/udp\"
      - \"\${DZ_QUERY_PORT}:\${DZ_QUERY_PORT}/udp\"
    environment:
      HOME: /dayz
      APPID: \${APPID}
      WORKSHOP_APPID: \${WORKSHOP_APPID}
      STEAM_USER: \${STEAM_USER}
      STEAM_PASS: \${STEAM_PASS}
      DZ_PORT: \${DZ_PORT}
      DZ_QUERY_PORT: \${DZ_QUERY_PORT}
      DZ_EXTRA_PARAMS: \${DZ_EXTRA_PARAMS}
      DZ_SYNC_ON_START: \${DZ_SYNC_ON_START}
      DZ_UPDATE_ON_START: \${DZ_UPDATE_ON_START}
      DZ_SERVERFILES: /dayz/serverfiles
      DZ_CONFIG_DIR: /dayz/config
      DZ_PROFILE: /dayz/profile
      DZ_STATE: /dayz/state
    ulimits:
      nofile:
        soft: 100000
        hard: 100000
    volumes:
      - ./data/serverfiles:/dayz/serverfiles
      - ./data/config:/dayz/config
      - ./data/profile:/dayz/profile
      - ./data/state:/dayz/state
      - ./data/backups:/dayz/backups
      - ./run.sh:/dayz/run.sh:ro
    command: [\"/dayz/run.sh\",\"foreground\"]
    healthcheck:
      test: [\"CMD-SHELL\",\"pgrep -f DayZServer >/dev/null || exit 1\"]
      interval: 30s
      timeout: 30s
      retries: 3
"
        warn "Bridge mode note: published ports can bypass UFW rules in some setups."
    fi

    write_file "${inst_dir}/.dayz-instance" \
"INSTANCE_NAME=${name}
CONTAINER_NAME=dayz-${name}
DIR=${inst_dir}
DZ_PORT=${dz_port}
DZ_QUERY_PORT=${query_port}
HOST_NETWORK=${use_host_net}
"
    chmod 600 "${inst_dir}/.dayz-instance" || true

    if [[ "${EUID}" -eq 0 ]]; then
        chown -R "${invoking_user}:${invoking_user}" "${inst_dir}" || true
    fi

    ok "Instance created."
}

update_run_sh_only() {
    local inst_dir="$1"
    local marker="${inst_dir}/.dayz-instance"
    [[ -f "${marker}" ]] || die "No instance marker at: ${marker}"

    local container_name
    container_name="$(marker_get "${marker}" "CONTAINER_NAME")"
    [[ -n "${container_name}" ]] || die "Could not read CONTAINER_NAME from marker."

    step "Step: Updating run.sh only"
    cp -f "${RUN_SH_SRC}" "${inst_dir}/run.sh"
    chmod +x "${inst_dir}/run.sh"
    sed -i 's/\r$//' "${inst_dir}/run.sh"
    ok "Updated run.sh."

    if "${DOCKER_ARR[@]}" ps --format '{{.Names}}' | grep -qx "${container_name}"; then
        if prompt_yn "Container '${container_name}' is running. Restart it now?" "Y"; then
            run_in_dir "${inst_dir}" "${DOCKER_ARR[@]}" compose restart
            ok "Restarted ${container_name}."
        fi
    else
        warn "Container '${container_name}' not running. Update applied."
    fi
}

# =============================================================================
# CLI Mode Support
# =============================================================================
CLI_MODE=0
CLI_NAME=""
CLI_DIR=""
CLI_PORT=""
CLI_QUERY_PORT=""
CLI_HOST_NET=""
CLI_STEAM_USER=""
CLI_STEAM_PASS=""
CLI_ADMIN_PASS=""
CLI_RCON_PASS=""
CLI_EXTRA_PARAMS=""
CLI_SYNC_ON_START=""
CLI_UPDATE_ON_START=""
CLI_NO_UFW=0
CLI_NO_START=0

show_usage() {
    cat <<'EOF'
DayZ Docker Server Installer

USAGE:
  ./install-dayz-docker.sh                    # Interactive wizard mode
  ./install-dayz-docker.sh [OPTIONS]          # CLI mode (non-interactive)

REQUIRED OPTIONS (CLI mode):
  --steam-user <user>     Steam account username
  --steam-pass <pass>     Steam account password
  --admin-pass <pass>     Server admin password
  --rcon-pass <pass>      RCON password (default: random)

OPTIONAL OPTIONS:
  --name <name>           Instance name (default: server1)
  --dir <path>            Install directory
  --port <port>           Game port UDP (default: 2302)
  --query-port <port>     Steam query port UDP (default: 27016)
  --host-net              Use host networking (default)
  --no-host-net           Use bridge networking
  --extra-params <str>    Extra DayZ launch parameters
  --sync-on-start         Auto-sync mods on container start
  --update-on-start       Auto-update server on container start
  --no-ufw                Skip UFW firewall configuration
  --no-start              Don't start container after creation
  -h, --help              Show this help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_usage; exit 0 ;;
            --steam-user) CLI_STEAM_USER="$2"; shift 2 ;;
            --steam-pass) CLI_STEAM_PASS="$2"; shift 2 ;;
            --admin-pass) CLI_ADMIN_PASS="$2"; shift 2 ;;
            --rcon-pass) CLI_RCON_PASS="$2"; shift 2 ;;
            --name) CLI_NAME="$2"; shift 2 ;;
            --dir) CLI_DIR="$2"; shift 2 ;;
            --port) CLI_PORT="$2"; shift 2 ;;
            --query-port) CLI_QUERY_PORT="$2"; shift 2 ;;
            --host-net) CLI_HOST_NET="yes"; shift ;;
            --no-host-net) CLI_HOST_NET="no"; shift ;;
            --extra-params) CLI_EXTRA_PARAMS="$2"; shift 2 ;;
            --sync-on-start) CLI_SYNC_ON_START="1"; shift ;;
            --update-on-start) CLI_UPDATE_ON_START="1"; shift ;;
            --no-ufw) CLI_NO_UFW=1; shift ;;
            --no-start) CLI_NO_START=1; shift ;;
            *) die "Unknown option: $1. Use --help for usage." ;;
        esac
    done

    if [[ -n "${CLI_STEAM_USER}" || -n "${CLI_STEAM_PASS}" || -n "${CLI_ADMIN_PASS}" || 
          -n "${CLI_NAME}" || -n "${CLI_DIR}" || -n "${CLI_PORT}" ]]; then
        CLI_MODE=1
    fi

    if [[ "${CLI_MODE}" == "1" ]]; then
        [[ -n "${CLI_STEAM_USER}" ]] || die "CLI mode requires --steam-user"
        [[ -n "${CLI_STEAM_PASS}" ]] || die "CLI mode requires --steam-pass"
        [[ -n "${CLI_ADMIN_PASS}" ]] || die "CLI mode requires --admin-pass"
        
        CLI_NAME="${CLI_NAME:-server1}"
        CLI_PORT="${CLI_PORT:-2302}"
        CLI_QUERY_PORT="${CLI_QUERY_PORT:-27016}"
        CLI_HOST_NET="${CLI_HOST_NET:-yes}"
        CLI_SYNC_ON_START="${CLI_SYNC_ON_START:-0}"
        CLI_UPDATE_ON_START="${CLI_UPDATE_ON_START:-0}"
        
        [[ "${CLI_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$ ]] || die "Invalid --name"
        [[ "${CLI_PORT}" =~ ^[0-9]+$ ]] || die "Invalid --port"
        [[ "${CLI_QUERY_PORT}" =~ ^[0-9]+$ ]] || die "Invalid --query-port"
    fi
}

run_cli_mode() {
    step "CLI Mode: Creating DayZ instance"
    
    local name="${CLI_NAME}"
    local inst_dir="${CLI_DIR:-${invoking_home}/servers/dayz-${name}}"
    local dz_port="${CLI_PORT}"
    local query_port="${CLI_QUERY_PORT}"
    local use_host_net="${CLI_HOST_NET}"
    local steam_user="${CLI_STEAM_USER}"
    local steam_pass="${CLI_STEAM_PASS}"
    local rcon_pass="${CLI_RCON_PASS:-CHANGEME_RCON_$(date +%s)}"
    local extra_params="${CLI_EXTRA_PARAMS:-}"
    local sync_on_start="${CLI_SYNC_ON_START}"
    local update_on_start="${CLI_UPDATE_ON_START}"
    
    info "Instance name:    ${name}"
    info "Install dir:      ${inst_dir}"
    info "Game port:        ${dz_port}"
    info "Query port:       ${query_port}"
    info "Host networking:  ${use_host_net}"
    
    if "${DOCKER_ARR[@]}" ps -a --format '{{.Names}}' | grep -qx "dayz-${name}"; then
        die "Container 'dayz-${name}' already exists."
    fi
    
    if [[ -e "${inst_dir}/.dayz-instance" ]]; then
        die "Instance marker exists at ${inst_dir}."
    fi
    
    if [[ "${CLI_NO_UFW}" != "1" ]]; then
        configure_ufw "${dz_port}" "${query_port}" "${inst_dir}"
    else
        info "Skipping UFW configuration (--no-ufw)"
    fi
    
    create_instance "${inst_dir}" "${name}" "${use_host_net}" "${dz_port}" "${query_port}" \
        "${steam_user}" "${steam_pass}" "${extra_params}" "${sync_on_start}" "${update_on_start}" \
        "${rcon_pass}"
    
    step "Step: Building image"
    run_in_dir "${inst_dir}" "${DOCKER_ARR[@]}" compose build --no-cache
    
    if [[ "${CLI_NO_START}" != "1" ]]; then
        step "Step: Starting container"
        run_in_dir "${inst_dir}" "${DOCKER_ARR[@]}" compose up -d
        ok "Started: dayz-${name}"
        info "Logs: cd '${inst_dir}' && ${DOCKER_ARR[*]} compose logs -f --tail=200"
    else
        info "Container not started (--no-start)."
    fi
    
    hr
    ok "CLI install complete!"
    info "Instance directory: ${inst_dir}"
    info "Container name: dayz-${name}"
    
    # Setup ban expiry timer if setup script exists
    local timer_setup="${SCRIPT_DIR}/lib/setup_ban_expiry_timer.sh"
    if [[ -f "${timer_setup}" ]]; then
        step "Step: Setting up ban expiry timer"
        if bash "${timer_setup}" "${inst_dir}" 2>/dev/null; then
            ok "Ban expiry timer enabled (checks every minute)"
        else
            warn "Could not setup ban expiry timer. Run manually: ${timer_setup} ${inst_dir}"
        fi
    fi
    
    info ""
    info "Manage with: ./server-manager.sh"
}

# =============================================================================
# TUI Interactive Logic
# =============================================================================
main_tui() {
    local scan_root="${invoking_home}/servers"
    
    while true; do
        draw_header "DayZ Docker Installer"
        
        mapfile -t markers < <(discover_instances_under "${scan_root}")
        mapfile -t containers < <(list_dayz_containers)
        
        local -a menu_items=()
        menu_items+=("🆕|Create NEW Instance")

        if [[ "${#markers[@]}" -gt 0 ]]; then
            menu_items+=("🔄|Update run.sh for Instance")
        else
            menu_items+=("🔄|Update run.sh (No instances found)")
        fi
        
        menu_items+=("🗑️|Delete Instance/Container")
        menu_items+=("--------------------")
        menu_items+=("✨|Run Server Manager")
        menu_items+=("--------------------")
        menu_items+=("❌|Exit")
        
        if ! run_menu menu_items "Main Menu"; then return; fi
        
        local selected_item="${menu_items[$MENU_RESULT]}"
        case "$selected_item" in
            "🆕|Create NEW Instance") tui_create_instance ;;
            "🔄|Update run.sh"*)
                if [[ "${#markers[@]}" -eq 0 ]]; then
                    show_message "No marker-based instances found." "Error"
                    continue
                fi
                tui_update_instance "${markers[@]}"
                ;;
            "🗑️|Delete Instance/Container") tui_delete_menu "${scan_root}" || true ;;
            "✨|Run Server Manager")
                if [[ -f "${SCRIPT_DIR}/server-manager.sh" ]]; then
                    bash "${SCRIPT_DIR}/server-manager.sh"
                    # After returning from server-manager, we stay in the installer
                    # and let the loop continue or return to main_menu.
                else
                    show_message "server-manager.sh not found."
                fi
                ;;
            "❌|Exit"|----*)
                exit 0
                ;;
        esac
    done
}

tui_create_instance() {
    local name
    name=$(read_input "Instance Name" "${preset_name:-server1}" "Create Instance")
    [[ -z "$name" ]] && return
    
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$ ]] || { show_message "Invalid name." "Error"; return; }
    
    local default_base="${invoking_home}/servers/dayz-${name}"
    local default_dir="$default_base"
    if [[ -e "$default_dir" ]]; then
        local n=2
        while [[ -e "${default_base}-${n}" ]]; do ((n+=1)); done
        default_dir="${default_base}-${n}"
    fi
    
    local inst_dir
    inst_dir=$(read_input "Install Directory" "$default_dir" "Create Instance")
    [[ -z "$inst_dir" ]] && return
    
    local use_host_net="yes"
    if ! confirm "Use Host Networking? (Recommended)" "y"; then
        use_host_net="no"
    fi
    
    local dz_port query_port
    dz_port=$(read_input "DayZ Game Port (UDP)" "${preset_dz_port:-2302}" "Network Config")
    [[ -z "$dz_port" ]] && return
    
    query_port=$(read_input "Steam Query Port (UDP)" "${preset_query_port:-27016}" "Network Config")
    [[ -z "$query_port" ]] && return
    
    local steam_user steam_pass
    while true; do
        steam_user=$(read_input "Steam Username (REQUIRED)" "" "Steam Credentials")
        [[ -z "$steam_user" ]] && continue
        [[ "${steam_user,,}" == "anonymous" ]] && { show_message "Anonymous not allowed for DayZ." "Error"; continue; }
        break
    done
    if [[ "$steam_user" != "anonymous" ]]; then
        steam_pass=$(read_input "Steam Password" "" "Steam Credentials")
    fi
    
    local admin_pass
    admin_pass=$(read_input "DayZ Admin Password" "changeme$(date +%s)" "Security")
    [[ -z "$admin_pass" ]] && return
    
    local rcon_pass
    rcon_pass=$(read_input "RCON Password" "rcon$(date +%s | tail -c 4)" "Security")
    [[ -z "$rcon_pass" ]] && return
    
    CLI_NAME="$name"
    CLI_DIR="$inst_dir"
    CLI_HOST_NET="$use_host_net"
    CLI_PORT="$dz_port"
    CLI_QUERY_PORT="$query_port"
    CLI_STEAM_USER="$steam_user"
    CLI_STEAM_PASS="$steam_pass"
    CLI_ADMIN_PASS="$admin_pass"
    CLI_RCON_PASS="$rcon_pass"
    CLI_SYNC_ON_START="0"
    CLI_UPDATE_ON_START="0"
    
    printf "%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
    hr
    info "Configuration complete. Starting installation..."
    hr
    
    run_cli_mode
    
    printf "\n%s%sPress Enter to return to menu...%s" "$DIM" "$BOLD" "$RESET"
    read -rsn1
}

tui_update_instance() {
    local -a markers=("${@}")
    local -a items=()
    local -a paths=()
    
    for m in "${markers[@]}"; do
        local n d
        n="$(marker_get "${m}" "INSTANCE_NAME")"
        d="$(dirname "${m}")"
        items+=("📁|${n:-?} (${d})")
        paths+=("$d")
    done
    items+=("--------------------")
    items+=("←|Cancel")
    
    if run_menu items "Update run.sh - Select Instance"; then
        if [[ $MENU_RESULT -lt ${#paths[@]} ]]; then
            local chosen="${paths[$MENU_RESULT]}"
            printf "%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
            update_run_sh_only "$chosen"
            printf "\n%s%sPress Enter to return to menu...%s" "$DIM" "$BOLD" "$RESET"
            read -rsn1
        fi
    fi
    return 0
}

tui_delete_menu() {
    local scan_root="$1"
    local choices=("🏷️|Marker-based Instances" "🐳|Containers detected by Docker" "--------------------" "←|Back")
    
    while true; do
        if ! run_menu choices "Delete Instance"; then return; fi
        
        local selected_choice="${choices[$MENU_RESULT]}"
        case "$selected_choice" in
            "🏷️|Marker-based Instances")
                mapfile -t markers < <(discover_instances_under "${scan_root}")
                if [[ ${#markers[@]} -eq 0 ]]; then
                    show_message "No instances found."
                    continue
                fi
                local -a items=() paths=()
                for m in "${markers[@]}"; do
                    local n d
                    n="$(marker_get "${m}" "INSTANCE_NAME")"
                    d="$(dirname "${m}")"
                    items+=("🗑️|${n} ($d)")
                    paths+=("$d")
                done
                items+=("--------------------")
                items+=("←|Back")
                
                if run_menu items "Select Instance to DELETE"; then
                    local selected_item="${items[$MENU_RESULT]}"
                    if [[ "$selected_item" == "←|Back" || "$selected_item" == ----* ]]; then continue; fi
                    
                    local p="${paths[$MENU_RESULT]}"
                    if confirm "DELETE directory and data: $p?" "n"; then
                        printf "%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
                        collect_presets_from_dir "$p"
                        delete_instance_dir "$p"
                        return
                    fi
                fi
                ;;
            "🐳|Containers detected by Docker")
                mapfile -t containers < <(list_dayz_containers)
                if [[ ${#containers[@]} -eq 0 ]]; then
                    show_message "No containers found."
                    continue
                fi
                local -a c_items=()
                for c in "${containers[@]}"; do c_items+=("🗑️|$c"); done
                c_items+=("--------------------")
                c_items+=("←|Back")
                if run_menu c_items "Select Container to DELETE"; then
                    local selected_item="${c_items[$MENU_RESULT]}"
                    if [[ "$selected_item" == "←|Back" || "$selected_item" == ----* ]]; then continue; fi
                    
                    local ctn="${containers[$MENU_RESULT]}"
                    if confirm "DELETE container $ctn?" "n"; then
                        printf "%s" "$SHOW_CURSOR" "$CLEAR_SCREEN"
                        collect_presets_from_container "$ctn"
                        delete_container_only "$ctn"
                        return
                    fi
                fi
                ;;
            "←|Back"|----*) return 0 ;;
        esac
    done
}

# =============================================================================
# Main Entry Point
# =============================================================================
main() {
    parse_args "$@"
    
    [[ -f "${RUN_SH_SRC}" ]] || die "Expected run.sh next to this installer: ${RUN_SH_SRC}"

    require_sudo_for_docker_socket
    ensure_docker

    if [[ "${DOCKER_GROUP_ADDED_THIS_RUN}" == "1" && "${EUID}" -ne 0 ]]; then
        hr
        warn "Docker group membership changed. Please re-login or run 'newgrp docker'."
        exit 0
    fi

    if [[ "${CLI_MODE}" == "1" ]]; then
        run_cli_mode
        exit 0
    fi
    
    main_tui
}

main "$@"
