#!/usr/bin/env bash
#
# This is a 100% working Netbox v4.4.9 & Slurp'it install with the following plugins:
#
#     netbox-secrets==2.4.1
#     slurpit_netbox==1.2.7
#     netbox-plugin-dns==1.4.7
#     netbox-inventory==2.4.1
#     netbox-routing==0.3.1
#     netbox-topology-views==4.4.0
#
# - 4.2.13
#   Plugin versions
#
# - 4.2.12
#   Menu updates
#
# - 4.2.11
#   Menu and URL fixes
#
# - 4.2.10
#   Docker-compose.override fix & URL fixes
#
# - 4.2.9
#   Menu status
#
# - 4.2.8
#   Slurp'it re-write
#
# - 4.2.7
#   Slurp'it re-write
#
# - 4.2.6
#   Slurp'it network fix
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

SCRIPT_VERSION="4.2.13"

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

green() { printf "\033[0;32m%s\033[0m" "$1"; }
red()   { printf "\033[0;31m%s\033[0m" "$1"; }
yellow(){ printf "\033[0;33m%s\033[0m" "$1"; }


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

get_host_ip() {
    ip route get 1 | awk '{print $7; exit}'
}

check_url_reachable() {
    local url="$1"
    if curl -s --max-time 2 "$url" >/dev/null; then
        echo "OK"
    else
        echo "FAIL"
    fi
}

print_url_status() {
    local label="$1"
    local url="$2"
    local status

    status="$(check_url_reachable "$url")"

    if [[ "$status" == "OK" ]]; then
        printf "%-22s %s [%s]\n" "$label:" "$url" "$(green OK)"
    else
        printf "%-22s %s [%s]\n" "$label:" "$url" "$(red FAIL)"
    fi
}

open_in_browser() {
    local url="$1"
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$url" >/dev/null 2>&1 &
    fi
}

