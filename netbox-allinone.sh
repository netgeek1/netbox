#!/usr/bin/env bash
set -euo pipefail

# netbox-manager with Slurp'it sidecar support (clean / upstream-exact / upstream-raw)
# - Builds NetBox with plugins
# - Adds Slurp'it stack alongside NetBox
# - Slurp'it mode selectable at install time AND via menu
# - Slurp'it UI port selectable at deployment time
# - Auto-generates (best-effort) a NetBox API token named "slurpit"
#
# NOTE:
# - Slurp'it upstream compose (as you pasted) uses Docker Hub images: slurpit/warehouse, slurpit/scraper, slurpit/scanner, slurpit/portal
# - The gitlab.com/slurpit.io/images registry is not used by that compose.
# - NetBox->Slurp'it "sync preconfig" is done by injecting likely env vars; if Slurp'it ignores them, nothing breaks.

SCRIPT_VERSION="4.1.0"

INSTALL_DIR="/opt/netbox-docker"
NETBOX_COMPOSE_DIR="${INSTALL_DIR}/netbox-docker"
NETBOX_BRANCH="release"

REAL_USER="${SUDO_USER:-${LOGNAME:-$(whoami)}}"

NETBOX_PORT="${NETBOX_PORT:-8000}"

# NetBox pinned (known-good)
NETBOX_VERSION_DEFAULT="v4.4.9"

# Plugin pinned (known-good examples; keep as you like)
NB_SECRETS_VERSION_DEFAULT="2.4.1"
SLURPIT_PLUGIN_VERSION_DEFAULT="1.2.7"
NB_DNS_VERSION_DEFAULT="1.4.7"
NB_INVENTORY_VERSION_DEFAULT="2.4.1"
NB_ROUTING_VERSION_DEFAULT="0.3.1"
NB_TOPOLOGY_VERSION_DEFAULT="4.4.0"

# Modes: pinned | latest
NETBOX_VERSION_MODE="${NETBOX_VERSION_MODE:-pinned}"
PLUGIN_VERSION_MODE="${PLUGIN_VERSION_MODE:-pinned}"

# Slurp'it modes (persisted to .env.slurpit)
# - integrated-clean
# - integrated-upstream
# - upstream-raw
SLURPIT_ENV_FILE="${NETBOX_COMPOSE_DIR}/.env.slurpit"
SLURPIT_MODE_DEFAULT="integrated-clean"

# Slurp'it raw upstream sources
SLURPIT_UPSTREAM_RAW_URL_DEFAULT="https://gitlab.com/slurpit.io/images/-/raw/main/docker-compose.yml"
SLURPIT_UPSTREAM_RAW_FILE="${NETBOX_COMPOSE_DIR}/docker-compose.slurpit.upstream.yml"
SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE="${NETBOX_COMPOSE_DIR}/docker-compose.slurpit.upstream.override.yml"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------
if [[ -t 1 ]]; then
  COLOR_RED="\033[31m"
  COLOR_GREEN="\033[32m"
  COLOR_YELLOW="\033[33m"
  COLOR_BLUE="\033[34m"
  COLOR_RESET="\033[0m"
else
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_RESET=""
fi

log()   { printf '[INFO] %s\n' "$*"; }
warn()  { printf "${COLOR_YELLOW}[WARN] %s${COLOR_RESET}\n" "$*" >&2; }
error() { printf "${COLOR_RED}[ERROR] %s${COLOR_RESET}\n" "$*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    sudo -E bash "$0" "$@"
    exit $?
  fi
}

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
    return
  fi

  log "Installing Docker Engine..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release openssl git

  mkdir -p /etc/apt/keyrings
  curl -sSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable docker
  systemctl start docker
  log "Docker installed."
}

ensure_docker_group() {
  getent group docker >/dev/null || groupadd docker
  if ! id "$REAL_USER" | grep -q docker; then
    log "Adding user '$REAL_USER' to docker group"
    usermod -aG docker "$REAL_USER"
    warn "You may need to log out/in for group changes to apply."
  fi
}

ensure_packages() {
  local pkgs=(curl jq openssl git)
  local missing=()
  for p in "${pkgs[@]}"; do
    command -v "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} > 0 )); then
    log "Installing packages: ${missing[*]}"
    apt-get update
    apt-get install -y "${missing[@]}"
  fi
}

ensure_dependencies() {
  install_docker
  ensure_docker_group
  ensure_packages
}

# ------------------------------------------------------------
# NetBox repo setup
# ------------------------------------------------------------
clone_netbox_docker() {
  log "Ensuring netbox-docker repository exists..."
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  if [[ ! -d netbox-docker ]]; then
    git clone -b "$NETBOX_BRANCH" https://github.com/netbox-community/netbox-docker.git
  else
    log "netbox-docker already exists."
  fi
}

