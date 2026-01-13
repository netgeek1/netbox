#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# netbox-manager with Slurp'it sidecar support (clean / upstream-exact / upstream-raw)
# Refactor based on your original script, preserving:
# - auto sudo escalation
# - docker install + docker group add
# - function-based structure
# - netbox-community/netbox-docker clone workflow
# - Slurp'it modes + upstream raw compose import + overrides
# - pinned/latest NetBox + pinned/latest plugins
# Adds hardening/safety sweep fixes:
# - ERR trap with line + command (no silent exits)
# - set -e safe grep usage in helpers
# - OS-safe package install wrapper (Ubuntu/Debian as original intent)
# - compose config preflight validation
# - required file assertions
# - safer env loading (no unsafe export parsing)
# - menu-selectable netbox-docker git update toggle (persisted)

SCRIPT_VERSION="4.2.0"

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

# Installer state (persisted)
INSTALLER_STATE_FILE="${NETBOX_COMPOSE_DIR}/.env.installer"
UPDATE_REPO_DEFAULT="no" # menu-selectable

# ------------------------------------------------------------
# Safety: error trap (no silent exits)
# ------------------------------------------------------------
ts() { date +"%Y-%m-%d %H:%M:%S"; }
on_err() {
  local ec=$?
  printf '[ERROR] %s | exit=%s | line=%s | cmd=%s\n' "$(ts)" "${ec}" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND}" >&2
  exit "${ec}"
}
trap on_err ERR

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
ok()    { printf "${COLOR_GREEN}[OK] %s${COLOR_RESET}\n" "$*"; }
warn()  { printf "${COLOR_YELLOW}[WARN] %s${COLOR_RESET}\n" "$*" >&2; }
error() { printf "${COLOR_RED}[ERROR] %s${COLOR_RESET}\n" "$*" >&2; }

# ------------------------------------------------------------
# Privilege escalation
# ------------------------------------------------------------
require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    fi
    error "This script requires root (or sudo)."
    exit 1
  fi
}

# ------------------------------------------------------------
# OS + package management (Ubuntu/Debian as per original)
# ------------------------------------------------------------
detect_os_id() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown}"
    return 0
  fi
  echo "unknown"
}

apt_install() {
  apt-get update
  apt-get install -y "$@"
}

ensure_packages() {
  local pkgs=(curl jq openssl git)
  local missing=()
  local p

  for p in "${pkgs[@]}"; do
    command -v "$p" >/dev/null 2>&1 || missing+=("$p")
  done

  if (( ${#missing[@]} > 0 )); then
    local os_id
    os_id="$(detect_os_id)"
    case "${os_id}" in
      ubuntu|debian)
        log "Installing packages: ${missing[*]}"
        apt_install "${missing[@]}"
        ;;
      *)
        error "Missing packages: ${missing[*]}"
        error "Unsupported OS for auto-install: ${os_id}"
        exit 1
        ;;
    esac
  fi
}

# ------------------------------------------------------------
# Dependencies: Docker
# ------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
    return
  fi

  local os_id
  os_id="$(detect_os_id)"
  case "${os_id}" in
    ubuntu|debian) ;;
    *)
      error "Unsupported OS for automatic Docker install: ${os_id}"
      exit 1
      ;;
  esac

  log "Installing Docker Engine..."
  apt_install ca-certificates curl gnupg lsb-release openssl git

  mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -sSL "https://download.docker.com/linux/${os_id}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker || true
  systemctl start docker || true
  ok "Docker installed."
}

ensure_docker_group() {
  getent group docker >/dev/null 2>&1 || groupadd docker || true
  if ! id "$REAL_USER" 2>/dev/null | grep -q '\bdocker\b' >/dev/null 2>&1; then
    log "Adding user '${REAL_USER}' to docker group"
    usermod -aG docker "$REAL_USER" || true
    warn "You may need to log out/in for group changes to apply."
  fi
}

ensure_dependencies() {
  install_docker
  ensure_docker_group
  ensure_packages
  docker compose version >/dev/null 2>&1 || { error "Docker Compose v2 plugin not available (docker compose)."; exit 1; }
}

