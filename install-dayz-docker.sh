#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
trap 'echo "ERROR: failed on line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH_SRC="${SCRIPT_DIR}/run.sh"

# ---------- styling ----------
USE_COLOR=0
if [[ -t 1 ]]; then USE_COLOR=1; fi
if [[ "${USE_COLOR}" == "1" ]]; then
  C0=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; CYN=$'\033[36m'
else
  C0=""; BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; CYN=""
fi

# All log output -> stderr (keeps stdout clean if you ever capture output)
hr(){ printf "%s\n" "${DIM}------------------------------------------------------------${C0}" >&2; }
step(){ hr; printf "%s%s==> %s%s\n" "${BOLD}" "${CYN}" "$*" "${C0}" >&2; }
info(){ printf "%s%s%s\n" "${BLU}" "$*" "${C0}" >&2; }
ok(){ printf "%s%s%s\n" "${GRN}" "$*" "${C0}" >&2; }
warn(){ printf "%sWARN:%s %s\n" "${YLW}" "${C0}" "$*" >&2; }
die(){ printf "%sERROR:%s %s\n" "${RED}" "${C0}" "$*" >&2; exit 1; }

show_cmd(){ printf "%s%s$ %s%s\n" "${DIM}" "${BOLD}" "$*" "${C0}" >&2; }
run_shell(){ show_cmd "$*"; bash -lc "$*"; }
run_arr(){ local -a cmd=( "$@" ); show_cmd "${cmd[*]}"; "${cmd[@]}"; }

is_cmd(){ command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then SUDO="sudo"; fi

invoking_user="${SUDO_USER:-$USER}"
invoking_home="$(getent passwd "${invoking_user}" | cut -d: -f6 || true)"
[[ -n "${invoking_home}" ]] || invoking_home="$HOME"

PUID="$(id -u "${invoking_user}")"
PGID="$(id -g "${invoking_user}")"

# If we add the user to docker group during this run, their current session is NOT refreshed.
DOCKER_GROUP_ADDED_THIS_RUN=0

# Presets used for recreate flows
preset_name=""
preset_dir=""
preset_host_net=""         # "yes"|"no"
preset_dz_port=""
preset_query_port=""
preset_extra_params=""

prompt_default() {
  local prompt="$1" default="$2" reply=""
  read -r -p "${prompt} [${default}]: " reply || true
  if [[ -z "${reply}" ]]; then printf "%s" "${default}"; else printf "%s" "${reply}"; fi
}

prompt_yn() {
  local prompt="$1" default="${2:-Y}" reply=""
  local hint="[Y/n]"
  [[ "${default}" =~ ^[Nn]$ ]] && hint="[y/N]"
  while true; do
    read -r -p "${prompt} ${hint}: " reply || true
    reply="${reply:-$default}"
    case "${reply}" in
      Y|y|yes|YES) return 0 ;;
      N|n|no|NO)   return 1 ;;
      *) warn "Please answer Y or n." ;;
    esac
  done
}

require_root_or_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then return 0; fi
  is_cmd sudo || die "Need root privileges (sudo not found)."
  sudo true
}

# -------------------------------------------------------------------
# IMPORTANT: Docker daemon socket access (permission denied fix)
# -------------------------------------------------------------------
require_sudo_for_docker_socket() {
  if ! is_cmd docker; then return 0; fi
  if docker info >/dev/null 2>&1; then return 0; fi

  if is_cmd sudo && sudo docker info >/dev/null 2>&1; then
    cat >&2 <<EOF
${YLW}WARN:${C0} Docker is installed and running, but your current shell user cannot access the Docker daemon socket:
  /var/run/docker.sock

Exact reason:
  The socket is owned by root:docker. Your current session does not have the required permissions (usually because:
  - you are not in the 'docker' group, OR
  - you were added, but haven't logged out/in yet so the group membership isn't active).

What you must do:
  Re-run this installer with sudo:
    sudo $0

Alternative (then you can run without sudo):
  Refresh group membership in this terminal:
    newgrp docker
  then re-run:
    $0
EOF
    exit 1
  fi

  die "Docker is installed but not reachable. Check: sudo systemctl status docker"
}

