#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

# =========================
# DayZ container manager
# =========================
# Used in two ways:
#  1) Container command: /dayz/run.sh foreground   (runs the server)
#  2) Admin commands:    /dayz/run.sh mod add 123...   etc.

APPID="${APPID:-223350}"
WORKSHOP_APPID="${WORKSHOP_APPID:-221100}"

STEAMCMD="${STEAMCMD:-/opt/steamcmd/steamcmd.sh}"

DZ_ROOT="${DZ_ROOT:-/dayz}"
DZ_SERVERFILES="${DZ_SERVERFILES:-/dayz/serverfiles}"
DZ_CONFIG_DIR="${DZ_CONFIG_DIR:-/dayz/config}"
DZ_PROFILE="${DZ_PROFILE:-/dayz/profile}"
DZ_STATE="${DZ_STATE:-/dayz/state}"

DZ_PORT="${DZ_PORT:-2302}"
DZ_QUERY_PORT="${DZ_QUERY_PORT:-27016}"

# If you want auto update/mod-sync every time the container starts:
DZ_SYNC_ON_START="${DZ_SYNC_ON_START:-0}"      # 1 = sync mods+servermods on each start
DZ_UPDATE_ON_START="${DZ_UPDATE_ON_START:-0}"  # 1 = update server on each start
DZ_INSTANCE_ID="$(echo "${DZ_INSTANCE_ID:-1}" | tr -cd '0-9')"

# Extra launch args passed verbatim
DZ_EXTRA_PARAMS="${DZ_EXTRA_PARAMS:-}"

# Steam login for Workshop downloads:
STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"

# Paths
WORKSHOP_DIR="${DZ_SERVERFILES}/steamapps/workshop/content/${WORKSHOP_APPID}"
KEYS_DIR="${DZ_SERVERFILES}/keys"
MODS_FILE="${DZ_CONFIG_DIR}/mods.txt"
SERVERMODS_FILE="${DZ_CONFIG_DIR}/servermods.txt"

MODS_ARGS_FILE="${DZ_STATE}/mods.args"
SERVERMODS_ARGS_FILE="${DZ_STATE}/servermods.args"

log(){ printf '[%s] %s\n' "$(date -Is)" "$*"; }
warn(){ printf '[%s] WARN: %s\n' "$(date -Is)" "$*" >&2; }
die(){ printf '[%s] ERROR: %s\n' "$(date -Is)" "$*" >&2; exit 1; }

is_cmd(){ command -v "$1" >/dev/null 2>&1; }

ensure_layout() {
  mkdir -p "${DZ_SERVERFILES}" "${DZ_CONFIG_DIR}" "${DZ_PROFILE}" "${DZ_STATE}" "${KEYS_DIR}"
  chmod 700 "${DZ_CONFIG_DIR}" "${DZ_STATE}" || true
  touch "${MODS_FILE}" "${SERVERMODS_FILE}"
  chmod 600 "${MODS_FILE}" "${SERVERMODS_FILE}" || true
  # --- NEW GUARDRAIL: Dummy CrashReporter ---
  local cr="${DZ_SERVERFILES}/CrashReporter"
  if [[ ! -f "${cr}" ]]; then
    echo '#!/bin/sh' > "${cr}"
    echo 'echo "CrashReporter invoked with args: $@"' >> "${cr}"
    echo 'exit 0' >> "${cr}"
    chmod +x "${cr}"
  fi
  # ------------------------------------------
}

require_steamcmd() {
  [[ -x "${STEAMCMD}" ]] || die "steamcmd not found/executable at: ${STEAMCMD}"
}

