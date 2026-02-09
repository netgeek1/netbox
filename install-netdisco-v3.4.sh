#!/usr/bin/env bash
# ============================================================
# NetDisco Docker Installer & Lifecycle Manager (operator-grade)
#
# This is built off the instructions at https://hub.docker.com/r/netdisco/netdisco
# - Readiness checks run INSIDE containers (no host port publishing)
# - Idempotent re-runs
# ============================================================

set -euo pipefail

SCRIPT_VERSION="3.4.7"

# -----------------------------
# Constants
# -----------------------------
ND_UID=901
ND_GID=901
DEFAULT_DIR="/opt/netdisco"
COMPOSE_FILE="compose.yaml"
SERVICE_NAME="netdisco"
POSTGRES_SERVICE="postgres"
BACKEND_CONTAINER="netdisco-backend"

# -----------------------------
# Privilege handling
# -----------------------------
if [[ $EUID -ne 0 ]]; then
  echo "[INFO] Elevation required — re-running with sudo..."
  exec sudo -E bash "$0" "$@"
fi

REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

# -----------------------------
# Helpers
# -----------------------------
log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err() { echo -e "[ERROR] $*" >&2; exit 1; }

docker_compose() {
  docker compose -f "$INSTALL_DIR/$COMPOSE_FILE" "$@"
}

containers_exist() {
  docker compose -f "$INSTALL_DIR/$COMPOSE_FILE" ps -q >/dev/null 2>&1
}

containers_running() {
  docker compose -f "$INSTALL_DIR/$COMPOSE_FILE" ps | grep -q "Up"
}

wait_for_ui() {
  log "Waiting for NetDisco UI..."
  for i in {1..60}; do
    if curl -fs http://localhost:5000 >/dev/null 2>&1; then
      log "NetDisco UI is available"
      return
    fi
    sleep 5
  done
  warn "UI did not become available in time"
}

ensure_dirs() {
  mkdir -p \
    "$INSTALL_DIR"/{config,logs,nd-site-local} \
    "$INSTALL_DIR/netdisco"/{config,logs,nd-site-local,pgdata,postgresql}

  chown -R $ND_UID:$ND_GID "$INSTALL_DIR"
  chmod -R 755 "$INSTALL_DIR"
}

backend_running() {
  docker ps --format '{{.Names}}' | grep -q "^${BACKEND_CONTAINER}$"
}

# -----------------------------
# Docker check
# -----------------------------
install_docker() {
  command -v docker >/dev/null 2>&1 && return 0

  log "Installing Docker Engine + Compose plugin (Ubuntu/Debian)..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release git
  
  #-------------
  # Install yq
  #-------------
  #apt-get isntall yq -y
  sudo wget https://github.com/mikefarah/yq/releases/download/3.4.1/yq_linux_amd64 -O /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq
  # yq --version
  # Should print: yq version 3.4.1


  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
  systemctl enable docker
  systemctl start docker
}

ensure_docker_group_access() {
  getent group docker >/dev/null || groupadd docker
  if ! id "$REAL_USER" 2>/dev/null | grep -q '\bdocker\b'; then
    usermod -aG docker "$REAL_USER"
    warn "Added '$REAL_USER' to docker group. Log out/in required for it to take effect."
    exit
  fi
}

install_docker
ensure_docker_group_access
# -----------------------------
# Install directory
# -----------------------------
read -rp "Install directory [$DEFAULT_DIR]: " INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"

# Normalize path
INSTALL_DIR="$(realpath -m "$INSTALL_DIR")"

SNMP_CONF="$INSTALL_DIR/nd-site-local/config.yml"

