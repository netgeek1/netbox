#!/usr/bin/env bash
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

SCRIPT_VERSION="2.0.1"

INSTALL_DIR="/opt"
NETBOX_COMPOSE_DIR="${INSTALL_DIR}/netbox-docker"
NETBOX_PORT="${NETBOX_PORT:-8000}"
NETBOX_BRANCH="release"
NETBOX_VERSION="v4.4.9"

REAL_USER="${SUDO_USER:-${LOGNAME:-$(whoami)}}"

log()   { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

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

create_compose_override() {
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
      start_period: 300s
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
    create_compose_override
    build_netbox
    start_netbox
    create_superuser
}

do_update() {
    require_root "$@"
    install_docker
    clone_netbox_docker
    update_netbox_repo
    create_plugin_requirements
    create_plugin_config
    create_plugin_dockerfile
    create_compose_override
    build_netbox
    restart_netbox
}

do_rebuild() {
    require_root "$@"
    install_docker
    clone_netbox_docker
    create_plugin_requirements
    create_plugin_config
    create_plugin_dockerfile
    create_compose_override
    build_netbox
    restart_netbox
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