# ------------------------------------------------------------
# Installer state (menu-selectable repo update)
# ------------------------------------------------------------
load_installer_state() {
  if [[ -f "${INSTALLER_STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${INSTALLER_STATE_FILE}" || true
  fi
  UPDATE_REPO="${UPDATE_REPO:-$UPDATE_REPO_DEFAULT}"
}

save_installer_state() {
  mkdir -p "${NETBOX_COMPOSE_DIR}" 2>/dev/null || true
  cat > "${INSTALLER_STATE_FILE}" <<EOF
# Managed by netbox-manager
UPDATE_REPO=${UPDATE_REPO}
EOF
}

toggle_repo_update_setting() {
  load_installer_state
  echo "Toggle netbox-docker git update on install/update/rebuild."
  echo "Current: UPDATE_REPO=${UPDATE_REPO}"
  echo "1) yes"
  echo "2) no"
  read -rp "Select [1-2]: " c
  case "${c}" in
    1) UPDATE_REPO="yes" ;;
    2) UPDATE_REPO="no" ;;
    *) warn "Invalid selection; unchanged." ;;
  esac
  save_installer_state
  ok "Saved: UPDATE_REPO=${UPDATE_REPO}"
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

update_netbox_repo_if_enabled() {
  load_installer_state
  if [[ "${UPDATE_REPO}" != "yes" ]]; then
    log "Repo update skipped (UPDATE_REPO=${UPDATE_REPO})."
    return 0
  fi

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
# Safer env loading (no unsafe export $(grep ...))
# ------------------------------------------------------------
load_env_file_safely() {
  # Loads KEY=VALUE (simple) pairs into environment; ignores comments/blank lines.
  # Does not attempt to interpret quotes/escapes; intended for this script-managed env files.
  local f="$1"
  [[ -f "$f" ]] || return 0

  while IFS='=' read -r k v; do
    [[ -z "${k:-}" ]] && continue
    [[ "${k}" =~ ^[[:space:]]*# ]] && continue
    k="${k#"${k%%[![:space:]]*}"}"
    v="${v:-}"
    if [[ "${k}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      export "${k}=${v}"
    fi
  done < <(grep -v '^[[:space:]]*$' "$f" || true)
}

# ------------------------------------------------------------
# Slurp'it env + prompts
# ------------------------------------------------------------
load_slurpit_env() {
  load_env_file_safely "$SLURPIT_ENV_FILE"
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

  [[ -n "$port" ]] || port="8081"
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

  local mariadb_pass="${SLURPIT_MARIADB_PASSWORD:-$(random_secret)}"
  local mongo_pass="${SLURPIT_MONGO_PASSWORD:-$(random_secret)}"
  local tz="${SLURPIT_TZ:-UTC}"
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
assert_compose_files() {
  cd "$NETBOX_COMPOSE_DIR"
  [[ -f docker-compose.yml ]] || { error "Missing docker-compose.yml in ${NETBOX_COMPOSE_DIR}"; exit 1; }

  # Our override should always exist after apply_slurpit_mode_to_compose_files
  [[ -f docker-compose.override.yml ]] || { error "Missing docker-compose.override.yml; run install/update first."; exit 1; }

  load_slurpit_env
  local mode="${SLURPIT_MODE:-$SLURPIT_MODE_DEFAULT}"

  if [[ "$mode" == "upstream-raw" ]]; then
    [[ -f "$SLURPIT_UPSTREAM_RAW_FILE" ]] || { error "Missing ${SLURPIT_UPSTREAM_RAW_FILE} (raw mode)"; exit 1; }
    [[ -f "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE" ]] || { error "Missing ${SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE} (raw mode)"; exit 1; }
  fi
}

dc() {
  cd "$NETBOX_COMPOSE_DIR"
  load_slurpit_env

  local mode="${SLURPIT_MODE:-$SLURPIT_MODE_DEFAULT}"
  local files=(-f docker-compose.yml)

  if [[ -f docker-compose.override.yml ]]; then
    files+=(-f docker-compose.override.yml)
  fi

  if [[ "$mode" == "upstream-raw" ]]; then
    files+=(-f "$SLURPIT_UPSTREAM_RAW_FILE" -f "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE")
  fi

  docker compose "${files[@]}" "$@"
}

compose_validate() {
  assert_compose_files
  log "Validating composed config..."
  dc config >/dev/null
}

# ------------------------------------------------------------
# NetBox token automation (best effort)
# ------------------------------------------------------------
wait_netbox_container() {
  cd "$NETBOX_COMPOSE_DIR"
  local tries=60
  local i

  for ((i=1; i<=tries; i++)); do
    if dc ps netbox 2>/dev/null | awk 'NR>1{print $0}' | grep -qi netbox >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

get_or_create_netbox_token_slurpit() {
  cd "$NETBOX_COMPOSE_DIR"

  local tries=20
  local i

  for ((i=1; i<=tries; i++)); do
    local token=""
    token="$(
      dc exec -T netbox python3 - <<'PY' 2>/dev/null || true
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

  token=""
  if wait_netbox_container; then
    token="$(get_or_create_netbox_token_slurpit)"
  fi

  if [[ -z "$token" ]]; then
    warn "NetBox token auto-generation failed (NetBox may not be ready yet)."
    warn "Continuing with empty SLURPIT_NETBOX_TOKEN; you can rerun 'Slurp'it: Enable' later."
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

  cat >> docker-compose.override.yml <<'EOF'

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

  mkdir -p slurpit/db/mariadb slurpit/db/mongodb slurpit/backup/warehouse slurpit/backup/portal slurpit/logs/nginx slurpit/logs/php slurpit/certs

  cat >> docker-compose.override.yml <<'EOF'

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

  cat > "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE" <<'EOF'

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
      warn "Unknown SLURPIT_MODE='${mode}'; falling back to integrated-clean."
      export SLURPIT_MODE="integrated-clean"
      write_slurpit_integrated_clean
      ;;
  esac

  compose_validate
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

restart_stack() { stop_stack; start_stack; }

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
  # Best effort: if services aren't present in the selected mode, don't fail the script.
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
    warn " netbox-manager superuser-create"
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
  update_netbox_repo_if_enabled

  cd "$NETBOX_COMPOSE_DIR"
  load_installer_state
  prepare_files

  ensure_slurpit_env
  apply_slurpit_mode_to_compose_files

  build_stack
  start_stack

  # Try again after NetBox is up (token best-effort); if changed, re-apply + restart.
  local token2=""
  token2="$(get_or_create_netbox_token_slurpit || true)"
  token2="${token2:-}"
  load_slurpit_env
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
  update_netbox_repo_if_enabled

  cd "$NETBOX_COMPOSE_DIR"
  load_installer_state
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
  load_installer_state
  prepare_files
  ensure_slurpit_env
  apply_slurpit_mode_to_compose_files

  build_stack
  restart_stack
}

enable_slurpit() {
  require_root "$@"
  ensure_dependencies
  clone_netbox_docker

  cd "$NETBOX_COMPOSE_DIR"
  ensure_slurpit_env
  apply_slurpit_mode_to_compose_files

  build_stack
  restart_stack
}

disable_slurpit() {
  require_root "$@"
  ensure_dependencies
  clone_netbox_docker

  cd "$NETBOX_COMPOSE_DIR"
  log "Disabling Slurp'it (keeping NetBox override + build)..."
  load_slurpit_env

  export SLURPIT_MODE="integrated-clean"
  write_netbox_override_header
  rm -f "$SLURPIT_UPSTREAM_RAW_FILE" "$SLURPIT_UPSTREAM_RAW_OVERRIDE_FILE" 2>/dev/null || true

  compose_validate
  restart_stack
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------
show_menu() {
  load_installer_state
  cat <<EOF
netbox-manager ${SCRIPT_VERSION}

Installer:
  u) Toggle repo update on deploy (UPDATE_REPO=${UPDATE_REPO})

Install/Update:
  1) Install (pinned versions)
  2) Install (latest NetBox + latest plugins)
  3) Update (pinned)
  4) Update (latest)
  5) Rebuild (pinned)
  6) Rebuild (latest)

Stack:
  7) Start
  8) Stop
  9) Restart
  10) Status
  11) Logs
  12) Shell (NetBox)