# -----------------------------
# Compose file
# -----------------------------
create_compose() {
  if [[ -f "$INSTALL_DIR/$COMPOSE_FILE" ]] && containers_exist; then
    warn "Compose exists and containers were created — not overwriting"
    return
  fi

  log "Creating compose.yaml"
  cat > "$INSTALL_DIR/$COMPOSE_FILE" <<'EOF'
# https://docs.docker.com/compose/how-tos/environment-variables/envvars-precedence/
x-common-environment: &common-environment
  NETDISCO_DOMAIN: '${NETDISCO_DOMAIN:-discover}'
  NETDISCO_DB_TENANT:
  NETDISCO_DB_NAME:
  NETDISCO_DB_HOST: '${NETDISCO_DB_HOST:-netdisco-postgresql}'
  NETDISCO_DB_PORT:
  NETDISCO_DB_USER:
  NETDISCO_DB_PASS:
  NETDISCO_RO_COMMUNITY:
  PGDATABASE:
  PGHOST:
  PGPORT:
  PGUSER:
  PGPASSWORD:
  NETDISCO_CURRENT_PG_VERSION: '${NETDISCO_CURRENT_PG_VERSION:-18}'

services:

  netdisco-postgresql:
    container_name: netdisco-postgresql
    image: netdisco/netdisco:latest-postgresql
    shm_size: 128mb
    hostname: netdisco-postgresql
    # !! healthcheck is defined in the Dockerfile
    volumes:
      - "./netdisco/postgresql:/var/lib/postgresql"
    environment:
      <<: *common-environment
      NETDISCO_DB_SUPERUSER:

  netdisco-postgresql-13:
    container_name: netdisco-postgresql-13
    image: netdisco/netdisco:latest-postgresql-13
    shm_size: 128mb
    hostname: netdisco-postgresql-13
    volumes:
      - "./netdisco/pgdata:/var/lib/postgresql/data"
    environment:
      <<: *common-environment
      NETDISCO_DB_SUPERUSER:
    profiles:
      - with-pg-upgrade

  netdisco-db-init:
    container_name: netdisco-db-init
    image: netdisco/netdisco:latest-backend
    entrypoint: ''
    command: "/home/netdisco/bin/netdisco-env /home/netdisco/bin/netdisco-updatedb.sh"
    user: postgres
    depends_on:
      netdisco-postgresql:
        condition: service_healthy
    volumes:
      - "./netdisco/pgdata:/var/lib/pgversions/pg13"
      - "./netdisco/postgresql:/var/lib/pgversions/new"
      - "./netdisco/config:/home/netdisco/environments"
    environment:
      <<: *common-environment
      DEPLOY_ADMIN_USER: '${DEPLOY_ADMIN_USER:-YES}' # or set to NO
      NETDISCO_ADMIN_USER:

  netdisco-backend:
    container_name: netdisco-backend
    image: netdisco/netdisco:latest-backend
    hostname: netdisco-backend
    depends_on:
      netdisco-db-init:
        condition: service_completed_successfully
    init: true # run a full process manager to get signals
    volumes:
      - "./netdisco/nd-site-local:/home/netdisco/nd-site-local"
      - "./netdisco/config:/home/netdisco/environments"
      - "./netdisco/logs:/home/netdisco/logs"
    environment:
      <<: *common-environment
    dns_opt:
      - 'ndots:0'
      - 'timeout:1'
      - 'retries:0'
      - 'attempts:1'
      - edns0
      - trustad

  netdisco-web:
    container_name: netdisco-web
    image: netdisco/netdisco:latest-web
    hostname: netdisco-web
    depends_on:
      netdisco-db-init:
        condition: service_completed_successfully
    init: true # run a full process manager to get signals
    volumes:
      - "./netdisco/nd-site-local:/home/netdisco/nd-site-local"
      - "./netdisco/config:/home/netdisco/environments"
      - "./netdisco/logs:/home/netdisco/logs"
    environment:
      <<: *common-environment
      IPV: '${IPV:-4}'
      PORT:
    ports:
      - "5000:5000"
    dns_opt:
      - 'ndots:0'
      - 'timeout:1'
      - 'retries:0'
      - 'attempts:1'
      - edns0
      - trustad
EOF
}

# -----------------------------
# Actions
# -----------------------------
install_netdisco() {
  log "Installing NetDisco..."
  mkdir -p "$INSTALL_DIR"
  ensure_dirs
  create_compose
  docker_compose pull
  docker_compose up -d
  wait_for_ui
}

upgrade_netdisco() {
  log "Upgrading NetDisco..."
  docker_compose pull
  docker_compose up -d
}

refresh_mac_vendors() {
  log "Refreshing MAC vendors..."
  docker exec netdisco-backend /bin/sh -c "netdisco-do macsuck"
}

status() {
  docker_compose ps
}

logs() {
  docker_compose logs -f --tail=100
}

stop_netdisco() {
  docker_compose down
}

start_netdisco() {
  docker_compose up -d
}

# ============================================================================
# SNMP MANAGEMENT - ADDED FUNCTIONS ONLY
# ============================================================================

SNMP_DB_FILE="$INSTALL_DIR/netdisco/config/snmp_credentials.db"