update_netbox_repo() {
  cd "$NETBOX_COMPOSE_DIR"
  log "Updating netbox-docker repo..."
  git pull --ff-only || warn "Git pull failed; check local changes."
}

# ------------------------------------------------------------
# NetBox plugins build files
# ------------------------------------------------------------
create_plugin_requirements() {
  cd "$NETBOX_COMPOSE_DIR"

  if [[ "$PLUGIN_VERSION_MODE" == "latest" ]]; then
    log "Writing plugin_requirements.txt with LATEST plugin versions..."
    cat > plugin_requirements.txt <<'EOF'
netbox-secrets
slurpit_netbox
netbox-plugin-dns
netbox-inventory
netbox-routing
netbox-topology-views
EOF
  else
    log "Writing plugin_requirements.txt with PINNED plugin versions..."
    cat > plugin_requirements.txt <<EOF
netbox-secrets==${NB_SECRETS_VERSION_DEFAULT}
slurpit_netbox==${SLURPIT_PLUGIN_VERSION_DEFAULT}
netbox-plugin-dns==${NB_DNS_VERSION_DEFAULT}
netbox-inventory==${NB_INVENTORY_VERSION_DEFAULT}
netbox-routing==${NB_ROUTING_VERSION_DEFAULT}
netbox-topology-views==${NB_TOPOLOGY_VERSION_DEFAULT}
EOF
  fi
}

create_plugin_config() {
  cd "$NETBOX_COMPOSE_DIR"
  log "Writing configuration/plugins.py..."
  mkdir -p configuration

  cat > configuration/plugins.py <<'EOF'
PLUGINS = [
    "netbox_secrets",
    "slurpit_netbox",
    "netbox_dns",
    "netbox_inventory",
    "netbox_routing",
    "netbox_topology_views",
]

PLUGINS_CONFIG = {
    "netbox_secrets": {
        "public_key": "",
        "private_key": "",
    },
    "netbox_inventory": {},
}
EOF
}

create_plugin_dockerfile() {
  cd "$NETBOX_COMPOSE_DIR"

  local netbox_image_tag
  if [[ "$NETBOX_VERSION_MODE" == "latest" ]]; then
    netbox_image_tag="latest"
  else
    netbox_image_tag="${NETBOX_VERSION_DEFAULT}"
  fi

  log "Writing Dockerfile-plugins using netboxcommunity/netbox:${netbox_image_tag}..."
  cat > Dockerfile-plugins <<EOF
FROM netboxcommunity/netbox:${netbox_image_tag}
COPY ./plugin_requirements.txt /opt/netbox/
RUN /usr/local/bin/uv pip install -r /opt/netbox/plugin_requirements.txt
EOF
}

# ------------------------------------------------------------
# Slurp'it env + prompts (stdout clean)
# ------------------------------------------------------------
load_slurpit_env() {
  if [[ -f "$SLURPIT_ENV_FILE" ]]; then
    # shellcheck disable=SC2046
    export $(grep -v '^[[:space:]]*#' "$SLURPIT_ENV_FILE" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | xargs -r)
  fi
}

random_secret() {
  openssl rand -base64 24 | tr -d '\n' | tr '/+' 'Aa'
}

prompt_slurpit_ui_port() {
  load_slurpit_env
  local default_port="${SLURPIT_UI_PORT:-8081}"

  echo "Choose Slurp'it UI port to expose (current: ${default_port}):" >&2
  echo "1) 8081 (default)" >&2
  echo "2) 80" >&2
  echo "3) 443" >&2
  echo "4) Custom" >&2
  read -rp "Select [1-4]: " choice >&2

  local port=""
  case "$choice" in
    1|"") port="8081" ;;
    2) port="80" ;;
    3) port="443" ;;
    4) read -rp "Enter custom port: " port >&2 ;;
    *) warn "Invalid choice; using 8081."; port="8081" ;;
  esac

  if [[ -z "$port" ]]; then port="8081"; fi
  echo "$port"
}

prompt_slurpit_mode() {
  load_slurpit_env
  local current="${SLURPIT_MODE:-$SLURPIT_MODE_DEFAULT}"

  echo "Choose Slurp'it deployment mode (current: ${current}):" >&2
  echo "1) Integrated (clean, production-ready)" >&2
  echo "2) Integrated (upstream-exact layout/services)" >&2
  echo "3) Upstream (raw compose import + override)" >&2
  read -rp "Select [1-3]: " choice >&2

  local mode=""
  case "$choice" in
    1|"") mode="integrated-clean" ;;
    2) mode="integrated-upstream" ;;
    3) mode="upstream-raw" ;;
    *) warn "Invalid choice; using integrated-clean."; mode="integrated-clean" ;;
  esac

  echo "$mode"
}