get_netbox_plugin_versions() {
    docker exec netbox-docker-netbox-1 sh -c \
      "python3 - <<'EOF'
import ast, pathlib, importlib, os

# Load plugins.py
cfg = pathlib.Path('/etc/netbox/config/plugins.py').read_text()
tree = ast.parse(cfg)

plugins = []
for node in tree.body:
    if isinstance(node, ast.Assign) and getattr(node.targets[0], 'id', None) == 'PLUGINS':
        plugins = [elt.value for elt in node.value.elts]
        break

def get_version_from_distinfo(name):
    base = '/opt/netbox/venv/lib/python3.12/site-packages'
    for entry in os.listdir(base):
        # Match both underscores and hyphens
        if entry.replace('_','-').startswith(name.replace('_','-')) and entry.endswith('.dist-info'):
            meta = os.path.join(base, entry, 'METADATA')
            if os.path.exists(meta):
                with open(meta) as f:
                    for line in f:
                        if line.startswith('Version:'):
                            return line.split(':',1)[1].strip()
            # Fallback: parse version from directory name
            parts = entry.split('-')
            if len(parts) > 1:
                return parts[1].replace('.dist.info','')
    return None

# Pretty print
for name in plugins:
    version = None

    # Try __version__
    try:
        mod = importlib.import_module(name)
        version = getattr(mod, '__version__', None)
    except Exception:
        pass

    # Try dist-info metadata
    if not version:
        version = get_version_from_distinfo(name)

    print(f\"{name}: {version or 'UNKNOWN'}\")
EOF"
}


###############################################################################
# URL Auto‑Detection Helpers
###############################################################################

# Detect host‑published port for a given container + internal port
detect_published_port() {
    local container="$1"
    local internal_port="$2"

    docker inspect "$container" \
      --format "{{range \$p, \$conf := .NetworkSettings.Ports}}{{if eq \$p \"${internal_port}/tcp\"}}{{range \$conf}}{{println .HostPort}}{{end}}{{end}}{{end}}" \
      2>/dev/null \
    | grep -E '^[0-9]+$' \
    | head -n1
}


# NetBox URL (always published)
get_netbox_url() {
    local host_port host_ip
    host_port="$(detect_published_port netbox-docker-netbox-1 8080)"
    host_ip="$(get_host_ip)"

    if [[ -n "$host_port" ]]; then
        echo "http://${host_ip}:${host_port}"
    else
        echo "http://netbox-docker-netbox-1:8080  (internal only)"
    fi
}

get_netbox_api_status_url() {
    local base
    base="$(get_netbox_url)"
    echo "${base}/api/status/"
}



# Slurp’it Portal URL (auto‑detect host → fallback to internal)
get_slurpit_portal_url() {
    local host_port host_ip
    host_port="$(detect_published_port slurpit-portal 80)"
    host_ip="$(get_host_ip)"

    if [[ -n "$host_port" ]]; then
        echo "http://${host_ip}:${host_port}"
    else
        echo "http://slurpit-portal:80  (internal only)"
    fi
}

# Slurp’it Warehouse URL (auto‑detect host → fallback to internal)
get_slurpit_warehouse_url() {
    local host_port host_ip
    host_port="$(detect_published_port slurpit-warehouse 3000)"
    host_ip="$(get_host_ip)"

    if [[ -n "$host_port" ]]; then
        echo "http://${host_ip}:${host_port}"
    else
        echo "http://slurpit-warehouse:3000  (internal only)"
    fi
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
services:
  slurpit-portal:
    networks:
      - netbox
    ports:
      - "8080:80"

  slurpit-warehouse:
    networks:
      - netbox
    ports:
      - "3000:3000"

  slurpit-scraper:
    networks:
      - netbox

  slurpit-scanner:
    networks:
      - netbox

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
    docker compose down
	docker network inspect netbox-docker_default >/dev/null 2>&1 \
  || docker network create netbox-docker_default
    docker compose up -d --force-recreate
}

###############################################################################
# NetBox plugin diagnostics (NetBox 4.x)
###############################################################################

get_netbox_plugins() {
    docker exec netbox-docker-netbox-1 sh -c \
      "python3 - <<'EOF'
import ast, pathlib
cfg = pathlib.Path('/etc/netbox/config/plugins.py').read_text()
tree = ast.parse(cfg)
for node in tree.body:
    if isinstance(node, ast.Assign) and getattr(node.targets[0], 'id', None) == 'PLUGINS':
        print([elt.value for elt in node.value.elts])
EOF" 2>/dev/null
}

check_netbox_plugin_imports() {
    docker exec netbox-docker-netbox-1 sh -c \
      "python3 - <<'EOF'
import ast, importlib, pathlib
cfg = pathlib.Path('/etc/netbox/config/plugins.py').read_text()
tree = ast.parse(cfg)
plugins = []
for node in tree.body:
    if isinstance(node, ast.Assign) and getattr(node.targets[0], 'id', None) == 'PLUGINS':
        plugins = [elt.value for elt in node.value.elts]
        break

for name in plugins:
    try:
        importlib.import_module(name)
        print(f\"{name}: OK\")
    except Exception as e:
        print(f\"{name}: FAIL ({e})\")
EOF" 2>/dev/null
}

###############################################################################
# Container metrics
###############################################################################

get_container_stats() {
    docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}} {{.MemPerc}}'
}

get_container_health() {
    docker ps --format '{{.Names}} {{.Status}}'
}

###############################################################################
# Integration checks
###############################################################################

check_slurpit_to_netbox_integration() {
    # Simple: can Slurp’it Portal resolve NetBox API?
    docker exec slurpit-portal sh -c \
      "curl -s --max-time 3 netbox-docker-netbox-1:8080/api/status/ >/dev/null && echo OK || echo FAIL" \
      2>/dev/null
}


###############################################################################
# System health dashboard (one-shot)
###############################################################################

system_health_dashboard() {
    clear
    echo "============================================================"
    echo "                 SYSTEM HEALTH DASHBOARD"
    echo "============================================================"
    echo

    local host_ip
    host_ip="$(get_host_ip)"

    echo "Host IP: $host_ip"
    echo

    # NetBox
    local nb_url nb_api nb_status
    nb_url="$(get_netbox_url)"
    nb_api="$(get_netbox_api_status_url)"
    nb_status="$(check_url_reachable "$nb_api")"
    [[ "$nb_status" == "OK" ]] && nb_status="$(green OK)" || nb_status="$(red FAIL)"

    echo "NETBOX"
    echo "  UI:          $nb_url"
    echo "  API Status:  $nb_api  [$nb_status]"
    echo

    # Slurp’it Portal
    local portal_url portal_status
    portal_url="$(get_slurpit_portal_url)"
    portal_status="$(check_url_reachable "$portal_url")"
    [[ "$portal_status" == "OK" ]] && portal_status="$(green OK)" || portal_status="$(red FAIL)"

    echo "SLURP’IT PORTAL"
    echo "  URL:         $portal_url  [$portal_status]"
    echo

    # Slurp’it Warehouse
    local wh_url wh_status
    wh_url="$(get_slurpit_warehouse_url)"
    wh_status="$(check_url_reachable "$wh_url")"
    [[ "$wh_status" == "OK" ]] && wh_status="$(green OK)" || wh_status="$(red FAIL)"

    echo "SLURP’IT WAREHOUSE"
    echo "  URL:         $wh_url  [$wh_status]"
    echo

    # Plugins
    echo "NETBOX PLUGINS (configured)"
    local plugins
    plugins="$(get_netbox_plugins)"
    echo "  $plugins"
    echo

    echo "NETBOX PLUGIN IMPORT HEALTH"
    check_netbox_plugin_imports | sed 's/^/  /'
    echo

    echo "NETBOX PLUGIN VERSIONS"
    get_netbox_plugin_versions | sed 's/^/ /'
#	versions="$(get_netbox_plugin_versions)"
#    echo "  $versions"
    echo
    
    # Containers
    echo "CONTAINERS (health)"
    get_container_health | sed 's/^/  /'
    echo

    # Networks
    echo "NETWORKS"
    if docker network inspect netbox-docker_default >/dev/null 2>&1; then
        echo "  netbox-docker_default: $(green OK)"
    else
        echo "  netbox-docker_default: $(red MISSING)"
    fi
    echo

    # Integration
    echo "INTEGRATION: Slurp’it → NetBox API"
    local integ
    integ="$(check_slurpit_to_netbox_integration)"
    [[ "$integ" == "OK" ]] && integ="$(green OK)" || integ="$(red FAIL)"
    echo "  Portal → NetBox API: [$integ]"
    echo

    echo "Press ENTER to return to menu"
    read -rsn1
}

###############################################################################
# Live TUI dashboard
###############################################################################

tui_dashboard() {
    while true; do
        clear
        echo "============================================================"
        echo "                    LIVE SYSTEM DASHBOARD"
        echo "============================================================"
        echo "(Q=Quit, R=Refresh, O=Open UI, L=Logs, S=Summary)"
        echo

        local host_ip
        host_ip="$(get_host_ip)"
        echo "Host IP: $host_ip"
        echo

        # NetBox
        local nb_url nb_api nb_status
        nb_url="$(get_netbox_url)"
        nb_api="$(get_netbox_api_status_url)"
        nb_status="$(check_url_reachable "$nb_api")"
        [[ "$nb_status" == "OK" ]] && nb_status="$(green OK)" || nb_status="$(red FAIL)"

        echo "NETBOX"
        echo "  UI:          $nb_url"
        echo "  API Status:  $nb_api  [$nb_status]"
        echo

        echo "PLUGIN VERSIONS"
        get_netbox_plugin_versions | sed 's/^/  /'
        echo

        # Slurp’it Portal
        local portal_url portal_status
        portal_url="$(get_slurpit_portal_url)"
        portal_status="$(check_url_reachable "$portal_url")"
        [[ "$portal_status" == "OK" ]] && portal_status="$(green OK)" || portal_status="$(red FAIL)"

        echo "SLURP’IT PORTAL"
        echo "  URL:         $portal_url  [$portal_status]"
        echo

        # Slurp’it Warehouse
        local wh_url wh_status
        wh_url="$(get_slurpit_warehouse_url)"
        wh_status="$(check_url_reachable "$wh_url")"
        [[ "$wh_status" == "OK" ]] && wh_status="$(green OK)" || wh_status="$(red FAIL)"

        echo "SLURP’IT WAREHOUSE"
        echo "  URL:         $wh_url  [$wh_status]"
        echo

        # Containers: health + stats
        echo "CONTAINERS (health)"
        get_container_health | sed 's/^/  /'
        echo

        echo "CONTAINERS (CPU/MEM)"
        get_container_stats | sed 's/^/  /'
        echo

        # Networks
        echo "NETWORKS"
        if docker network inspect netbox-docker_default >/dev/null 2>&1; then
            echo "  netbox-docker_default: $(green OK)"
        else
            echo "  netbox-docker_default: $(red MISSING)"
        fi
        echo

        # Integration
        echo "INTEGRATION: Slurp’it → NetBox API"
        local integ
        integ="$(check_slurpit_to_netbox_integration)"
        [[ "$integ" == "OK" ]] && integ="$(green OK)" || integ="$(red FAIL)"
        echo "  Portal → NetBox API: [$integ]"
        echo

        # Non-blocking key handler
        read -rsn1 -t 30 key || true
        case "$key" in
            q|Q) break ;;
            r|R) continue ;;  # immediate refresh
            o|O)
                # Open NetBox UI by default
                open_in_browser "$(get_netbox_url)"
                ;;
            l|L)
                clear
                echo "=== Recent NetBox logs (Ctrl+C to exit) ==="
                docker logs --tail 100 netbox-docker-netbox-1
                echo
                echo "Press ENTER to return to TUI"
                read -rsn1
                ;;
            s|S)
                clear
                system_health_dashboard
                ;;
        esac
    done
}