# Docker wrapper as array (supports "sudo docker")
DOCKER=(docker)
select_docker_wrapper() {
  if docker info >/dev/null 2>&1; then DOCKER=(docker); return 0; fi
  if is_cmd sudo && sudo docker info >/dev/null 2>&1; then DOCKER=(sudo docker); warn "Using sudo for docker commands."; return 0; fi
  return 1
}

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

    info "Will run: apt-get update; install prereqs; add Docker repo; install docker-ce + compose plugin; enable docker."
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

    if prompt_yn "Add user '${invoking_user}' to docker group (avoids sudo for docker; requires re-login)?" "Y"; then
      run_arr ${SUDO} usermod -aG docker "${invoking_user}"
      DOCKER_GROUP_ADDED_THIS_RUN=1
      warn "User '${invoking_user}' was added to the 'docker' group."
      warn "This does NOT apply to your current login session until you log out/in (or run: newgrp docker)."
    fi
  fi

  docker compose version >/dev/null 2>&1 || die "docker compose plugin missing."
  select_docker_wrapper || die "Docker installed but not usable (permission/daemon issue)."

  ok "Docker Compose plugin OK: $(docker compose version 2>/dev/null || true)"
  ok "Using docker wrapper: ${DOCKER[*]}"
}

discover_instances_under() {
  local root="$1"
  [[ -d "${root}" ]] || return 0
  find "${root}" -type f -name ".dayz-instance" -print 2>/dev/null || true
}

list_dayz_containers() {
  "${DOCKER[@]}" ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^dayz-[A-Za-z0-9][A-Za-z0-9-]{0,31}$' || true
}

