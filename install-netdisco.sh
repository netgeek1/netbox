#!/usr/bin/env bash
# ============================================================
# NetDisco Docker Installer & Lifecycle Manager (operator-grade)
#
# This is built off the instructions at https://hub.docker.com/r/netdisco/netdisco
# - Readiness checks run INSIDE containers (no host port publishing)
# - Idempotent re-runs
# ============================================================

set -euo pipefail

SCRIPT_VERSION="3.1.0"

# -----------------------------
# Constants
# -----------------------------
ND_UID=901
ND_GID=901
DEFAULT_DIR="/opt/netdisco"
COMPOSE_FILE="compose.yaml"
SERVICE_NAME="netdisco"
POSTGRES_SERVICE="postgres"

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

# -----------------------------
# Docker check
# -----------------------------
install_docker() {
  command -v docker >/dev/null 2>&1 && return 0

  log "Installing Docker Engine + Compose plugin (Ubuntu/Debian)..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release git

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
  docker exec netdisco /bin/sh -c "netdisco-do macsuck"
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

# -----------------------------
# SNMP management
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
    0) exit 0 ;;
    *) warn "Invalid option" ;;
  esac
done
