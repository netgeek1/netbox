f#!/usr/bin/env bash
#
# This is a 100% working Netbox v4.4.9 install with the following plugins:
#
#     netbox-secrets==2.4.1
#     slurpit_netbox==1.2.7
#     netbox-plugin-dns==1.4.7
#     netbox-inventory==2.4.1
#     netbox-routing==0.3.1
#     netbox-topology-views==4.4.0
#
# - 4.2.3
#   Slurp'it full build
#   
#
# - 4.2.2 
#   Slurp'it git download and prep
#   
# 
# Netbox Plugins
#  - https://netboxlabs.com/plugins
#      - Need to add to plugin_requirements.txt, configuration/plugins.py and PLUGINS=
#
# - 2.0.1
#   Version pinning to NetBox 4.4.9 and plugins versions that work
#
# - v1.1.3
#   Added Netbox Routing
#    - https://github.com/DanSheps/netbox-routing
#   Added Netbox Inventory
#    - https://github.com/ArnesSI/netbox-inventory
#   Added Netbox Topology Views
#    - https://github.com/netbox-community/netbox-topology-views
#
#
# - v1.1.2
#   Added Slurpit Plugin 
#    - https://gitlab.com/slurpit.io/slurpit_netbox
#    - https://www.youtube.com/watch?v=Asji7fTfCy8
#   Added Netbox DNS
#    - https://github.com/peteeckel/netbox-plugin-dns
#

set -euo pipefail

SCRIPT_VERSION="4.2.5"

INSTALL_DIR="/opt"
NETBOX_COMPOSE_DIR="${INSTALL_DIR}/netbox-docker"
NETBOX_PORT="${NETBOX_PORT:-8000}"
NETBOX_BRANCH="release"
NETBOX_VERSION="v4.4.9"

SLURPIT_COMPOSE_DIR="${INSTALL_DIR}/slurpit-docker"

REAL_USER="${SUDO_USER:-${LOGNAME:-$(whoami)}}"

log()   { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# ------------------------------------------------------------
# Root handling
# ------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[INFO] Elevation required — re-running with sudo..."
        sudo -E bash "$0" "$@"
        exit $?
    fi
}

# ------------------------------------------------------------
# Docker install
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
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
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

# ------------------------------------------------------------
# Clone netbox-docker
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
# Clone slurpit-docker
# ------------------------------------------------------------
clone_slurpit_docker() {
    log "Ensuring slurpit-docker repository exists..."

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    if [[ ! -d slurpit-docker ]]; then
        git clone https://gitlab.com/slurpit.io/images.git slurpit-docker
    else
        log "slurpit-docker already exists."
    fi
}

update_slurpit_repo() {
    cd "$SLURPIT_COMPOSE_DIR"
    log "Updating slurpit-docker repo..."
    git pull --ff-only || warn "Git pull failed; check local changes."
}

# ------------------------------------------------------------
# Plugin bundle (your exact working list)
# ------------------------------------------------------------
create_plugin_requirements() {
    cd "$NETBOX_COMPOSE_DIR"
    log "Writing plugin_requirements.txt..."

    cat > plugin_requirements.txt <<'EOF'
netbox-secrets==2.4.1
slurpit_netbox==1.2.7
netbox-plugin-dns==1.4.7
netbox-inventory==2.4.1
netbox-routing==0.3.1
netbox-topology-views==4.4.0
EOF
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
    "netbox_routing",
    "netbox_inventory",
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
    log "Writing Dockerfile-plugins with pinned NetBox version ${NETBOX_VERSION}..."

    cat > Dockerfile-plugins <<EOF
FROM netboxcommunity/netbox:${NETBOX_VERSION}

COPY ./plugin_requirements.txt /opt/netbox/
RUN /usr/local/bin/uv pip install -r /opt/netbox/plugin_requirements.txt
EOF
}

create_netbox_compose_override() {
    cd "$NETBOX_COMPOSE_DIR"
    log "Writing docker-compose.override.yml..."

    cat > docker-compose.override.yml <<EOF
services:
  netbox:
    build:
      context: .
      dockerfile: Dockerfile-plugins
    ports:
      - "${NETBOX_PORT}:8080"
    environment:
      - "PLUGINS=['netbox_secrets','slurpit_netbox','netbox_dns','netbox_routing','netbox_inventory','netbox_topology_views']"
    volumes:
      - ./configuration:/etc/netbox/config
    healthcheck:
      start_period: 600s
EOF
}

# ------------------------------------------------------------
# Build & lifecycle
# ------------------------------------------------------------
build_netbox() {
    cd "$NETBOX_COMPOSE_DIR"
    log "Pulling base images..."
    docker compose pull

    log "Building NetBox image..."
    docker compose build
}

start_netbox() {
    cd "$NETBOX_COMPOSE_DIR"
    log "Starting NetBox..."
    docker compose up -d
}