select_from_list() {
  local -a items=("$@")
  local idx

  for i in "${!items[@]}"; do
    printf "  [%d] %s\n" "$i" "${items[$i]}" >&2
  done

  while true; do
    read -r -p "Select index: " idx || true
    [[ "${idx}" =~ ^[0-9]+$ ]] || { warn "Enter a number."; continue; }
    (( idx >= 0 && idx < ${#items[@]} )) || { warn "Out of range."; continue; }
    printf "%s\n" "${items[$idx]}"
    return 0
  done
}

marker_get() {
  local marker="$1" key="$2"
  grep -E "^${key}=" "${marker}" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

dotenv_get() {
  local file="$1" key="$2"
  local line val
  line="$(grep -E "^${key}=" "${file}" 2>/dev/null | head -n1 || true)"
  [[ -n "${line}" ]] || return 1
  val="${line#*=}"
  val="${val%$'\r'}"
  if [[ "${val}" =~ ^\".*\"$ ]]; then
    val="${val:1:${#val}-2}"
    val="${val//\\n/$'\n'}"
    val="${val//\\\"/\"}"
    val="${val//\\\\/\\}"
  fi
  printf "%s" "${val}"
}

env_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf "\"%s\"" "$s"
}

find_marker_dir_by_instance_name() {
  local scan_root="$1" inst_name="$2"
  local m
  while IFS= read -r m; do
    [[ -f "${m}" ]] || continue
    if [[ "$(marker_get "${m}" "INSTANCE_NAME")" == "${inst_name}" ]]; then
      dirname "${m}"
      return 0
    fi
  done < <(discover_instances_under "${scan_root}")
  return 1
}

compose_workdir_for_container() {
  local container="$1"
  "${DOCKER[@]}" inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "${container}" 2>/dev/null || true
}

container_has_compose_dir() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 1
  [[ -f "${dir}/docker-compose.yml" || -f "${dir}/.dayz-instance" ]] || return 1
  return 0
}

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
  info "About to add:"
  info "  - UDP ${port}-$((port+3))  : DayZ game port range (base + 0..3)"
  info "  - UDP ${query}            : Steam query port (steamQueryPort in serverDZ.cfg)"
  info "These will be recorded in: ${inst_dir}/UFW_RULES.txt"

  if ! prompt_yn "Add these UFW rules now?" "Y"; then
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

Adjust if you use different custom ports.
EOF
  chmod 600 "${inst_dir}/UFW_RULES.txt" || true

  ufw_allow_with_comment_fallback "${port}:$((port+3))/udp" "DayZ game ports (base +0..+3)"
  ufw_allow_with_comment_fallback "${query}/udp" "DayZ Steam query port (steamQueryPort)"

  ${SUDO} ufw status | grep -qi "Status: active" && ok "UFW active; rules applied." || warn "UFW inactive; rules added but not active."
}

write_file() {
  local path="$1"; shift
  mkdir -p "$(dirname "${path}")"
  cat > "${path}" <<EOF
$*
EOF
}

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
  warn "This will remove the container and delete the directory (including serverfiles/config/profile/state/backups in that folder)."

  if ! prompt_yn "Continue with deletion?" "N"; then
    warn "Deletion cancelled."
    return 1
  fi

  local confirm=""
  read -r -p "Type the instance name '${name}' to confirm: " confirm || true
  [[ "${confirm}" == "${name}" ]] || die "Confirmation did not match. Aborting deletion."

  if [[ -f "${inst_dir}/docker-compose.yml" ]]; then
    run_shell "cd '${inst_dir}' && ${DOCKER[*]} compose down --remove-orphans || true"
  fi

  if "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -qx "${container_name}"; then
    run_shell "${DOCKER[*]} rm -f '${container_name}'"
  fi

  if rm -rf "${inst_dir}" 2>/dev/null; then
    :
  else
    warn "Direct rm failed (permissions). Retrying with sudo."
    run_shell "${SUDO} rm -rf '${inst_dir}'"
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

  local confirm=""
  read -r -p "Type DELETE to confirm: " confirm || true
  [[ "${confirm}" == "DELETE" ]] || die "Confirmation did not match. Aborting deletion."

  local workdir=""
  workdir="$(compose_workdir_for_container "${container}")"

  if [[ -n "${workdir}" && -d "${workdir}" && -f "${workdir}/docker-compose.yml" ]]; then
    run_shell "cd '${workdir}' && ${DOCKER[*]} compose down --remove-orphans || true"
  fi

  if "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    run_shell "${DOCKER[*]} rm -f '${container}'"
  fi

  if [[ -n "${workdir}" ]] && container_has_compose_dir "${workdir}"; then
    warn "Compose working directory detected:"
    warn "  ${workdir}"
    warn "This directory looks like a DayZ instance directory (has docker-compose.yml or .dayz-instance)."
    if prompt_yn "Delete that directory as well?" "Y"; then
      if rm -rf "${workdir}" 2>/dev/null; then
        :
      else
        run_shell "${SUDO} rm -rf '${workdir}'"
      fi
      ok "Deleted directory: ${workdir}"
    else
      warn "Directory kept: ${workdir}"
    fi
  fi

  ok "Deleted container '${container}'."
}

delete_by_name_or_container() {
  local scan_root="$1" inst_name="$2"
  local container="dayz-${inst_name}"

  local mdir=""
  if mdir="$(find_marker_dir_by_instance_name "${scan_root}" "${inst_name}" 2>/dev/null)"; then
    collect_presets_from_dir "${mdir}"
    delete_instance_dir "${mdir}"
    return $?
  fi

  if "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -qx "${container}"; then
    collect_presets_from_container "${container}"
    delete_container_only "${container}"
    return $?
  fi

  die "Nothing found to delete for instance '${inst_name}' (no marker under ${scan_root}, no container ${container})."
}

create_instance() {
  local inst_dir="$1" name="$2"
  local container_name="dayz-${name}"
  local use_host_net="$3" dz_port="$4" query_port="$5"
  local steam_user="$6" steam_pass="$7" extra_params="$8"
  local sync_on_start="$9" update_on_start="${10}"

  step "Step: Creating instance files"
  info "Instance directory: ${inst_dir}"
  info "Container name:      ${container_name}"

  if "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -qx "${container_name}"; then
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

  write_file "${inst_dir}/data/config/BEServer_x64.cfg" \
"RConPassword CHANGEME_RCON_PASSWORD
RConPort $((dz_port+3))
RestrictRCon 1
"
  chmod 600 "${inst_dir}/data/config/BEServer_x64.cfg"

  [[ -f "${inst_dir}/data/config/mods.txt" ]] || write_file "${inst_dir}/data/config/mods.txt" "# one Workshop ID per line\n"
  [[ -f "${inst_dir}/data/config/servermods.txt" ]] || write_file "${inst_dir}/data/config/servermods.txt" "# one Workshop ID per line\n"
  chmod 600 "${inst_dir}/data/config/mods.txt" "${inst_dir}/data/config/servermods.txt" || true

  # FIX: noble has libtbb12, NOT libtbb2
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

  # Prevent endless restart loops by default
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

  if "${DOCKER[@]}" ps --format '{{.Names}}' | grep -qx "${container_name}"; then
    if prompt_yn "Container '${container_name}' is running. Restart it now?" "Y"; then
      run_shell "cd '${inst_dir}' && ${DOCKER[*]} compose restart"
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
  --steam-user <user>     Steam account username (for Workshop mods)
  --steam-pass <pass>     Steam account password
  --admin-pass <pass>     Server admin password (passwordAdmin in serverDZ.cfg)

OPTIONAL OPTIONS:
  --name <name>           Instance name (default: server1)
  --dir <path>            Install directory (default: ~/servers/dayz-<name>)
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

EXAMPLES:
  # Quick install with defaults:
  ./install-dayz-docker.sh --steam-user myuser --steam-pass mypass --admin-pass myadmin

  # Custom ports and name:
  ./install-dayz-docker.sh --steam-user myuser --steam-pass mypass --admin-pass myadmin \
    --name vanilla --port 2402 --query-port 27017

  # Full non-interactive install:
  ./install-dayz-docker.sh \
    --steam-user myuser \
    --steam-pass mypass \
    --admin-pass secretadmin \
    --name modded \
    --port 2302 \
    --sync-on-start \
    --no-start
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_usage
        exit 0
        ;;
      --steam-user)
        CLI_STEAM_USER="$2"
        shift 2
        ;;
      --steam-pass)
        CLI_STEAM_PASS="$2"
        shift 2
        ;;
      --admin-pass)
        CLI_ADMIN_PASS="$2"
        shift 2
        ;;
      --name)
        CLI_NAME="$2"
        shift 2
        ;;
      --dir)
        CLI_DIR="$2"
        shift 2
        ;;
      --port)
        CLI_PORT="$2"
        shift 2
        ;;
      --query-port)
        CLI_QUERY_PORT="$2"
        shift 2
        ;;
      --host-net)
        CLI_HOST_NET="yes"
        shift
        ;;
      --no-host-net)
        CLI_HOST_NET="no"
        shift
        ;;
      --extra-params)
        CLI_EXTRA_PARAMS="$2"
        shift 2
        ;;
      --sync-on-start)
        CLI_SYNC_ON_START="1"
        shift
        ;;
      --update-on-start)
        CLI_UPDATE_ON_START="1"
        shift
        ;;
      --no-ufw)
        CLI_NO_UFW=1
        shift
        ;;
      --no-start)
        CLI_NO_START=1
        shift
        ;;
      *)
        die "Unknown option: $1. Use --help for usage."
        ;;
    esac
  done

  # If any CLI args were provided, we're in CLI mode
  if [[ -n "${CLI_STEAM_USER}" || -n "${CLI_STEAM_PASS}" || -n "${CLI_ADMIN_PASS}" || 
        -n "${CLI_NAME}" || -n "${CLI_DIR}" || -n "${CLI_PORT}" ]]; then
    CLI_MODE=1
  fi

  # Validate required args in CLI mode
  if [[ "${CLI_MODE}" == "1" ]]; then
    [[ -n "${CLI_STEAM_USER}" ]] || die "CLI mode requires --steam-user"
    [[ -n "${CLI_STEAM_PASS}" ]] || die "CLI mode requires --steam-pass"
    [[ -n "${CLI_ADMIN_PASS}" ]] || die "CLI mode requires --admin-pass"
    
    # Apply defaults for optional params
    CLI_NAME="${CLI_NAME:-server1}"
    CLI_PORT="${CLI_PORT:-2302}"
    CLI_QUERY_PORT="${CLI_QUERY_PORT:-27016}"
    CLI_HOST_NET="${CLI_HOST_NET:-yes}"
    CLI_SYNC_ON_START="${CLI_SYNC_ON_START:-0}"
    CLI_UPDATE_ON_START="${CLI_UPDATE_ON_START:-0}"
    
    # Validate
    [[ "${CLI_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$ ]] || die "Invalid --name: must be alphanumeric with dashes, max 32 chars"
    [[ "${CLI_PORT}" =~ ^[0-9]+$ ]] || die "Invalid --port: must be a number"
    [[ "${CLI_QUERY_PORT}" =~ ^[0-9]+$ ]] || die "Invalid --query-port: must be a number"
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
  local extra_params="${CLI_EXTRA_PARAMS:-}"
  local sync_on_start="${CLI_SYNC_ON_START}"
  local update_on_start="${CLI_UPDATE_ON_START}"
  
  info "Instance name:    ${name}"
  info "Install dir:      ${inst_dir}"
  info "Game port:        ${dz_port}"
  info "Query port:       ${query_port}"
  info "Host networking:  ${use_host_net}"
  
  # Check if container already exists
  if "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -qx "dayz-${name}"; then
    die "Container 'dayz-${name}' already exists. Use a different --name or remove it first."
  fi
  
  # Check if directory exists
  if [[ -e "${inst_dir}/.dayz-instance" ]]; then
    die "Instance marker exists at ${inst_dir}. Remove it or choose a different --dir."
  fi
  
  # UFW
  if [[ "${CLI_NO_UFW}" != "1" ]]; then
    configure_ufw "${dz_port}" "${query_port}" "${inst_dir}"
  else
    info "Skipping UFW configuration (--no-ufw)"
  fi
  
  # Create instance - use CLI_ADMIN_PASS instead of prompting
  step "Step: Creating instance files"
  info "Instance directory: ${inst_dir}"
  info "Container name:      dayz-${name}"
  
  local container_name="dayz-${name}"
  
  mkdir -p "${inst_dir}/data/serverfiles" "${inst_dir}/data/config" "${inst_dir}/data/profile" "${inst_dir}/data/state" "${inst_dir}/data/backups"
  chmod 700 "${inst_dir}/data" "${inst_dir}/data/config" "${inst_dir}/data/state" || true
  
  [[ -f "${RUN_SH_SRC}" ]] || die "Missing ${RUN_SH_SRC}. Put run.sh next to install-dayz-docker.sh."
  cp -f "${RUN_SH_SRC}" "${inst_dir}/run.sh"
  chmod +x "${inst_dir}/run.sh"
  sed -i 's/\r$//' "${inst_dir}/run.sh"
  
  write_file "${inst_dir}/data/config/serverDZ.cfg" \
"hostname = \"DayZ ${name}\";
password = \"\";
passwordAdmin = \"${CLI_ADMIN_PASS}\";
maxPlayers = 30;
verifySignatures = 2;
forceSameBuild = 1;
persistent = 1;
instanceId = 1;

steamQueryPort = ${query_port};

class Missions { class DayZ { template = \"dayzOffline.chernarusplus\"; }; };
"
  chmod 600 "${inst_dir}/data/config/serverDZ.cfg"
  
  write_file "${inst_dir}/data/config/BEServer_x64.cfg" \
"RConPassword CHANGEME_RCON_PASSWORD
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
  
  # Build image
  step "Step: Building image"
  run_shell "cd '${inst_dir}' && ${DOCKER[*]} compose build --no-cache"
  
  # Start if not --no-start
  if [[ "${CLI_NO_START}" != "1" ]]; then
    step "Step: Starting container"
    run_shell "cd '${inst_dir}' && ${DOCKER[*]} compose up -d"
    ok "Started: dayz-${name}"
    info "Logs: cd '${inst_dir}' && ${DOCKER[*]} compose logs -f --tail=200"
  else
    info "Container not started (--no-start). Start later: cd '${inst_dir}' && ${DOCKER[*]} compose up -d"
  fi
  
  hr
  ok "CLI install complete!"
  info "Instance directory: ${inst_dir}"
  info "Container name: dayz-${name}"
  info ""
  info "Manage with: ./server-manager.sh"
}

main() {
  parse_args "$@"
  
  [[ -f "${RUN_SH_SRC}" ]] || die "Expected run.sh next to this installer: ${RUN_SH_SRC}"

  require_sudo_for_docker_socket
  ensure_docker

  if [[ "${DOCKER_GROUP_ADDED_THIS_RUN}" == "1" && "${EUID}" -ne 0 ]]; then
    hr
    warn "Docker group membership was changed during this run, but your current session is not refreshed yet."
    warn "To prevent 'permission denied' errors on /var/run/docker.sock, the installer will now exit BEFORE creating any DayZ instance folders/files."
    info "Do ONE of the following, then re-run this installer:"
    info "  1) Log out and log back in"
    info "  2) Or run in this terminal: newgrp docker"
    info "Then re-run:"
    info "  $0"
    hr
    exit 0
  fi

  # CLI mode branch - run non-interactively if args provided
  if [[ "${CLI_MODE}" == "1" ]]; then
    run_cli_mode
    exit 0
  fi

  step "Step: Discovering existing DayZ instances"
  local scan_root="${invoking_home}/servers"
  info "Scanning under: ${scan_root}"

  mapfile -t markers < <(discover_instances_under "${scan_root}")
  mapfile -t containers < <(list_dayz_containers)

  if [[ "${#markers[@]}" -gt 0 || "${#containers[@]}" -gt 0 ]]; then
    if [[ "${#markers[@]}" -gt 0 ]]; then
      ok "Found existing instances (marker-based):"
      for m in "${markers[@]}"; do
        local n c d
        n="$(marker_get "${m}" "INSTANCE_NAME")"
        c="$(marker_get "${m}" "CONTAINER_NAME")"
        d="$(dirname "${m}")"
        printf "  - %s (%s) at %s\n" "${n:-?}" "${c:-?}" "${d}" >&2
      done
    else
      warn "No .dayz-instance markers found under ${scan_root}."
    fi

    if [[ "${#containers[@]}" -gt 0 ]]; then
      ok "Found existing DayZ containers:"
      for ctn in "${containers[@]}"; do
        local wd=""
        wd="$(compose_workdir_for_container "${ctn}")"
        if [[ -n "${wd}" ]]; then
          printf "  - %s (compose dir: %s)\n" "${ctn}" "${wd}" >&2
        else
          printf "  - %s\n" "${ctn}" >&2
        fi
      done
    fi

    hr
    info "Choose action:"
    info "  [1] Create NEW instance (does not touch existing containers/data)"
    if [[ "${#markers[@]}" -gt 0 ]]; then
      info "  [2] Update run.sh only for an existing marker-based instance"
    else
      info "  [2] Update run.sh only (unavailable: no markers found)"
    fi
    info "  [3] Delete an existing instance/container, then optionally recreate with same name"
    info "  [4] Exit"
    local choice=""
    read -r -p "Select [1/2/3/4]: " choice || true
    case "${choice}" in
      1) ;;
      2)
        [[ "${#markers[@]}" -gt 0 ]] || die "No marker-based instances found to update."
        local -a inst_dirs=()
        for m in "${markers[@]}"; do inst_dirs+=( "$(dirname "${m}")" ); done
        local chosen_dir
        chosen_dir="$(select_from_list "${inst_dirs[@]}")"
        update_run_sh_only "${chosen_dir}"
        exit 0
        ;;
      3)
        hr
        info "Delete by:"
        if [[ "${#markers[@]}" -gt 0 ]]; then
          info "  [1] Marker-based instance (deletes container + directory)"
        else
          info "  [1] Marker-based instance (unavailable: no markers found)"
        fi
        if [[ "${#containers[@]}" -gt 0 ]]; then
          info "  [2] Container (deletes container; deletes compose dir if detected and confirmed)"
        else
          info "  [2] Container (unavailable: no containers found)"
        fi
        info "  [3] Back"
        local del_choice=""
        read -r -p "Select [1/2/3]: " del_choice || true
        case "${del_choice}" in
          1)
            [[ "${#markers[@]}" -gt 0 ]] || die "No marker-based instances found to delete."
            local -a inst_dirs=()
            for m in "${markers[@]}"; do inst_dirs+=( "$(dirname "${m}")" ); done
            local del_dir
            del_dir="$(select_from_list "${inst_dirs[@]}")"

            collect_presets_from_dir "${del_dir}"
            delete_instance_dir "${del_dir}" || exit 0

            if ! prompt_yn "Recreate a fresh instance with the same name '${preset_name}' now?" "Y"; then
              exit 0
            fi
            ;;
          2)
            [[ "${#containers[@]}" -gt 0 ]] || die "No DayZ containers found to delete."
            local del_ctn
            del_ctn="$(select_from_list "${containers[@]}")"

            collect_presets_from_container "${del_ctn}"
            delete_container_only "${del_ctn}" || exit 0

            if ! prompt_yn "Recreate a fresh instance with the same name '${preset_name}' now?" "Y"; then
              exit 0
            fi
            ;;
          3) ;;
          *) die "Invalid selection." ;;
        esac
        ;;
      4) exit 0 ;;
      *) die "Invalid selection." ;;
    esac
  fi

  step "Step: DayZ docker setup parameters"

  local name
  while true; do
    name="$(prompt_default "Instance name (letters/numbers/dash, e.g. server1)" "${preset_name:-server1}")"
    [[ "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$ ]] || { warn "Invalid name."; continue; }

    if "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -qx "dayz-${name}"; then
      warn "Container already exists: dayz-${name}."
      if prompt_yn "Delete existing '${name}' and recreate with the SAME name now?" "N"; then
        delete_by_name_or_container "${scan_root}" "${name}" || true
        break
      fi
      continue
    fi
    break
  done

  local base_dir="${invoking_home}/servers/dayz-${name}"
  local default_dir=""

  if [[ -n "${preset_dir}" && ! -e "${preset_dir}" ]]; then
    default_dir="${preset_dir}"
  else
    default_dir="${base_dir}"
    if [[ -e "${default_dir}" ]]; then
      local n=2
      while [[ -e "${base_dir}-${n}" ]]; do ((n++)); done
      default_dir="${base_dir}-${n}"
    fi
  fi

  local inst_dir
  inst_dir="$(prompt_default "Install directory for this instance" "${default_dir}")"

  local use_host_net="yes"
  if prompt_yn "Use host networking? Recommended for game servers + UFW behavior." "Y"; then
    use_host_net="yes"
  else
    use_host_net="no"
  fi

  local dz_port query_port
  dz_port="$(prompt_default "DayZ game port (UDP base, will use +0..+3)" "${preset_dz_port:-2302}")"
  [[ "${dz_port}" =~ ^[0-9]+$ ]] || die "Invalid port."
  query_port="$(prompt_default "Steam query port (UDP)" "${preset_query_port:-27016}")"
  [[ "${query_port}" =~ ^[0-9]+$ ]] || die "Invalid query port."

  step "Step: Steam credentials"
  info "For Workshop mods you need a Steam account; credentials are stored in .env (chmod 600)."
  local steam_user steam_pass
  steam_user="$(prompt_default "Steam username (required for Workshop mod downloads)" "anonymous")"
  steam_pass=""
  if [[ "${steam_user}" != "anonymous" ]]; then
    read -r -s -p "Steam password: " steam_pass; echo ""
  else
    warn "Mods will not download as anonymous."
  fi

  local extra_params
  extra_params="$(prompt_default "Extra DayZ start params (optional)" "${preset_extra_params:-}")"

  local sync_on_start update_on_start
  sync_on_start="0"; update_on_start="0"
  if prompt_yn "Auto-sync mods on container start? (downloads on start)" "N"; then sync_on_start="1"; fi
  if prompt_yn "Auto-update server on container start?" "N"; then update_on_start="1"; fi

  configure_ufw "${dz_port}" "${query_port}" "${inst_dir}"
  create_instance "${inst_dir}" "${name}" "${use_host_net}" "${dz_port}" "${query_port}" "${steam_user}" "${steam_pass}" "${extra_params}" "${sync_on_start}" "${update_on_start}"

  step "Step: Building image"
  run_shell "cd '${inst_dir}' && ${DOCKER[*]} compose build --no-cache"

  if prompt_yn "Start the server container now?" "Y"; then
    step "Step: Starting container"
    run_shell "cd '${inst_dir}' && ${DOCKER[*]} compose up -d"
    ok "Started: dayz-${name}"
    info "Logs: cd '${inst_dir}' && ${DOCKER[*]} compose logs -f --tail=200"
  else
    info "Start later: cd '${inst_dir}' && ${DOCKER[*]} compose up -d"
  fi

  hr
  ok "Inside-container commands (examples):"
  info "  ${DOCKER[*]} exec -it dayz-${name} /dayz/run.sh status"
  info "  ${DOCKER[*]} exec -it dayz-${name} /dayz/run.sh mod add 1559212036 1564026768"
  info "  ${DOCKER[*]} exec -it dayz-${name} /dayz/run.sh sync-mods"
}

main "$@"