save_slurpit_env() {
  local mode="$1"
  local ui_port="$2"
  local netbox_token="$3"

  # Clean-mode secrets (also used by upstream-exact if you want to keep secrets out of the compose)
  local mariadb_pass="${SLURPIT_MARIADB_PASSWORD:-$(random_secret)}"
  local mongo_pass="${SLURPIT_MONGO_PASSWORD:-$(random_secret)}"

  # Upstream uses TZ Europe/Amsterdam; clean uses UTC by default
  local tz="${SLURPIT_TZ:-UTC}"

  # Raw upstream URL (overrideable)
  local raw_url="${SLURPIT_UPSTREAM_RAW_URL:-$SLURPIT_UPSTREAM_RAW_URL_DEFAULT}"

  cat > "$SLURPIT_ENV_FILE" <<EOF
# Slurp'it settings managed by netbox-manager
SLURPIT_MODE=${mode}
SLURPIT_UI_PORT=${ui_port}
SLURPIT_TZ=${tz}
SLURPIT_UPSTREAM_RAW_URL=${raw_url}

# NetBox integration (best-effort injection; harmless if ignored)
SLURPIT_NETBOX_URL=http://netbox:8080
SLURPIT_NETBOX_TOKEN=${netbox_token}
SLURPIT_NETBOX_VERIFY_SSL=false
SLURPIT_NETBOX_SYNC_ENABLED=true
SLURPIT_NETBOX_SYNC_INTERVAL=300

# Clean-mode (and optional upstream-exact) database credentials
SLURPIT_MARIADB_DATABASE=portal
SLURPIT_MARIADB_USER=slurpit
SLURPIT_MARIADB_PASSWORD=${mariadb_pass}
SLURPIT_MONGO_ROOT_USER=slurpit
SLURPIT_MONGO_PASSWORD=${mongo_pass}
EOF
}

# ------------------------------------------------------------
# Docker compose wrapper (adds Slurp'it files when needed)
# ------------------------------------------------------------
dc() {
  cd "$NETBOX_COMPOSE_DIR"

  load_slurpit_env
  local mode="${SLURPIT_MODE:-$SLURPIT_MODE_DEFAULT}"

  # Base netbox-docker compose
  local files=(-f docker-compose.yml)

  # Our local override (NetBox build + plugins + (maybe) Slurp'it integrated)
  if [[ -f docker-compose.override.yml ]]; then
    files+=(-f docker-compose.override.yml)
  fi

  # If upstream raw mode, also include upstream file + override
  if [[ "$mode" == "upstream-raw" ]]; then
    if [[ -f "$SLURPIT_UPSTREAM_RAW_FILE" ]]; then
      files+=(-f "$SLURPIT_UPSTREAM_RAW_FILE")
    fi
    if [[ -f "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE" ]]; then
      files+=(-f "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE")
    fi
  fi

  docker compose "${files[@]}" "$@"
}

# ------------------------------------------------------------
# NetBox token automation (best effort)
# ------------------------------------------------------------
wait_netbox_container() {
  cd "$NETBOX_COMPOSE_DIR"
  local tries=60
  local i
  for ((i=1; i<=tries; i++)); do
    if dc ps netbox 2>/dev/null | awk 'NR>1{print $0}' | grep -qi netbox; then
      return 0
    fi
    sleep 2
  done
  return 1
}

get_or_create_netbox_token_slurpit() {
  cd "$NETBOX_COMPOSE_DIR"

  # NetBox must be running enough for Django + DB to respond. We'll try a few times.
  local tries=20
  local i
  for ((i=1; i<=tries; i++)); do
    local token=""
    token="$(dc exec -T netbox python3 - <<'PY' 2>/dev/null || true
from django.contrib.auth import get_user_model
from users.models import Token

User = get_user_model()
u = User.objects.filter(is_superuser=True).first()
if not u:
    raise SystemExit(2)

t, _ = Token.objects.get_or_create(user=u, name="slurpit")
print(t.key)
PY
)"
    token="$(echo "$token" | tr -d '\r' | tail -n1)"
    if [[ -n "$token" ]]; then
      echo "$token"
      return 0
    fi
    sleep 3
  done

  echo ""
  return 0
}