# Steam credentials: STEAM_USER/STEAM_PASS from the environment (older
# instances) or, preferred, from the private file the installer writes into
# the config dir. That way the password is not part of the container
# environment (docker inspect, every child process of the server).
load_steam_credentials() {
  local f="${DZ_CONFIG_DIR}/.steam.env"
  [[ -z "${STEAM_PASS:-}" && -f "${f}" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    [[ "${k}" == "STEAM_USER" || "${k}" == "STEAM_PASS" ]] || continue
    v="${v%$'\r'}"
    if [[ "${v}" =~ ^\".*\"$ ]]; then
      # same escapes as env_quote in lib/utils.sh
      v="${v:1:${#v}-2}"
      v="${v//\\n/$'\n'}"; v="${v//\\\"/\"}"; v="${v//\\\\/\\}"; v="${v//\$\$/\$}"
    fi
    printf -v "${k}" '%s' "${v}"
  done < "${f}"
}

# Run steamcmd with a private script instead of +login on the command line,
# so the password is not visible in the process list of host or container.
# Usage: run_steamcmd_script "<user> <pass>|anonymous" +cmd arg... [+cmd arg...]
run_steamcmd_script() {
  local login_line="$1"; shift
  local script
  script=$(mktemp "${DZ_STEAM_TMPDIR:-/dev/shm}/steamcmd.XXXXXX" 2>/dev/null) || script=$(mktemp)
  chmod 600 "${script}"
  {
    echo "@NoPromptForPassword 1"
    echo "force_install_dir ${DZ_SERVERFILES}"
    echo "login ${login_line}"
    # every +command token starts a new line, the following tokens are its arguments
    local tok line=""
    for tok in "$@"; do
      if [[ "${tok}" == +* ]]; then
        [[ -n "${line}" ]] && echo "${line}"
        line="${tok#+}"
      else
        line="${line} ${tok}"
      fi
    done
    [[ -n "${line}" ]] && echo "${line}"
    echo "quit"
  } > "${script}"
  local rc=0
  "${STEAMCMD}" +runscript "${script}" || rc=$?
  rm -f "${script}"
  return "${rc}"
}

run_steamcmd_server() {
  require_steamcmd
  load_steam_credentials
  # Server downloads often work as anonymous; if user provided creds, use them.
  local login="anonymous"
  if [[ -n "${STEAM_USER}" && "${STEAM_USER}" != "anonymous" && -n "${STEAM_PASS}" ]]; then
    login="${STEAM_USER} ${STEAM_PASS}"
  fi
  run_steamcmd_script "${login}" "$@"
}

run_steamcmd_workshop_multi() {
  # args passed as array; caller builds +workshop_download_item ...
  require_steamcmd
  load_steam_credentials
  if [[ -z "${STEAM_USER}" || "${STEAM_USER}" == "anonymous" ]]; then
    die "Workshop mod download requires a Steam account. Set STEAM_USER/STEAM_PASS (not anonymous)."
  fi
  [[ -n "${STEAM_PASS}" ]] || die "STEAM_PASS is empty but STEAM_USER is set."
  # NOTE: steamcmd often returns non-zero even on success; don't let set -e kill us
  run_steamcmd_script "${STEAM_USER} ${STEAM_PASS}" "$@" || {
    local rc=$?
    warn "SteamCMD exited with code $rc (may be normal for 'already up to date')"
  }
}

read_ids() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  awk '
    { gsub(/\r/,""); }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { print $1 }
  ' "${file}" | awk '/^[0-9]+$/' | awk '!seen[$0]++'
}

list_add_id() {
  local file="$1" id="$2"
  [[ "${id}" =~ ^[0-9]+$ ]] || die "Invalid workshop id: ${id}"
  if ! grep -Eq "^[[:space:]]*#?[[:space:]]*${id}[[:space:]]*$" "${file}"; then
    append_line "${file}" "${id}"
  else
    # if present but commented, enable it
    sed -i -E "s/^[[:space:]]*#[[:space:]]*${id}[[:space:]]*$/${id}/" "${file}" || true
  fi
}

list_remove_id() {
  local file="$1" id="$2"
  [[ "${id}" =~ ^[0-9]+$ ]] || die "Invalid workshop id: ${id}"
  sed -i -E "/^[[:space:]]*#?[[:space:]]*${id}[[:space:]]*$/d" "${file}"
}

list_disable_id() {
  local file="$1" id="$2"
  [[ "${id}" =~ ^[0-9]+$ ]] || die "Invalid workshop id: ${id}"
  if grep -Eq "^[[:space:]]*${id}[[:space:]]*$" "${file}"; then
    sed -i -E "s/^[[:space:]]*${id}[[:space:]]*$/# ${id}/" "${file}"
  else
    # if missing, append commented placeholder
    if ! grep -Eq "^[[:space:]]*#[[:space:]]*${id}[[:space:]]*$" "${file}"; then
      append_line "${file}" "# ${id}"
    fi
  fi
}

list_enable_id() {
  local file="$1" id="$2"
  [[ "${id}" =~ ^[0-9]+$ ]] || die "Invalid workshop id: ${id}"
  if grep -Eq "^[[:space:]]*#[[:space:]]*${id}[[:space:]]*$" "${file}"; then
    sed -i -E "s/^[[:space:]]*#[[:space:]]*${id}[[:space:]]*$/${id}/" "${file}"
  else
    if ! grep -Eq "^[[:space:]]*${id}[[:space:]]*$" "${file}"; then
      append_line "${file}" "${id}"
    fi
  fi
}

parse_ids() {
  # accepts: "1,2 3" -> one id per line; fails (prints nothing) on any invalid id
  local raw="$*"
  raw="${raw//,/ }"
  # The script sets IFS to newline+tab globally, so split on spaces explicitly here
  local IFS=$' \t\n'
  # shellcheck disable=SC2206
  local arr=( ${raw} )
  local x
  for x in "${arr[@]}"; do
    [[ "${x}" =~ ^[0-9]+$ ]] || { warn "Invalid workshop id: ${x}"; return 1; }
  done
  printf '%s\n' "${arr[@]}"
}

# Append one line, starting a fresh line first if the file lacks a final newline
append_line() {
  local file="$1" text="$2"
  if [[ -s "${file}" && -n "$(tail -c1 "${file}")" ]]; then printf '\n' >> "${file}"; fi
  printf '%s\n' "${text}" >> "${file}"
}

server_bin() {
  if [[ -x "${DZ_SERVERFILES}/DayZServer" ]]; then
    echo "${DZ_SERVERFILES}/DayZServer"
  elif [[ -x "${DZ_SERVERFILES}/DayZServer_x64" ]]; then
    echo "${DZ_SERVERFILES}/DayZServer_x64"
  else
    echo ""
  fi
}

update_server() {
  log "Updating DayZ server (appid ${APPID})..."
  run_steamcmd_server +app_update "${APPID}"
  log "Server update finished."
}

validate_server() {
  log "Validating DayZ server files (appid ${APPID})..."
  run_steamcmd_server +app_update "${APPID}" validate
  log "Validation finished."
}

validate_config() {
  if [[ -z "${DZ_INSTANCE_ID}" ]]; then
    die "Configuration Error: DZ_INSTANCE_ID is missing. This is required by DayZServer."
  fi
  # We could add checks for Port, Profile dir, etc. here
}

sync_mod_list() {
  local list_file="$1"
  local out_args_file="$2"

  local ids
  ids="$(read_ids "${list_file}" || true)"
  if [[ -z "${ids}" ]]; then
    echo -n "" > "${out_args_file}"
    return 0
  fi

  # Build steamcmd workshop download args safely (no eval)
  local -a args=()
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    args+=( +workshop_download_item "${WORKSHOP_APPID}" "${id}" validate )
  done <<< "${ids}"

  log "Downloading workshop items from ${list_file}..."
  run_steamcmd_workshop_multi "${args[@]}"
  log "Workshop download finished."

  mod_list_apply_fixes "$list_file" "$out_args_file"
}

mod_list_apply_fixes() {
  local list_file="$1"
  local out_args_file="$2"

  local ids
  ids="$(read_ids "${list_file}" || true)"
  if [[ -z "${ids}" ]]; then
    echo -n "" > "${out_args_file}"
    return 0
  fi

  mkdir -p "${KEYS_DIR}"
  local mod_args=""
  
  # Track valid mods for garbage collection
  # We use an associative array to store "valid" IDs
  declare -A VALID_MODS
  
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    VALID_MODS["$id"]=1
    
    local mod_dir="${WORKSHOP_DIR}/${id}"
    if [[ -d "${mod_dir}" ]]; then
      # Fix casing recursively (required for Linux compatibility)
      log "Fixing casing for mod id=${id}..."
      local d f n
      while IFS= read -r p; do
        d="$(dirname "${p}")"; f="$(basename "${p}")"; n="${f,,}"
        if [[ "${f}" != "${n}" ]]; then
          mv -T "${p}" "${d}/${n}" 2>/dev/null && log "  Renamed: ${f} -> ${n}" || true
        fi
      done < <(find "${mod_dir}" -depth 2>/dev/null)
      log "Casing normalized for mod id=${id}."

      ln -sfn "${mod_dir}" "${DZ_SERVERFILES}/@${id}"
      touch "${mod_dir}" # Update mtime to reflect sync status in UI
      # Keep track of first installation date
      if [[ ! -f "${mod_dir}/.first_installed" ]]; then
          date +%s > "${mod_dir}/.first_installed"
      fi
      mod_args+="${mod_args:+;}"
      mod_args+="@${id}"

      # Copy .bikey files
      if [[ -d "${DZ_SERVERFILES}/@${id}" ]]; then
        local key_count
        key_count=$(find -L "${DZ_SERVERFILES}/@${id}" -maxdepth 3 -type f -iname "*.bikey" -printf '.' | wc -c)
        if [[ ${key_count} -gt 0 ]]; then
            find -L "${DZ_SERVERFILES}/@${id}" -maxdepth 3 -type f -iname "*.bikey" -print0 2>/dev/null \
              | xargs -0 -I{} cp -v -f "{}" "${KEYS_DIR}/" 2>/dev/null | sed "s/^/  [Key] /" || true
            log "Synchronized ${key_count} keys for mod @${id}"
        fi
      fi
    else
      warn "Workshop content missing for id=${id} (expected ${mod_dir})"
    fi
  done <<< "${ids}"

  # Garbage Collection: Remove symlinks for mods that are NOT in EITHER list
  # We need to check both mods.txt AND servermods.txt to avoid pruning valid mods
  log "Performing garbage collection on old mod links..."
  
  # Build combined valid list from BOTH files
  declare -A ALL_VALID_MODS
  local all_ids
  all_ids="$(read_ids "${MODS_FILE}" 2>/dev/null || true)"
  while IFS= read -r id; do
    [[ -n "$id" ]] && ALL_VALID_MODS["$id"]=1
  done <<< "$all_ids"
  all_ids="$(read_ids "${SERVERMODS_FILE}" 2>/dev/null || true)"
  while IFS= read -r id; do
    [[ -n "$id" ]] && ALL_VALID_MODS["$id"]=1
  done <<< "$all_ids"
  
  while IFS= read -r link; do
    local link_name
    link_name="$(basename "$link")"      # e.g., @123456
    local link_id="${link_name#@}"       # e.g., 123456
    
    # Check if this ID is in EITHER list (safe for set -u)
    if [[ -z "${ALL_VALID_MODS[$link_id]+x}" ]]; then
        # Double check it is a numeric ID (safety)
        if [[ "$link_id" =~ ^[0-9]+$ ]]; then
            log "Pruning removed mod: $link_name"
            rm -f "$link"
        fi
    fi
  done < <(find "${DZ_SERVERFILES}" -maxdepth 1 -name "@[0-9]*" -type l)

  echo -n "${mod_args}" > "${out_args_file}"
  chmod 600 "${out_args_file}" || true
}

sync_mods()       { sync_mod_list "${MODS_FILE}" "${MODS_ARGS_FILE}"; }
sync_servermods() { sync_mod_list "${SERVERMODS_FILE}" "${SERVERMODS_ARGS_FILE}"; }
fix_mods()        { mod_list_apply_fixes "${MODS_FILE}" "${MODS_ARGS_FILE}"; }
fix_servermods()  { mod_list_apply_fixes "${SERVERMODS_FILE}" "${SERVERMODS_ARGS_FILE}"; }

print_mod_args() {
  echo "mods:       $(cat "${MODS_ARGS_FILE}" 2>/dev/null || true)"
  echo "servermods: $(cat "${SERVERMODS_ARGS_FILE}" 2>/dev/null || true)"
}

purge_mod() {
  local id="$1"
  [[ "${id}" =~ ^[0-9]+$ ]] || die "Invalid workshop id: ${id}"
  rm -rf "${WORKSHOP_DIR:?}/${id}" || true
  rm -f "${DZ_SERVERFILES}/@${id}" || true
  log "Purged mod content + symlink for id=${id} (keys not removed automatically)."
}

mission_name() {
  # extracts template = "dayzOffline.chernarusplus";
  local cfg="${DZ_CONFIG_DIR}/serverDZ.cfg"
  [[ -f "${cfg}" ]] || { echo ""; return 0; }
  grep -E 'template[[:space:]]*=' "${cfg}" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true
}

backup_now() {
  local m
  m="$(mission_name)"
  [[ -n "${m}" ]] || die "Could not determine mission template from serverDZ.cfg"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local backup_dir="${DZ_ROOT}/backups"
  mkdir -p "${backup_dir}"

  local mission_path="${DZ_SERVERFILES}/mpmissions/${m}"
  [[ -d "${mission_path}" ]] || die "Mission path not found: ${mission_path}"

  local out1="${backup_dir}/mission-${m}-${ts}.tar"
  local out2="${backup_dir}/profile-${ts}.tar"

  log "Backing up mission: ${mission_path} -> ${out1}"
  tar -cf "${out1}" -C "${DZ_SERVERFILES}/mpmissions" "${m}"

  log "Backing up profile: ${DZ_PROFILE} -> ${out2} (excluding *.log/*.RPT)"
  tar --exclude='*.log' --exclude='*.RPT' -cf "${out2}" -C "${DZ_ROOT}" "profile"

  log "Backup completed."
}

wipe_data() {
  local m
  m="$(mission_name)"
  [[ -n "${m}" ]] || die "Could not determine mission template from serverDZ.cfg"

  local base="${DZ_SERVERFILES}/mpmissions/${m}/storage_1"
  [[ -d "${base}" ]] || die "storage_1 not found: ${base}"

  if [[ "${FORCE:-0}" != "1" ]]; then
    die "Wipe is destructive. Re-run with FORCE=1 to proceed."
  fi

  rm -f "${base}/players.db" || true
  rm -rf "${base}/data"/* || true
  log "Wipe completed (players.db + storage_1/data/*)."
}

server_proc_pid() {
  # best-effort: find the DayZ server process in this container
  pgrep -f "DayZServer" | head -n1 || true
}

status() {
  local pid
  pid="$(server_proc_pid)"
  if [[ -n "${pid}" ]]; then
    echo "RUNNING pid=${pid} port=${DZ_PORT} query=${DZ_QUERY_PORT}"
  else
    echo "STOPPED port=${DZ_PORT} query=${DZ_QUERY_PORT}"
  fi
}

stop_server() {
  local pid
  pid="$(server_proc_pid)"
  if [[ -z "${pid}" ]]; then
    log "Server not running."
    return 0
  fi

  log "Stopping server pid=${pid}..."
  kill -INT "${pid}" 2>/dev/null || true

  for i in {1..90}; do
    sleep 1
    if ! kill -0 "${pid}" 2>/dev/null; then
      log "Server stopped."
      return 0
    fi
  done

  warn "Graceful stop timed out; sending SIGKILL."
  kill -KILL "${pid}" 2>/dev/null || true
}

start_foreground() {
  ensure_layout
  validate_config

  # Install/update server if missing
  if [[ -z "$(server_bin)" ]]; then
    warn "Server binary missing; running update-server first."
    update_server
  elif [[ "${DZ_UPDATE_ON_START}" == "1" ]]; then
    update_server
  fi

  # -------------------------------------------------------------------------
  # Always regenerate mods.args from mods.txt before starting
  # This ensures the command-line always matches the current mod list
  # -------------------------------------------------------------------------
  log "Regenerating mod arguments from config files..."
  fix_mods
  fix_servermods
  log "Mod arguments updated."

  # Optional: Full sync (downloads) on DZ_SYNC_ON_START=1
  if [[ "${DZ_SYNC_ON_START}" == "1" ]]; then
    log "DZ_SYNC_ON_START=1, running full sync..."
    if [[ -n "$(read_ids "${MODS_FILE}" || true)" ]]; then sync_mods; fi
    if [[ -n "$(read_ids "${SERVERMODS_FILE}" || true)" ]]; then sync_servermods; fi
  fi

  # Ensure args files exist
  [[ -f "${MODS_ARGS_FILE}" ]] || echo -n "" > "${MODS_ARGS_FILE}"
  [[ -f "${SERVERMODS_ARGS_FILE}" ]] || echo -n "" > "${SERVERMODS_ARGS_FILE}"

  local mods_arg servermods_arg
  mods_arg="$(cat "${MODS_ARGS_FILE}" 2>/dev/null || true)"
  servermods_arg="$(cat "${SERVERMODS_ARGS_FILE}" 2>/dev/null || true)"

  local bin
  bin="$(server_bin)"
  [[ -n "${bin}" ]] || die "DayZ server binary still missing after update."

  mkdir -p "${DZ_SERVERFILES}/battleye"

  # ---------------------------------------------------------------------------------------
  # FIX: Legacy engine path/argument quirks matching manual test success
  # ---------------------------------------------------------------------------------------
  unset IFS
  # 1. Switch to server directory
  cd "${DZ_SERVERFILES}"
  export LD_LIBRARY_PATH=".:${DZ_SERVERFILES}:${LD_LIBRARY_PATH:-}"

  # 2. Symlink config locally so we can use relative path "-config=serverDZ.cfg"
  ln -sf "${DZ_CONFIG_DIR}/serverDZ.cfg" "serverDZ.cfg"
  
  # Link BattlEye config if present (Handle both cases: BEServer_x64.cfg and beserver_x64.cfg)
  if [[ -f "${DZ_CONFIG_DIR}/BEServer_x64.cfg" ]]; then
      ln -sf "${DZ_CONFIG_DIR}/BEServer_x64.cfg" "battleye/BEServer_x64.cfg"
      ln -sf "${DZ_CONFIG_DIR}/BEServer_x64.cfg" "battleye/beserver_x64.cfg"
  fi

  # 3. Use bash array to guarantee clean arguments (no newline/quoting issues)
  local -a args=(
    "-config=serverDZ.cfg"
    "-port=${DZ_PORT}"
    "-profiles=${DZ_PROFILE}"
    "-BEpath=${DZ_SERVERFILES}/battleye"
    "-instanceId=${DZ_INSTANCE_ID}"
    "-freezecheck"
  )

  # Append optional args if present
  if [[ -n "${mods_arg}" ]]; then args+=("-mod=${mods_arg}"); fi
  if [[ -n "${servermods_arg}" ]]; then args+=("-serverMod=${servermods_arg}"); fi
  if [[ -n "${DZ_EXTRA_PARAMS}" ]]; then args+=(${DZ_EXTRA_PARAMS}); fi

  # -------------------------------------------------------------------------
  # Start ban expiry daemon in background (if enabled and available)
  # -------------------------------------------------------------------------
  if [[ "${DZ_BAN_EXPIRY_DAEMON:-1}" != "0" ]] && [[ -f "/dayz/lib/ban_expiry_daemon.sh" ]]; then
    log "Starting ban expiry daemon..."

    # Get RCON password for ban reload
    local rcon_pass=""
    if [[ -f "${DZ_CONFIG_DIR}/BEServer_x64.cfg" ]]; then
      rcon_pass=$(grep "^RConPassword" "${DZ_CONFIG_DIR}/BEServer_x64.cfg" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)
    fi

    # Calculate RCON port (game port + 3)
    local rcon_port=$((DZ_PORT + 3))

    # Start daemon with environment variables
    DZ_STATE="/dayz/state" \
    DZ_SERVERFILES="${DZ_SERVERFILES}" \
    DZ_LIB_DIR="/dayz/lib" \
    DZ_RCON_PORT="${rcon_port}" \
    RCON_PASSWORD="${rcon_pass}" \
    bash /dayz/lib/ban_expiry_daemon.sh &

    log "Ban expiry daemon started (PID: $!)"
  fi

  log "Launching DayZ server..."
  log "  Command: ./$(basename "${bin}") ${args[*]}"

  # 4. Execute relatively
  exec "./$(basename "${bin}")" "${args[@]}"
}

tail_console() {
  # Tail latest RPT if present, otherwise tail a general log file.
  local latest
  latest="$(ls -1t "${DZ_PROFILE}"/*.RPT 2>/dev/null | head -n1 || true)"
  if [[ -n "${latest}" ]]; then
    log "Tailing ${latest}"
    exec tail -n 200 -f "${latest}"
  fi
  warn "No .RPT found in ${DZ_PROFILE}. Tailing directory listing instead."
  exec sh -lc "ls -la '${DZ_PROFILE}' && sleep infinity"
}

usage() {
  cat <<'EOF'
/dayz/run.sh

Lifecycle:
  foreground                 Run server in foreground (used by container)
  status                     Show server status
  stop                       Stop server process (if running)
  console                    Tail latest .RPT in profile

Server files:
  update-server              SteamCMD app_update for server
  validate-server            SteamCMD validate for server

Mods:
  sync-mods                  Download enabled mods in config/mods.txt and build args
  sync-servermods            Download enabled servermods in config/servermods.txt and build args
  fix-mods                   Fix casing and sync keys for mods.txt (fast)
  fix-servermods             Fix casing and sync keys for servermods.txt (fast)
  args                       Print computed -mod / -serverMod args
  purge-mod <id>             Delete workshop content for a mod ID (does not edit lists)

List editing:
  mod add <ids...>           Add/enable workshop IDs in mods.txt (comma/space separated)
  mod remove <ids...>        Remove IDs from mods.txt
  mod enable <ids...>        Uncomment IDs in mods.txt
  mod disable <ids...>       Comment out IDs in mods.txt
  mod list                   Show mods.txt

  servermod add|remove|enable|disable|list ...  (same for servermods.txt)

Maintenance:
  backup                     Tar mission + profile into /dayz/backups
  wipe                       Wipe players.db and storage_1/data/* (requires FORCE=1)
EOF
}

ensure_layout

cmd="${1:-}"
shift || true

case "${cmd}" in
  foreground) start_foreground ;;
  status)     status ;;
  stop)       stop_server ;;
  console)    tail_console ;;

  update-server)   update_server ;;
  validate-server) validate_server ;;

  sync-mods)       sync_mods ;;
  sync-servermods) sync_servermods ;;
  fix-mods)        fix_mods ;;
  fix-servermods)  fix_servermods ;;
  args)            print_mod_args ;;
  purge-mod)       [[ $# -ge 1 ]] || die "Usage: purge-mod <id>"; purge_mod "$1" ;;

  backup) backup_now ;;
  wipe)   wipe_data ;;

  mod)
    sub="${1:-}"; shift || true
    case "${sub}" in
      add)     ids=$(parse_ids "$*") || exit 1; for id in ${ids}; do list_add_id "${MODS_FILE}" "${id}"; done;;
      remove)  ids=$(parse_ids "$*") || exit 1; for id in ${ids}; do list_remove_id "${MODS_FILE}" "${id}"; done;;
      enable)  ids=$(parse_ids "$*") || exit 1; for id in ${ids}; do list_enable_id "${MODS_FILE}" "${id}"; done;;
      disable) ids=$(parse_ids "$*") || exit 1; for id in ${ids}; do list_disable_id "${MODS_FILE}" "${id}"; done;;
      list)    sed -n '1,200p' "${MODS_FILE}";;
      *) die "Usage: mod {add|remove|enable|disable|list} <ids...>" ;;
    esac
    ;;

  servermod)
    sub="${1:-}"; shift || true
    case "${sub}" in
      add)     ids=$(parse_ids "$*") || exit 1; for id in ${ids}; do list_add_id "${SERVERMODS_FILE}" "${id}"; done;;
      remove)  ids=$(parse_ids "$*") || exit 1; for id in ${ids}; do list_remove_id "${SERVERMODS_FILE}" "${id}"; done;;
      enable)  ids=$(parse_ids "$*") || exit 1; for id in ${ids}; do list_enable_id "${SERVERMODS_FILE}" "${id}"; done;;
      disable) ids=$(parse_ids "$*") || exit 1; for id in ${ids}; do list_disable_id "${SERVERMODS_FILE}" "${id}"; done;;
      list)    sed -n '1,200p' "${SERVERMODS_FILE}";;
      *) die "Usage: servermod {add|remove|enable|disable|list} <ids...>" ;;
    esac
    ;;

  ""|-h|--help|help) usage ;;
  *) die "Unknown command: ${cmd}. Try: /dayz/run.sh help" ;;
esac
