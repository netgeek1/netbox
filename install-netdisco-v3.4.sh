#!/usr/bin/env bash
# ============================================================
# NetDisco Docker Installer & Lifecycle Manager (operator-grade)
#
# This is built off the instructions at https://hub.docker.com/r/netdisco/netdisco
# - Readiness checks run INSIDE containers (no host port publishing)
# - Idempotent re-runs
# ============================================================

set -euo pipefail

SCRIPT_VERSION="3.4.1"

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
# SNMP config handling
# -----------------------------
# ------------------------------------------------------------
# SNMP DB helpers (DB-backed, not YAML)
# ------------------------------------------------------------

ensure_snmp_db() {
  docker exec netdisco-backend netdisco-do dbicdeploy >/dev/null 2>&1 || true
}

list_snmp_profiles() {
  ensure_snmp_db

  echo
  echo "Configured SNMP profiles:"
  echo "-------------------------"

  docker exec netdisco-backend netdisco-do snmp_auth list 2>/dev/null \
    | awk '
        /^tag:/ {
            tag=$2
        }
        /community:/ {
            printf "[v2c] %s\n", tag
        }
        /user:/ {
            user=$2
        }
        /auth:/ {
            auth=$2
        }
        /priv:/ {
            priv=$2
            printf "[v3 ] %s | Auth: %s | Priv: %s\n", user, auth, priv
        }
      '

  echo
}

add_snmp_v2_profile() {
  read -rp "Profile name (tag): " TAG
  read -rsp "Community: " COMMUNITY
  echo

  ensure_snmp_db

  docker exec netdisco-backend netdisco-do snmp_auth create \
      --tag "$TAG" \
      --community "$COMMUNITY"

  echo "[OK] Added v2c profile: $TAG"
}

add_snmp_v3_profile() {
  read -rp "Profile name (tag): " TAG
  read -rp "User: " USER
  read -rp "Auth protocol (MD5/SHA): " AUTHPROTO
  read -rsp "Auth password: " AUTHPASS
  echo
  read -rp "Priv protocol (DES/AES): " PRIVPROTO
  read -rsp "Priv password: " PRIVPASS
  echo

  ensure_snmp_db

  docker exec netdisco-backend netdisco-do snmp_auth create \
      --tag "$TAG" \
      --user "$USER" \
      --auth "$AUTHPROTO" \
      --authpass "$AUTHPASS" \
      --priv "$PRIVPROTO" \
      --privpass "$PRIVPASS"

  echo "[OK] Added v3 profile: $TAG"
}

delete_snmp_profile() {
  list_snmp_profiles
  read -rp "Profile tag to delete: " TAG

  docker exec netdisco-backend netdisco-do snmp_auth delete --tag "$TAG"
  echo "[OK] Deleted profile: $TAG"
}

# ------------------------
# Regenerate Deployment from DB
# ------------------------
snmp_regen_deployment() {
  mkdir -p "$(dirname "$DEPLOYMENT_YML")"
  echo "snmp_auth:" > "$DEPLOYMENT_YML"
  while IFS='|' read -r version tag rest; do
    if [[ "$version" == "v2c" ]]; then
      community="$rest"
      echo "  - tag: $tag" >> "$DEPLOYMENT_YML"
      echo "    community: $community" >> "$DEPLOYMENT_YML"
    else
      user=$(echo "$rest" | cut -d'|' -f1)
      authproto=$(echo "$rest" | cut -d'|' -f2)
      authpass=$(echo "$rest" | cut -d'|' -f3)
      privproto=$(echo "$rest" | cut -d'|' -f4)
      privpass=$(echo "$rest" | cut -d'|' -f5)
      echo "  - tag: $tag" >> "$DEPLOYMENT_YML"
      echo "    user: $user" >> "$DEPLOYMENT_YML"
      echo "    authproto: $authproto" >> "$DEPLOYMENT_YML"
      echo "    authpass: $authpass" >> "$DEPLOYMENT_YML"
      echo "    privproto: $privproto" >> "$DEPLOYMENT_YML"
      echo "    privpass: $privpass" >> "$DEPLOYMENT_YML"
    fi
  done < "$SNMP_DB"
}