snmp_db_ensure() {
  mkdir -p "$INSTALL_DIR/netdisco/config"
  if [[ ! -f "$SNMP_DB_FILE" ]]; then
    sudo touch "$SNMP_DB_FILE"
    sudo chmod 0640 "$SNMP_DB_FILE"
    sudo chgrp 901 "$SNMP_DB_FILE" 2>/dev/null || true
  fi
}

snmp_db_list() {
  snmp_db_ensure
  sudo cat "$SNMP_DB_FILE" 2>/dev/null | grep -v '^#' | grep -v '^$' || true
}

snmp_db_add() {
  local line="$1"
  snmp_db_ensure
  echo "$line" | sudo tee -a "$SNMP_DB_FILE" >/dev/null
}

snmp_db_delete() {
  local tag="$1"
  snmp_db_ensure
  local tmp=$(mktemp)
  sudo cat "$SNMP_DB_FILE" | grep -v "|${tag}|" > "$tmp"
  sudo cp "$tmp" "$SNMP_DB_FILE"
  rm -f "$tmp"
  sudo chmod 0640 "$SNMP_DB_FILE"
  sudo chgrp 901 "$SNMP_DB_FILE" 2>/dev/null || true
}

snmp_regen_deployment() {
  snmp_db_ensure
  local yml="$INSTALL_DIR/netdisco/config/deployment.yml"
  local v3_count=$(snmp_db_list | grep -c '^v3|' || true)
  
  if [[ "$v3_count" -gt 0 ]]; then
    {
      echo "no_auth: false"
      echo "discover_snmpver: 3"
      echo "device_auth:"
      snmp_db_list | grep '^v3|' | while IFS='|' read -r typ tag user aproto apass mode pproto ppass; do
        echo "  - tag: $tag"
        echo "    user: $user"
        echo "    ro: true"
        echo "    auth:"
        echo "      proto: $aproto"
        echo "      pass: $apass"
        if [[ "$mode" == "authPriv" ]]; then
          echo "    priv:"
          echo "      proto: $pproto"
          echo "      pass: $ppass"
        fi
      done
    } > "$yml"
  else
    {
      echo "no_auth: true"
      echo "discover_snmpver: 2"
      echo "device_auth: []"
    } > "$yml"
  fi
  
  chmod 0640 "$yml"
  chown 901:901 "$yml" 2>/dev/null || true
}

snmp_list() {
  echo
  echo "=== SNMP Credentials ==="
  local i=0
  snmp_db_list | while IFS='|' read -r typ tag rest; do
    i=$((i+1))
    if [[ "$typ" == "v3" ]]; then
      echo "[$i] $tag (SNMPv3)"
    elif [[ "$typ" == "v2c" ]]; then
      echo "[$i] $tag (SNMPv2c)"
    fi
  done
  if [[ $(snmp_db_list | wc -l) -eq 0 ]]; then
    echo "(none)"
  fi
  echo
}

snmp_add() {
  echo
  echo "1) SNMPv3"
  echo "2) SNMPv2c"
  read -rp "Select [1]: " kind
  kind="${kind:-1}"

  read -rp "Tag: " tag
  [[ -z "$tag" ]] && echo "Cancelled" && return

  if [[ "$kind" == "2" ]]; then
    read -rsp "Community: " comm
    echo
    snmp_db_add "v2c|$tag|$comm"
  else
    read -rp "Username: " user
    read -rp "Auth (SHA/MD5) [SHA]: " aproto
    aproto="${aproto:-SHA}"
    read -rsp "Auth pass: " apass
    echo
    echo "1) authPriv"
    echo "2) authNoPriv"
    read -rp "Select [1]: " pm
    pm="${pm:-1}"
    if [[ "$pm" == "1" ]]; then
      read -rp "Priv (AES/DES) [AES]: " pproto
      pproto="${pproto:-AES}"
      read -rsp "Priv pass: " ppass
      echo
      snmp_db_add "v3|$tag|$user|$aproto|$apass|authPriv|$pproto|$ppass"
    else
      snmp_db_add "v3|$tag|$user|$aproto|$apass|authNoPriv||"
    fi
  fi

  snmp_regen_deployment

  # Reload containers with updated deployment.yml and env
  docker compose restart netdisco-backend netdisco-web >/dev/null 2>&1 || true
  echo "Added $tag"
}