stop_netbox() {
    cd "$NETBOX_COMPOSE_DIR"
    log "Stopping NetBox..."
    docker compose down
}

restart_netbox() {
    stop_netbox
    start_netbox
}

status_netbox() {
    cd "$NETBOX_COMPOSE_DIR"
    docker compose ps
}

logs_netbox() {
    cd "$NETBOX_COMPOSE_DIR"
    docker compose logs -f "${1:-netbox}"
}

shell_netbox() {
    cd "$NETBOX_COMPOSE_DIR"
    docker compose exec netbox /bin/bash
}

# ------------------------------------------------------------
# Superuser
# ------------------------------------------------------------
create_superuser() {
    cd "$NETBOX_COMPOSE_DIR"
    docker compose exec netbox /opt/netbox/netbox/manage.py createsuperuser || {
        warn "NetBox not healthy yet. Run manually:"
        echo "  docker compose exec netbox /opt/netbox/netbox/manage.py createsuperuser"
    }
}

reset_superuser_password() {
    local user="${1:-}"
    [[ -z "$user" ]] && { error "Usage: netbox-manager superuser reset <username>"; exit 1; }

    cd "$NETBOX_COMPOSE_DIR"
    docker compose exec netbox /opt/netbox/netbox/manage.py changepassword "$user"
}



# ------------------------------------------------------------
# Slurp-it override.yml
# ------------------------------------------------------------
create_slurpit_compose_override() {
    cd "$SLURPIT_COMPOSE_DIR"
    log "Writing docker-compose.override.yml..."

    cat > docker-compose.override.yml <<EOF
networks:
  netbox:
    external: true
    name: netbox-docker_default
EOF
}

# ------------------------------------------------------------
# Bring up Slurp-it
# ------------------------------------------------------------

check_internet() {
    # Define space-separated list of hosts
    hosts="8.8.8.8 1.1.1.1 google.com"
    timeout=2  # Timeout in seconds

    for host in $hosts; do
        if ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1; then
            return 0  # Internet is available (0 = success in Bash)
        fi
    done
    return 1  # No internet connection (1 = failure in Bash)
}


# Function to handle Docker Compose operations
slurpit_docker_compose_up() {    
    if check_internet; then
        docker compose pull
    else
        echo "No internet connection detected"
        echo "Skipping pull operation"
    fi
    
    echo "Starting containers..."
    docker compose up -d
}