# ------------------------
# SNMP Test
# ------------------------
snmp_test() {
  ensure_snmp_db
  if [[ ! $(docker ps -q -f name=netdisco-backend) ]]; then
    echo "NetDisco backend container is not running!"
    read -rp "Press Enter to continue..."
    return
  fi

  echo
  echo "SNMP Test Menu"
  echo "=============="
  echo "1) List profiles"
  echo "2) Test all profiles (default)"
  echo "3) Test single profile"
  echo "4) Manual test"
  echo "0) Back"
  echo

  read -rp "Select option [2]: " choice
  choice=${choice:-2}

  case "$choice" in
    1) list_snmp_profiles ;;
    2)
      read -rp "Target IP/CIDR for testing all profiles: " target
      while IFS='|' read -r version tag rest; do
        echo "Testing $tag on $target..."
        if [[ "$version" == "v2c" ]]; then
          community="$rest"
          docker exec -it netdisco-backend netdisco-do discover -d "$target" -c "$community"
        else
          user=$(echo "$rest" | cut -d'|' -f1)
          authproto=$(echo "$rest" | cut -d'|' -f2)
          authpass=$(echo "$rest" | cut -d'|' -f3)
          privproto=$(echo "$rest" | cut -d'|' -f4)
          privpass=$(echo "$rest" | cut -d'|' -f5)
          docker exec -it netdisco-backend netdisco-do discover -d "$target" -u "$user" \
            --authproto "$authproto" --authpass "$authpass" --privproto "$privproto" --privpass "$privpass"
        fi
      done < "$SNMP_DB"
      ;;
    3)
      list_snmp_profiles
      read -rp "Profile to test: " tag
      line=$(grep "|$tag|" "$SNMP_DB")
      [[ -z "$line" ]] && { echo "Profile not found."; read -rp "Press Enter..."; return; }

      read -rp "Target IP/CIDR for testing $tag: " target
      version=$(echo "$line" | cut -d'|' -f1)
      if [[ "$version" == "v2c" ]]; then
        community=$(echo "$line" | cut -d'|' -f3)
        docker exec -it netdisco-backend netdisco-do discover -d "$target" -c "$community"
      else
        user=$(echo "$line" | cut -d'|' -f2)
        authproto=$(echo "$line" | cut -d'|' -f3)
        authpass=$(echo "$line" | cut -d'|' -f4)
        privproto=$(echo "$line" | cut -d'|' -f5)
        privpass=$(echo "$line" | cut -d'|' -f6)
        docker exec -it netdisco-backend netdisco-do discover -d "$target" -u "$user" \
          --authproto "$authproto" --authpass "$authpass" --privproto "$privproto" --privpass "$privpass"
      fi
      ;;
    4)
      read -rp "Target IP/CIDR: " target
      read -rp "SNMP version (2c/3): " version
      if [[ "$version" == "2c" ]]; then
        read -rp "Community: " community
        docker exec -it netdisco-backend netdisco-do discover -d "$target" -c "$community"
      else
        read -rp "User: " user
        read -s -rp "Auth password: " authpass; echo
        read -s -rp "Priv password: " privpass; echo
        docker exec -it netdisco-backend netdisco-do discover -d "$target" -u "$user" \
          --authpass "$authpass" --privpass "$privpass"
      fi
      ;;
    0) return ;;
    *) echo "Invalid option" ;;
  esac
  read -rp "Press Enter to continue..."
}

# ------------------------
# SNMP Menu Loop
# ------------------------
snmp_menu() {
  while true; do
    echo
    echo "SNMP Management"
    echo "==============="
    echo "1) List profiles"
    echo "2) Add SNMP v2c profile"
    echo "3) Add SNMP v3 profile"
    echo "4) Edit v3 profile"
    echo "5) Delete profile"
    echo "6) Test SNMP"
    echo "0) Back"
    echo
    read -rp "Select option: " choice

    case "$choice" in
      1) list_snmp_profiles ;;
      2) add_snmp_v2 ;;
      3) add_snmp_v3 ;;
      4) edit_snmp_v3 ;;
      5) delete_snmp_profile ;;
      6) snmp_test ;;
      0) break ;;
      *) echo "Invalid selection" ;;
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