snmp_delete() {
  snmp_list
  read -rp "Tag to delete: " tag
  [[ -z "$tag" ]] && echo "Cancelled" && return

  echo "Type DELETE to confirm:"
  read -r confirm
  [[ "$confirm" != "DELETE" ]] && echo "Cancelled" && return

  # Ensure DB exists
  snmp_db_ensure

  # Remove the line(s) for this tag
  local tmp
  tmp=$(mktemp)
  sudo awk -F'|' -v t="$tag" '$2 != t' "$SNMP_DB_FILE" > "$tmp"
  sudo mv "$tmp" "$SNMP_DB_FILE"
  sudo chmod 0640 "$SNMP_DB_FILE"
  sudo chown $ND_UID:$ND_GID "$SNMP_DB_FILE" 2>/dev/null || true

  # Regenerate deployment.yml with remaining credentials
  snmp_regen_deployment

  # Restart backend so Netdisco picks up the change
  docker compose restart netdisco-backend netdisco-web >/dev/null 2>&1 || true

  echo "Deleted SNMP credential '$tag'."
}


snmp_test() {
  snmp_list
  read -rp "Tag to test: " tag
  [[ -z "$tag" ]] && echo "Cancelled" && return

  read -rp "Target IP: " ip
  [[ -z "$ip" ]] && echo "Cancelled" && return

  # Load the credential from DB
  local dbline
  dbline=$(snmp_db_list | grep "|${tag}|")
  if [[ -z "$dbline" ]]; then
    echo "Tag not found!"
    return
  fi

  # Parse credential fields
  IFS='|' read -r typ _tag user aproto apass mode pproto ppass <<<"$dbline"

  # Backup current deployment.yml
  local yml="$INSTALL_DIR/netdisco/config/deployment.yml"
  local yml_bak
  yml_bak=$(mktemp)
  [[ -f "$yml" ]] && cp -f "$yml" "$yml_bak"

  # Regenerate a temp deployment.yml with only this credential
  if [[ "$typ" == "v3" ]]; then
    {
      echo "no_auth: false"
      echo "discover_snmpver: 3"
      echo "device_auth:"
      echo "  - tag: $tag"
      echo "    user: $user"
      echo "    ro: true"
      echo "    auth:"
      echo "      proto: $aproto"
      echo "      pass: $apass"
      if [[ "$mode" == "authPriv" ]]; then
        echo "    priv:"
        echo "      proto: $pproto"
        echo "      pass: $ppass"
      fi
    } > "$yml"
  else
    # v2c
    local comm
    comm=$(echo "$dbline" | awk -F'|' '{print $3}')
    {
      echo "no_auth: true"
      echo "discover_snmpver: 2"
      echo "device_auth: []"
    } > "$yml"
    export NETDISCO_RO_COMMUNITY="$comm"
  fi

  # Restart backend to pick up new deployment.yml
  docker compose restart netdisco-backend >/dev/null 2>&1 || true

  echo "Testing SNMP credential '$tag' against $ip..."
  docker exec -it netdisco-backend netdisco-do discover -d "$ip" || true

  # Restore original deployment.yml
  [[ -f "$yml_bak" ]] && cp -f "$yml_bak" "$yml"
  rm -f "$yml_bak"

  # Restart backend to restore full configuration
  docker compose restart netdisco-backend >/dev/null 2>&1 || true

  echo "Test complete."
}



snmp_menu() {
  while true; do
    echo
    echo "SNMP Management"
    echo "==============="
    echo "1) List"
    echo "2) Add"
    echo "3) Delete"
    echo "4) Test"
    echo "0) Back"
    echo
    read -rp "Select: " opt
    
    case "$opt" in
      1) snmp_list; read -p "Press enter..." ;;
      2) snmp_add; read -p "Press enter..." ;;
      3) snmp_delete; read -p "Press enter..." ;;
      4) snmp_test; read -p "Press enter..." ;;
      0) break ;;
    esac
  done
}

# -----------------------------
# Menu
# -----------------------------
while true; do
  cat <<EOF

NetDisco Manager
================
1) Install / Initialize
2) Start
3) Stop
4) Upgrade
5) Refresh MAC vendors
6) Status
7) Logs
8) SNMP Management
0) Exit

EOF
  read -rp "Select option: " opt

  case "$opt" in
    1) install_netdisco ;;
    2) start_netdisco ;;
    3) stop_netdisco ;;
    4) upgrade_netdisco ;;
    5) refresh_mac_vendors ;;
    6) status ;;
    7) logs ;;
    8) snmp_menu ;;
    0) exit 0 ;;
    *) warn "Invalid option" ;;
  esac
done