ensure_slurpit_env() {
  load_slurpit_env

  local mode ui_port token
  mode="$(prompt_slurpit_mode)"
  ui_port="$(prompt_slurpit_ui_port)"

  # If NetBox isn't up yet, we still write env with empty token, then we can re-run later.
  token=""
  if wait_netbox_container; then
    token="$(get_or_create_netbox_token_slurpit)"
  fi

  if [[ -z "$token" ]]; then
    warn "NetBox token auto-generation failed (NetBox may not be ready yet)."
    warn "Continuing with empty SLURPIT_NETBOX_TOKEN; you can rerun 'Enable Slurp'it' after NetBox is up."
  fi

  save_slurpit_env "$mode" "$ui_port" "$token"
  load_slurpit_env
}

# ------------------------------------------------------------
# Compose writers
# ------------------------------------------------------------
write_netbox_override_header() {
  cd "$NETBOX_COMPOSE_DIR"

  cat > docker-compose.override.yml <<EOF
services:
  netbox:
    build:
      context: .
      dockerfile: Dockerfile-plugins
    ports:
      - "${NETBOX_PORT}:8080"
    volumes:
      - ./configuration:/etc/netbox/config
    healthcheck:
      start_period: 300s
    networks:
      - default
      - slurpit-network

networks:
  slurpit-network:
    driver: bridge
EOF
}

write_slurpit_integrated_clean() {
  cd "$NETBOX_COMPOSE_DIR"
  load_slurpit_env

  # Add Slurp'it clean stack directly into docker-compose.override.yml
  cat >> docker-compose.override.yml <<'EOF'

services:
  slurpit-mariadb:
    image: mariadb:12-noble
    environment:
      TZ: ${SLURPIT_TZ:-UTC}
      MARIADB_DATABASE: ${SLURPIT_MARIADB_DATABASE:-portal}
      MARIADB_USER: ${SLURPIT_MARIADB_USER:-slurpit}
      MARIADB_PASSWORD: ${SLURPIT_MARIADB_PASSWORD}
      MARIADB_RANDOM_ROOT_PASSWORD: "true"
    volumes:
      - slurpit-mariadb-data:/var/lib/mysql
    networks:
      - slurpit-network
    restart: always

  slurpit-mongodb:
    image: mongo:8
    command: mongod --quiet --logpath /tmp/mongo.log --setParameter logLevel=0
    environment:
      TZ: ${SLURPIT_TZ:-UTC}
      MONGO_INITDB_ROOT_USERNAME: ${SLURPIT_MONGO_ROOT_USER:-slurpit}
      MONGO_INITDB_ROOT_PASSWORD: ${SLURPIT_MONGO_PASSWORD}
    volumes:
      - slurpit-mongodb-data:/data/db
    networks:
      - slurpit-network
    restart: always

  slurpit-warehouse:
    image: slurpit/warehouse:latest
    depends_on:
      - slurpit-mongodb
    environment:
      TZ: ${SLURPIT_TZ:-UTC}
      WAREHOUSE_MONGODB_LOCAL: "false"
      WAREHOUSE_PORTAL_URL: http://slurpit-portal
      WAREHOUSE_MONGODB_URI: mongodb://${SLURPIT_MONGO_ROOT_USER:-slurpit}:${SLURPIT_MONGO_PASSWORD}@slurpit-mongodb:27017/slurpit?authSource=admin

      # Best-effort NetBox integration (safe if ignored)
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      NETBOX_SYNC_ENABLED: ${SLURPIT_NETBOX_SYNC_ENABLED:-true}
      NETBOX_SYNC_INTERVAL: ${SLURPIT_NETBOX_SYNC_INTERVAL:-300}
      WAREHOUSE_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      WAREHOUSE_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      WAREHOUSE_NETBOX_SYNC_ENABLED: ${SLURPIT_NETBOX_SYNC_ENABLED:-true}
    networks:
      - slurpit-network
    restart: always

  slurpit-scraper:
    image: slurpit/scraper:latest
    depends_on:
      - slurpit-warehouse
    environment:
      TZ: ${SLURPIT_TZ:-UTC}
      SCRAPER_WAREHOUSE_HOSTNAME: slurpit-warehouse

      # Best-effort NetBox integration (safe if ignored)
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      SCRAPER_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      SCRAPER_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
    networks:
      - slurpit-network
    restart: always

  slurpit-scanner:
    image: slurpit/scanner:latest
    depends_on:
      - slurpit-warehouse
    environment:
      TZ: ${SLURPIT_TZ:-UTC}
      SCANNER_WAREHOUSE_HOSTNAME: slurpit-warehouse

      # Best-effort NetBox integration (safe if ignored)
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      SCANNER_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      SCANNER_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
    networks:
      - slurpit-network
    restart: always

  slurpit-portal:
    image: slurpit/portal:latest
    depends_on:
      - slurpit-mariadb
      - slurpit-warehouse
    environment:
      TZ: ${SLURPIT_TZ:-UTC}
      PORTAL_BASE_URL: http://localhost
      PORTAL_WAREHOUSE_URL: http://slurpit-warehouse
      PORTAL_MENU_MODE: classic
      PORTAL_DB_HOSTNAME: slurpit-mariadb
      PORTAL_DB_USERNAME: ${SLURPIT_MARIADB_USER:-slurpit}
      PORTAL_DB_PASSWORD: ${SLURPIT_MARIADB_PASSWORD}

      # Best-effort NetBox integration (safe if ignored)
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      PORTAL_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      PORTAL_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
    ports:
      - "${SLURPIT_UI_PORT}:80"
    networks:
      - slurpit-network
    restart: always

volumes:
  slurpit-mariadb-data:
  slurpit-mongodb-data:
EOF
}