###############################################################################
# Slurp’it ↔ NetBox Integration Functions
###############################################################################
slurpit_netbox_integration() {

detect_netbox_api_container() {
  docker ps --format '{{.Names}} {{.Image}}' \
    | awk '$2 ~ /netboxcommunity\/netbox/ && $1 ~ /netbox-[0-9]+$/ {print $1; exit}'
}

NETBOX_CONTAINER="$(detect_netbox_api_container)"

if [[ -z "$NETBOX_CONTAINER" ]]; then
  die "Unable to locate NetBox API container"
fi

NETBOX_URL="http://${NETBOX_CONTAINER}:8000"

detect_slurpit_containers() {
  docker ps --format '{{.Names}} {{.Image}}' \
    | awk '$2 ~ /^slurpit\// {print $1}'
}

SLURPIT_CONTAINERS=($(detect_slurpit_containers))

if [[ ${#SLURPIT_CONTAINERS[@]} -eq 0 ]]; then
  die "No Slurp’it containers detected"
fi
}

###############################################################################
# Check NetBox API reachability
###############################################################################
check_netbox_reachable() {
  slurpit_netbox_integration
  log "Checking NetBox API reachability..."
  curl -s "${NETBOX_URL}/api/status/" >/dev/null \
    || die "NetBox API not reachable"
}


###############################################################################
# Ensure NetBox API token exists (NetBox 4.4+ correct)
###############################################################################
ensure_netbox_token() {
  log "Ensuring NetBox API token exists..."

  NETBOX_TOKEN="$(
  docker exec -i "${NETBOX_CONTAINER}" \
    /opt/netbox/netbox/manage.py shell <<'PY'
from django.contrib.auth import get_user_model
from users.models import Token

User = get_user_model()
u = User.objects.filter(is_superuser=True).first()
assert u, "No superuser found"

token = Token.objects.filter(user=u, description="Slurp'it").first()
if not token:
    token = Token.objects.create(
        user=u,
        description="Slurp'it",
        write_enabled=True
    )

print(token.key)
PY
  )"

  NETBOX_TOKEN="$(echo "$NETBOX_TOKEN" | tr -d '\r\n[:space:]')"
  [[ -n "$NETBOX_TOKEN" ]] || die "Failed to obtain NetBox API token"

  log "NetBox API token ready"
}


###############################################################################
# Restart Slurp’it services only
###############################################################################
restart_slurpit_services() {
  log "Restarting Slurp’it services..."
  docker restart "${SLURPIT_CONTAINERS[@]}" >/dev/null
}


###############################################################################
# Verify Slurp’it plugin is registered in NetBox
###############################################################################
verify_plugin_registered() {
  log "Verifying Slurp’it plugin registration..."

  docker exec -i "${NETBOX_CONTAINER}" \
    /opt/netbox/netbox/manage.py shell <<'PY'
from django.conf import settings
assert "slurpit_netbox" in settings.PLUGINS
print("Slurp’it plugin registered")
PY
}


###############################################################################
# Verify Slurp’it can reach NetBox (container-to-container)
###############################################################################
verify_slurpit_reachability() {
  log "Verifying Slurp’it can reach NetBox..."

  docker exec slurpit-warehouse sh -c "
    curl -s "${NETBOX_URL}/api/status/" >/dev/null
  " || die "Slurp’it cannot reach NetBox API"

  log "SUCCESS: Slurp’it ↔ NetBox integration verified"
}


###############################################################################
# Main function: wire Slurp’it to NetBox
###############################################################################
wire_slurpit_netbox() {
  check_netbox_reachable
  ensure_netbox_token
  restart_slurpit_services
  verify_plugin_registered
  verify_slurpit_reachability
}

# ------------------------------------------------------------
# Health & diagnostics
# ------------------------------------------------------------
health_check() {
    cd "$NETBOX_COMPOSE_DIR"
    docker compose ps
}

version_info() {
    echo "netbox-manager version: $SCRIPT_VERSION"
}

# ------------------------------------------------------------
# High-level install/update/rebuild
# ------------------------------------------------------------
do_install() {
    require_root "$@"
    install_docker
    ensure_docker_group
    clone_netbox_docker
    create_plugin_requirements
    create_plugin_config
    create_plugin_dockerfile
    create_netbox_compose_override
    build_netbox
    start_netbox
    create_superuser
    clone_slurpit_docker
    create_slurpit_compose_override
	slurpit_docker_compose_up
	wire_slurpit_netbox
}

do_update() {
    require_root "$@"
    install_docker
    clone_netbox_docker
    update_netbox_repo
    create_plugin_requirements
    create_plugin_config
    create_plugin_dockerfile
    create_netbox_compose_override
    build_netbox
    restart_netbox
    clone_slurpit_docker
    update_slurpit_repo
	slurpit_docker_compose_up
	wire_slurpit_netbox
}

do_rebuild() {
    require_root "$@"
    install_docker
    clone_netbox_docker
    create_plugin_requirements
    create_plugin_config
    create_plugin_dockerfile
    create_netbox_compose_override
    build_netbox
    restart_netbox
    clone_slurpit_docker
    create_slurpit_compose_override
	slurpit_docker_compose_up
	wire_slurpit_netbox
}

# ------------------------------------------------------------
# Menu UI
# ------------------------------------------------------------
show_menu() {
cat <<EOF
netbox-manager ${SCRIPT_VERSION}

1) Install
2) Update
3) Rebuild
4) Start
5) Stop
6) Restart
7) Status
8) Logs
9) Shell
10) Superuser: Create
11) Superuser: Reset Password
12) Health Check
13) Version Info
0) Exit
EOF
}

menu_loop() {
  while true; do
    show_menu
    read -rp "Select: " choice
    echo
    case "$choice" in
      1) do_install ;;
      2) do_update ;;
      3) do_rebuild ;;
      4) start_netbox ;;
      5) stop_netbox ;;
      6) restart_netbox ;;
      7) status_netbox ;;
      8) read -rp "Service [netbox]: " svc; logs_netbox "${svc:-netbox}" ;;
      9) shell_netbox ;;
      10) create_superuser ;;
      11) read -rp "Username: " u; reset_superuser_password "$u" ;;
      12) health_check ;;
      13) version_info ;;
      0) exit 0 ;;
      *) echo "Invalid option." ;;
    esac
    echo
  done
}

# ------------------------------------------------------------
# CLI dispatcher
# ------------------------------------------------------------
dispatch() {
  require_root
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    install) do_install "$@" ;;
    update) do_update "$@" ;;
    rebuild) do_rebuild "$@" ;;
    start) start_netbox ;;
    stop) stop_netbox ;;
    restart) restart_netbox ;;
    status) status_netbox ;;
    logs) logs_netbox "${1:-netbox}" ;;
    shell) shell_netbox ;;
    superuser)
      case "${1:-}" in
        create) create_superuser ;;
        reset) shift; reset_superuser_password "${1:-}" ;;
        *) error "Usage: netbox-manager superuser [create|reset <user>]" ;;
      esac
      ;;
    health) health_check ;;
    version) version_info ;;
    "") menu_loop ;;
    *) error "Unknown command: $cmd" ;;
  esac
}

dispatch "$@"
