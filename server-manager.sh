#!/usr/bin/env bash
# Manager script for DayZ Docker instances

# Colors
bold=$(tput bold 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)
green=$(tput setaf 2 2>/dev/null || true)
cyan=$(tput setaf 6 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true)

# Detect Docker
DOCKER="docker"
if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker not found."
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  else
    echo "Error: Cannot connect to Docker daemon (try sudo?)"
    exit 1
  fi
fi

# Find Instances
declare -a INSTANCE_DIRS=()
declare -a INSTANCE_NAMES=()

scan_instances() {
  # Fix: Detect real user home if running as sudo
  local invoking_user="${SUDO_USER:-$USER}"
  local invoking_home
  invoking_home="$(getent passwd "${invoking_user}" | cut -d: -f6 || echo "$HOME")"
  local search_root="${invoking_home}/servers"
  
  if [[ -d "$search_root" ]]; then
    while IFS= read -r marker; do
      local dir
      dir="$(dirname "$marker")"
      local name
      name="$(grep '^INSTANCE_NAME=' "$marker" | cut -d= -f2-)"
      [[ -z "$name" ]] && name="$(basename "$dir")"
      
      INSTANCE_DIRS+=("$dir")
      INSTANCE_NAMES+=("$name")
    done < <(find "$search_root" -maxdepth 3 -name ".dayz-instance" 2>/dev/null || true)
  fi
}

select_instance() {
  echo "${bold}Found DayZ Instances:${reset}"
  local i=0
  for name in "${INSTANCE_NAMES[@]}"; do
    local status="OFFLINE"
    local dir="${INSTANCE_DIRS[$i]}"
    local cname="dayz-${name}"
    
    # Quick status check
    if $DOCKER ps --format '{{.Names}}' | grep -q "^${cname}$"; then
      status="${green}RUNNING${reset}"
    fi
    
    echo "  [$i] ${cyan}${name}${reset} (${status})"
    ((i++))
  done
  
  if [[ $i -eq 0 ]]; then
    echo "  ${red}No instances found under ~/servers${reset}"
    exit 0
  fi
  
  echo ""
  read -r -p "Select Instance [0-$((i-1))]: " choice || exit 0
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -ge "$i" ]]; then
    echo "Invalid selection."
    exit 1
  fi
  
  SELECTED_DIR="${INSTANCE_DIRS[$choice]}"
  SELECTED_NAME="${INSTANCE_NAMES[$choice]}"
  SELECTED_CONTAINER="dayz-${SELECTED_NAME}"
}

manage_menu() {
  while true; do
    clear
    echo ""
    echo "${bold}=== ${cyan}${SELECTED_NAME}${reset} ${bold}===${reset}"
    echo ""
    echo "  ${bold}Server Control:${reset}"
    echo "    [1] Start Server"
    echo "    [2] Stop Server"
    echo "    [3] Restart Server"
    echo ""
    echo "  ${bold}Monitoring:${reset}"
    echo "    [4] View Docker Logs (Ctrl+C to exit)"
    echo "    [5] Enter Container Shell (bash)"
    echo ""
    echo "  ${bold}Maintenance:${reset}"
    echo "    [6] Sync Workshop Mods"
    echo "    [7] Update Server Files"
    echo ""
    echo "    [0] Exit"
    echo ""
    
    read -r -p "Select: " action
    
    case "$action" in
      1) (cd "$SELECTED_DIR" && $DOCKER compose up -d) ;;
      2) (cd "$SELECTED_DIR" && $DOCKER compose stop) ;;
      3) (cd "$SELECTED_DIR" && $DOCKER compose restart) ;;
      4) (cd "$SELECTED_DIR" && $DOCKER compose logs -f --tail=200) ;;
      5) $DOCKER exec -it "$SELECTED_CONTAINER" /bin/bash || echo "${red}Not running${reset}" ;;
      6) $DOCKER exec -it "$SELECTED_CONTAINER" /dayz/run.sh sync-mods ;;
      7) $DOCKER exec -it "$SELECTED_CONTAINER" /dayz/run.sh update-server ;;
      0) exit 0 ;;
      *) echo "Invalid" ;;
    esac

    echo ""
    read -r -p "Press Enter..." dummy
  done
}

# Main
scan_instances
select_instance
manage_menu