write_slurpit_integrated_upstream_exact() {
  cd "$NETBOX_COMPOSE_DIR"
  load_slurpit_env

  # Keep upstream service names/healthchecks/depends_on conditions/host mounts/container_name/restart.
  # Minimal changes:
  # - make secrets come from .env.slurpit (no hardcoded secrets)
  # - add portal port mapping to chosen UI port
  # - add best-effort NetBox env to each service
  #
  # Host paths are placed under ./slurpit/* so they don't mix with netbox-docker paths.
  mkdir -p slurpit/db/mariadb slurpit/db/mongodb slurpit/backup/warehouse slurpit/backup/portal slurpit/logs/nginx slurpit/logs/php slurpit/certs

  cat >> docker-compose.override.yml <<'EOF'

services:
  slurpit-mariadb:
    image: mariadb:12-noble
    container_name: slurpit-mariadb
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    environment:
      TZ: ${SLURPIT_TZ:-Europe/Amsterdam}
      MARIADB_DATABASE: ${SLURPIT_MARIADB_DATABASE:-portal}
      MARIADB_USER: ${SLURPIT_MARIADB_USER:-slurpit}
      MARIADB_PASSWORD: ${SLURPIT_MARIADB_PASSWORD}
      MARIADB_RANDOM_ROOT_PASSWORD: true
    networks:
      - slurpit-network
    volumes:
      - ./slurpit/db/mariadb:/var/lib/mysql
    restart: always

  slurpit-mongodb:
    image: mongo:8
    container_name: slurpit-mongodb
    command: mongod --quiet --logpath /tmp/mongo.log --setParameter logLevel=0
    healthcheck:
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/127.0.0.1/27017"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    environment:
      TZ: ${SLURPIT_TZ:-Europe/Amsterdam}
      MONGO_INITDB_ROOT_USERNAME: ${SLURPIT_MONGO_ROOT_USER:-slurpit}
      MONGO_INITDB_ROOT_PASSWORD: ${SLURPIT_MONGO_PASSWORD}
    networks:
      - slurpit-network
    volumes:
      - ./slurpit/db/mongodb:/data/db
    restart: always

  slurpit-warehouse:
    image: slurpit/warehouse:latest
    container_name: slurpit-warehouse
    depends_on:
      slurpit-mongodb:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/services"]
      interval: 10s
      timeout: 10s
      retries: 360
    networks:
      - slurpit-network
    environment:
      TZ: ${SLURPIT_TZ:-Europe/Amsterdam}
      WAREHOUSE_MONGODB_LOCAL: false
      WAREHOUSE_PORTAL_URL: http://slurpit-portal
      WAREHOUSE_MONGODB_URI: mongodb://${SLURPIT_MONGO_ROOT_USER:-slurpit}:${SLURPIT_MONGO_PASSWORD}@slurpit-mongodb:27017/slurpit?authSource=admin

      # Best-effort NetBox integration (safe if ignored)
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      NETBOX_SYNC_ENABLED: ${SLURPIT_NETBOX_SYNC_ENABLED:-true}
      NETBOX_SYNC_INTERVAL: ${SLURPIT_NETBOX_SYNC_INTERVAL:-300}
      WAREHOUSE_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      WAREHOUSE_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      WAREHOUSE_NETBOX_SYNC_ENABLED: ${SLURPIT_NETBOX_SYNC_ENABLED:-true}
    volumes:
      - ./slurpit/backup/warehouse:/backup/files
    restart: always

  slurpit-scraper:
    image: slurpit/scraper:latest
    container_name: slurpit-scraper
    depends_on:
      slurpit-warehouse:
        condition: service_healthy
    networks:
      - slurpit-network
    environment:
      TZ: ${SLURPIT_TZ:-Europe/Amsterdam}
      SCRAPER_POOLSIZE: 8
      SCRAPER_TIMEOUT: 60
      SCRAPER_COMMAND_TIMEOUT: 120
      SCRAPER_WAREHOUSE_HOSTNAME: slurpit-warehouse
      SCRAPER_POLL_ENABLED: true
      SCRAPER_POLL_TESTS_ENABLED: true
      SCRAPER_POLL_PROFILER_ENABLED: true
      SCRAPER_IDENTIFIER: scraper
      SCRAPER_TAGS: '[default]'

      # Best-effort NetBox integration (safe if ignored)
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      SCRAPER_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      SCRAPER_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
    restart: always

  slurpit-scanner:
    image: slurpit/scanner:latest
    container_name: slurpit-scanner
    depends_on:
      slurpit-warehouse:
        condition: service_healthy
    networks:
      - slurpit-network
    environment:
      TZ: ${SLURPIT_TZ:-Europe/Amsterdam}
      SCANNER_POOLSIZE: 8
      SCANNER_SNMP_TIMEOUT: 6
      SCANNER_SMART_IP_DISCOVERY: true
      SCANNER_WAREHOUSE_HOSTNAME: slurpit-warehouse
      SCANNER_IDENTIFIER: scanner
      SCANNER_TAGS: '[default]'

      # Best-effort NetBox integration (safe if ignored)
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      SCANNER_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      SCANNER_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
    restart: always

  slurpit-portal:
    image: slurpit/portal:latest
    container_name: slurpit-portal
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 10s
      timeout: 10s
      retries: 360
    networks:
      - slurpit-network
    depends_on:
      slurpit-mariadb:
        condition: service_healthy
      slurpit-warehouse:
        condition: service_healthy
    environment:
      TZ: ${SLURPIT_TZ:-Europe/Amsterdam}
      PORTAL_BASE_URL: http://localhost
      PORTAL_WAREHOUSE_URL: http://slurpit-warehouse
      PORTAL_MENU_MODE: classic
      PORTAL_DB_HOSTNAME: slurpit-mariadb
      PORTAL_DB_USERNAME: ${SLURPIT_MARIADB_USER:-slurpit}
      PORTAL_DB_PASSWORD: ${SLURPIT_MARIADB_PASSWORD}

      # Best-effort NetBox integration (safe if ignored)
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      PORTAL_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      PORTAL_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
    volumes:
      - ./slurpit/logs/nginx:/var/log/nginx/
      - ./slurpit/logs/php:/var/log/php/
      - ./slurpit/certs:/etc/nginx/certs/
      - ./slurpit/backup/portal:/backup/files
    ports:
      - "${SLURPIT_UI_PORT}:80"
    restart: always
EOF
}