version_info() {
    echo "netbox-manager version: $SCRIPT_VERSION"
}

###############################################################################
# Slurp’it ↔ NetBox integration module with network auto-repair
###############################################################################

# Logging helpers (assumes die/log not already defined)
log() { echo "[INFO] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

###############################################################################
# Detection helpers
###############################################################################

detect_netbox_api_container() {
  docker ps --format '{{.Names}} {{.Image}}' \
    | awk '$2 ~ /netboxcommunity\/netbox/ && $1 ~ /netbox-[0-9]+$/ {print $1; exit}'
}

detect_netbox_network() {
  local netbox_container
  netbox_container="$(detect_netbox_api_container)"
  [[ -n "$netbox_container" ]] || return 1

  docker inspect "$netbox_container" \
    --format '{{range $k, $_ := .NetworkSettings.Networks}}{{println $k}}{{end}}' \
    | head -n1
}

detect_slurpit_containers() {
  docker ps --format '{{.Names}} {{.Image}}' \
    | awk '$2 ~ /^slurpit\// {print $1}'
}

###############################################################################
# Network auto-repair
###############################################################################

ensure_netbox_network_exists() {
  local netbox_network
  netbox_network="$(detect_netbox_network || true)"

  if [[ -z "$netbox_network" ]]; then
    die "Unable to detect NetBox network (is NetBox running?)"
  fi

  if ! docker network inspect "$netbox_network" >/dev/null 2>&1; then
    log "Creating NetBox network '$netbox_network'..."
    docker network create "$netbox_network" >/dev/null
  fi

  echo "$netbox_network"
}

attach_slurpit_to_netbox_network() {
  local netbox_network="$1"
  local slurpit_containers=("$@")
  slurpit_containers=("${slurpit_containers[@]:1}")

  for c in "${slurpit_containers[@]}"; do
    if ! docker inspect "$c" \
      --format '{{range $k, $_ := .NetworkSettings.Networks}}{{println $k}}{{end}}' \
      | grep -qx "$netbox_network"; then
      log "Attaching $c to network '$netbox_network'..."
      docker network connect "$netbox_network" "$c" >/dev/null || \
        die "Failed to attach $c to network '$netbox_network'"
    fi
  done
}

###############################################################################
# NetBox API reachability
###############################################################################

check_netbox_reachable() {
  local netbox_url="$1"
  log "Checking NetBox API reachability at $netbox_url..."
  curl -s "${netbox_url}/api/status/" >/dev/null \
    || die "NetBox API not reachable at ${netbox_url}"
}

###############################################################################
# NetBox token management (NetBox 4.4+)
###############################################################################

ensure_netbox_token() {
  local netbox_container="$1"
  log "Ensuring NetBox API token exists..."

  NETBOX_TOKEN="$(
  docker exec -i "${netbox_container}" \
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
# Slurp’it lifecycle + verification
###############################################################################

restart_slurpit_services() {
  local slurpit_containers=("$@")
  [[ ${#slurpit_containers[@]} -gt 0 ]] || die "No Slurp’it containers detected"

  log "Restarting Slurp’it services..."
  docker restart "${slurpit_containers[@]}" >/dev/null
}

verify_plugin_registered() {
  local netbox_container="$1"
  log "Verifying Slurp’it plugin registration..."

  docker exec -i "${netbox_container}" \
    /opt/netbox/netbox/manage.py shell <<'PY'
from django.conf import settings
assert "slurpit_netbox" in settings.PLUGINS
print("Slurp’it plugin registered")
PY
}

verify_slurpit_reachability() {
  local slurpit_warehouse="$1"
  local netbox_url="$2"

  log "Verifying Slurp’it can reach NetBox..."

  docker exec "$slurpit_warehouse" sh -c "
    curl -s ${netbox_url}/api/status/ >/dev/null
  " || die "Slurp’it cannot reach NetBox API at ${netbox_url}"

  log "SUCCESS: Slurp’it ↔ NetBox integration verified"
}

###############################################################################
# Main entrypoint
###############################################################################

wire_slurpit_netbox() {
  # Detect NetBox API container
  local netbox_container
  netbox_container="$(detect_netbox_api_container)"
  [[ -n "$netbox_container" ]] || die "Unable to locate NetBox API container"

  # Detect NetBox network and ensure it exists
  local netbox_network
  netbox_network="$(ensure_netbox_network_exists)"

  # Detect Slurp’it containers
  local slurpit_containers
  mapfile -t slurpit_containers < <(detect_slurpit_containers)
  [[ ${#slurpit_containers[@]} -gt 0 ]] || die "No Slurp’it containers detected"

  # Auto-repair: attach Slurp’it containers to NetBox network
  attach_slurpit_to_netbox_network "$netbox_network" "${slurpit_containers[@]}"

  # Derive NetBox URL as seen by Slurp’it (container-to-container)
  local netbox_url="http://${netbox_container}:8080"

  # Check NetBox reachability from host
  check_netbox_reachable "http://localhost:8000"

  # Ensure token
  ensure_netbox_token "$netbox_container"

  # Restart Slurp’it
  restart_slurpit_services "${slurpit_containers[@]}"

  # Verify plugin
  verify_plugin_registered "$netbox_container"

  # Pick warehouse container for smoke test
  local slurpit_warehouse=""
  for c in "${slurpit_containers[@]}"; do
    if [[ "$c" == *"warehouse"* ]]; then
      slurpit_warehouse="$c"
      break
    fi
  done
  [[ -n "$slurpit_warehouse" ]] || die "Unable to locate Slurp’it warehouse container"

  # Verify Slurp’it → NetBox connectivity over shared network
  verify_slurpit_reachability "$slurpit_warehouse" "$netbox_url"
}

slurpit_netbox_status() {
  echo "------------------------------------------------------------"
  echo " Slurp’it ↔ NetBox Status Report (Read‑Only)"
  echo "------------------------------------------------------------"

  #
  # Detect NetBox API container
  #
  local netbox_container
  netbox_container="$(detect_netbox_api_container)"
  if [[ -z "$netbox_container" ]]; then
    echo "NetBox API container: NOT FOUND"
    return 1
  fi
  echo "NetBox API container: $netbox_container"

  #
  # Detect NetBox network
  #
  local netbox_network
  netbox_network="$(detect_netbox_network || true)"
  if [[ -z "$netbox_network" ]]; then
    echo "NetBox network: NOT FOUND"
  else
    echo "NetBox network: $netbox_network"
  fi

  #
  # Detect Slurp’it containers
  #
  local slurpit_containers
  mapfile -t slurpit_containers < <(detect_slurpit_containers)
  if [[ ${#slurpit_containers[@]} -eq 0 ]]; then
    echo "Slurp’it containers: NONE FOUND"
    return 1
  fi

  echo "Slurp’it containers:"
  for c in "${slurpit_containers[@]}"; do
    echo "  - $c"
  done

  #
  # Check network membership
  #
  echo
  echo "Network membership:"
  if [[ -z "$netbox_network" ]]; then
    echo "  Cannot check — NetBox network unknown"
  else
    for c in "${slurpit_containers[@]}"; do
      if docker inspect "$c" \
        --format '{{range $k, $_ := .NetworkSettings.Networks}}{{println $k}}{{end}}' \
        | grep -qx "$netbox_network"; then
        echo "  $c: JOINED"
      else
        echo "  $c: NOT JOINED"
      fi
    done
  fi

  #
  # Check NetBox API reachability (host → NetBox)
  #
  echo
  echo "NetBox API reachability (host → NetBox):"
  if curl -s "http://localhost:8000/api/status/" >/dev/null; then
    echo "  OK"
  else
    echo "  FAILED"
  fi

  #
  # Check plugin registration
  #
  echo
  echo "Slurp’it plugin registration:"
  if docker exec -i "$netbox_container" \
    /opt/netbox/netbox/manage.py shell <<'PY' 2>/dev/null | grep -q "Slurp’it plugin registered"
from django.conf import settings
assert "slurpit_netbox" in settings.PLUGINS
print("Slurp’it plugin registered")
PY
  then
    echo "  REGISTERED"
  else
    echo "  NOT REGISTERED"
  fi

  #
  # Check Slurp’it → NetBox reachability
  #
  echo
  echo "Slurp’it → NetBox API reachability:"
  local warehouse=""
  for c in "${slurpit_containers[@]}"; do
    [[ "$c" == *"warehouse"* ]] && warehouse="$c"
  done

  if [[ -z "$warehouse" ]]; then
    echo "  Warehouse container not found — cannot test"
  else
    local netbox_url="http://${netbox_container}:8080"
    if docker exec "$warehouse" sh -c "curl -s ${netbox_url}/api/status/ >/dev/null"; then
      echo "  OK"
    else
      echo "  FAILED"
    fi
  fi

  echo
  echo "------------------------------------------------------------"
  echo " Status report complete."
  echo "------------------------------------------------------------"
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
12) System Health Dashboard
13) Version Info
14) Slurp'it Netbox Status
15) URLs & Dashboard
16) Open in Browser
17) Live TUI Dashboard
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
      12) system_health_dashboard ;;
      13) version_info ;;
      14) slurpit_netbox_status ;;
      15)
        echo
        print_url_status "NetBox UI"            "$(get_netbox_url)"
        print_url_status "NetBox API Status"    "$(get_netbox_api_status_url)"
        echo
        print_url_status "Slurp’it Portal"       "$(get_slurpit_portal_url)"
        print_url_status "Slurp’it Warehouse"    "$(get_slurpit_warehouse_url)"
        echo
        echo "Plugin Docs:"
        echo "  - Secrets:           https://github.com/netbox-community/netbox-secrets"
        echo "  - Slurp’it Plugin:   https://gitlab.com/slurpit.io/slurpit_netbox"
        echo "  - DNS:               https://github.com/peteeckel/netbox-plugin-dns"
        echo "  - Inventory:         https://github.com/ArnesSI/netbox-inventory"
        echo "  - Routing:           https://github.com/DanSheps/netbox-routing"
        echo "  - Topology Views:    https://github.com/netbox-community/netbox-topology-views"
        echo
        ;;
      
      16)
        echo "Which service?"
        echo "1) NetBox UI"
        echo "2) Slurp’it Portal"
        echo "3) Slurp’it Warehouse"
        read -rp "> " svc
      
        case "$svc" in
          1) open_in_browser "$(get_netbox_url)" ;;
          2) open_in_browser "$(get_slurpit_portal_url)" ;;
          3) open_in_browser "$(get_slurpit_warehouse_url)" ;;
          *) echo "Invalid selection." ;;
        esac
        ;;
      17) tui_dashboard ;;
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
    health) system_health_dashboard ;;
    version) version_info ;;
    "") menu_loop ;;
    *) error "Unknown command: $cmd" ;;
  esac
}

dispatch "$@"
