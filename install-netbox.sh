#!/usr/bin/env bash
set -e

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
# Function: create_plugin_requirements
# ------------------------------------------------------------
create_plugin_requirements() {
    echo "[INFO] Creating plugin_requirements.txt..."

    cat > plugin_requirements.txt <<'EOF'
netbox-secrets
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
]

PLUGINS_CONFIG = {
    "netbox_secrets": {
        "public_key": "",
        "private_key": "",
    }
}
EOF
}

# ------------------------------------------------------------
# Function: create_plugin_dockerfile
# ------------------------------------------------------------
create_plugin_dockerfile() {
    echo "[INFO] Creating Dockerfile-plugins..."

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
    echo "[INFO] Creating docker-compose.override.yml..."

    cat > docker-compose.override.yml <<EOF
services:
  netbox:
    ports:
      - 8000:8080
EOF
}

# ------------------------------------------------------------
# Function: build_and_start
# ------------------------------------------------------------
build_and_start() {
    echo "[INFO] Pulling base images..."
    docker compose pull

    echo "[INFO] Building NetBox image (Dockerfile + plugin_requirements.txt)..."
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
#    create_plugin_requirements
#    create_plugin_config
#    create_plugin_dockerfile
    create_compose_override
    build_and_start
    create_superuser

    echo
    echo "------------------------------------------------------------"
    echo " NetBox installation complete."
    echo " netbox-secrets installed via BOTH:"
    echo "   - Dockerfile-plugins"
    echo "   - plugin_requirements.txt"
    echo
    echo " Access NetBox at: http://<server-ip>:${NETBOX_PORT}"
    echo "------------------------------------------------------------"
}

main "$@"
