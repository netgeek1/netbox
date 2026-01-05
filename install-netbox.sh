#!/usr/bin/env bash
#
# Netbox Plugins
#  - https://netboxlabs.com/plugins
#      - Need to add to plugin_requirements.txt, configuration/plugins.py and PLUGINS=
#
#
# - v1.1.4
#   Added Slurpit Server
#    - https://gitlab.com/slurpit.io/slurpit_netbox
#    - https://www.youtube.com/watch?v=Asji7fTfCy8
#
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
#   Added Netbox DNS
#    - https://github.com/peteeckel/netbox-plugin-dns



set -euo pipefail

SCRIPT_VERSION="1.1.4"

INSTALL_DIR="/opt"
NETBOX_PORT="${1:-8000}"
NETBOX_BRANCH="release"

# ------------------------------------------------------------
# Function: require_root
# ------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[INFO] Elevation required — re-running with sudo..."
        sudo bash "$0" "$@"
        exit $?
    fi
}

# ------------------------------------------------------------
# Function: install_docker
# ------------------------------------------------------------
install_docker() {
  command -v docker >/dev/null 2>&1 && return
  log "Docker not found; installing prerequisites + Docker Engine..."

  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release openssl

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

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
    warn "You may need to log out/in for group changes to apply in existing sessions."
  fi
}

# ------------------------------------------------------------
# Function: clone_netbox_docker
# ------------------------------------------------------------
clone_netbox_docker() {
    echo "[INFO] Cloning netbox-docker repository..."

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    if [[ ! -d netbox-docker ]]; then
        git clone -b "$NETBOX_BRANCH" https://github.com/netbox-community/netbox-docker.git
    else
        echo "[INFO] netbox-docker already exists — using existing clone."
    fi

    cd netbox-docker
}

# ------------------------------------------------------------
# Function: clone_slurpit_docker
# ------------------------------------------------------------
clone_slurpit_docker() {
    echo "[INFO] Cloning slurpit-docker repository..."

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    if [[ ! -d slurpit-docker ]]; then
        git clone https://gitlab.com/slurpit.io/images.git slurpit-docker
    else
        echo "[INFO] slurpit-docker already exists — using existing clone."
    fi

    cd slurpit-docker
    cp docker-compose.override-EXAMPLE.yml docker-compose.override.yml
}

# ------------------------------------------------------------
# Function: create_plugin_requirements
# ------------------------------------------------------------
create_plugin_requirements() {
    echo "[INFO] Creating plugin_requirements.txt (wiki method)..."

    cat > plugin_requirements.txt <<'EOF'
netbox-secrets
slurpit_netbox
netbox-plugin-dns
netbox-routing
netbox-inventory
netbox-topology-views
EOF
}

# ------------------------------------------------------------
# Function: create_plugin_config
# ------------------------------------------------------------
create_plugin_config() {
    echo "[INFO] Creating configuration/plugins.py..."

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

# ------------------------------------------------------------
# Function: create_plugin_dockerfile
# ------------------------------------------------------------
create_plugin_dockerfile() {
    echo "[INFO] Creating Dockerfile-plugins (wiki method)..."

    cat > Dockerfile-plugins <<'EOF'
FROM netboxcommunity/netbox:latest

COPY ./plugin_requirements.txt /opt/netbox/
RUN /usr/local/bin/uv pip install -r /opt/netbox/plugin_requirements.txt
EOF
}

# ------------------------------------------------------------
# Function: create_compose_override
# ------------------------------------------------------------
create_compose_override() {
    echo "[INFO] Creating docker-compose.override.yml (wiki method + 900s health)..."

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
      start_period: 900s
EOF
}

# ------------------------------------------------------------
# Function: build_and_start
# ------------------------------------------------------------
build_and_start() {
    echo "[INFO] Pulling base images..."
    docker compose pull

    echo "[INFO] Building NetBox image (wiki plugin method)..."
    docker compose build

    echo "[INFO] Starting NetBox stack..."
    docker compose up -d
}

# ------------------------------------------------------------
# Function: create_superuser
# ------------------------------------------------------------
create_superuser() {
    echo "[INFO] Attempting to create NetBox superuser..."
    docker compose exec netbox /opt/netbox/netbox/manage.py createsuperuser || {
        echo "[WARN] NetBox not healthy yet — rerun manually:"
        echo "       cd ${INSTALL_DIR}/netbox-docker"
        echo "       docker compose exec netbox /opt/netbox/netbox/manage.py createsuperuser"
    }
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
main() {
    require_root "$@"
    install_docker
    clone_netbox_docker
    create_plugin_requirements
    create_plugin_config
    create_plugin_dockerfile
    create_compose_override
    cd "$INSTALL_DIR/netbox-docker"
    build_and_start
    clone_slurpit_docker
    cd "$INSTALL_DIR/slurpit-docker"
    build_and_start
    create_superuser

    echo
    echo "------------------------------------------------------------"
    echo " NetBox installation complete."
    echo " netbox-secrets installed EXACTLY per the wiki:"
    echo "   - plugin_requirements.txt"
    echo "   - Dockerfile-plugins using uv pip"
    echo "   - PLUGINS=['netbox_secrets','slurpit_netbox','netbox_dns','netbox_routing','netbox_inventory','netbox_topology_views']"
    echo "   - configuration/plugins.py"
    echo "------------------------------------------------------------"
    echo " Access NetBox at: http://<server-ip>:${NETBOX_PORT}"
    echo "------------------------------------------------------------"
}

main "$@"