NetBox:
  13) Superuser: Create

Slurp'it:
  14) Enable (choose mode + port)
  15) Disable
  16) Logs
  17) Shell (portal)

  0) Exit
EOF
}

menu_loop() {
  while true; do
    show_menu
    read -rp "Select: " choice
    echo

    case "$choice" in
      u|U) toggle_repo_update_setting ;;
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
  netbox-manager toggle-repo-update
EOF
}

dispatch() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    "")
      menu_loop
      ;;
    install)
      NETBOX_VERSION_MODE="pinned"; PLUGIN_VERSION_MODE="pinned"; do_install "$@"
      ;;
    install-latest)
      NETBOX_VERSION_MODE="latest"; PLUGIN_VERSION_MODE="latest"; do_install "$@"
      ;;
    update)
      NETBOX_VERSION_MODE="pinned"; PLUGIN_VERSION_MODE="pinned"; do_update "$@"
      ;;
    update-latest)
      NETBOX_VERSION_MODE="latest"; PLUGIN_VERSION_MODE="latest"; do_update "$@"
      ;;
    rebuild)
      NETBOX_VERSION_MODE="pinned"; PLUGIN_VERSION_MODE="pinned"; do_rebuild "$@"
      ;;
    rebuild-latest)
      NETBOX_VERSION_MODE="latest"; PLUGIN_VERSION_MODE="latest"; do_rebuild "$@"
      ;;
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
    toggle-repo-update) toggle_repo_update_setting ;;
    -h|--help|help) usage ;;
    *)
      error "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

dispatch "$@"