fetch_slurpit_upstream_raw_compose() {
  cd "$NETBOX_COMPOSE_DIR"
  load_slurpit_env

  local url="${SLURPIT_UPSTREAM_RAW_URL:-$SLURPIT_UPSTREAM_RAW_URL_DEFAULT}"
  log "Fetching Slurp'it upstream raw compose: ${url}"
  curl -fsSL "$url" -o "$SLURPIT_UPSTREAM_RAW_FILE"
}

write_slurpit_upstream_raw_override() {
  cd "$NETBOX_COMPOSE_DIR"
  load_slurpit_env

  # This override:
  # - exposes portal UI port (if upstream compose doesn't)
  # - injects best-effort NetBox env
  # - attaches services to slurpit-network (if upstream defines it)
  cat > "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE" <<'EOF'
services:
  slurpit-portal:
    ports:
      - "${SLURPIT_UI_PORT}:80"
    environment:
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      PORTAL_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      PORTAL_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}

  slurpit-warehouse:
    environment:
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      NETBOX_SYNC_ENABLED: ${SLURPIT_NETBOX_SYNC_ENABLED:-true}
      NETBOX_SYNC_INTERVAL: ${SLURPIT_NETBOX_SYNC_INTERVAL:-300}
      WAREHOUSE_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      WAREHOUSE_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      WAREHOUSE_NETBOX_SYNC_ENABLED: ${SLURPIT_NETBOX_SYNC_ENABLED:-true}

  slurpit-scraper:
    environment:
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      SCRAPER_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      SCRAPER_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}

  slurpit-scanner:
    environment:
      NETBOX_URL: ${SLURPIT_NETBOX_URL}
      NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
      SCANNER_NETBOX_URL: ${SLURPIT_NETBOX_URL}
      SCANNER_NETBOX_TOKEN: ${SLURPIT_NETBOX_TOKEN}
EOF
}

apply_slurpit_mode_to_compose_files() {
  cd "$NETBOX_COMPOSE_DIR"
  load_slurpit_env

  local mode="${SLURPIT_MODE:-$SLURPIT_MODE_DEFAULT}"

  # Always rewrite base override with NetBox build + slurpit-network join
  write_netbox_override_header

  case "$mode" in
    integrated-clean)
      log "Configuring Slurp'it mode: integrated-clean"
      write_slurpit_integrated_clean
      rm -f "$SLURPIT_UPSTREAM_RAW_FILE" "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE" 2>/dev/null || true
      ;;
    integrated-upstream)
      log "Configuring Slurp'it mode: integrated-upstream"
      write_slurpit_integrated_upstream_exact
      rm -f "$SLURPIT_UPSTREAM_RAW_FILE" "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE" 2>/dev/null || true
      ;;
    upstream-raw)
      log "Configuring Slurp'it mode: upstream-raw"
      fetch_slurpit_upstream_raw_compose
      write_slurpit_upstream_raw_override
      ;;
    *)
      warn "Unknown SLURPIT_MODE='$mode'; falling back to integrated-clean."
      export SLURPIT_MODE="integrated-clean"
      write_slurpit_integrated_clean
      ;;
  esac
}

# ------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------
build_stack() {
  cd "$NETBOX_COMPOSE_DIR"
  log "Pulling images..."
  dc pull

  log "Building NetBox image..."
  dc build
}

start_stack() {
  cd "$NETBOX_COMPOSE_DIR"
  log "Starting stack..."
  dc up -d
}

stop_stack() {
  cd "$NETBOX_COMPOSE_DIR"
  log "Stopping stack..."
  dc down
}

restart_stack() {
  stop_stack
  start_stack
}

status_stack() {
  cd "$NETBOX_COMPOSE_DIR"
  dc ps
}

logs_stack() {
  cd "$NETBOX_COMPOSE_DIR"
  local svc="${1:-}"
  if [[ -n "$svc" ]]; then
    dc logs -f "$svc"
  else
    dc logs -f
  fi
}

shell_netbox() {
  cd "$NETBOX_COMPOSE_DIR"
  dc exec netbox /bin/bash
}

# Slurp'it helpers
slurpit_logs() {
  cd "$NETBOX_COMPOSE_DIR"
  dc logs -f slurpit-portal slurpit-warehouse slurpit-scraper slurpit-scanner slurpit-mariadb slurpit-mongodb || true
}

slurpit_shell_portal() {
  cd "$NETBOX_COMPOSE_DIR"
  dc exec slurpit-portal /bin/bash || true
}

# ------------------------------------------------------------
# Superuser
# ------------------------------------------------------------
create_superuser() {
  cd "$NETBOX_COMPOSE_DIR"
  dc exec netbox /opt/netbox/netbox/manage.py createsuperuser || {
    warn "NetBox may not be ready yet. Try again later:"
    warn "  netbox-manager superuser-create"
  }
}

# ------------------------------------------------------------
# High-level flows
# ------------------------------------------------------------
prepare_files() {
  cd "$NETBOX_COMPOSE_DIR"
  create_plugin_requirements
  create_plugin_config
  create_plugin_dockerfile
}

do_install() {
  require_root "$@"
  ensure_dependencies
  clone_netbox_docker

  cd "$NETBOX_COMPOSE_DIR"
  prepare_files

  # Ask + persist mode/port/token (token best-effort)
  ensure_slurpit_env

  # Write compose files for selected mode
  apply_slurpit_mode_to_compose_files

  # Bring up stack
  build_stack
  start_stack

  # Try again to ensure token exists once NetBox is actually up, then re-apply env + restart
  local token2=""
  token2="$(get_or_create_netbox_token_slurpit)"
  if [[ -n "$token2" && "${SLURPIT_NETBOX_TOKEN:-}" != "$token2" ]]; then
    save_slurpit_env "${SLURPIT_MODE}" "${SLURPIT_UI_PORT}" "$token2"
    load_slurpit_env
    apply_slurpit_mode_to_compose_files
    restart_stack
  fi

  create_superuser
}

do_update() {
  require_root "$@"
  ensure_dependencies
  clone_netbox_docker
  update_netbox_repo

  cd "$NETBOX_COMPOSE_DIR"
  prepare_files

  ensure_slurpit_env
  apply_slurpit_mode_to_compose_files

  build_stack
  restart_stack
}

do_rebuild() {
  require_root "$@"
  ensure_dependencies
  clone_netbox_docker

  cd "$NETBOX_COMPOSE_DIR"
  prepare_files

  ensure_slurpit_env
  apply_slurpit_mode_to_compose_files

  build_stack
  restart_stack
}

enable_slurpit() {
  require_root "$@"
  cd "$NETBOX_COMPOSE_DIR"

  ensure_slurpit_env
  apply_slurpit_mode_to_compose_files

  build_stack
  restart_stack
}

disable_slurpit() {
  require_root "$@"
  cd "$NETBOX_COMPOSE_DIR"

  # Remove Slurp'it mode files but keep NetBox override header
  log "Disabling Slurp'it (keeping NetBox override + build)..."
  load_slurpit_env
  export SLURPIT_MODE="integrated-clean"
  write_netbox_override_header
  rm -f "$SLURPIT_UPSTREAM_RAW_FILE" "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE" 2>/dev/null || true

  restart_stack
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------
show_menu() {
cat <<EOF
netbox-manager ${SCRIPT_VERSION}

1) Install (pinned versions)
2) Install (latest NetBox + latest plugins)
3) Update (pinned)
4) Update (latest)
5) Rebuild (pinned)
6) Rebuild (latest)
7) Start
8) Stop
9) Restart
10) Status
11) Logs
12) Shell (NetBox)

13) Superuser: Create
14) Slurp'it: Enable (choose mode + port)
15) Slurp'it: Disable
16) Slurp'it: Logs
17) Slurp'it: Shell (portal)

0) Exit
EOF
}

menu_loop() {
  while true; do
    show_menu
    read -rp "Select: " choice
    echo
    case "$choice" in
      1) NETBOX_VERSION_MODE="pinned"; PLUGIN_VERSION_MODE="pinned"; do_install ;;
      2) NETBOX_VERSION_MODE="latest"; PLUGIN_VERSION_MODE="latest"; do_install ;;
      3) NETBOX_VERSION_MODE="pinned"; PLUGIN_VERSION_MODE="pinned"; do_update ;;
      4) NETBOX_VERSION_MODE="latest"; PLUGIN_VERSION_MODE="latest"; do_update ;;
      5) NETBOX_VERSION_MODE="pinned"; PLUGIN_VERSION_MODE="pinned"; do_rebuild ;;
      6) NETBOX_VERSION_MODE="latest"; PLUGIN_VERSION_MODE="latest"; do_rebuild ;;
      7) start_stack ;;
      8) stop_stack ;;
      9) restart_stack ;;
      10) status_stack ;;
      11) read -rp "Service (blank = all): " svc; logs_stack "${svc:-}" ;;
      12) shell_netbox ;;
      13) create_superuser ;;
      14) enable_slurpit ;;
      15) disable_slurpit ;;
      16) slurpit_logs ;;
      17) slurpit_shell_portal ;;
      0) exit 0 ;;
      *) echo "Invalid option." ;;
    esac
    echo
  done
}

# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------
usage() {
  cat <<EOF
Usage:
  netbox-manager                 # interactive menu
  netbox-manager install
  netbox-manager install-latest
  netbox-manager update
  netbox-manager update-latest
  netbox-manager rebuild
  netbox-manager rebuild-latest
  netbox-manager start|stop|restart|status|logs [service]|shell
  netbox-manager superuser-create
  netbox-manager slurpit-enable
  netbox-manager slurpit-disable
  netbox-manager slurpit-logs
  netbox-manager slurpit-shell
EOF
}

dispatch() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    "") menu_loop ;;
    install) NETBOX_VERSION_MODE="pinned"; PLUGIN_VERSION_MODE="pinned"; do_install "$@" ;;
    install-latest) NETBOX_VERSION_MODE="latest"; PLUGIN_VERSION_MODE="latest"; do_install "$@" ;;
    update) NETBOX_VERSION_MODE="pinned"; PLUGIN_VERSION_MODE="pinned"; do_update "$@" ;;
    update-latest) NETBOX_VERSION_MODE="latest"; PLUGIN_VERSION_MODE="latest"; do_update "$@" ;;
    rebuild) NETBOX_VERSION_MODE="pinned"; PLUGIN_VERSION_MODE="pinned"; do_rebuild "$@" ;;
    rebuild-latest) NETBOX_VERSION_MODE="latest"; PLUGIN_VERSION_MODE="latest"; do_rebuild "$@" ;;
    start) start_stack ;;
    stop) stop_stack ;;
    restart) restart_stack ;;
    status) status_stack ;;
    logs) logs_stack "${1:-}" ;;
    shell) shell_netbox ;;
    superuser-create) create_superuser ;;
    slurpit-enable) enable_slurpit ;;
    slurpit-disable) disable_slurpit ;;
    slurpit-logs) slurpit_logs ;;
    slurpit-shell) slurpit_shell_portal ;;
    -h|--help|help) usage ;;
    *) error "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

dispatch "$@"
