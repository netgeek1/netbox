#!/usr/bin/env bash
# =============================================================================
#  NetBox Auto-Deploy & Network Discovery Suite  --  Ubuntu 24.04
#  Version: 2.2.12
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# GLOBAL CONSTANTS
# -----------------------------------------------------------------------------
SCRIPT_VERSION="2.2.12"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
REAL_USER="${SUDO_USER:-$(id -un)}"   # actual user even when run via sudo

BASE_DIR="/opt/netbox-discovery"
LOG_DIR="/var/log/netbox-discovery"
CONFIG_FILE="$BASE_DIR/config.conf"
CREDS_FILE="$BASE_DIR/.credentials.enc"
CREDS_KEY_FILE="$BASE_DIR/.creds.key"
DISCOVERY_DIR="$BASE_DIR/discovery"
NETBOX_DIR="/opt/netbox-docker"
DOCKER_COMPOSE="docker compose"    # updated by detect_docker_compose()

R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
C='\033[0;36m'  W='\033[1;37m'  D='\033[2m'  NC='\033[0m'

NETBOX_PORT=8000
NETBOX_API_URL=""
NETBOX_API_TOKEN=""
NETBOX_ADMIN_PASS=""
DEFAULT_SITE_NAME="Default Site"
SCAN_TIMEOUT=5
SNMP_TIMEOUT=3
SSH_TIMEOUT=10
MAX_THREADS=20
DEBUG_MODE=0

LOG_FILE="$LOG_DIR/discovery-$(date +%Y%m%d).log"

# -----------------------------------------------------------------------------
# LOGGING  -- stderr so $() captures never pick up log text
# -----------------------------------------------------------------------------
_log() {
    local lvl="$1"; shift
    printf '[%s] [%-5s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$lvl" "$*" >> "$LOG_FILE" 2>/dev/null
}
log_info()  { _log "INFO"  "$@"; printf "${G}[INFO]${NC}  %s\n"  "$*" >&2; }
log_warn()  { _log "WARN"  "$@"; printf "${Y}[WARN]${NC}  %s\n"  "$*" >&2; }
log_error() { _log "ERROR" "$@"; printf "${R}[ERROR]${NC} %s\n"  "$*" >&2; }
log_ok()    { _log "OK"    "$@"; printf "${G}[OK]${NC}    %s\n"  "$*" >&2; }
log_debug() { _log "DEBUG" "$@"
    [[ $DEBUG_MODE -eq 1 ]] && printf "${D}[DEBUG]${NC} %s\n" "$*" >&2; }
log_step()  { _log "STEP"  "$*"
    printf "\n${C}====== ${W}%s${C} ======${NC}\n" "$*" >&2; }

# -----------------------------------------------------------------------------
# UTILITIES
# -----------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        printf "${Y}Not root -- re-launching with sudo...${NC}\n" >&2
        exec sudo "$0" "$@"
    fi
}
pause()      { echo; read -rp "  Press [Enter] to continue..."; }
confirm()    { local r; read -rp "  ${1:-Are you sure?} [y/N] " r; [[ "${r,,}" == "y" ]]; }
cmd_exists() { command -v "$1" &>/dev/null; }
spinner() {
    local pid=$1 i=0 chars='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s ' "${chars:$((i++%4)):1}"; sleep 0.1
    done; printf '\r     \r'
}
valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'; read -ra o <<< "$1"
    local x; for x in "${o[@]}"; do (( x <= 255 )) || return 1; done
}
valid_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]
}
slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' \
        | tr ' _' '-' | tr -dc '[:alnum:]-' | sed 's/-\+/-/g'
}
nb_urlencode() {
    python3 -c \
        "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

get_host_ip() {
    # Finds the LAN-reachable IP, not 127.0.0.1
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
}

NETBOX_API_URL="http://$(get_host_ip):${NETBOX_PORT}"

# -----------------------------------------------------------------------------
# DOCKER COMPOSE DETECTION
# -----------------------------------------------------------------------------
detect_docker_compose() {
    if docker compose version &>/dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose &>/dev/null 2>&1; then
        DOCKER_COMPOSE="docker-compose"
        log_warn "compose plugin absent -- falling back to docker-compose"
    else
        DOCKER_COMPOSE="docker compose"
        log_warn "docker compose not detected; will try after install"
    fi
}

# -----------------------------------------------------------------------------
# DOCKER GROUP MANAGEMENT
# -----------------------------------------------------------------------------
ensure_docker_group() {
    getent group docker >/dev/null 2>&1 || groupadd docker
    if [[ -n "$REAL_USER" ]] && ! id "$REAL_USER" 2>/dev/null | grep -q docker; then
        log_info "Adding user '$REAL_USER' to docker group"
        usermod -aG docker "$REAL_USER"
        log_warn "Log out and back in (or run: newgrp docker) for group change to apply"
    fi
}

# -----------------------------------------------------------------------------
# BANNER
# -----------------------------------------------------------------------------
banner() {
    clear
    printf "${C}"
    echo "  +====================================================================+"
    echo "  |   NetBox Auto-Deploy & Network Discovery Suite  v${SCRIPT_VERSION}           |"
    echo "  |   Ubuntu 24.04  |  Multi-Protocol  |  Full NetBox Auto-Sync       |"
    echo "  +====================================================================+"
    printf "${NC}\n"
    printf "  ${D}Log   : %s${NC}\n" "$LOG_FILE"
    printf "  ${D}Config: %s${NC}\n" "$CONFIG_FILE"
    printf "  ${D}NetBox: %s${NC}\n" "${NETBOX_API_URL:-<not set>}"
    local _tok_disp="${NETBOX_API_TOKEN:0:8}...${NETBOX_API_TOKEN: -4}"
    [[ -z "$NETBOX_API_TOKEN" ]] && _tok_disp="<not set>"
    printf "  ${D}Token : %s${NC}  ${D}Admin: %s${NC}\n" \
        "$_tok_disp" "${NETBOX_ADMIN_PASS:-<see creds file>}"
    echo ""
}

# -----------------------------------------------------------------------------
# DIRECTORY & CONFIG
# -----------------------------------------------------------------------------
init_dirs() {
    mkdir -p "$BASE_DIR" "$LOG_DIR" "$DISCOVERY_DIR"
    chmod 700 "$BASE_DIR"; chmod 755 "$LOG_DIR"; touch "$LOG_FILE"
}
save_config() {
    cat > "$CONFIG_FILE" <<CONF
# NetBox Discovery Suite Config -- $(date)
NETBOX_PORT=${NETBOX_PORT}
NETBOX_API_URL=${NETBOX_API_URL}
NETBOX_API_TOKEN="${NETBOX_API_TOKEN}"
NETBOX_ADMIN_PASS="${NETBOX_ADMIN_PASS}"
DEFAULT_SITE_NAME="${DEFAULT_SITE_NAME}"
SCAN_TIMEOUT=${SCAN_TIMEOUT}
SNMP_TIMEOUT=${SNMP_TIMEOUT}
SSH_TIMEOUT=${SSH_TIMEOUT}
MAX_THREADS=${MAX_THREADS}
DEBUG_MODE=${DEBUG_MODE}
CONF
    chmod 600 "$CONFIG_FILE"
}
load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    NETBOX_API_URL="http://$(get_host_ip):${NETBOX_PORT}"
}

# -----------------------------------------------------------------------------
# ENCRYPTED CREDENTIAL STORE
# -----------------------------------------------------------------------------
EMPTY_CREDS='{"snmp_communities":["public","private"],"snmp_v3":[],
  "ssh_credentials":[],"windows_credentials":[],"telnet_credentials":[],"device_overrides":{}}'

init_creds() {
    if [[ ! -f "$CREDS_KEY_FILE" ]]; then
        openssl rand -base64 48 > "$CREDS_KEY_FILE"; chmod 600 "$CREDS_KEY_FILE"
        log_info "Generated credential encryption key"
    fi
    [[ ! -f "$CREDS_FILE" ]] && write_creds "$EMPTY_CREDS"
}
read_creds() {
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -pass file:"$CREDS_KEY_FILE" -in "$CREDS_FILE" 2>/dev/null \
        || echo "$EMPTY_CREDS"
}
write_creds() {
    echo "$1" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -pass file:"$CREDS_KEY_FILE" -out "$CREDS_FILE" 2>/dev/null
    chmod 600 "$CREDS_FILE"
}
get_communities_for() {
    local ip="$1" creds; creds=$(read_creds)
    local ov; ov=$(echo "$creds" \
        | jq -r ".device_overrides[\"$ip\"].snmp_community // empty" 2>/dev/null)
    if [[ -n "$ov" ]]; then echo "$ov"
    else echo "$creds" | jq -r '.snmp_communities[]' 2>/dev/null || echo "public"; fi
}
get_ssh_creds_for() {
    local ip="$1" creds; creds=$(read_creds)
    local ov; ov=$(echo "$creds" \
        | jq -r ".device_overrides[\"$ip\"] // empty" 2>/dev/null)
    if [[ -n "$ov" && "$ov" != "null" ]]; then
        echo "$ov" | jq -c \
            '{username:.ssh_username,password:.ssh_password,
              key_file:.ssh_key,enable_pass:.enable_pass}'
    else
        echo "$creds" | jq -c '.ssh_credentials[]' 2>/dev/null || true
    fi
}

get_windows_creds_for() {
    local ip="$1" creds; creds=$(read_creds)
    local ov; ov=$(echo "$creds" \
        | jq -r ".device_overrides[\"$ip\"] // empty" 2>/dev/null) || ov=""
    if [[ -n "${ov:-}" && "$ov" != "null" ]]; then
        local wu wp wd
        wu=$(echo "$ov" | jq -r '.windows_username // empty' 2>/dev/null) || wu=""
        wp=$(echo "$ov" | jq -r '.windows_password // empty' 2>/dev/null) || wp=""
        wd=$(echo "$ov" | jq -r '.windows_domain   // empty' 2>/dev/null) || wd=""
        if [[ -n "${wu:-}" ]]; then
            local override_entry global_list
            override_entry=$(jq -n \
                --arg u "${wu:-}" --arg p "${wp:-}" --arg d "${wd:-}" \
                '[{username:$u,password:$p,domain:$d}]')
            global_list=$(echo "$creds" \
                | jq -c '.windows_credentials // []' 2>/dev/null || echo "[]")
            echo "$override_entry" | jq -c ". + $global_list" 2>/dev/null \
                || echo "[]"
            return
        fi
    fi
    echo "$creds" | jq -c '.windows_credentials // []' 2>/dev/null || echo "[]"
}

# -----------------------------------------------------------------------------
# DEPENDENCY INSTALLATION
# -----------------------------------------------------------------------------
install_deps() {
    log_step "Installing System Dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >> "$LOG_FILE" 2>&1

    printf "  ${W}Docker (official repo)${NC} ... "
    if ! cmd_exists docker || ! docker compose version &>/dev/null 2>&1; then
        apt-get install -y ca-certificates curl gnupg >> "$LOG_FILE" 2>&1 || true
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
        chmod a+r /etc/apt/keyrings/docker.gpg 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list 2>/dev/null || true
        apt-get update -qq >> "$LOG_FILE" 2>&1 || true
        apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1 \
            || { log_warn "Official install failed -- trying docker.io"
                 apt-get install -y docker.io >> "$LOG_FILE" 2>&1 || true; }
        printf "${G}OK${NC}\n"
    else printf "${G}already installed${NC}\n"; fi

    local pkgs=(
        git curl wget ipcalc bc
        nmap masscan arp-scan fping
        snmp snmpd snmp-mibs-downloader
        sshpass openssh-client lldpd telnet
        samba-common-bin nbtscan
        dnsutils bind9-dnsutils
        avahi-daemon avahi-utils
        jq python3 python3-pip python3-dev
        netcat-openbsd openssl whois traceroute tcpdump
    )
    local failed=() pkg
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -l "$pkg" &>/dev/null; then
            printf "  Installing ${W}%s${NC} ... " "$pkg"
            if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
                printf "${G}OK${NC}\n"
            else
                printf "${R}FAILED${NC}\n"; failed+=("$pkg")
            fi
        fi
    done

    printf "  ${W}SNMP MIBs${NC} ... "
    if cmd_exists download-mibs; then
        download-mibs >> "$LOG_FILE" 2>&1 || true
    else
        sed -i 's/^mibs :$/#mibs :/' /etc/snmp/snmp.conf 2>/dev/null || true
    fi
    sed -i '/^mibs +ALL/d' /etc/snmp/snmp.conf 2>/dev/null || true
    echo "mibs +ALL" >> /etc/snmp/snmp.conf 2>/dev/null || true
    printf "${G}OK${NC}\n"

    log_info "Installing Python network libraries..."
    local pylib
    for pylib in netmiko napalm pysnmp paramiko requests pynetbox scapy \
                 netbox-agent pywinrm; do
        pip3 install --break-system-packages --quiet \
            --root-user-action=ignore --ignore-installed \
            "$pylib" >> "$LOG_FILE" 2>&1 \
            || pip3 install --break-system-packages --quiet \
               --root-user-action=ignore \
               "$pylib" >> "$LOG_FILE" 2>&1 || true
    done

    local svc
    for svc in docker lldpd avahi-daemon; do
        systemctl enable "$svc" >> "$LOG_FILE" 2>&1 || true
        systemctl start  "$svc" >> "$LOG_FILE" 2>&1 || true
    done

    printf "  ${W}RustScan${NC} (fast port scanner) ... "
    if ! cmd_exists rustscan; then
        # Primary: Docker image (officially recommended; Docker already present
        # for NetBox). Creates a /usr/local/bin/rustscan wrapper that runs the
        # container with --network host so it sees the same interfaces as nmap.
        local _rs_ok=0
        if cmd_exists docker; then
            if docker pull rustscan/rustscan:2.1.1 >> "$LOG_FILE" 2>&1; then
                cat > /usr/local/bin/rustscan <<'RSWRAP'
#!/bin/bash
exec docker run --rm --network host rustscan/rustscan:2.1.1 "$@"
RSWRAP
                chmod +x /usr/local/bin/rustscan
                _rs_ok=1
                printf "${G}OK (Docker)${NC}\n"
            fi
        fi
        # Fallback: .deb from bee-san/RustScan releases
        if [[ $_rs_ok -eq 0 ]]; then
            local _rs_ver
            _rs_ver=$(curl -sf \
                "https://api.github.com/repos/bee-san/RustScan/releases/latest" \
                | jq -r '.tag_name // "2.1.1"' 2>/dev/null || echo "2.1.1")
            local _rs_deb="rustscan_${_rs_ver}_amd64.deb"
            if curl -sfL \
                "https://github.com/bee-san/RustScan/releases/download/${_rs_ver}/${_rs_deb}" \
                -o /tmp/rustscan.deb 2>/dev/null \
                && dpkg -i /tmp/rustscan.deb >> "$LOG_FILE" 2>&1; then
                printf "${G}OK (.deb)${NC}\n"
            else
                printf "${Y}skipped (optional)${NC}\n"
            fi
            rm -f /tmp/rustscan.deb
        fi
    else printf "${G}already installed${NC}\n"; fi

    ensure_docker_group

    [[ ${#failed[@]} -gt 0 ]] \
        && log_warn "Failed packages: ${failed[*]}" \
        || log_ok "All dependencies installed"
    pause
}

# -----------------------------------------------------------------------------
# NETBOX DEPLOYMENT
# -----------------------------------------------------------------------------
deploy_netbox() {
    log_step "Deploying NetBox via Docker Compose"
    detect_docker_compose

    if ! cmd_exists docker; then
        log_error "Docker not installed -- run Option 1 first"
        pause; return 1
    fi

    local admin_pass secret_key creds_out
    admin_pass="NetBox@$(openssl rand -hex 5)"
    secret_key=$(openssl rand -base64 60 | tr -d '\n/+=' | head -c 50)

    NETBOX_ADMIN_PASS="$admin_pass"
    save_config

    creds_out="$BASE_DIR/netbox-credentials.txt"
    cat > "$creds_out" <<CREDEOF
NetBox Access Credentials
=========================
URL:       http://$(get_host_ip):${NETBOX_PORT}
Username:  admin
Password:  ${admin_pass}
API Token: (populated after startup -- see below)

KEEP THIS FILE SECURE
CREDEOF
    chmod 600 "$creds_out"
    log_info "Credentials pre-saved: $creds_out"

    if [[ -d "$NETBOX_DIR/.git" ]]; then
        log_info "Updating netbox-docker repo..."
        git -C "$NETBOX_DIR" pull -q >> "$LOG_FILE" 2>&1
    else
        log_info "Cloning netbox-docker..."
        git clone -q https://github.com/netbox-community/netbox-docker.git \
            "$NETBOX_DIR" >> "$LOG_FILE" 2>&1
    fi
    cd "$NETBOX_DIR" || { log_error "Cannot cd to $NETBOX_DIR"; return 1; }

    # SUPERUSER_API_TOKEN intentionally omitted.
    # NetBox v4.5+ changed Token.key to a new format (varchar(12)); forcing a
    # pre-generated 40-char hex string causes DataError. Token is created via
    # Django shell after startup using Token.objects.create() with no key=.
    cat > docker-compose.override.yml <<DCEOF
services:
  netbox:
    ports:
      - "${NETBOX_PORT}:8080"
    environment:
      SKIP_SUPERUSER: "false"
      SUPERUSER_NAME: "admin"
      SUPERUSER_PASSWORD: "${admin_pass}"
      SUPERUSER_EMAIL: "admin@netbox.local"
      SECRET_KEY: "${secret_key}"
      PROCESSES: "2"
  netbox-worker:
    environment:
      SECRET_KEY: "${secret_key}"
DCEOF

    log_info "Pulling Docker images (may take several minutes)..."
    $DOCKER_COMPOSE pull >> "$LOG_FILE" 2>&1 &
    spinner $!; wait $! || { log_error "$DOCKER_COMPOSE pull failed"; pause; return 1; }

    log_info "Starting NetBox containers..."
    $DOCKER_COMPOSE up -d >> "$LOG_FILE" 2>&1 &
    spinner $!; wait $!

    printf "  Waiting for NetBox to initialize "
    local retries=0 http_code=""
    until http_code=$(curl -s -o /dev/null -w "%{http_code}" \
              --max-time 5 "http://$(get_host_ip):${NETBOX_PORT}/" 2>/dev/null) \
          && [[ "$http_code" =~ ^[234] ]]; do
        sleep 5; printf "."; (( retries++ )) || true
        if (( retries > 72 )); then
            printf "\n${Y}Timeout -- NetBox may still be starting.${NC}\n" >&2
            printf "  Check: cd %s && %s logs netbox | tail -30\n" \
                "$NETBOX_DIR" "$DOCKER_COMPOSE" >&2
            break
        fi
    done
    printf " ${G}HTTP %s${NC}\n" "$http_code"

    # Token creation aligned with netbox-docker super_user.py behaviour:
    # - get_or_create user (idempotent)
    # - only set password when creating a new user
    # - NO key= passed to Token.objects.create(); NetBox generates its own
    #   native-format key (required for NetBox 4.5+ varchar(12) field)
    log_info "Configuring admin credentials via Django shell..."
    local setup_py setup_result setup_tries=0
    setup_py="
from django.contrib.auth.models import User
from users.models import Token
import sys

u, created = User.objects.get_or_create(username='admin')
if created:
    u.set_password('${admin_pass}')
    u.is_superuser = True
    u.is_staff = True
    u.save()
    sys.stderr.write('Created new admin user\n')
else:
    sys.stderr.write('Admin user already exists\n')

t = Token.objects.filter(user=u).first()
if not t:
    t = Token.objects.create(user=u)
    sys.stderr.write('Created new token\n')
else:
    sys.stderr.write('Using existing token\n')

print('SETUP_OK:' + str(t.key))
"

    until setup_result=$(cd "$NETBOX_DIR" && \
            $DOCKER_COMPOSE exec -T netbox \
            python manage.py shell << PYEOF 2>/dev/null | grep "^SETUP_OK:"
${setup_py}
PYEOF
    ); do
        sleep 5; (( setup_tries++ )) || true
        if (( setup_tries > 18 )); then
            log_warn "Django shell timed out"
            log_warn "Manual: docker exec -it <netbox> python manage.py changepassword admin"
            break
        fi
    done

    if [[ "$setup_result" == SETUP_OK:* ]]; then
        NETBOX_API_TOKEN="${setup_result#SETUP_OK:}"
        log_ok "Credentials configured: token=${NETBOX_API_TOKEN:0:12}..."
        save_config
        sed -i "s|^API Token:.*|API Token: ${NETBOX_API_TOKEN}|" \
            "$creds_out" 2>/dev/null || true
        sed -i "s|^Password:.*|Password:  ${admin_pass}|" \
            "$creds_out" 2>/dev/null || true
    else
        log_warn "Django shell incomplete -- create token manually in NetBox UI"
    fi

    printf "\n${G}+----------------------------------------------+${NC}\n"
    printf "${G}|  NetBox Deployed!                            |${NC}\n"
    printf "${G}+----------------------------------------------+${NC}\n"
    printf "  URL:      ${W}http://$(get_host_ip):%s${NC}\n" "$NETBOX_PORT"
    printf "  Username: ${W}admin${NC}\n"
    printf "  Password: ${W}%s${NC}\n" "$admin_pass"
    printf "  Token:    ${W}%s${NC}\n" "${NETBOX_API_TOKEN:-<create via UI>}"
    printf "  Saved:    ${D}%s${NC}\n" "$creds_out"
    pause
}

# -----------------------------------------------------------------------------
# NETBOX REST API HELPERS
# Note: -f removed from curl so API error responses are captured and logged
# -----------------------------------------------------------------------------
nb_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    [[ -z "$NETBOX_API_TOKEN" ]] && { log_error "API token not set"; return 1; }
    local args=(-s -X "$method"
        -H "Authorization: Token $NETBOX_API_TOKEN"
        -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${NETBOX_API_URL}/api/${endpoint}" 2>>"$LOG_FILE"
}
nb_get()   { nb_api GET   "$1"; }
nb_post()  { nb_api POST  "$1" "${2:-}"; }
nb_patch() { nb_api PATCH "$1" "${2:-}"; }

nb_get_or_create_site() {
    local name="$DEFAULT_SITE_NAME" slug enc res id
    slug=$(slugify "$name"); enc=$(nb_urlencode "$name")
    res=$(nb_get "dcim/sites/?name=${enc}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/sites/" \
            "{\"name\":\"$name\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
        log_info "Created site: $name (ID: $id)"
    fi
    echo "$id"
}

nb_get_or_create_manufacturer() {
    local name="$1" slug enc res id
    slug=$(slugify "$name"); enc=$(nb_urlencode "$name")
    res=$(nb_get "dcim/manufacturers/?name=${enc}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/manufacturers/" \
            "{\"name\":\"$name\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
    fi
    echo "$id"
}

nb_get_or_create_device_type() {
    local mfr_id="$1" model="$2" slug enc res id slug_enc
    # Truncate to 64 chars; long model names from sys_descr drift between
    # runs and cause slug collisions on the second attempt
    model="${model:0:64}"
    slug=$(slugify "$model")
    [[ -z "$slug" ]] && slug="unknown-model"
    enc=$(nb_urlencode "$model")
    res=$(nb_get "dcim/device-types/?model=${enc}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/device-types/" \
            "{\"manufacturer\":$mfr_id,\"model\":\"$model\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
        # POST failed (likely slug collision from prior partial run).
        # Recover by searching for the slug directly.
        if [[ -z "$id" ]]; then
            slug_enc=$(nb_urlencode "$slug")
            res=$(nb_get "dcim/device-types/?slug=${slug_enc}")
            id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
        fi
    fi
    echo "$id"
}

nb_get_or_create_role() {
    local name="$1" color="${2:-2196f3}" slug enc res id
    slug=$(slugify "$name"); enc=$(nb_urlencode "$name")
    res=$(nb_get "dcim/device-roles/?name=${enc}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/device-roles/" \
            "{\"name\":\"$name\",\"slug\":\"$slug\",\"color\":\"$color\"}")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
    fi
    echo "$id"
}

nb_get_or_create_vlan() {
    local vid="$1" name="${2:-VLAN-$1}" site_id="$3" res id payload
    res=$(nb_get "ipam/vlans/?vid=${vid}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        payload=$(jq -n \
            --argjson vid "$vid" --arg name "$name" --argjson site "$site_id" \
            '{vid:$vid,name:$name,site:$site,status:"active"}')
        res=$(nb_post "ipam/vlans/" "$payload")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
        [[ -n "$id" ]] && log_info "Created VLAN $vid: $name"
    fi
    echo "$id"
}

nb_add_ip() {
    local ip="$1" device_id="${2:-}" iface_id="${3:-}"
    [[ "$ip" != */* ]] && ip="${ip}/32"
    local enc; enc=$(nb_urlencode "$ip")
    local existing; existing=$(nb_get "ipam/ip-addresses/?address=${enc}")
    local ip_id; ip_id=$(echo "$existing" | jq -r '.results[0].id // empty' 2>/dev/null)
    local payload
    payload=$(jq -n --arg addr "$ip" '{address:$addr,status:"active"}')
    if [[ -n "$iface_id" && "$iface_id" =~ ^[0-9]+$ ]]; then
        payload=$(echo "$payload" | jq \
            ".assigned_object_type=\"dcim.interface\" \
             | .assigned_object_id=$iface_id")
    fi
    if [[ -z "$ip_id" ]]; then
        local res; res=$(nb_post "ipam/ip-addresses/" "$payload")
        ip_id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
    else
        nb_patch "ipam/ip-addresses/${ip_id}/" "$payload" >/dev/null 2>&1 || true
    fi
    if [[ -n "$device_id" && "$device_id" =~ ^[0-9]+$ \
          && -n "$ip_id" && "$ip_id" =~ ^[0-9]+$ ]]; then
        nb_patch "dcim/devices/${device_id}/" \
            "{\"primary_ip4\":$ip_id}" >/dev/null 2>&1 || true
    fi
    echo "$ip_id"
}

nb_add_interface() {
    local device_id="$1" if_name="$2" if_type="${3:-other}" \
          mac="${4:-}" desc="${5:-}"
    local enc; enc=$(nb_urlencode "$if_name")
    local existing; existing=$(nb_get \
        "dcim/interfaces/?device_id=$device_id&name=${enc}")
    local id; id=$(echo "$existing" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        local payload
        payload=$(jq -n \
            --argjson dev  "$device_id" \
            --arg     name "$if_name" \
            --arg     type "$if_type" \
            --arg     mac  "$mac" \
            --arg     desc "$desc" \
            '{device:$dev,name:$name,type:$type,description:$desc,
              mac_address:(if $mac!="" and $mac!="null" then $mac else null end)}')
        local res; res=$(nb_post "dcim/interfaces/" "$payload")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
    fi
    echo "$id"
}

nb_upsert_device() {
    # primary_ip (8th arg): IP-first dedup -- find existing device by IP,
    # update in-place, rename auto-gen name to real hostname if richer.
    local name="$1" role="$2" mfr="$3" model="$4" site_id="$5" \
          serial="${6:-}" comments="${7:-}" primary_ip="${8:-}"
    local mfr_id dtype_id role_id
    mfr_id=$(nb_get_or_create_manufacturer "$mfr")
    dtype_id=$(nb_get_or_create_device_type "$mfr_id" "$model")
    role_id=$(nb_get_or_create_role "$role")

    if [[ -z "$mfr_id"   || ! "$mfr_id"   =~ ^[0-9]+$ ]]; then
        log_error "Invalid manufacturer ID for $name"; return 1; fi
    if [[ -z "$dtype_id" || ! "$dtype_id" =~ ^[0-9]+$ ]]; then
        log_error "Invalid device_type ID for $name"; return 1; fi
    if [[ -z "$role_id"  || ! "$role_id"  =~ ^[0-9]+$ ]]; then
        log_error "Invalid role ID for $name"; return 1; fi
    if [[ -z "$site_id"  || ! "$site_id"  =~ ^[0-9]+$ ]]; then
        log_error "Invalid site ID for $name"; return 1; fi

    # Sanitize serial: SNMP entity MIB returns error strings like
    # "iso.3.6.1... = No Such Object..." which exceed NetBox's max_length=50
    local clean_serial=""
    if [[ -n "$serial" \
          && ${#serial} -le 50 \
          && "$serial" != *"No Such"* \
          && "$serial" != *"iso."* \
          && "$serial" != *"Not avail"* ]]; then
        clean_serial="$serial"
    fi

    # ------ IP-first deduplication ---------------------------------------------------------------------------------------------------------------------------------
    local dev_id=""
    if [[ -n "${primary_ip:-}" ]]; then
        local _ie _ir _at _ai
        _ie=$(nb_urlencode "${primary_ip}/32")
        _ir=$(nb_get "ipam/ip-addresses/?address=${_ie}&limit=1")
        if [[ $(echo "$_ir" | jq '.count // 0' 2>/dev/null) == "0" ]]; then
            _ie=$(nb_urlencode "$primary_ip")
            _ir=$(nb_get "ipam/ip-addresses/?address=${_ie}&limit=1")
        fi
        _at=$(echo "$_ir" | jq -r '.results[0].assigned_object_type // empty' 2>/dev/null)
        _ai=$(echo "$_ir" | jq -r '.results[0].assigned_object_id  // empty' 2>/dev/null)
        if [[ "$_at" == "dcim.interface" && -n "${_ai:-}" && "$_ai" =~ ^[0-9]+$ ]]; then
            local _id
            _id=$(nb_get "dcim/interfaces/${_ai}/" | jq -r '.device.id // empty' 2>/dev/null)
            if [[ -n "${_id:-}" && "$_id" =~ ^[0-9]+$ ]]; then
                dev_id="$_id"
                log_info "Found existing device by IP $primary_ip (ID: $dev_id)"
                local _cn _ap="^device-[0-9]+-[0-9]+-[0-9]+-[0-9]+$"
                _cn=$(nb_get "dcim/devices/${dev_id}/" | jq -r '.name // empty' 2>/dev/null)
                if [[ -n "${_cn:-}" && "$_cn" != "$name" ]]; then
                    if [[ "$_cn" =~ $_ap && ! "$name" =~ $_ap ]]; then
                        log_info "Renaming device: $_cn -> $name"
                    elif [[ ! "$_cn" =~ $_ap && "$name" =~ $_ap ]]; then
                        log_debug "Keeping richer name $_cn over auto-gen $name"
                        name="$_cn"
                    fi
                fi
            fi
        fi
    fi
    # ------ Name lookup (fallback) ---------------------------------------------------------------------------------------------------------------------------------
    if [[ -z "$dev_id" || ! "$dev_id" =~ ^[0-9]+$ ]]; then
        local enc; enc=$(nb_urlencode "$name")
        local existing; existing=$(nb_get "dcim/devices/?name=${enc}")
        dev_id=$(echo "$existing" | jq -r '.results[0].id // empty' 2>/dev/null)
    fi

    local payload
    payload=$(jq -n \
        --arg     name     "$name" \
        --argjson dt       "$dtype_id" \
        --argjson role     "$role_id" \
        --argjson site     "$site_id" \
        --arg     serial   "$clean_serial" \
        --arg     comments "$comments" \
        '{name:$name,device_type:$dt,role:$role,site:$site,
          status:"active",serial:$serial,comments:$comments}')

    if [[ -z "$dev_id" ]]; then
        local api_resp
        api_resp=$(nb_post "dcim/devices/" "$payload")
        dev_id=$(echo "$api_resp" | jq -r '.id // empty' 2>/dev/null)
        if [[ -n "$dev_id" && "$dev_id" =~ ^[0-9]+$ ]]; then
            log_info "Created device: $name (ID: $dev_id)"
        else
            local err_detail
            err_detail=$(echo "$api_resp" \
                | jq -c '.detail // .name // .' 2>/dev/null | head -c 200)
            log_error "Device POST failed for $name: $err_detail"
            return 1
        fi
    else
        nb_patch "dcim/devices/${dev_id}/" "$payload" >/dev/null 2>&1
        log_info "Updated device: $name (ID: $dev_id)"
    fi
    echo "$dev_id"
}

nb_create_cable() {
    local a_id="$1" b_id="$2" label="${3:-}"
    nb_post "dcim/cables/" \
        "{\"a_terminations\":[{\"object_type\":\"dcim.interface\",\"object_id\":$a_id}],
          \"b_terminations\":[{\"object_type\":\"dcim.interface\",\"object_id\":$b_id}],
          \"label\":\"$label\"}" >/dev/null 2>&1 || true
}

# Idempotent custom field creator -- only POSTs if field does not yet exist
nb_ensure_custom_field() {
    local name="$1" label="$2" type="${3:-text}" obj_types="${4:-dcim.device}"
    local enc; enc=$(nb_urlencode "$name")
    local res; res=$(nb_get "extras/custom-fields/?name=${enc}")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        nb_post "extras/custom-fields/" \
            "$(jq -n --arg n "$name" --arg l "$label" --arg t "$type" \
                --argjson ot "[\"$obj_types\"]" \
                '{name:$n,label:$l,type:$t,object_types:$ot}')" \
            >/dev/null 2>&1 || true
    fi
}

nb_get_or_create_cluster_type() {
    local name="$1" slug enc res id
    slug=$(slugify "$name"); enc=$(nb_urlencode "$name")
    res=$(nb_get "virtualization/cluster-types/?name=${enc}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        res=$(nb_post "virtualization/cluster-types/" \
            "{\"name\":\"$name\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
        log_info "Created cluster type: $name (ID: $id)"
    fi
    echo "$id"
}

nb_get_or_create_cluster() {
    local name="$1" type_id="$2" site_id="$3" enc res id payload
    enc=$(nb_urlencode "$name")
    res=$(nb_get "virtualization/clusters/?name=${enc}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        payload=$(jq -n \
            --arg     name "$name" \
            --argjson type "$type_id" \
            --argjson site "$site_id" \
            '{name:$name,type:$type,site:$site}')
        res=$(nb_post "virtualization/clusters/" "$payload")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
        log_info "Created cluster: $name (ID: $id)"
    fi
    echo "$id"
}

nb_upsert_vm() {
    local name="$1" cluster_id="$2" status="${3:-active}" \
          vcpus="${4:-}" memory_mb="${5:-}" site_id="${6:-}" comments="${7:-}"
    local enc; enc=$(nb_urlencode "$name")
    local existing; existing=$(nb_get \
        "virtualization/virtual-machines/?name=${enc}")
    local vm_id; vm_id=$(echo "$existing" \
        | jq -r '.results[0].id // empty' 2>/dev/null)
    local payload
    payload=$(jq -n \
        --arg     name     "$name" \
        --argjson cluster  "$cluster_id" \
        --arg     status   "$status" \
        --arg     comments "$comments" \
        '{name:$name,cluster:$cluster,status:$status,comments:$comments}')
    [[ -n "$vcpus"     && "$vcpus"     =~ ^[0-9]+$ ]] \
        && payload=$(echo "$payload" | jq ".vcpus=$vcpus")
    [[ -n "$memory_mb" && "$memory_mb" =~ ^[0-9]+$ ]] \
        && payload=$(echo "$payload" | jq ".memory=$memory_mb")
    [[ -n "$site_id"   && "$site_id"   =~ ^[0-9]+$ ]] \
        && payload=$(echo "$payload" | jq ".site=$site_id")
    if [[ -z "$vm_id" ]]; then
        local api_resp
        api_resp=$(nb_post "virtualization/virtual-machines/" "$payload")
        vm_id=$(echo "$api_resp" | jq -r '.id // empty' 2>/dev/null)
        if [[ -n "$vm_id" && "$vm_id" =~ ^[0-9]+$ ]]; then
            log_info "Created VM: $name (ID: $vm_id)"
        else
            log_error "VM POST failed for $name: $(echo "$api_resp" \
                | jq -c '.detail // .name // .' 2>/dev/null | head -c 150)"
            return 1
        fi
    else
        nb_patch "virtualization/virtual-machines/${vm_id}/" \
            "$payload" >/dev/null 2>&1
        log_info "Updated VM: $name (ID: $vm_id)"
    fi
    echo "$vm_id"
}

nb_add_vm_interface() {
    local vm_id="$1" if_name="$2" mac="${3:-}" desc="${4:-}"
    local enc; enc=$(nb_urlencode "$if_name")
    local existing; existing=$(nb_get \
        "virtualization/interfaces/?virtual_machine_id=$vm_id&name=${enc}")
    local id; id=$(echo "$existing" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        local payload
        payload=$(jq -n \
            --argjson vm  "$vm_id" \
            --arg     name "$if_name" \
            --arg     mac  "$mac" \
            --arg     desc "$desc" \
            '{virtual_machine:$vm,name:$name,description:$desc,
              mac_address:(if $mac!="" and $mac!="null" then $mac else null end)}')
        local res; res=$(nb_post "virtualization/interfaces/" "$payload")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
    fi
    echo "$id"
}

# -----------------------------------------------------------------------------
# SNMP HELPERS  (top-level -- bash forbids "local func()")
# -----------------------------------------------------------------------------
_snmp_get() {
    local ip="$1" tok="$2" tout="$3" oid="$4"
    if [[ "$tok" == v3:* ]]; then
        local IFS=':'; read -r _ u ap ap2 pp pp2 <<< "$tok"
        snmpget -v3 -u "$u" -l authPriv \
            -a "$ap" -A "$ap2" -x "$pp" -X "$pp2" \
            -t "$tout" -r 1 "$ip" "$oid" 2>/dev/null | sed 's/.*: //' || true
    else
        snmpget -v2c -c "$tok" -t "$tout" -r 1 "$ip" "$oid" 2>/dev/null \
            | sed 's/.*: //' || true
    fi
}
_snmp_walk() {
    local ip="$1" tok="$2" tout="$3" oid="$4"
    if [[ "$tok" == v3:* ]]; then
        local IFS=':'; read -r _ u ap ap2 pp pp2 <<< "$tok"
        snmpwalk -v3 -u "$u" -l authPriv \
            -a "$ap" -A "$ap2" -x "$pp" -X "$pp2" \
            -t "$tout" -r 1 "$ip" "$oid" 2>/dev/null || true
    else
        snmpwalk -v2c -c "$tok" -t "$tout" -r 1 "$ip" "$oid" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# TARGET PARSING  (multi-subnet support)
# parse_targets: normalises any mix of CIDRs, IPs, and file paths into an
# array of individual scan targets printed one-per-line to stdout.
# Supports: "192.168.0.0/24,10.0.0.0/8" or "/path/to/subnets.txt"
# File format: one target per line; # comments; blank lines ignored;
#              inline comments supported; leading/trailing whitespace stripped.
# -----------------------------------------------------------------------------
parse_targets() {
    local raw="$1"
    python3 - "$raw" <<'PYEOF'
import sys, os, re, ipaddress

raw = sys.argv[1].strip()
targets = []

def add_target(t):
    t = t.strip()
    if not t or t.startswith('#'):
        return
    # Remove inline comments
    t = t.split('#')[0].strip()
    if not t:
        return
    try:
        net = ipaddress.ip_network(t, strict=False)
        # Always include prefix length so _do_host_discovery CIDR filter
        # fires correctly; bare IPs become explicit /32 targets
        targets.append(str(net))
        return
    except ValueError:
        pass
    try:
        ipaddress.ip_address(t)
        targets.append(t + '/32')
        return
    except ValueError:
        pass

# Check if the input is a file
if os.path.isfile(raw):
    with open(raw) as f:
        for line in f:
            add_target(line)
else:
    # Split on commas and whitespace
    for part in re.split(r'[,\s]+', raw):
        add_target(part)

# Deduplicate while preserving order
seen = set()
for t in targets:
    if t not in seen:
        seen.add(t)
        print(t)
PYEOF
}

# expand_host_file: reads a host file containing IPs and/or CIDRs (with
# comments and whitespace), writes individual host IPs to LIVE_HOSTS_FILE.
expand_host_file() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import sys, ipaddress

results = []
with open(sys.argv[1]) as f:
    for raw_line in f:
        line = raw_line.split('#')[0].strip()
        if not line:
            continue
        try:
            net = ipaddress.ip_network(line, strict=False)
            if net.num_addresses == 1:
                results.append(str(net.network_address))
            else:
                for host in net.hosts():
                    results.append(str(host))
        except ValueError:
            try:
                ipaddress.ip_address(line)
                results.append(line)
            except ValueError:
                pass

# Deduplicate, preserve order
seen = set()
for ip in results:
    if ip not in seen:
        seen.add(ip)
        print(ip)
PYEOF
}

# -----------------------------------------------------------------------------
# DISCOVERY ENGINE
# -----------------------------------------------------------------------------
DISC_RESULTS=""
LIVE_HOSTS_FILE="$DISCOVERY_DIR/live_hosts.txt"

init_scan_session() {
    DISC_RESULTS="$DISCOVERY_DIR/results_$(date +%Y%m%d_%H%M%S).json"
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tgt "$1" \
        '{scan_time:$ts,target:$tgt,hosts:[]}' > "$DISC_RESULTS"
    log_info "Session: $DISC_RESULTS"
}
append_host() {
    local tmp; tmp=$(mktemp)
    jq ".hosts += [$1]" "$DISC_RESULTS" > "$tmp" && mv "$tmp" "$DISC_RESULTS"
}

# ?? Multi-target wrapper ??????????????????????????????????????????????????????
# Runs discover_live_hosts for each target, then deduplicates the combined
# result so Phase 2 scans each unique host exactly once.
discover_targets() {
    local targets=("$@")
    local combined; combined=$(mktemp)
    > "$LIVE_HOSTS_FILE"

    local t
    for t in "${targets[@]}"; do
        log_step "Phase 1 -- Host Discovery: $t"
        local tmp_hosts; tmp_hosts=$(mktemp)
        _do_host_discovery "$t" "$tmp_hosts"
        cat "$tmp_hosts" >> "$combined"
        rm -f "$tmp_hosts"
    done

    # Dedup and sort combined result
    sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -u "$combined" \
        > "$LIVE_HOSTS_FILE"
    rm -f "$combined"

    local count; count=$(wc -l < "$LIVE_HOSTS_FILE")
    log_ok "Phase 1 complete -- $count unique live hosts across all targets"
    printf "\n  ${G}Total found: ${W}%s hosts${NC}\n" "$count"
}

# Internal: runs all host-discovery probes for a single target, writes results
# to the provided output file.
_do_host_discovery() {
    local target="$1" out_file="$2"
    local tmp_all; tmp_all=$(mktemp)

    printf "  ${W}ARP scan${NC} .................. "
    if cmd_exists arp-scan; then
        arp-scan --localnet --quiet 2>/dev/null \
            | awk '/^[0-9]/{print $1}' >> "$tmp_all"
        arp-scan "$target" --quiet 2>/dev/null \
            | awk '/^[0-9]/{print $1}' >> "$tmp_all" 2>/dev/null || true
        printf "${G}done${NC}\n"
    else printf "${Y}skipped${NC}\n"; fi

    printf "  ${W}fping ICMP sweep${NC} .......... "
    if cmd_exists fping; then
        fping -a -g "$target" 2>/dev/null >> "$tmp_all" || true
        printf "${G}done${NC}\n"
    else printf "${Y}skipped${NC}\n"; fi

    printf "  ${W}nmap ping sweep${NC} ........... "
    if cmd_exists nmap; then
        nmap -sn -PE -PS22,80,443,8080 -PA80,443 \
            --host-timeout 10s "$target" -oG - 2>/dev/null \
            | awk '/Up$/{print $2}' >> "$tmp_all"
        printf "${G}done${NC}\n"
    else printf "${Y}skipped${NC}\n"; fi

    printf "  ${W}masscan${NC} ................... "
    if cmd_exists masscan; then
        masscan "$target" -p22,80,443,8080,161,23 \
            --rate=2000 --wait 2 -oG - 2>/dev/null \
            | awk '/open/{print $6}' >> "$tmp_all" || true
        printf "${G}done${NC}\n"
    else printf "${Y}skipped${NC}\n"; fi

    printf "  ${W}SNMP sweep${NC} ................ "
    local comm
    while IFS= read -r comm; do
        fping -a -g "$target" 2>/dev/null | while read -r ip; do
            snmpget -v2c -c "$comm" -t 1 -r 0 "$ip" \
                1.3.6.1.2.1.1.1.0 &>/dev/null && echo "$ip" >> "$tmp_all"
        done &
    done < <(get_communities_for "0.0.0.0")
    wait; printf "${G}done${NC}\n"

    printf "  ${W}mDNS/Bonjour${NC} .............. "
    if cmd_exists avahi-browse; then
        timeout 8 avahi-browse -atr --no-fail 2>/dev/null \
            | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' >> "$tmp_all" || true
        printf "${G}done${NC}\n"
    else printf "${Y}skipped${NC}\n"; fi

    printf "  ${W}NetBIOS scan${NC} .............. "
    if cmd_exists nbtscan; then
        nbtscan -q "$target" 2>/dev/null \
            | awk '/^[0-9]/{print $1}' >> "$tmp_all" || true
        printf "${G}done${NC}\n"
    else printf "${Y}skipped${NC}\n"; fi

    printf "  ${W}ARP cache (passive)${NC} ....... "
    ip neigh show 2>/dev/null | awk '/REACHABLE|STALE|DELAY/{print $1}' \
        >> "$tmp_all"
    arp -n 2>/dev/null | awk 'NR>1&&$3!="(incomplete)"{print $1}' >> "$tmp_all"
    printf "${G}done${NC}\n"

    # Filter to target CIDR + dedup + validate
    sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -u "$tmp_all" \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        | while IFS= read -r ip; do valid_ip "$ip" && echo "$ip"; done \
        > "$out_file"
    rm -f "$tmp_all"

    # Filter to requested CIDR only (removes docker-bridge / host IPs)
    if valid_cidr "$target"; then
        python3 - "$target" "$out_file" <<'PYEOF'
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
with open(sys.argv[2]) as f:
    kept = [l.strip() for l in f
            if l.strip() and ipaddress.ip_address(l.strip()) in net]
with open(sys.argv[2], 'w') as f:
    f.write('\n'.join(kept) + ('\n' if kept else ''))
PYEOF
    fi

    local count; count=$(wc -l < "$out_file")
    log_info "$target: $count hosts"
}

# Legacy single-target wrapper (used internally and by --auto-scan)
discover_live_hosts() {
    local target="$1"
    discover_targets "$target"
}

# ?? Phase 2: Deep scan ????????????????????????????????????????????????????????
scan_all_hosts() {
    local total; total=$(wc -l < "$LIVE_HOSTS_FILE")
    log_step "Phase 2 -- Deep Scanning $total Hosts"
    local idx=0 ip
    while IFS= read -r ip <&3; do
        (( idx++ )) || true
        printf "\n  ${C}[%d/%d]${NC} ${W}%s${NC}\n" "$idx" "$total" "$ip"
        scan_single_host "$ip"
    done 3< "$LIVE_HOSTS_FILE"
    log_ok "Phase 2 complete"
}

scan_single_host() {
    local ip="$1"
    local tmp; tmp=$(mktemp -d)
    probe_nmap    "$ip" "$tmp" </dev/null &
    probe_snmp    "$ip" "$tmp" </dev/null &
    probe_ssh     "$ip" "$tmp" </dev/null &
    probe_http    "$ip" "$tmp" </dev/null &
    probe_netbios "$ip" "$tmp" </dev/null &
    probe_dns     "$ip" "$tmp" </dev/null &
    probe_banners "$ip" "$tmp" </dev/null &
    probe_mdns    "$ip" "$tmp" </dev/null &
    probe_winrm   "$ip" "$tmp" </dev/null &
    wait
    local host_json
    host_json=$(merge_host_data "$ip" "$tmp")
    append_host "$host_json"
    local hn role os
    hn=$(echo "$host_json"   | jq -r '.hostname // "?"')
    role=$(echo "$host_json" | jq -r '.device_role // "?"')
    os=$(echo "$host_json"   | jq -r '.os // ""')
    printf "    ${G}OK${NC}  %-16s  %-28s  %-16s  %s\n" "$ip" "$hn" "$role" "$os"
    rm -rf "$tmp"
}

# ?? Probe: nmap ???????????????????????????????????????????????????????????????
probe_nmap() {
    local ip="$1" tmp="$2"
    local xml="$tmp/nmap.xml"
    local nmap_ports="21-23,25,53,80,110,139,143,443,445,512-514,587,623,631,\
830,1433,1521,3306,3389,5432,5900,5901,5985,5986,6379,\
8080,8291,8443,8728-8729,8888,9100,9200,9300,10443,27017"

    # Use RustScan when available: scans all 65535 ports fast, hands
    # found ports to nmap for service/version detection
    if cmd_exists rustscan; then
        local rs_raw rs_ports
        # Merge stderr+stdout: Docker routes the "Open IP:PORT" lines to
        # stderr alongside the banner. --accessible strips ANSI color codes.
        # --no-nmap removed in v2.1.1; "-- -sn" passes ping-only flag to
        # nmap so it exits fast; RustScan Open IP:PORT lines appear first
        rs_raw=$(rustscan --addresses "$ip" --ulimit 5000 \
            --range 1-65535 --accessible -- -sn 2>&1) || true
        rs_ports=$(printf "%s\n" "$rs_raw" \
            | grep -oP "Open [^:]+:\K[0-9]+" \
            | sort -un | tr "\n" "," | sed "s/,$//" ) || true
        [[ -n "$rs_ports" ]] && nmap_ports="$rs_ports"
        log_info "RustScan found ports: ${rs_ports:-none}"
        # Log raw output at trace level for diagnosis
        echo "[TRACE] rustscan raw: $rs_raw" >> "$LOG_FILE" 2>/dev/null || true
    fi

    nmap -sV -O --osscan-guess \
        -p "$nmap_ports" \
        --script "banner,ssh-hostkey,snmp-info,\
http-title,http-server-header,ssl-cert,\
nbstat,smb-security-mode,dns-service-discovery,\
ms-sql-info,mysql-info,mongodb-info,\
rdp-enum-encryption,vnc-info" \
        -T4 --host-timeout 90s --max-retries 2 \
        -oX "$xml" "$ip" >> "$LOG_FILE" 2>&1 || true
    python3 /dev/stdin "$xml" <<'PYEOF' > "$tmp/nmap.json" 2>/dev/null
import xml.etree.ElementTree as ET, json, sys
def parse(f):
    r = {"ports":[],"os":None,"os_accuracy":None,
         "mac":None,"vendor":None,"hostname":None,"scripts":{}}
    try: tree = ET.parse(f)
    except: return r
    for host in tree.findall('host'):
        for hn in (host.find('hostnames') or []):
            if hn.get('type') == 'PTR': r['hostname'] = hn.get('name')
            elif not r['hostname']:     r['hostname'] = hn.get('name')
        for addr in host.findall('address'):
            if addr.get('addrtype') == 'mac':
                r['mac'] = addr.get('addr'); r['vendor'] = addr.get('vendor','')
        os_el = host.find('os')
        if os_el:
            for m in os_el.findall('osmatch'):
                r['os'] = m.get('name'); r['os_accuracy'] = m.get('accuracy'); break
        for port in (host.find('ports') or []):
            st = port.find('state')
            if st is None or st.get('state') != 'open': continue
            p = {'port':port.get('portid'),'proto':port.get('protocol'),
                 'service':None,'version':None,'banner':None,'scripts':{}}
            svc = port.find('service')
            if svc:
                p['service'] = svc.get('name','')
                p['version'] = (svc.get('product','')+' '+svc.get('version','')).strip()
            for sc in port.findall('script'):
                out = (sc.get('output','') or '')[:300]
                p['scripts'][sc.get('id','')] = out
                if sc.get('id','') == 'banner': p['banner'] = out
            r['ports'].append(p)
        for sc in host.findall('hostscript/script'):
            r['scripts'][sc.get('id','')] = (sc.get('output','') or '')[:300]
    return r
print(json.dumps(parse(sys.argv[1])))
PYEOF
}

# ?? Probe: SNMP ???????????????????????????????????????????????????????????????
probe_snmp() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/snmp.json"
    local communities; communities=$(get_communities_for "$ip")
    local tok="" comm
    while IFS= read -r comm; do
        snmpget -v2c -c "$comm" -t "$SNMP_TIMEOUT" -r 1 \
            "$ip" 1.3.6.1.2.1.1.1.0 &>/dev/null && { tok="$comm"; break; }
    done <<< "$communities"
    if [[ -z "$tok" ]]; then
        local creds; creds=$(read_creds)
        local v3c
        while IFS= read -r v3c; do
            local v3u v3ap v3ap2 v3pp v3pp2
            v3u=$(echo "$v3c"    | jq -r '.username')
            v3ap=$(echo "$v3c"   | jq -r '.auth_proto // "SHA"')
            v3ap2=$(echo "$v3c"  | jq -r '.auth_pass')
            v3pp=$(echo "$v3c"   | jq -r '.priv_proto // "AES"')
            v3pp2=$(echo "$v3c"  | jq -r '.priv_pass')
            snmpget -v3 -u "$v3u" -l authPriv \
                -a "$v3ap" -A "$v3ap2" -x "$v3pp" -X "$v3pp2" \
                -t "$SNMP_TIMEOUT" -r 1 "$ip" 1.3.6.1.2.1.1.1.0 &>/dev/null \
                && { tok="v3:${v3u}:${v3ap}:${v3ap2}:${v3pp}:${v3pp2}"; break; }
        done < <(echo "$creds" | jq -c '.snmp_v3[]' 2>/dev/null || true)
    fi
    [[ -z "$tok" ]] && return

    local t="$tok" ts="$SNMP_TIMEOUT"
    local sys_descr sys_name sys_loc sys_contact sys_uptime sys_oid chassis_ser
    sys_descr=$(   _snmp_get "$ip" "$t" "$ts" 1.3.6.1.2.1.1.1.0)
    sys_name=$(    _snmp_get "$ip" "$t" "$ts" 1.3.6.1.2.1.1.5.0)
    sys_loc=$(     _snmp_get "$ip" "$t" "$ts" 1.3.6.1.2.1.1.6.0)
    sys_contact=$( _snmp_get "$ip" "$t" "$ts" 1.3.6.1.2.1.1.4.0)
    sys_uptime=$(  _snmp_get "$ip" "$t" "$ts" 1.3.6.1.2.1.1.3.0)
    sys_oid=$(     _snmp_get "$ip" "$t" "$ts" 1.3.6.1.2.1.1.2.0)
    chassis_ser=$( _snmp_get "$ip" "$t" "$ts" 1.3.6.1.2.1.47.1.1.1.1.11.1)
    # Clear SNMP error strings from serial (v2.0.9)
    if [[ "$chassis_ser" == *"No Such"* || "$chassis_ser" == iso.* \
          || "$chassis_ser" == *"not available"* ]]; then
        chassis_ser=""
    fi

    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.2.1.2.2         > "$tmp/snmp_ifaces.txt"
    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.2.1.47.1.1.1.1  > "$tmp/snmp_entity.txt"
    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.2.1.17.4.3.1    > "$tmp/snmp_mac.txt"
    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.2.1.17.1.4.1.2  > "$tmp/snmp_bport.txt"
    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.2.1.4.22.1       > "$tmp/snmp_arp.txt"
    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.2.1.4.20.1       > "$tmp/snmp_iptable.txt"
    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.2.1.17.7.1.4.5.1.1 > "$tmp/snmp_pvid.txt"
    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.4.1.9.9.46.1.3.1.1.2 > "$tmp/snmp_vlannames.txt"
    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.4.1.9.9.23.1.2.1.1 > "$tmp/snmp_cdp.txt"
    _snmp_walk "$ip" "$t" "$ts" 1.0.8802.1.1.2.1.4       > "$tmp/snmp_lldp.txt"

    python3 /dev/stdin \
        "$tmp" "$tok" \
        "${sys_descr:-}" "${sys_name:-}" "${sys_loc:-}" \
        "${sys_contact:-}" "${sys_uptime:-}" "${sys_oid:-}" \
        "${chassis_ser:-}" \
        <<'PYEOF' > "$tmp/snmp.json" 2>/dev/null
import re, json, sys, os
tmp=sys.argv[1]; working_token=sys.argv[2]
sys_descr=sys.argv[3].strip().strip('"'); sys_name=sys.argv[4].strip().strip('"')
sys_loc=sys.argv[5].strip().strip('"');   sys_contact=sys.argv[6].strip().strip('"')
sys_uptime=sys.argv[7].strip();           sys_oid=sys.argv[8].strip()
chassis_ser=sys.argv[9].strip().strip('"')
# Normalize sys_oid: snmpget may return 'iso.3.6.1.4.1.X' instead of '1.3.6.1.4.1.X'
if sys_oid.startswith('iso.'): sys_oid='1.'+sys_oid[4:]
# Clear fields that contain raw snmpget OID lines rather than actual values
# (happens when device returns empty/no value, e.g. FortiGate empty sysDescr)
def _is_raw_oid(v): return v.startswith('iso.') or (v.startswith('1.3.6.') and '=' in v)
if _is_raw_oid(sys_descr):    sys_descr=''
if _is_raw_oid(chassis_ser):  chassis_ser=''
if _is_raw_oid(sys_name):     sys_name=''

def rf(n):
    p=os.path.join(tmp,n)
    return open(p).read() if os.path.exists(p) else ''

ifaces_raw=rf('snmp_ifaces.txt'); mac_table_raw=rf('snmp_mac.txt')
bport_raw=rf('snmp_bport.txt');   arp_table_raw=rf('snmp_arp.txt')
ip_table_raw=rf('snmp_iptable.txt'); pvid_raw=rf('snmp_pvid.txt')
vlan_name_raw=rf('snmp_vlannames.txt')
cdp_raw=rf('snmp_cdp.txt'); lldp_raw=rf('snmp_lldp.txt')
entity_raw=rf('snmp_entity.txt')

ifaces={}
for line in ifaces_raw.split('\n'):
    idx_m=re.search(r'(\d+)\s*=',line)
    if not idx_m: continue
    idx=idx_m.group(1)
    v=re.search(r'=\s*(?:STRING|INTEGER|Gauge32|Counter32|PhysAddress):\s*(.*)',line)
    if not v: continue
    val=v.group(1).strip().strip('"')
    if idx not in ifaces: ifaces[idx]={}
    if '2.2.1.2.'  in line: ifaces[idx]['name']        =val
    elif '2.2.1.3.' in line: ifaces[idx]['type']       =val
    elif '2.2.1.6.' in line: ifaces[idx]['mac']        =val
    elif '2.2.1.7.' in line: ifaces[idx]['admin_status']=val
    elif '2.2.1.8.' in line: ifaces[idx]['oper_status'] =val
    elif '2.2.1.5.' in line: ifaces[idx]['speed']       =val
interfaces=[{'index':k,**v} for k,v in ifaces.items() if 'name' in v]

port_to_if={}
for line in bport_raw.split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)',line)
    if m: port_to_if[m.group(1)]=m.group(2)

mac_port_map=[]
for line in mac_table_raw.split('\n'):
    m=re.match(r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)',line)
    if m:
        mac=':'.join('{:02x}'.format(int(o)) for o in m.group(1).split('.'))
        bp=m.group(2); ii=port_to_if.get(bp,bp)
        mac_port_map.append({'mac':mac,'port_index':bp,'if_index':ii,
            'if_name':ifaces.get(ii,{}).get('name','Port-'+ii)})

arp_entries=[]
for line in arp_table_raw.split('\n'):
    m=re.match(r'.*4\.22\.1\.2\.\d+\.(\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)',line)
    if m: arp_entries.append({'ip':m.group(1),'if_index':m.group(2)})

ip_if_map={}; ip_mask_map={}
for line in ip_table_raw.split('\n'):
    m=re.match(r'.*4\.20\.1\.2\.(\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)',line)
    if m: ip_if_map[m.group(1)]=m.group(2)
    m=re.match(r'.*4\.20\.1\.3\.(\d+\.\d+\.\d+\.\d+)\s*=\s*IpAddress:\s*(\S+)',line)
    if m: ip_mask_map[m.group(1)]=m.group(2)
ip_table=[{'ip':ip,'if_index':idx,'mask':ip_mask_map.get(ip,'255.255.255.0')}
          for ip,idx in ip_if_map.items()]

vlan_pvid={}
for line in pvid_raw.split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*(?:Gauge32|INTEGER|Unsigned32):\s*(\d+)',line)
    if m: vlan_pvid[m.group(1)]=m.group(2)

vlan_names={}
for line in vlan_name_raw.split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)',line)
    if m: vlan_names[m.group(1)]=m.group(2).strip().strip('"')

for entry in mac_port_map:
    bp=entry['port_index']; ii=entry['if_index']
    entry['vlan']=vlan_pvid.get(bp,vlan_pvid.get(ii,''))
    entry['vlan_name']=vlan_names.get(entry['vlan'],'')
    entry['remote_ip']=next((a['ip'] for a in arp_entries if a['if_index']==ii),'')

cdp_devs={}
for line in cdp_raw.split('\n'):
    for sfx,fld in [('.6.','device_id'),('.8.','platform'),('.7.','remote_port')]:
        m=re.match(r'.*'+re.escape(sfx)+r'(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)',line)
        if m:
            key='{}_{}'.format(m.group(1),m.group(2))
            cdp_devs.setdefault(key,{})[fld]=m.group(3).strip().strip('"')
cdp_neighbors=list(cdp_devs.values())

# Parse entity MIB walk: col 2=desc 7=name 10=sw_rev 11=serial 13=model
_ent={}
for _line in entity_raw.split('\n'):
    _m=re.search(r'47\.1\.1\.1\.1\.(\d+)\.(\d+)\s*=\s*(?:STRING|OID):\s*(.*)',_line)
    if not _m: continue
    _col,_idx,_val=_m.group(1),_m.group(2),_m.group(3).strip().strip('"').strip("'")
    if _is_raw_oid(_val): _val=''
    _ent.setdefault(_idx,{})
    {'2':'desc','7':'name','10':'sw_rev','11':'serial','13':'model'}.get(_col) and \
        _ent[_idx].__setitem__({'2':'desc','7':'name','10':'sw_rev','11':'serial','13':'model'}[_col],_val)
entity_inventory=[{'desc':v.get('desc',''),'name':v.get('name',''),
    'model':v.get('model',''),'serial':v.get('serial',''),
    'sw_rev':v.get('sw_rev','')} for v in _ent.values() if any(v.values())]

lldp_sys={}
for line in lldp_raw.split('\n'):
    m=re.match(r'.*\.(\d+)\.(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)',line)
    if not m: continue
    lp,ri,val=m.group(2),m.group(3),m.group(4).strip().strip('"')
    key='{}_{}'.format(lp,ri); lldp_sys.setdefault(key,{})
    if '4.1.1.9'  in line: lldp_sys[key]['sys_name'] =val
    if '4.1.1.10' in line: lldp_sys[key]['sys_desc'] =val[:100]
    if '4.1.1.7'  in line: lldp_sys[key]['port_id']  =val
    if '4.1.1.8'  in line: lldp_sys[key]['port_desc']=val
lldp_neighbors=list(lldp_sys.values())

print(json.dumps({'available':True,'community':working_token,
    'sys_descr':sys_descr,'sys_name':sys_name,'sys_location':sys_loc,
    'sys_contact':sys_contact,'sys_uptime':sys_uptime,'sys_oid':sys_oid,
    'chassis_serial':chassis_ser,'interfaces':interfaces,'ip_table':ip_table,
    'mac_port_map':mac_port_map,'vlan_pvid':vlan_pvid,'vlan_names':vlan_names,
    'arp_entries':arp_entries,'cdp_neighbors':cdp_neighbors,
    'lldp_neighbors':lldp_neighbors,'entity_inventory':entity_inventory}))
PYEOF
}

# ?? Probe: SSH ????????????????????????????????????????????????????????????????
probe_ssh() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/ssh.json"
    nc -z -w "$SCAN_TIMEOUT" "$ip" 22 2>/dev/null || return
    local banner
    banner=$(nc -w 3 "$ip" 22 2>/dev/null | head -1 | tr -dc '[:print:]')
    local ssh_opts=(-o StrictHostKeyChecking=no
        -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes
        -o LogLevel=error -o UserKnownHostsFile=/dev/null
        -o PreferredAuthentications=publickey,password)
    local remote_cmd
    remote_cmd='printf "HN=%s\n" "$(hostname)"; uname -a; \
cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null; \
ip addr 2>/dev/null || ifconfig; lscpu 2>/dev/null | head -5; \
free -h 2>/dev/null | head -2'
    local sys_info="" cred
    while IFS= read -r cred; do
        [[ -z "$cred" || "$cred" == "null" ]] && continue
        local su sp sk
        su=$(echo "$cred" | jq -r '.username  // empty')
        sp=$(echo "$cred" | jq -r '.password  // empty')
        sk=$(echo "$cred" | jq -r '.key_file  // empty')
        [[ -z "$su" ]] && continue
        local opts=("${ssh_opts[@]}")
        [[ -n "$sk" && -f "$sk" ]] && opts+=(-i "$sk")
        if [[ -n "$sp" ]]; then
            sys_info=$(sshpass -p "$sp" ssh "${opts[@]}" \
                "${su}@${ip}" "$remote_cmd" 2>/dev/null || true)
        else
            sys_info=$(ssh "${opts[@]}" "${su}@${ip}" "$remote_cmd" 2>/dev/null || true)
        fi
        [[ -n "$sys_info" ]] && break
    done < <(get_ssh_creds_for "$ip")
    jq -n \
        --arg banner "$banner" \
        --arg hn     "$(echo "$sys_info" | grep '^HN=' | cut -d= -f2)" \
        --arg os     "$(echo "$sys_info" | grep -m1 'PRETTY_NAME=\|ProductName:' \
                         | sed 's/.*=//;s/.*: //' | tr -d '"')" \
        --arg kernel "$(echo "$sys_info" | grep '^Linux\|^Darwin' | head -1)" \
        --arg cpu    "$(echo "$sys_info" | grep -i 'model name\|CPU' \
                         | head -1 | sed 's/.*: //')" \
        '{available:true,banner:$banner,hostname:$hn,os:$os,
          kernel:$kernel,cpu:$cpu}' > "$tmp/ssh.json"
}

# ?? Probe: HTTP/HTTPS ?????????????????????????????????????????????????????????
probe_http() {
    local ip="$1" tmp="$2"
    local svc_file="$tmp/http_svcs.ndjson"; > "$svc_file"
    local port
    for port in 80 443 8080 8443 8000 8888 3000 5000 9090 9443 4443; do
        local proto="http"
        [[ "$port" =~ ^(443|8443|9443|4443)$ ]] && proto="https"
        local hdr="$tmp/h${port}.txt"
        curl -skL --max-time "$SCAN_TIMEOUT" --max-redirs 3 \
            -A "NetBox-Discovery/2.1" -D "$hdr" \
            "${proto}://${ip}:${port}/" > "$tmp/b${port}.html" 2>/dev/null \
            || continue
        [[ ! -f "$hdr" ]] && continue
        local status server title cert_cn=""
        status=$(head -1 "$hdr" | awk '{print $2}')
        server=$(grep -i '^Server:' "$hdr" | head -1 | cut -d' ' -f2- | tr -d '\r')
        title=$(grep -oi '<title[^>]*>[^<]*</title>' "$tmp/b${port}.html" \
            | sed 's/<[^>]*>//g' | head -1 | xargs 2>/dev/null || true)
        if [[ "$proto" == "https" ]]; then
            cert_cn=$(echo | openssl s_client -connect "${ip}:${port}" \
                -servername "$ip" 2>/dev/null \
                | openssl x509 -noout -subject 2>/dev/null \
                | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 || true)
        fi
        jq -n --argjson port "$port" --arg proto "$proto" \
            --arg status "${status:-?}" --arg server "$server" \
            --arg title "$title" --arg cert_cn "${cert_cn:-}" \
            '{port:$port,proto:$proto,status:$status,server:$server,
              title:$title,cert_cn:$cert_cn}' >> "$svc_file"
    done
    if [[ -s "$svc_file" ]]; then
        jq -s '{http_services:.}' "$svc_file" > "$tmp/http.json" 2>/dev/null \
            || echo '{"http_services":[]}' > "$tmp/http.json"
    else echo '{"http_services":[]}' > "$tmp/http.json"; fi
}

# ?? Probe: NetBIOS ????????????????????????????????????????????????????????????
probe_netbios() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/netbios.json"
    cmd_exists nmblookup || return
    nc -z -w 2 "$ip" 139 2>/dev/null \
        || nc -z -w 2 "$ip" 445 2>/dev/null || return
    local nb_raw; nb_raw=$(nmblookup -A "$ip" 2>/dev/null || true)
    [[ -z "$nb_raw" ]] && return
    jq -n \
        --arg name "$(echo "$nb_raw" | awk '/<00>/ && !/GROUP/{print $1;exit}')" \
        --arg wg   "$(echo "$nb_raw" | awk '/<00>.*GROUP/{print $1;exit}')" \
        '{available:true,netbios_name:$name,workgroup:$wg}' \
        > "$tmp/netbios.json"
}

# ?? Probe: DNS ????????????????????????????????????????????????????????????????
probe_dns() {
    local ip="$1" tmp="$2"
    local ptr
    ptr=$(dig +short +time=3 +tries=1 -x "$ip" 2>/dev/null \
        | head -1 | sed 's/\.$//' || true)
    jq -n --arg ptr "$ptr" '{ptr_hostname:$ptr}' > "$tmp/dns.json"
}

# ?? Probe: Banner grab ????????????????????????????????????????????????????????
probe_banners() {
    local ip="$1" tmp="$2"
    local bnr_file="$tmp/banners.ndjson"; > "$bnr_file"
    local port
    for port in 21 23 25 110 143 515 631 5060; do
        local b
        b=$(timeout 3 bash -c \
            "printf '' | nc -w 3 $ip $port 2>/dev/null \
             | head -1 | tr -dc '[:print:]'" 2>/dev/null || true)
        [[ -n "$b" && ${#b} -gt 4 ]] \
            && jq -n --argjson p "$port" --arg b "$b" \
               '{port:$p,banner:$b}' >> "$bnr_file"
    done
    if [[ -s "$bnr_file" ]]; then
        jq -s '{banners:.}' "$bnr_file" > "$tmp/banners.json" 2>/dev/null \
            || echo '{"banners":[]}' > "$tmp/banners.json"
    else echo '{"banners":[]}' > "$tmp/banners.json"; fi
}

# ?? Probe: mDNS ???????????????????????????????????????????????????????????????
probe_mdns() {
    local ip="$1" tmp="$2"
    local n=""
    cmd_exists avahi-resolve \
        && n=$(avahi-resolve -a "$ip" 2>/dev/null | awk '{print $2}' || true)
    jq -n --arg n "$n" '{mdns_hostname:$n}' > "$tmp/mdns.json"
}

# -- WinRM / Windows discovery -----------------------------------------------
probe_winrm() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/winrm.json"
    local port=5985 proto="http"
    if nc -z -w 2 "$ip" 5985 2>/dev/null; then
        port=5985; proto="http"
    elif nc -z -w 2 "$ip" 5986 2>/dev/null; then
        port=5986; proto="https"
    else
        return
    fi
    if ! python3 -c "import winrm" 2>/dev/null; then
        log_debug "pywinrm not installed -- skipping WinRM probe for $ip"
        return
    fi
    local win_creds; win_creds=$(get_windows_creds_for "$ip")
    [[ "${win_creds:-[]}" == "[]" ]] && return
    local creds_tmp; creds_tmp=$(mktemp --suffix=.json)
    echo "$win_creds" > "$creds_tmp"
    python3 /dev/stdin \
        "$ip" "$port" "$proto" "$creds_tmp" "$tmp/winrm.json" \
        <<'PYEOF' 2>/dev/null
import sys, json
try:
    import winrm as _winrm
except ImportError:
    sys.exit(0)
ip, port, proto, creds_file, out_file = sys.argv[1:6]
try:
    creds = json.load(open(creds_file))
except Exception:
    creds = []
PS_DISCOVER = r"""
$ErrorActionPreference = "SilentlyContinue"
$cs   = Get-CimInstance Win32_ComputerSystem  2>$null
$os   = Get-CimInstance Win32_OperatingSystem 2>$null
$bios = Get-CimInstance Win32_BIOS            2>$null
$cpu  = Get-CimInstance Win32_Processor 2>$null | Select-Object -First 1
$nics = Get-NetAdapter -Physical 2>$null | Where-Object { $_.Status -eq "Up" } |
        ForEach-Object {
            $if = $_
            $v4 = Get-NetIPAddress -InterfaceIndex $if.ifIndex 2>$null |
                  Where-Object { $_.AddressFamily -eq "IPv4" -and $_.IPAddress -ne "127.0.0.1" }
            [ordered]@{ Name=$if.Name; Description=$if.InterfaceDescription;
                        MacAddress=($if.MacAddress -replace "-",":").ToUpper();
                        IPAddresses=@($v4.IPAddress); PrefixLens=@([int[]]$v4.PrefixLength) }
        }
$isHyperV = $false
try { $isHyperV = ($null -ne (Get-Command Get-VM -ErrorAction SilentlyContinue)) } catch {}
[ordered]@{ Hostname=$cs.Name; Domain=$cs.Domain; Manufacturer=$cs.Manufacturer;
            Model=$cs.Model; SerialNumber=$bios.SerialNumber; OS=$os.Caption;
            OSVersion=$os.Version; IsServer=($os.ProductType -ne 1);
            IsHyperV=$isHyperV;
            CPUName=$cpu.Name; CPUCores=[int]$cpu.NumberOfCores;
            MemoryGB=[math]::Round($cs.TotalPhysicalMemory/1GB,2);
            NetworkAdapters=@($nics) } | ConvertTo-Json -Depth 4
"""
result = None
for cred in creds:
    username = cred.get("username","")
    password = cred.get("password","")
    domain   = (cred.get("domain") or "").strip()
    if not username: continue
    auth_user = f"{domain}\\{username}" if (domain and "\\" not in username and "@" not in username) else username
    try:
        sess = _winrm.Session(f"{proto}://{ip}:{port}/wsman",
            auth=(auth_user,password), transport="ntlm",
            server_cert_validation="ignore",
            operation_timeout_sec=30, read_timeout_sec=35)
        r = sess.run_ps(PS_DISCOVER)
        if r.status_code==0 and r.std_out:
            data = json.loads(r.std_out.decode("utf-8","replace").strip())
            data.update({"available":True,"auth_user":auth_user,"winrm_port":int(port)})
            result = data; break
    except Exception: continue
with open(out_file,"w") as f:
    json.dump(result or {"available":False}, f)
PYEOF
    rm -f "$creds_tmp"
}

# ?? Merge probe data ??????????????????????????????????????????????????????????
merge_host_data() {
    local ip="$1" tmp="$2"
    python3 /dev/stdin "$ip" "$tmp" <<'PYEOF'
import json, os, sys
ip=sys.argv[1]; tmp=sys.argv[2]
def load(f):
    p=os.path.join(tmp,f+'.json')
    try: return json.load(open(p)) if os.path.exists(p) else {}
    except: return {}
nmap=load('nmap'); snmp=load('snmp'); ssh=load('ssh')
http=load('http'); nb=load('netbios'); dns=load('dns')
bnr=load('banners'); mdns=load('mdns'); winrm=load('winrm')

host={'ip':ip,'hostname':None,'mac':None,'vendor':None,
      'os':None,'os_accuracy':None,
      'device_role':'Endpoint','manufacturer':'Unknown','model':'Unknown',
      'serial':'','winrm_nics':[],'scan_tier':4,'is_hyperv':False,
      'ports':nmap.get('ports',[]),'interfaces':snmp.get('interfaces',[]),
      'ip_table':snmp.get('ip_table',[]),'mac_port_map':snmp.get('mac_port_map',[]),
      'vlan_pvid':snmp.get('vlan_pvid',{}),'vlan_names':snmp.get('vlan_names',{}),
      'arp_entries':snmp.get('arp_entries',[]),
      'http_services':http.get('http_services',[]),'banners':bnr.get('banners',[]),
      'lldp_neighbors':snmp.get('lldp_neighbors',[]),
      'cdp_neighbors':snmp.get('cdp_neighbors',[]),
      'snmp_details':{'sys_descr':snmp.get('sys_descr',''),
          'sys_location':snmp.get('sys_location',''),
          'sys_contact':snmp.get('sys_contact',''),
          'sys_uptime':snmp.get('sys_uptime',''),
          'sys_oid':snmp.get('sys_oid',''),
          'community':snmp.get('community','')},
      'ssh_details':{'cpu':ssh.get('cpu',''),'banner':ssh.get('banner',''),
          'kernel':ssh.get('kernel','')},
      'discovery_methods':[]}

for src in (snmp.get('sys_name'),ssh.get('hostname'),nmap.get('hostname'),
            dns.get('ptr_hostname'),mdns.get('mdns_hostname'),nb.get('netbios_name')):
    if src and src.strip() and src.lower() not in ('none','null',''):
        host['hostname']=src.strip(); break
if not host['hostname']:
    host['hostname']='device-'+ip.replace('.', '-')

host['mac']=nmap.get('mac'); host['vendor']=nmap.get('vendor','')
host['os']=nmap.get('os') or ssh.get('os') or ''
host['os_accuracy']=nmap.get('os_accuracy')
host['serial']=snmp.get('chassis_serial','')

# WinRM enrichment overrides weaker sources
if winrm.get('available'):
    if winrm.get('Hostname'):     host['hostname']    =winrm['Hostname']
    if winrm.get('Manufacturer'): host['manufacturer']=winrm['Manufacturer']
    if winrm.get('Model'):        host['model']       =winrm['Model'][:80]
    if winrm.get('OS'):           host['os']          =winrm['OS']
    sn=str(winrm.get('SerialNumber','') or '')
    if sn and not any(x in sn for x in ('To Be Filled','Default','None','Not Specified','')):
        host['serial']=sn[:50]
    host['winrm_nics']=[{'name':n.get('Name','eth'),'description':n.get('Description',''),
        'mac':n.get('MacAddress',''),'ips':n.get('IPAddresses',[]) or [],
        'prefix_lens':n.get('PrefixLens',[]) or []}
        for n in (winrm.get('NetworkAdapters') or [])]
    host['is_hyperv']=bool(winrm.get('IsHyperV',False))

if nmap.get('ports'):         host['discovery_methods'].append('nmap')
if snmp.get('available'):     host['discovery_methods'].append('snmp')
if ssh.get('available'):      host['discovery_methods'].append('ssh')
if http.get('http_services'): host['discovery_methods'].append('http')
if nb.get('available'):       host['discovery_methods'].append('netbios')
if dns.get('ptr_hostname'):   host['discovery_methods'].append('dns')
if bnr.get('banners'):        host['discovery_methods'].append('banner')
if winrm.get('available'):    host['discovery_methods'].append('winrm')

# scan_tier: 1=winrm(richest) 2=ssh 3=snmp 4=nmap/fallback
if winrm.get('available'):      host['scan_tier']=1
elif ssh.get('available'):      host['scan_tier']=2
elif snmp.get('available'):     host['scan_tier']=3
else:                           host['scan_tier']=4

if winrm.get('available'):
    host['device_role']='Server' if winrm.get('IsServer') else 'Workstation'

snmp_up=bool(snmp.get('available'))
sys_descr=(snmp.get('sys_descr') or '').lower()
os_str=(host['os'] or '').lower()
open_ports={str(p.get('port','')) for p in host['ports']}
http_ttl=' '.join(s.get('title','') for s in host['http_services']).lower()
# Include entity MIB descriptions + model names so devices whose sysDescr
# is sparse (e.g. 'FortiGate-61E') still get classified from entity strings
entity_text=' '.join(
    ' '.join([e.get('desc',''),e.get('model','')])
    for e in snmp.get('entity_inventory',[])
).lower()
# Include nmap port script output (http-title, banners, etc.) in combined
# so devices identified via port scripts (e.g. FortiGate http-title) classify
nmap_scripts=' '.join(
    str(v) for p in host.get('ports',[]) for v in (p.get('scripts') or {}).values()
    if isinstance(v,str)
).lower()
combined=' '.join([sys_descr,os_str,http_ttl,entity_text,nmap_scripts])
sys_oid=(snmp.get('sys_oid') or '').strip()
if sys_oid.startswith('iso.'): sys_oid='1.'+sys_oid[4:]

# sysObjectID prefix table -- gives definitive vendor+role for SNMP devices
# before any keyword matching runs. Enterprise OID prefix -> (role, manufacturer)
# Checked in priority order; first match wins.
OID_MAP=[
    # Firewalls
    ('1.3.6.1.4.1.12356.',  'Firewall',    'Fortinet'),    # Fortinet
    ('1.3.6.1.4.1.2620.',   'Firewall',    'Check Point'), # Check Point
    ('1.3.6.1.4.1.25461.',  'Firewall',    'Palo Alto'),   # Palo Alto
    ('1.3.6.1.4.1.8741.',   'Firewall',    'SonicWall'),   # SonicWall
    ('1.3.6.1.4.1.3417.',   'Firewall',    'Barracuda'),   # Barracuda
    ('1.3.6.1.4.1.9.1.746', 'Firewall',    'Cisco'),       # Cisco ASA
    ('1.3.6.1.4.1.9.1.745', 'Firewall',    'Cisco'),       # Cisco PIX
    ('1.3.6.1.4.1.9.1.620', 'Firewall',    'Cisco'),       # Cisco FWSM
    ('1.3.6.1.4.1.4874.1.1.100', 'Firewall','Juniper'),    # Juniper SRX
    # Routers
    ('1.3.6.1.4.1.9.1.',    'Router',      'Cisco'),       # Cisco IOS routers
    ('1.3.6.1.4.1.2636.1.1.1.2.',  'Router','Juniper'),    # Juniper MX/EX routers
    ('1.3.6.1.4.1.9694.',   'Router',      'MikroTik'),    # MikroTik
    ('1.3.6.1.4.1.41112.1.19.','Firewall', 'Ubiquiti'),    # Ubiquiti UCG (Cloud Gateway)
    ('1.3.6.1.4.1.41112.1.4.','Wireless AP','Ubiquiti'),   # Ubiquiti UniFi AP
    ('1.3.6.1.4.1.41112.1.6.','Router',    'Ubiquiti'),    # Ubiquiti EdgeRouter
    ('1.3.6.1.4.1.41112.',  'Router',      'Ubiquiti'),    # Ubiquiti (generic catch-all)
    ('1.3.6.1.4.1.4413.',   'Router',      'Broadcom'),    # Broadcom (EdgeRouter)
    ('1.3.6.1.4.1.30065.',  'Router',      'Arista'),      # Arista
    ('1.3.6.1.4.1.18060.',  'Router',      'OpenBSD'),     # OpenBSD/OpenVPN
    # Switches
    ('1.3.6.1.4.1.11.',     'Switch',      'HP'),          # HP ProCurve / HPE
    ('1.3.6.1.4.1.25506.',  'Switch',      'H3C'),         # H3C
    ('1.3.6.1.4.1.43.',     'Switch',      '3Com'),        # 3Com
    ('1.3.6.1.4.1.6486.',   'Switch',      'Alcatel'),     # Alcatel-Lucent OmniSwitch
    ('1.3.6.1.4.1.1916.',   'Switch',      'Extreme Networks'), # Extreme
    ('1.3.6.1.4.1.1991.',   'Switch',      'Brocade'),     # Brocade / Ruckus ICX
    ('1.3.6.1.4.1.2636.1.1.1.4.',  'Switch','Juniper'),    # Juniper EX switches
    ('1.3.6.1.4.1.12356.106.','Switch',     'Fortinet'),   # FortiSwitch
    # Wireless APs
    ('1.3.6.1.4.1.14823.',  'Wireless AP', 'Aruba'),       # Aruba
    ('1.3.6.1.4.1.388.',    'Wireless AP', 'Symbol'),      # Symbol/Zebra AP
    ('1.3.6.1.4.1.25053.',  'Wireless AP', 'Ruckus'),      # Ruckus
    ('1.3.6.1.4.1.9.1.525', 'Wireless AP', 'Cisco'),       # Cisco Aironet
    ('1.3.6.1.4.1.14988.',  'Wireless AP', 'MikroTik'),    # MikroTik (also AP)
    # UPS / Power
    ('1.3.6.1.4.1.318.',    'UPS',         'APC'),         # APC / Schneider
    ('1.3.6.1.4.1.534.',    'UPS',         'Eaton'),       # Eaton / Powerware
    ('1.3.6.1.4.1.476.',    'UPS',         'Liebert'),     # Liebert / Vertiv
    ('1.3.6.1.4.1.4779.',   'UPS',         'CyberPower'),  # CyberPower
    ('1.3.6.1.4.1.850.',    'UPS',         'Tripp Lite'),  # Tripp Lite
    # Printers
    ('1.3.6.1.4.1.11.2.3.9.','Printer',    'HP'),          # HP JetDirect
    ('1.3.6.1.4.1.1347.',   'Printer',     'Kyocera'),     # Kyocera
    ('1.3.6.1.4.1.253.',    'Printer',     'Xerox'),       # Xerox
    ('1.3.6.1.4.1.2001.',   'Printer',     'Ricoh'),       # Ricoh
    ('1.3.6.1.4.1.367.',    'Printer',     'Ricoh'),       # Ricoh (alternate)
    ('1.3.6.1.4.1.1602.',   'Printer',     'Canon'),       # Canon
    ('1.3.6.1.4.1.2435.',   'Printer',     'Brother'),     # Brother
    ('1.3.6.1.4.1.1248.',   'Printer',     'Epson'),       # Epson
    ('1.3.6.1.4.1.18334.',  'Printer',     'Konica Minolta'),# Konica Minolta
    # Cameras / NVR
    ('1.3.6.1.4.1.368.',    'IP Camera',   'Axis'),        # Axis
    ('1.3.6.1.4.1.39165.',  'IP Camera',   'Hikvision'),   # Hikvision
    ('1.3.6.1.4.1.36493.',  'IP Camera',   'Dahua'),       # Dahua
    # Load Balancers
    ('1.3.6.1.4.1.3375.',   'Server',      'F5'),          # F5 BIG-IP
    ('1.3.6.1.4.1.5624.',   'Firewall',    'Ericom'),      # Ericom / NetScaler alt
    ('1.3.6.1.4.1.5951.',   'Server',      'Citrix'),      # Citrix NetScaler
    # NAS / Storage
    ('1.3.6.1.4.1.6574.',   'Server',      'Synology'),    # Synology
    ('1.3.6.1.4.1.24681.',  'Server',      'QNAP'),        # QNAP
    # Generic Cisco (catch-all, must come after specific Cisco entries)
    ('1.3.6.1.4.1.9.',      'Switch',      'Cisco'),       # Cisco (generic)
    # Juniper (catch-all)
    ('1.3.6.1.4.1.2636.',   'Router',      'Juniper'),     # Juniper (generic)
]

# Apply OID-prefix classification before keyword matching
_oid_role=None; _oid_mfr=None
if sys_oid:
    for prefix,role,mfr in OID_MAP:
        if sys_oid.startswith(prefix):
            _oid_role=role; _oid_mfr=mfr; break

FW=['firewall','fortigate','fortios','palo alto','checkpoint','asa','sonicwall',
    'opnsense','pfsense','netscreen','juniper srx','srx','watchguard','sophos','cisco asa',
    'stonegate','netscaler','bigip','f5 ',
    'ucg-fiber','ucg-ultra','ucg-max','ucg-enterprise','unifi ucg']
RT=['router','gateway','ios xe','ios xr','junos','routeros','vyos ','edgeos',
    'edgerouter','unifi security gateway','usg','mikrotik','rb ','tilfa','cisco ios']
SW=['switch','catalyst','nexus',' eos ','comware','procurve','arubaos',
    'ex series','qfx','powerconnect','1810g','1910','2530','2920','2960',
    '3750','3850','9300','netgear gs','sg300','sg500','sf ','icx ','fcs ',
    'flexfabric','hp 1910','hp 1810','tplink','tp-link','d-link','dgs-','des-',
    'unmanaged switch','smart switch','managed switch','fortiswitch','fsl-']
AP=['access point','aironet','unifi','airmax','lightweight ap',
    'aruba','instant ap','iap-','wap','wifi','wireless ap','802.11','ath0',
    'ubiquiti','ruijie ap','ruckus','meraki mr',
    'u6-','u6pro','u7-','uap-','uap-ac','u-lte','ulte','unifi6',
    'nanostation','litebeam','nanobeam','powerbeam','airfiber']
SV=['linux','ubuntu','debian','centos','rhel','windows server','esxi',
    'vmware','proxmox','freebsd']
PR=['printer','jetdirect','xerox','ricoh','canon','brother','lexmark',
    'epson','kyocera','konica','minolta','sharp','samsung clp','samsung ml',
    'hp laserjet','hp officejet','hp deskjet','hp color','pagewide',
    'print server','multifunction','mfp','all-in-one']
UP=['ups','apc','eaton','powerware','uninterruptible',
    'cyberpower','tripp lite','tripplite','schneider electric ups',
    'liebert','vertiv','pdu','power distribution']
CA=['camera','axis comm','hikvision','dahua','hanwha',
    'bosch cam','pelco','vivotek','avigilon','genetec','milestone',
    'ip cam','ipcam','nvr','dvr','cctv']

# OID-prefix result overrides keyword classifier when SNMP is available
if _oid_role:
    host['device_role']=_oid_role
    if _oid_mfr: host['manufacturer']=_oid_mfr
elif any(k in combined for k in FW):  host['device_role']='Firewall'
elif any(k in combined for k in RT) and (snmp_up or '161' in open_ports
     or '830' in open_ports or '8291' in open_ports):
    host['device_role']='Router'
elif any(k in combined for k in SW) and (snmp_up or '161' in open_ports):
    host['device_role']='Switch'
elif any(k in combined for k in AP):  host['device_role']='Wireless AP'
elif any(k in combined for k in PR) or '9100' in open_ports or '631' in open_ports:
    host['device_role']='Printer'
elif any(k in combined for k in UP):  host['device_role']='UPS'
elif any(k in combined for k in CA):  host['device_role']='IP Camera'
elif 'windows server' in os_str or 'windows server' in combined:
    host['device_role']='Server'
elif '3389' in open_ports: host['device_role']='Server'
elif any(k in combined for k in SV):  host['device_role']='Server'
elif 'windows' in os_str:  host['device_role']='Workstation'
elif '5060' in open_ports or 'sip' in combined: host['device_role']='IP Phone'
elif '445' in open_ports or nb.get('available'): host['device_role']='Workstation'

vendor=host.get('vendor','') or ''
if vendor not in ('','null','None'): host['manufacturer']=vendor
else:
    MFR={'cisco':'Cisco','juniper':'Juniper','arista':'Arista',
         'procurve':'HP','hp ':'HP','hewlett':'HP','dell':'Dell',
         'microsoft':'Microsoft','vmware':'VMware','apple':'Apple',
         'ubiquiti':'Ubiquiti','mikrotik':'MikroTik','fortigate':'Fortinet',
         'fortinet':'Fortinet','palo alto':'Palo Alto','sonicwall':'SonicWall',
         'checkpoint':'Check Point','apc':'APC','eaton':'Eaton',
         'netgear':'Netgear','axis':'Axis','hikvision':'Hikvision',
         'synology':'Synology','qnap':'QNAP','h3c':'H3C','huawei':'Huawei',
         'meraki':'Cisco Meraki','brocade':'Brocade','ruckus':'Ruckus',
         'aruba':'Aruba','watchguard':'WatchGuard','sophos':'Sophos',
         'f5 ':'F5','bigip':'F5','netscaler':'Citrix','citrix':'Citrix',
         'kyocera':'Kyocera','ricoh':'Ricoh','xerox':'Xerox','epson':'Epson',
         'brother':'Brother','canon':'Canon','konica':'Konica Minolta',
         'dahua':'Dahua','hanwha':'Hanwha','pelco':'Pelco',
         'cyberpower':'CyberPower','liebert':'Liebert','vertiv':'Vertiv',
         'extreme':'Extreme Networks','alcatel':'Alcatel-Lucent'}
    # Skip keyword MFR lookup when OID already identified the vendor;
    # prevents script text from overriding a definitive OID match
    if not _oid_mfr:
        for k,v in MFR.items():
            if k in combined: host['manufacturer']=v; break
    else:
        host['manufacturer']=_oid_mfr

sd=snmp.get('sys_descr','') or ''
if sd: host['model']=sd[:120].strip()
elif ssh.get('net_device_info'):
    lns=[l for l in ssh['net_device_info'].split('\n') if l.strip()]
    host['model']=lns[0][:120].strip() if lns else 'Unknown'
else:
    # Try entity inventory: sw_rev often has 'ProductName v1.2.3' format;
    # take first word which is typically the model name (e.g. FortiGate-61E)
    _ent_model=''
    for _e in snmp.get('entity_inventory',[]):
        _sw=(_e.get('sw_rev') or '').strip()
        _m =(_e.get('model')  or '').strip()
        if _sw and not _sw.startswith('iso.'):
            _cand=_sw.split()[0].rstrip(',')
            if re.match(r'[A-Za-z].*[0-9]',_cand):   # looks like a model
                _ent_model=_cand[:80]; break
        if _m and not _m.startswith('iso.'):
            _ent_model=_m[:80]; break
    host['model']=_ent_model or (host['os'] or 'Unknown')[:80]

print(json.dumps(host))
PYEOF
}

# -----------------------------------------------------------------------------
# SWITCHPORT MAPPING
# -----------------------------------------------------------------------------
map_switchports() {
    local switch_ip="$1"
    log_step "Switchport Mapping: $switch_ip"
    local community; community=$(get_communities_for "$switch_ip" | head -1)
    python3 /dev/stdin "$switch_ip" "$community" \
            "$SNMP_TIMEOUT" "$DISCOVERY_DIR" <<'PYEOF'
import subprocess, json, re, sys, os
ip=sys.argv[1]; community=sys.argv[2]; timeout=sys.argv[3]; disc_dir=sys.argv[4]
def walk(oid,comm=None):
    c=comm or community
    try:
        r=subprocess.run(['snmpwalk','-v2c','-c',c,'-t',timeout,'-r1',ip,oid],
                         capture_output=True,text=True,timeout=30)
        return r.stdout
    except: return ''

print('  Fetching interface table...')
if_names={}; if_status={}; if_admin={}; if_speed={}; if_mac={}
for line in walk('1.3.6.1.2.1.2.2.1.2').split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)',line)
    if m: if_names[m.group(1)]=m.group(2).strip().strip('"')
for line in walk('1.3.6.1.2.1.2.2.1.8').split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)',line)
    if m: if_status[m.group(1)]='up' if m.group(2)=='1' else 'down'
for line in walk('1.3.6.1.2.1.2.2.1.7').split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)',line)
    if m: if_admin[m.group(1)]='up' if m.group(2)=='1' else 'down'
for line in walk('1.3.6.1.2.1.2.2.1.5').split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*(?:Gauge32|INTEGER):\s*(\d+)',line)
    if m: if_speed[m.group(1)]=m.group(2)
for line in walk('1.3.6.1.2.1.2.2.1.6').split('\n'):
    m=re.search(r'\.(\d+)\s*=\s*(?:STRING|Hex-STRING):\s*(.+)',line)
    if m: if_mac[m.group(1)]=m.group(2).strip()

print('  Fetching bridge port -> ifIndex mapping...')
port_to_if={}
for line in walk('1.3.6.1.2.1.17.1.4.1.2').split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)',line)
    if m: port_to_if[m.group(1)]=m.group(2)

print('  Fetching VLAN assignments...')
port_vlan={}
for line in walk('1.3.6.1.2.1.17.7.1.4.5.1.1').split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*(?:Gauge32|INTEGER|Unsigned32):\s*(\d+)',line)
    if m: port_vlan[m.group(1)]=m.group(2)

print('  Fetching VLAN names...')
vlan_names={}
for line in walk('1.3.6.1.4.1.9.9.46.1.3.1.1.2').split('\n'):
    m=re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)',line)
    if m: vlan_names[m.group(1)]=m.group(2).strip().strip('"')
if not vlan_names:
    for line in walk('1.3.6.1.2.1.17.7.1.4.2.1.4').split('\n'):
        m=re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)',line)
        if m: vlan_names[m.group(1)]=m.group(2).strip().strip('"')

print('  Fetching MAC address table...')
mac_to_port={}
for line in walk('1.3.6.1.2.1.17.4.3.1.2').split('\n'):
    m=re.match(r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)',line)
    if m:
        mac=':'.join('{:02x}'.format(int(o)) for o in m.group(1).split('.'))
        mac_to_port[mac]=m.group(2)

if not mac_to_port and vlan_names:
    print('  Standard bridge MIB: 0 MACs -- trying Cisco per-VLAN communities...')
    for vid in list(vlan_names.keys())[:10]:
        vlan_comm='{0}@{1}'.format(community,vid)
        for line in walk('1.3.6.1.2.1.17.4.3.1.2',comm=vlan_comm).split('\n'):
            m=re.match(r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)',line)
            if m:
                mac=':'.join('{:02x}'.format(int(o)) for o in m.group(1).split('.'))
                mac_to_port[mac]=m.group(2)
        if mac_to_port:
            print('  Found MACs via community @{0}'.format(vid)); break

print('  Found {0} MAC entries'.format(len(mac_to_port)))
arp_map={}
for line in walk('1.3.6.1.2.1.4.22.1.2').split('\n'):
    m=re.search(r'\.(\d+\.\d+\.\d+\.\d+)\s*=\s*(?:STRING|Hex-STRING):\s*(.+)',line)
    if m and '4.22.1.2' in line: arp_map[m.group(2).strip().lower()]=m.group(1)

if_entries={}
for idx,name in if_names.items():
    bports=[bp for bp,ii in port_to_if.items() if ii==idx]
    vlan=''
    for bp in bports:
        if bp in port_vlan: vlan=port_vlan[bp]; break
    if not vlan and idx in port_vlan: vlan=port_vlan[idx]
    macs_on_port=[mac for mac,bp in mac_to_port.items()
                  if port_to_if.get(bp,bp)==idx]
    remote_ips=[]
    for mac in macs_on_port:
        mn=mac.replace(':','').lower()
        for k,v in arp_map.items():
            if mn in k.replace(':','').replace(' ',''):
                remote_ips.append(v); break
    spd=if_speed.get(idx,'0')
    spd_m=str(int(spd)//1000000)+'M' if spd.isdigit() else '?'
    if_entries[idx]={'if_index':idx,'if_name':name,
        'admin':if_admin.get(idx,'?'),'oper':if_status.get(idx,'?'),
        'speed':spd_m,'mac':if_mac.get(idx,''),
        'vlan':vlan,'vlan_name':vlan_names.get(str(vlan),''),
        'clients':macs_on_port,'remote_ips':remote_ips}

port_entries=sorted(if_entries.values(),key=lambda x:x['if_name'])
out_file=os.path.join(disc_dir,'switchport_'+ip.replace('.', '-')+'.json')
with open(out_file,'w') as f:
    json.dump({'switch_ip':ip,'interfaces':port_entries,
               'vlan_names':vlan_names,'interface_count':len(if_names),
               'mac_count':len(mac_to_port)},f,indent=2)

print('  Saved: '+out_file)
print('\n  Switch     : '+ip)
print('  Interfaces : {0}'.format(len(if_names)))
print('  MAC entries: {0}'.format(len(mac_to_port)))
if vlan_names:
    pairs=sorted(vlan_names.items(),key=lambda x:int(x[0]) if x[0].isdigit() else 0)[:10]
    print('  VLANs      : '+', '.join('{0}={1}'.format(k,v) for k,v in pairs))
print()
hdr='  {:<24} {:<5} {:<5} {:<8} {:<6} {:<18} {:<17} {}'.format(
    'Interface','Adm','Oper','Speed','VLAN','VLAN Name','Port MAC','Remote IPs / Clients')
print(hdr); print('  '+'-'*110)
for e in port_entries:
    cl=', '.join(e['remote_ips']) if e['remote_ips'] else ', '.join(e['clients'][:3])
    print('  {:<24} {:<5} {:<5} {:<8} {:<6} {:<18} {:<17} {}'.format(
        e['if_name'][:23],e['admin'][:4],e['oper'][:4],e['speed'][:7],
        str(e['vlan'])[:5],e['vlan_name'][:17],e['mac'][:16],cl[:50]))
if not port_entries:
    print('  (No interfaces found -- check SNMP community and device support)')
PYEOF
}

# -----------------------------------------------------------------------------
# SYNC TO NETBOX
# -----------------------------------------------------------------------------
sync_to_netbox() {
    local results_file="${1:-}"
    [[ -z "$results_file" ]] \
        && results_file=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
    [[ ! -f "$results_file" ]] \
        && { log_error "No results file found"; pause; return 1; }

    log_step "Syncing to NetBox: $(basename "$results_file")"

    if [[ -z "$NETBOX_API_TOKEN" ]]; then
        read -rp "  Enter NetBox API Token: " NETBOX_API_TOKEN; save_config
    fi

    if ! nc -z -w 5 $(get_host_ip) "${NETBOX_PORT}" 2>/dev/null; then
        log_error "NetBox port ${NETBOX_PORT} not reachable -- is it running?"
        log_info  "Start: Menu -> NetBox Management -> Start NetBox"
        pause; return 1
    fi
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Authorization: Token $NETBOX_API_TOKEN" \
        "${NETBOX_API_URL}/api/dcim/sites/" 2>/dev/null)
    if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        log_error "NetBox API auth failed (HTTP $http_code)"
        log_info  "Token : ${NETBOX_API_TOKEN:0:12}..."
        log_info  "Creds : cat $BASE_DIR/netbox-credentials.txt"
        read -rp "  Enter correct token (blank to cancel): " new_tok
        if [[ -n "$new_tok" ]]; then NETBOX_API_TOKEN="$new_tok"; save_config
        else pause; return 1; fi
    elif [[ "$http_code" != "200" ]]; then
        log_error "NetBox API HTTP $http_code"
        pause; return 1
    fi

    local site_id; site_id=$(nb_get_or_create_site)
    [[ -z "$site_id" || ! "$site_id" =~ ^[0-9]+$ ]] \
        && { log_error "Cannot create site"; pause; return 1; }
    log_info "Site ID: $site_id"
    # Ensure custom fields exist (idempotent)
    nb_ensure_custom_field "discovered_ports" "Discovered Ports" "text" "dcim.device"
    nb_ensure_custom_field "discovery_methods" "Discovery Methods" "text" "dcim.device"

    local total; total=$(jq '.hosts | length' "$results_file")
    local ok=0 fail=0 idx=0

    local host
    while IFS= read -r host; do
        (( idx++ )) || true
        local ip hn role mfr model os serial
        local loc contact uptime oid dmethods comments
        ip=$(echo "$host"       | jq -r '.ip')
        hn=$(echo "$host"       | jq -r '.hostname // "unknown"')
        role=$(echo "$host"     | jq -r '.device_role // "Endpoint"')
        mfr=$(echo "$host"      | jq -r '.manufacturer // "Unknown"')
        model=$(echo "$host"    | jq -r '.model // "Unknown"' | cut -c1-64)
        os=$(echo "$host"       | jq -r '.os // ""')
        serial=$(echo "$host"   | jq -r '.serial // ""')
        loc=$(echo "$host"      | jq -r '.snmp_details.sys_location // ""')
        contact=$(echo "$host"  | jq -r '.snmp_details.sys_contact // ""')
        uptime=$(echo "$host"   | jq -r '.snmp_details.sys_uptime // ""')
        oid=$(echo "$host"      | jq -r '.snmp_details.sys_oid // ""')
        dmethods=$(echo "$host" | jq -r '.discovery_methods | join(", ")')

        comments="Discovered by NetBox Discovery Suite v${SCRIPT_VERSION}"
        [[ -n "$os"      ]] && comments="${comments}\nOS         : $os"
        [[ -n "$loc"     ]] && comments="${comments}\nLocation   : $loc"
        [[ -n "$contact" ]] && comments="${comments}\nContact    : $contact"
        [[ -n "$uptime"  ]] && comments="${comments}\nUptime     : $uptime"
        [[ -n "$oid"     ]] && comments="${comments}\nSNMP OID   : $oid"
        comments="${comments}\nDiscovery  : $dmethods"

        printf "  ${C}[%d/%d]${NC} ${W}%-16s${NC} %-28s %-14s " \
            "$idx" "$total" "$ip" "$hn" "$role"

        local dev_id
        dev_id=$(nb_upsert_device "$hn" "$role" "$mfr" "$model" \
            "$site_id" "$serial" "$comments" "$ip" 2>>"$LOG_FILE")

        if [[ -z "$dev_id" || ! "$dev_id" =~ ^[0-9]+$ ]]; then
            printf "${R}FAIL${NC}\n"; (( fail++ )); continue
        fi

        # Skip mgmt0 when WinRM NICs are present -- the real NIC names
        # and IPs will be assigned in the WinRM NIC loop below, avoiding
        # the IP landing on a placeholder interface and then needing
        # reassignment.
        local _has_winrm_nics
        _has_winrm_nics=$(echo "$host" \
            | jq '.winrm_nics | length' 2>/dev/null || echo 0)
        local mac_addr mgmt_id
        if [[ "${_has_winrm_nics:-0}" -eq 0 ]]; then
            mac_addr=$(echo "$host" | jq -r '.mac // ""')
            mgmt_id=$(nb_add_interface \
                "$dev_id" "mgmt0" "other" "$mac_addr" \
                "Management (auto-discovered)" 2>/dev/null)
            if [[ -n "$mgmt_id" && "$mgmt_id" =~ ^[0-9]+$ ]]; then
                nb_add_ip "$ip" "$dev_id" "$mgmt_id" >/dev/null 2>&1 || true
            fi
        fi

        local ip_table_json vlan_pvid_json vlan_names_json lldp_json cdp_json
        ip_table_json=$(echo "$host"    | jq -c '.ip_table // []')
        vlan_pvid_json=$(echo "$host"   | jq -c '.vlan_pvid // {}')
        vlan_names_json=$(echo "$host"  | jq -c '.vlan_names // {}')
        lldp_json=$(echo "$host"        | jq -c '.lldp_neighbors // []')
        cdp_json=$(echo "$host"         | jq -c '.cdp_neighbors // []')

        local iface
        while IFS= read -r iface; do
            local if_name if_mac if_type if_idx nb_type if_desc lldp_d cdp_d
            if_name=$(echo "$iface" | jq -r '.name // "if"')
            if_mac=$(echo "$iface"  | jq -r '.mac // ""')
            if_type=$(echo "$iface" | jq -r '.type // "other"')
            if_idx=$(echo "$iface"  | jq -r '.index // ""')
            nb_type="other"
            case "$if_type" in
                6)   nb_type="1000base-t"       ;;
                53)  nb_type="1000base-x-sfp"   ;;
                161) nb_type="ieee802-11a"       ;;
                24)  nb_type="virtual"           ;;
            esac
            lldp_d=$(echo "$lldp_json" | jq -r \
                "[.[] | select(.port_id==\"$if_name\" or .port_desc==\"$if_name\")
                  | \"LLDP: \"+(.sys_name // \"?\")] | join(\"; \")" \
                2>/dev/null || echo "")
            cdp_d=$(echo "$cdp_json" | jq -r \
                "[.[] | select(.remote_port==\"$if_name\")
                  | \"CDP: \"+(.device_id // \"?\")] | join(\"; \")" \
                2>/dev/null || echo "")
            if_desc="${lldp_d}${cdp_d:+; $cdp_d}"

            local if_id
            if_id=$(nb_add_interface "$dev_id" "$if_name" "$nb_type" \
                "$if_mac" "${if_desc:0:200}" 2>/dev/null) || true
            [[ -z "$if_id" || ! "$if_id" =~ ^[0-9]+$ ]] && continue

            # Assign IP from SNMP ip_table; skip unroutable addresses (v2.0.9)
            local iface_ip iface_mask iface_prefix
            iface_ip=$(echo "$ip_table_json" | jq -r \
                "[.[] | select(.if_index==\"$if_idx\") | .ip][0] // empty" \
                2>/dev/null || echo "")
            if [[ -n "$iface_ip" \
                  && "$iface_ip" != "0.0.0.0" \
                  && "$iface_ip" != 127.* \
                  && "$iface_ip" != 169.254.* ]]; then
                iface_mask=$(echo "$ip_table_json" | jq -r \
                    "[.[] | select(.ip==\"$iface_ip\") | .mask][0] \
                     // \"255.255.255.0\"" 2>/dev/null || echo "255.255.255.0")
                iface_prefix=$(python3 -c \
                    "import ipaddress; \
print(ipaddress.IPv4Network('$iface_ip/$iface_mask',strict=False).prefixlen)" \
                    2>/dev/null || echo "24")
                nb_add_ip "${iface_ip}/${iface_prefix}" "" "$if_id" \
                    >/dev/null 2>&1 || true
            fi

            local pvid vlan_nm vlan_id
            pvid=$(echo "$vlan_pvid_json" | jq -r \
                ".\"$if_idx\" // empty" 2>/dev/null || echo "")
            if [[ -n "$pvid" && "$pvid" =~ ^[0-9]+$ && "$pvid" != "0" ]]; then
                vlan_nm=$(echo "$vlan_names_json" | jq -r \
                    ".\"$pvid\" // \"VLAN-$pvid\"" 2>/dev/null || echo "VLAN-$pvid")
                vlan_id=$(nb_get_or_create_vlan \
                    "$pvid" "$vlan_nm" "$site_id" 2>/dev/null) || true
                if [[ -n "$vlan_id" && "$vlan_id" =~ ^[0-9]+$ ]]; then
                    nb_patch "dcim/interfaces/${if_id}/" \
                        "{\"untagged_vlan\":$vlan_id,\"mode\":\"access\"}" \
                        >/dev/null 2>&1 || true
                fi
            fi
        done < <(echo "$host" | jq -c '.interfaces[]?' 2>/dev/null || true)

        # WinRM NIC interfaces (Windows hosts)
        local winrm_nic
        while IFS= read -r winrm_nic; do
            local wn_name wn_mac wn_desc wn_if_id _idx_ip
            wn_name=$(echo "$winrm_nic" | jq -r '.name // "NIC"')
            wn_mac=$(echo "$winrm_nic"  | jq -r '.mac  // ""')
            wn_desc=$(echo "$winrm_nic" | jq -r '.description // ""')
            wn_if_id=$(nb_add_interface "$dev_id" "$wn_name" \
                "1000base-t" "$wn_mac" "${wn_desc:0:200}" 2>/dev/null) || true
            [[ -z "$wn_if_id" || ! "$wn_if_id" =~ ^[0-9]+$ ]] && continue
            _idx_ip=0
            local wn_ip wn_pl
            while IFS= read -r wn_ip; do
                [[ -z "$wn_ip" || "$wn_ip" == "null" ]] \
                    && { (( _idx_ip++ )) || true; continue; }
                [[ "$wn_ip" == 127.* || "$wn_ip" == 169.254.* ]] \
                    && { (( _idx_ip++ )) || true; continue; }
                wn_pl=$(echo "$winrm_nic" \
                    | jq -r ".prefix_lens[$_idx_ip] // 24" 2>/dev/null || echo "24")
                nb_add_ip "${wn_ip}/${wn_pl}" "" "$wn_if_id" >/dev/null 2>&1 || true
                (( _idx_ip++ )) || true
            done < <(echo "$winrm_nic" | jq -r '.ips[]?' 2>/dev/null || true)
        done < <(echo "$host" | jq -c '.winrm_nics[]?' 2>/dev/null || true)

        local nbr
        while IFS= read -r nbr; do
            local nbr_name nbr_local_port nbr_remote_port
            nbr_name=$(echo "$nbr" | jq -r '.sys_name // .device_id // empty')
            nbr_local_port=$(echo "$nbr" | jq -r '.port_id // .remote_port // empty')
            nbr_remote_port=$(echo "$nbr" | jq -r '.port_desc // .remote_port // empty')
            [[ -z "$nbr_name" ]] && continue
            local nbr_enc nbr_dev_id
            nbr_enc=$(nb_urlencode "$nbr_name")
            nbr_dev_id=$(nb_get "dcim/devices/?name=${nbr_enc}" \
                | jq -r '.results[0].id // empty' 2>/dev/null || echo "")
            [[ -z "$nbr_dev_id" || ! "$nbr_dev_id" =~ ^[0-9]+$ ]] && continue
            local local_if_id nbr_if_id
            local_if_id=$(nb_add_interface "$dev_id" \
                "${nbr_local_port:-to-$nbr_name}" "other" "" \
                "Topology link to $nbr_name" 2>/dev/null) || true
            nbr_if_id=$(nb_add_interface "$nbr_dev_id" \
                "${nbr_remote_port:-to-$hn}" "other" "" \
                "Topology link to $hn" 2>/dev/null) || true
            [[ -z "$local_if_id" || ! "$local_if_id" =~ ^[0-9]+$ ]] && continue
            [[ -z "$nbr_if_id"   || ! "$nbr_if_id"   =~ ^[0-9]+$ ]] && continue
            nb_create_cable "$local_if_id" "$nbr_if_id" \
                "$hn <-> $nbr_name" >/dev/null 2>&1 || true
            log_info "Cable: $hn <-> $nbr_name"
        done < <({
            echo "$host" | jq -c '.lldp_neighbors[]?' 2>/dev/null
            echo "$host" | jq -c '.cdp_neighbors[]?'  2>/dev/null
        } 2>/dev/null || true)

        # Populate custom fields: open ports + discovery methods
        local _ports_cf _dmethods_cf
        _ports_cf=$(echo "$host" | jq -r \
            '[.ports[] | .port + "/" + (.service // .proto // "tcp")] | join(", ")' \
            2>/dev/null || echo "")
        _dmethods_cf=$(echo "$host" | jq -r \
            '.discovery_methods | join(", ")' 2>/dev/null || echo "")
        if [[ -n "$_ports_cf" || -n "$_dmethods_cf" ]]; then
            nb_patch "dcim/devices/${dev_id}/" \
                "$(jq -n --arg p "$_ports_cf" --arg d "$_dmethods_cf" \
                    '{custom_fields:{discovered_ports:$p,discovery_methods:$d}}')" \
                >/dev/null 2>&1 || true
        fi

        printf "${G}OK${NC}\n"; (( ok++ ))

        # Auto-run full Hyper-V PS1 sync when discovery found a WinRM
        # host with Hyper-V available and stored credentials exist
        local _tier _is_hv
        _tier=$(echo "$host" | jq -r '.scan_tier // 4' 2>/dev/null || echo 4)
        _is_hv=$(echo "$host" | jq -r '.is_hyperv // false' 2>/dev/null || echo false)
        if [[ "$_tier" == "1" && "$_is_hv" == "true" ]]; then
            local _wcc
            _wcc=$(get_windows_creds_for "$ip" | jq 'length' 2>/dev/null || echo 0)
            if [[ "${_wcc:-0}" -gt 0 ]]; then
                log_info "Auto-running Hyper-V PS1 sync for $ip (Hyper-V detected)"
                import_hyperv_powershell "$ip" "auto"
            fi
        fi

    done < <(jq -c '.hosts[]' "$results_file")

    printf "\n  ${G}Complete:${NC} %d synced  ${R}%d failed${NC}  (total: %d)\n" \
        "$ok" "$fail" "$total"
    log_info "Sync: ok=$ok fail=$fail total=$total"
    pause
}

# -----------------------------------------------------------------------------
# NETBOX-AGENT CONFIG GENERATOR
# -----------------------------------------------------------------------------
generate_agent_config() {
    local dest="${1:-/etc/netbox_agent.yaml}"
    [[ -z "$NETBOX_API_TOKEN" ]] \
        && { log_error "API token not set -- run deploy first"; return 1; }
    cat > "$dest" <<AGENTEOF
# netbox-agent configuration -- generated by NetBox Discovery Suite v${SCRIPT_VERSION}
# See: https://github.com/solvik/netbox_agent
netbox:
  url: "${NETBOX_API_URL}"
  token: "${NETBOX_API_TOKEN}"
  ssl_verify: false

network:
  lldp: true
  ignore_interfaces: "(dummy.*|docker.*|virbr.*|veth.*|br-.*|lo)"
  ignore_ips: (127\.0\.0\..*|169\.254\..*|::1.*)

device:
  server_role: "Server"

virtual:
  enabled: true

inventory: true
AGENTEOF
    chmod 600 "$dest"
    log_ok "Agent config written: $dest"
}

# -----------------------------------------------------------------------------
# RUN NETBOX-AGENT LOCALLY
# -----------------------------------------------------------------------------
run_agent_local() {
    log_step "Registering local machine via netbox-agent"
    if ! cmd_exists netbox_agent; then
        log_error "netbox-agent not installed -- run Option 1 (Install Deps) first"
        pause; return 1
    fi
    local cfg; cfg=$(mktemp --suffix=.yaml)
    generate_agent_config "$cfg"
    log_info "Running: netbox_agent --register"
    netbox_agent -c "$cfg" --register 2>&1 | tee -a "$LOG_FILE"
    rm -f "$cfg"
    log_ok "Local registration complete"
    pause
}

# -----------------------------------------------------------------------------
# DEPLOY NETBOX-AGENT TO A REMOTE LINUX HOST
# -----------------------------------------------------------------------------
deploy_agent_remote() {
    local host_ip="$1"
    log_step "Deploying netbox-agent to $host_ip"

    # Resolve credentials
    local creds; creds=$(read_creds)
    local ssh_user="" ssh_pass="" ssh_key=""
    local ov; ov=$(echo "$creds" \
        | jq -r ".device_overrides[\"$host_ip\"] // empty" 2>/dev/null)
    if [[ -n "$ov" && "$ov" != "null" ]]; then
        ssh_user=$(echo "$ov" | jq -r '.ssh_username // empty')
        ssh_pass=$(echo "$ov" | jq -r '.ssh_password // empty')
        ssh_key=$(echo "$ov"  | jq -r '.ssh_key      // empty')
    else
        ssh_user=$(echo "$creds" \
            | jq -r '.ssh_credentials[0].username // empty' 2>/dev/null)
        ssh_pass=$(echo "$creds" \
            | jq -r '.ssh_credentials[0].password // empty' 2>/dev/null)
        ssh_key=$(echo "$creds"  \
            | jq -r '.ssh_credentials[0].key_file // empty' 2>/dev/null)
    fi
    if [[ -z "$ssh_user" ]]; then
        read -rp "  SSH username: " ssh_user
    fi

    local ssh_opts=(-o StrictHostKeyChecking=no -o ConnectTimeout=10
        -o LogLevel=error -o UserKnownHostsFile=/dev/null
        -o BatchMode=no)
    [[ -n "$ssh_key" && -f "$ssh_key" ]] && ssh_opts+=(-i "$ssh_key")

    # Generate config locally then push
    local cfg; cfg=$(mktemp --suffix=.yaml)
    generate_agent_config "$cfg"

    local remote_cmd=(
        "pip3 install --break-system-packages --quiet"
        "--root-user-action=ignore netbox-agent 2>/dev/null || true;"
        "netbox_agent -c /tmp/.nba_cfg.yaml --register"
    )

    log_info "Pushing config to $host_ip..."
    if [[ -n "$ssh_pass" ]]; then
        sshpass -p "$ssh_pass" scp "${ssh_opts[@]}" \
            "$cfg" "${ssh_user}@${host_ip}:/tmp/.nba_cfg.yaml" 2>/dev/null \
            || { log_error "SCP failed to $host_ip"; rm -f "$cfg"; return 1; }
        log_info "Running netbox-agent on $host_ip..."
        sshpass -p "$ssh_pass" ssh "${ssh_opts[@]}" \
            "${ssh_user}@${host_ip}" \
            "${remote_cmd[*]}" 2>&1 | tee -a "$LOG_FILE"
    else
        scp "${ssh_opts[@]}" \
            "$cfg" "${ssh_user}@${host_ip}:/tmp/.nba_cfg.yaml" 2>/dev/null \
            || { log_error "SCP failed to $host_ip"; rm -f "$cfg"; return 1; }
        log_info "Running netbox-agent on $host_ip..."
        ssh "${ssh_opts[@]}" \
            "${ssh_user}@${host_ip}" \
            "${remote_cmd[*]}" 2>&1 | tee -a "$LOG_FILE"
    fi
    rm -f "$cfg"
    log_ok "Agent deployment to $host_ip complete"
    pause
}

# -----------------------------------------------------------------------------
# BATCH DEPLOY AGENT TO ALL DISCOVERED LINUX HOSTS
# -----------------------------------------------------------------------------
deploy_agents_to_discovered() {
    local results_file="${1:-}"
    [[ -z "$results_file" ]] \
        && results_file=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
    [[ ! -f "$results_file" ]] \
        && { log_error "No results file found"; pause; return 1; }

    log_step "Batch Agent Deployment: $(basename "$results_file")"

    local ok=0 fail=0 skip=0 total idx=0
    total=$(jq '.hosts | length' "$results_file")

    local host
    while IFS= read -r host; do
        (( idx++ )) || true
        local ip hn role os
        ip=$(echo "$host"   | jq -r '.ip')
        hn=$(echo "$host"   | jq -r '.hostname // "?"')
        role=$(echo "$host" | jq -r '.device_role // "Endpoint"')
        os=$(echo "$host"   | jq -r '.os // ""')

        printf "  ${C}[%d/%d]${NC} ${W}%-16s${NC} %-28s %-16s ... " \
            "$idx" "$total" "$ip" "$hn" "$role"

        # Skip non-Linux hosts
        case "${role,,}" in
            firewall|router|switch|"wireless ap"|printer|ups|"ip camera")
                printf "${D}skip (network device)${NC}\n"; (( skip++ )); continue ;;
        esac
        local methods; methods=$(echo "$host" \
            | jq -r '.discovery_methods | join(",")')
        if ! echo "$methods" | grep -q "ssh"; then
            printf "${D}skip (no SSH)${NC}\n"; (( skip++ )); continue
        fi
        if echo "${os,,}" | grep -qi "windows"; then
            printf "${D}skip (Windows)${NC}\n"; (( skip++ )); continue
        fi

        printf "\n"
        if deploy_agent_remote "$ip" 2>>"$LOG_FILE"; then
            (( ok++ ))
        else
            printf "${R}  FAIL${NC}\n"; (( fail++ ))
        fi
    done < <(jq -c '.hosts[]' "$results_file")

    printf "\n  ${G}Complete:${NC} %d deployed  ${R}%d failed${NC}  %d skipped\n" \
        "$ok" "$fail" "$skip"
    log_info "Agent batch: ok=$ok fail=$fail skip=$skip total=$total"
    pause
}

# -----------------------------------------------------------------------------
# WINDOWS HYPER-V IMPORT (WinRM / PowerShell)
# For Linux Hyper-V hosts: use deploy_agent_remote() with virtual.hypervisor=true
# -----------------------------------------------------------------------------
import_hyperv_powershell() {
    # Runs the Hyper-V -> NetBox sync PS1 on a Windows host.
    # $2=auto: non-interactive mode -- uses first stored credential,
    #          executes via WinRM, no prompts, no pause at end.
    local host_ip="$1" _auto_mode="${2:-}"
    log_step "Hyper-V PowerShell Sync: $host_ip"

    local win_user="" win_pass="" win_port="5985" win_proto="http" _wp=""
    local win_creds; win_creds=$(get_windows_creds_for "$host_ip")
    local win_cred_count; win_cred_count=$(echo "$win_creds" | jq 'length' 2>/dev/null || echo 0)

    if [[ -n "$_auto_mode" ]]; then
        # Non-interactive: use first available stored credential
        if [[ "${win_cred_count:-0}" -eq 0 ]]; then
            log_warn "No Windows credentials for $host_ip -- skipping auto Hyper-V sync"
            return
        fi
        local _sel; _sel=$(echo "$win_creds" | jq -c '.[0]' 2>/dev/null)
        local _su _sd
        _su=$(echo "$_sel" | jq -r '.username // ""' 2>/dev/null)
        _sd=$(echo "$_sel" | jq -r '.domain   // ""' 2>/dev/null)
        win_pass=$(echo "$_sel" | jq -r '.password // ""' 2>/dev/null)
        win_user="${_sd:+$_sd\\}${_su}"
    else
        # Interactive: show stored credential list
        if [[ "${win_cred_count:-0}" -gt 0 ]]; then
            printf "\n  ${W}Stored Windows credentials:${NC}\n"
            local _idx=0
            while IFS= read -r _c; do
                local _u _d
                _u=$(echo "$_c" | jq -r '.username // ""' 2>/dev/null)
                _d=$(echo "$_c" | jq -r '.domain   // ""' 2>/dev/null)
                if [[ -n "$_d" ]]; then
                    printf "   %d) %s\\%s\n" "$(( _idx + 1 ))" "$_d" "$_u"
                else
                    printf "   %d) .\\%s\n" "$(( _idx + 1 ))" "$_u"
                fi
                (( _idx++ )) || true
            done < <(echo "$win_creds" | jq -c '.[]'  2>/dev/null)
            printf "   0) Enter credentials manually\n"
            local _pick
            read -rp $'\n  Select [1]: ' _pick; _pick="${_pick:-1}"
            if [[ "$_pick" =~ ^[1-9][0-9]*$ && "$_pick" -le "$win_cred_count" ]]; then
                local _sel; _sel=$(echo "$win_creds" \
                    | jq -c ".[$(( _pick - 1 ))]" 2>/dev/null)
                local _su _sd
                _su=$(echo "$_sel" | jq -r '.username // ""' 2>/dev/null)
                _sd=$(echo "$_sel" | jq -r '.domain   // ""' 2>/dev/null)
                win_pass=$(echo "$_sel" | jq -r '.password // ""' 2>/dev/null)
                win_user="${_sd:+$_sd\\}${_su}"
            fi
        fi
        # Fall back to manual entry if nothing selected
        [[ -z "$win_user" ]] && read -rp  "  Windows username (domain\user): " win_user
        [[ -z "$win_pass" ]] && { read -rsp "  Windows password: " win_pass; echo; }
        read -rp "  WinRM port [5985]: " _wp
        [[ -n "${_wp:-}" ]] && win_port="$_wp"
    fi

    # Resolve NetBox IDs for cluster type and VM role ----------------------
    local site_id; site_id=$(nb_get_or_create_site)
    local ct_id;   ct_id=$(nb_get_or_create_cluster_type "Microsoft Hyper-V")
    local role_id; role_id=$(nb_get_or_create_role "Server" "2196f3")
    if [[ -z "$ct_id"   || ! "$ct_id"   =~ ^[0-9]+$ ]]; then
        log_error "Cannot get/create cluster type"; pause; return 1; fi
    if [[ -z "$role_id" || ! "$role_id" =~ ^[0-9]+$ ]]; then
        log_error "Cannot get/create VM role";       pause; return 1; fi

    log_info "Cluster type ID: $ct_id  |  Role ID: $role_id"

    # Generate the PS1 script with substituted settings --------------------
    local ps1_file; ps1_file=$(mktemp --suffix=.ps1)
    python3 - "$ps1_file" \
        "$NETBOX_API_TOKEN" "${NETBOX_API_URL}/api" \
        "$host_ip" "$ct_id" "$role_id" "$site_id" <<'GENEOF'
import sys, textwrap

out_path   = sys.argv[1]
nb_token   = sys.argv[2]
nb_uri     = sys.argv[3]
hv_host    = sys.argv[4]
ct_id      = sys.argv[5]
role_id    = sys.argv[6]
site_id    = sys.argv[7]

ps1 = textwrap.dedent(rf"""
$token      = "{nb_token}"
$uri        = "{nb_uri}"
$hyperVHost = "{hv_host}"
$NetboxHyperVClusterType = {ct_id}
$NetboxServerRoleID      = {role_id}
$SiteId                  = {site_id}

############################################################
# Hyper-V to NetBox Sync  --  Host Device + Cluster + VMs
############################################################

if ($PSVersionTable.PSVersion.Major -ge 6) {{
    $global:PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true
}} else {{
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {{
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {{
        return true;
    }}
}}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InformationPreference = "SilentlyContinue"
$ProgressPreference    = "SilentlyContinue"
$VerbosePreference     = "SilentlyContinue"
$DebugPreference       = "SilentlyContinue"

$uri = $uri.TrimEnd("/")
$cs = Get-CimInstance Win32_ComputerSystem

if ($cs.Domain -and $cs.Domain -ne "WORKGROUP") {{
    $hostName = "$($cs.DNSHostName).$($cs.Domain)"
}} else {{
    try {{
        $hostName = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
    }} catch {{
        $hostName = $env:COMPUTERNAME
    }}
}}
$clusterName = "$env:COMPUTERNAME"

$headers = $null
function New-AuthHeaders {{
    $h = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $h.Add("Authorization", "Token $token")
    $h.Add("Content-Type",  "application/json")
    $h.Add("Accept",        "application/json")
    return $h
}}
$headers = New-AuthHeaders

function Invoke-NB {{
    param([string]$Uri,[string]$Method="GET",[string]$Body=$null)
    $p = @{{Uri=$Uri;Method=$Method;Headers=$headers;UseBasicParsing=$true}}
    if ($Body) {{ $p.Body = $Body }}
    return Invoke-WebRequest @p
}}

function Get-NBErrorBody {{
    param($Exception)
    try {{
        $r = $Exception.Response
        if ($r -and $r.GetResponseStream()) {{
            return (New-Object System.IO.StreamReader($r.GetResponseStream())).ReadToEnd()
        }}
    }} catch {{}}
    return $null
}}

############################################################
# MAC helpers
############################################################

function Normalize-MacRaw {{
    param([string]$Mac)
    if (-not $Mac) {{ return $null }}
    return ($Mac -replace '[^0-9A-Fa-f]','').ToLower()
}}

function Normalize-MacPretty {{
    param([string]$Mac)
    $raw = Normalize-MacRaw $Mac
    if (-not $raw -or $raw.Length -ne 12) {{ return $null }}
    return (($raw -split '(.{{2}})' | Where-Object {{ $_ -ne '' }}) -join ':').ToUpper()
}}

############################################################
# Subnet helpers
############################################################

function Get-MaskFromPrefix {{
    param([string]$Prefix)
    $ml = [int]($Prefix.Split("/")[1])
    $mb = @([byte]0,[byte]0,[byte]0,[byte]0)
    for ($i=0;$i -lt 4;$i++) {{
        $bits=[Math]::Max(0,[Math]::Min(8,$ml-($i*8)))
        $mb[$i] = switch ($bits) {{
            8 {{ [byte]255 }}
            0 {{ [byte]0 }}
            default {{ [byte](256-[Math]::Pow(2,8-$bits)) }}
        }}
    }}
    return [System.Net.IPAddress]::new([byte[]]$mb)
}}

function Test-IPInSubnet {{
    param([System.Net.IPAddress]$Subnet,[System.Net.IPAddress]$Mask,[System.Net.IPAddress]$IPAddress)
    $mk=$Mask.GetAddressBytes(); $sk=$Subnet.GetAddressBytes(); $ik=$IPAddress.GetAddressBytes()
    for ($i=0;$i -lt 4;$i++) {{
        if (($ik[$i] -band $mk[$i]) -ne $sk[$i]) {{ return $false }}
    }}
    return $true
}}

############################################################
# Pre-flight checks
############################################################

function Test-NetboxConnectivity {{
    Write-Host "Running pre-flight checks..."
    $eps = @(
        "$uri/dcim/devices/",
        "$uri/dcim/device-types/",
        "$uri/dcim/manufacturers/",
        "$uri/dcim/device-roles/",
        "$uri/virtualization/clusters/",
        "$uri/virtualization/virtual-machines/",
        "$uri/virtualization/interfaces/",
        "$uri/dcim/mac-addresses/",
        "$uri/ipam/prefixes/",
        "$uri/ipam/ip-addresses/"
    )
    $ok=$true
    foreach ($ep in $eps) {{
        try {{
            Invoke-NB -Uri "${{ep}}?limit=1" | Out-Null
            Write-Host "  [OK]   $ep"
        }} catch {{
            Write-Host "  [FAIL] $ep -- $($_.Exception.Message)"
            $eb = Get-NBErrorBody $_.Exception
            if ($eb) {{ Write-Host "         $eb" }}
            $ok=$false
        }}
    }}
    if (-not $ok) {{
        Write-Host "[ABORT] Fix the above errors first."
        exit 1
    }}
    Write-Host "Pre-flight checks passed.`n"
}}

############################################################
# Manufacturer / Device Type / Device Role helpers
############################################################

function Get-OrCreateManufacturer {{
    param([string]$Name)
    if (-not $Name) {{ $Name = "Unknown" }}
    $slug = ($Name.ToLower() -replace '[^a-z0-9]+','-').Trim('-')
    # GET by name first
    try {{
        $resp = Invoke-NB -Uri "$uri/dcim/manufacturers/?name=$([uri]::EscapeDataString($Name))"
        $res  = ($resp.Content | ConvertFrom-Json).results
        if ($res.Count -gt 0) {{ return $res[0] }}
    }} catch {{}}
    # Try POST
    $body = @{{ name = $Name; slug = $slug }} | ConvertTo-Json
    try {{
        $resp = Invoke-NB -Uri "$uri/dcim/manufacturers/" -Method POST -Body $body
        $obj  = $resp.Content | ConvertFrom-Json
        if ($obj.id) {{ return $obj }}
    }} catch {{}}
    # POST failed (slug collision) -- fall back to GET by slug
    try {{
        $resp = Invoke-NB -Uri "$uri/dcim/manufacturers/?slug=$([uri]::EscapeDataString($slug))"
        $res  = ($resp.Content | ConvertFrom-Json).results
        if ($res.Count -gt 0) {{ return $res[0] }}
    }} catch {{}}
    Write-Host "  [ERROR] Cannot get or create manufacturer: $Name"
    return $null
}}

function Get-OrCreateDeviceType {{
    param([int]$ManufacturerId,[string]$Model)
    if (-not $Model) {{ $Model = "Unknown" }}
    $slug = ($Model.ToLower() -replace '[^a-z0-9]+','-').Trim('-')
    if ($slug.Length -gt 64) {{ $slug = $slug.Substring(0,64).TrimEnd('-') }}
    # GET by model + manufacturer
    try {{
        $resp = Invoke-NB -Uri "$uri/dcim/device-types/?model=$([uri]::EscapeDataString($Model))&manufacturer_id=$ManufacturerId"
        $res  = ($resp.Content | ConvertFrom-Json).results
        if ($res.Count -gt 0) {{ return $res[0] }}
    }} catch {{}}
    # Try POST
    $body = @{{ model = $Model; slug = $slug; manufacturer = $ManufacturerId; u_height = 1 }} | ConvertTo-Json
    try {{
        $resp = Invoke-NB -Uri "$uri/dcim/device-types/" -Method POST -Body $body
        $obj  = $resp.Content | ConvertFrom-Json
        if ($obj.id) {{ return $obj }}
    }} catch {{}}
    # POST failed (slug collision) -- fall back to GET by slug
    try {{
        $resp = Invoke-NB -Uri "$uri/dcim/device-types/?slug=$([uri]::EscapeDataString($slug))"
        $res  = ($resp.Content | ConvertFrom-Json).results
        if ($res.Count -gt 0) {{ return $res[0] }}
    }} catch {{}}
    # Last resort: search by model name only (ignore manufacturer)
    try {{
        $resp = Invoke-NB -Uri "$uri/dcim/device-types/?model=$([uri]::EscapeDataString($Model))"
        $res  = ($resp.Content | ConvertFrom-Json).results
        if ($res.Count -gt 0) {{ return $res[0] }}
    }} catch {{}}
    Write-Host "  [ERROR] Cannot get or create device type: $Model"
    return $null
}}

function Get-DeviceRoleByName {{
    param([string]$Name)
    try {{
        $resp = Invoke-NB -Uri "$uri/dcim/device-roles/?name=$([uri]::EscapeDataString($Name))"
        $res  = ($resp.Content | ConvertFrom-Json).results
        if ($res.Count -gt 0) {{ return $res[0] }}
    }} catch {{}}
    Write-Host "[ERROR] Device role '$Name' not found in NetBox. Create it first."
    exit 1
}}

############################################################
# Cluster helpers
############################################################

function Get-NetboxCluster {{
    param([string]$Name)
    try {{
        $resp = Invoke-NB -Uri "$uri/virtualization/clusters/?name=$([uri]::EscapeDataString($Name))"
        return (($resp.Content | ConvertFrom-Json).results)[0]
    }} catch {{ return $null }}
}}

function Add-NetboxCluster {{
    param([string]$Name,[int]$NetboxHyperVClusterType)
    $b=@{{name=$Name;type=$NetboxHyperVClusterType}}|ConvertTo-Json
    $resp = Invoke-NB -Uri "$uri/virtualization/clusters/" -Method POST -Body $b
    return ($resp.Content|ConvertFrom-Json)
}}

function Set-NetboxCluster {{
    param([string]$Name,[int]$NetboxHyperVClusterType)
    $c=Get-NetboxCluster -Name $Name
    if (-not $c) {{ $c=Add-NetboxCluster -Name $Name -NetboxHyperVClusterType $NetboxHyperVClusterType }}
    return [int]$c.id
}}

############################################################
# Device helpers (Hyper-V host)
############################################################

function Get-NetboxDevice {{
    param([string]$Name)
    try {{
        $resp = Invoke-NB -Uri "$uri/dcim/devices/?name=$([uri]::EscapeDataString($Name))"
        return (($resp.Content | ConvertFrom-Json).results)[0]
    }} catch {{ return $null }}
}}

function Add-NetboxDevice {{
    param([string]$Name,[int]$ClusterId,[int]$SiteId,[int]$DeviceTypeId,[int]$DeviceRoleId)
    $b = @{{
        name=$Name; device_type=$DeviceTypeId; role=$DeviceRoleId
        site=$SiteId; status="active"; cluster=$ClusterId
    }} | ConvertTo-Json
    $resp = Invoke-NB -Uri "$uri/dcim/devices/" -Method POST -Body $b
    return ($resp.Content | ConvertFrom-Json)
}}

function Find-DeviceByHostIP {{
    # IP-first dedup: find an existing device that owns this host IP.
    # Prevents a second device being created when a device was previously
    # created by an nmap scan using an auto-generated name.
    param([string]$HostIP)
    if (-not $HostIP) {{ return $null }}
    foreach ($cidr in @("$HostIP/32", $HostIP)) {{
        try {{
            $enc = [uri]::EscapeDataString($cidr)
            $r = ((Invoke-NB -Uri "$uri/ipam/ip-addresses/?address=$enc&limit=1").Content | ConvertFrom-Json).results
            if ($r.Count -gt 0 -and $r[0].assigned_object_type -eq "dcim.interface" -and $r[0].assigned_object_id) {{
                $ifId = [int]$r[0].assigned_object_id
                $iface = ((Invoke-NB -Uri "$uri/dcim/interfaces/$ifId/").Content | ConvertFrom-Json)
                if ($iface.device -and $iface.device.id) {{ return [int]$iface.device.id }}
            }}
        }} catch {{}}
    }}
    return $null
}}

function Set-NetboxDevice {{
    param([string]$Name,[int]$ClusterId,[int]$SiteId,[int]$DeviceTypeId,[int]$DeviceRoleId)
    $devId = $null
    # Try IP-first: resolve the local host IP to find any pre-existing device
    $localIP = (Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object {{ $_.IPAddress -notlike "169.254*" -and
                                $_.IPAddress -ne "127.0.0.1" -and
                                $_.IPAddress -ne "0.0.0.0" }} |
                Select-Object -First 1).IPAddress
    if ($localIP) {{ $devId = Find-DeviceByHostIP -HostIP $localIP }}
    if ($devId) {{
        Write-Host "  Found existing device by IP $localIP (ID $devId)"
        # Smart rename: upgrade auto-gen placeholder to real hostname
        $curName = ((Invoke-NB -Uri "$uri/dcim/devices/$devId/").Content | ConvertFrom-Json).name
        if ($curName -match "^device-\d+-\d+-\d+-\d+$" -and $Name -notmatch "^device-\d+-\d+-\d+-\d+$") {{
            Write-Host "  Renaming $curName -> $Name"
        }} elseif ($curName -notmatch "^device-\d+-\d+-\d+-\d+$" -and $Name -match "^device-\d+-\d+-\d+-\d+$") {{
            Write-Host "  Keeping richer name $curName"
            $Name = $curName
        }}
        $patch = @{{
            name=$Name; cluster=$ClusterId; site=$SiteId
            device_type=$DeviceTypeId; role=$DeviceRoleId; status="active"
        }} | ConvertTo-Json
        try {{ Invoke-NB -Uri "$uri/dcim/devices/$devId/" -Method PATCH -Body $patch | Out-Null }}
        catch {{ Write-Host "  [WARN] Update device $Name : $($_.Exception.Message)" }}
        return $devId
    }}
    # Fall back to name lookup
    $dev = Get-NetboxDevice -Name $Name
    if ($dev) {{
        $patch = @{{
            cluster=$ClusterId; site=$SiteId
            device_type=$DeviceTypeId; role=$DeviceRoleId; status="active"
        }} | ConvertTo-Json
        try {{ Invoke-NB -Uri "$uri/dcim/devices/$($dev.id)/" -Method PATCH -Body $patch | Out-Null }}
        catch {{ Write-Host "  [WARN] Failed to update device $Name : $($_.Exception.Message)" }}
    }} else {{
        $dev = Add-NetboxDevice -Name $Name -ClusterId $ClusterId -SiteId $SiteId -DeviceTypeId $DeviceTypeId -DeviceRoleId $DeviceRoleId
    }}
    return [int]$dev.id
}}

############################################################
# Custom field helpers (dcim.device)
############################################################

function Ensure-CustomField {{
    param([string]$Name,[string]$Label,[string]$Type)
    try {{
        $resp = Invoke-NB -Uri "$uri/extras/custom-fields/?name=$([uri]::EscapeDataString($Name))"
        $res  = ($resp.Content | ConvertFrom-Json).results
        if ($res.Count -gt 0) {{ return $res[0] }}
    }} catch {{}}
    $body = @{{
        name=$Name; label=$Label; type=$Type; object_types=@("dcim.device")
    }} | ConvertTo-Json
    try {{
        $resp = Invoke-NB -Uri "$uri/extras/custom-fields/" -Method POST -Body $body
        return ($resp.Content | ConvertFrom-Json)
    }} catch {{
        Write-Host "  [WARN] Failed to create custom field $Name : $($_.Exception.Message)"
        return $null
    }}
}}

function Ensure-HostCustomFields {{
    param([int]$MaxDiskIndex)
    Ensure-CustomField -Name "vcpus"         -Label "vCPUs"           -Type "integer" | Out-Null
    Ensure-CustomField -Name "memory_mb"     -Label "Memory (MB)"     -Type "integer" | Out-Null
    Ensure-CustomField -Name "memory_gb"     -Label "Memory (GB)"     -Type "integer" | Out-Null
    Ensure-CustomField -Name "disk_total_gb" -Label "Disk Total (GB)" -Type "integer" | Out-Null
    Ensure-CustomField -Name "disk_count"    -Label "Disk Count"      -Type "integer" | Out-Null
    Ensure-CustomField -Name "os_version"    -Label "OS Version"      -Type "text"    | Out-Null
    Ensure-CustomField -Name "cpu_model"     -Label "CPU Model"       -Type "text"    | Out-Null
    for ($i=0; $i -le $MaxDiskIndex; $i++) {{
        Ensure-CustomField -Name ("disk_{{0}}_size_gb"   -f $i) -Label ("Disk {{0}} Size (GB)"   -f $i) -Type "integer" | Out-Null
        Ensure-CustomField -Name ("disk_{{0}}_media"     -f $i) -Label ("Disk {{0}} Media"       -f $i) -Type "text"    | Out-Null
        Ensure-CustomField -Name ("disk_{{0}}_interface" -f $i) -Label ("Disk {{0}} Interface"   -f $i) -Type "text"    | Out-Null
    }}
}}

############################################################
# IPAM prefix helpers
############################################################

function Get-NetboxIPAMPrefixes {{
    $all=@(); $next="$uri/ipam/prefixes/?limit=1000"
    while ($next) {{
        try {{
            $r=(Invoke-NB -Uri $next).Content|ConvertFrom-Json
            $all+=$r.results
            $next=if($r.next){{$r.next}}else{{$null}}
        }} catch {{ break }}
    }}
    Write-Host "  Loaded $($all.Count) IPAM prefix(es)"
    return $all
}}

function Get-NetboxPrefixFromIP {{
    param([System.Net.IPAddress]$IP,$Prefixes)
    if ($IP.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {{ return $null }}
    foreach ($p in $Prefixes) {{
        if ($p.prefix -notmatch '^\d+\.\d+\.\d+\.\d+/') {{ continue }}
        $mask=Get-MaskFromPrefix -Prefix $p.prefix
        $sip=[System.Net.IPAddress]::Parse($p.prefix.Split("/")[0])
        if (Test-IPInSubnet -IPAddress $IP -Subnet $sip -Mask $mask) {{
            return $p.prefix.Split("/")[1]
        }}
    }}
    return $null
}}

############################################################
# VM helpers
############################################################

function Find-NetboxVM {{
    param([string]$Name)
    try {{
        return (((Invoke-NB -Uri "$uri/virtualization/virtual-machines/?name=$([uri]::EscapeDataString($Name))").Content|ConvertFrom-Json).results)
    }} catch {{ return @() }}
}}

function Get-VMTotalDiskBytes {{
    param([string]$VmName)
    $total = 0
    $drives = Get-VMHardDiskDrive -VMName $VmName -ErrorAction SilentlyContinue
    foreach ($d in $drives) {{
        try {{
            if (Test-Path $d.Path) {{
                $vhd = Get-VHD -Path $d.Path -ErrorAction Stop
                if ($vhd -and $vhd.Size) {{ $total += $vhd.Size }}
            }}
        }} catch {{}}
    }}
    return [int64]$total
}}

function Sync-NetboxVM {{
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM,[int]$RoleId,[int]$ClusterId)
    $nm=$VM.VMName
    $existing=Find-NetboxVM -Name $nm
    $tid=$null
    foreach ($m in $existing) {{
        if ($m.cluster -and $m.cluster.id -eq $ClusterId) {{ $tid=$m.id }}
    }}
    $diskGB=[int][Math]::Ceiling((Get-VMTotalDiskBytes -VmName $nm)/1GB)
    $memMB=if($VM.DynamicMemoryEnabled){{[int]($VM.MemoryMaximum/1MB)}}else{{[int]($VM.MemoryStartup/1MB)}}
    $status=if($VM.State -eq "Running"){{"active"}}else{{"offline"}}
    $b=@{{
        name=$nm; cluster=$ClusterId; status=$status; role=$RoleId
        vcpus=[int]$VM.ProcessorCount; memory=$memMB; disk=$diskGB
    }} | ConvertTo-Json
    try {{
        if ($tid) {{$r=Invoke-NB -Uri "$uri/virtualization/virtual-machines/$tid/" -Method PATCH -Body $b}}
        else       {{$r=Invoke-NB -Uri "$uri/virtualization/virtual-machines/" -Method POST -Body $b}}
        return [int]($r.Content|ConvertFrom-Json).id
    }} catch {{
        Write-Host "  [ERROR] VM sync failed for $nm : $($_.Exception.Message)"
        $eb=Get-NBErrorBody $_.Exception
        if($eb){{Write-Host "  $eb"}}
        return $null
    }}
}}

############################################################
# MAC object helpers
############################################################

function Get-NetboxMac {{
    param([string]$MacPretty)
    try {{
        $r=((Invoke-NB -Uri "$uri/dcim/mac-addresses/?mac_address=$MacPretty").Content|ConvertFrom-Json).results
        if($r.Count -gt 0){{return $r[0]}}
    }} catch {{}}
    return $null
}}

function Create-NetboxMac {{
    param([string]$MacPretty,[int]$NicId)
    $b=@{{
        mac_address=$MacPretty
        assigned_object_type="virtualization.vminterface"
        assigned_object_id=$NicId
    }} | ConvertTo-Json
    try {{
        $r=(Invoke-NB -Uri "$uri/dcim/mac-addresses/" -Method POST -Body $b).Content|ConvertFrom-Json
        Write-Host "  Created MAC $MacPretty (ID $($r.id))"
        return $r
    }} catch {{
        $ex=Get-NetboxMac -MacPretty $MacPretty
        if($ex){{Write-Host "  MAC $MacPretty exists (ID $($ex.id))"; return $ex}}
        Write-Host "  [ERROR] MAC create failed $MacPretty : $($_.Exception.Message)"
        return $null
    }}
}}

function Ensure-NetboxMac {{
    param([string]$MacPretty,[int]$NicId)
    $m=Get-NetboxMac -MacPretty $MacPretty
    if($m){{return $m}}
    return (Create-NetboxMac -MacPretty $MacPretty -NicId $NicId)
}}

############################################################
# NIC helpers (VM)
############################################################

function Test-NetboxInterfaceExists {{
    param([int]$NicId)
    try {{
        return ((Invoke-NB -Uri "$uri/virtualization/interfaces/$NicId/").StatusCode -eq 200)
    }} catch {{ return $false }}
}}

function Get-NetboxNIC {{
    param([string]$VmId,[string]$MacAddress)
    $mp=Normalize-MacPretty $MacAddress
    $mr=Normalize-MacRaw $MacAddress
    if ($mp) {{
        try {{
            $mo=Get-NetboxMac -MacPretty $mp
            if ($mo -and $mo.assigned_object_type -eq "virtualization.vminterface" -and $mo.assigned_object_id) {{
                $cid=[int]$mo.assigned_object_id
                if (Test-NetboxInterfaceExists -NicId $cid) {{ return $cid }}
                Write-Host "  [WARN] MAC points to deleted interface $cid -- will recreate"
            }}
        }} catch {{}}
    }}
    try {{
        $r=((Invoke-NB -Uri "$uri/virtualization/interfaces/?virtual_machine_id=$VmId").Content|ConvertFrom-Json).results
        foreach ($n in $r) {{
            $nr=Normalize-MacRaw $n.mac_address
            if ($nr -and $nr -eq $mr) {{ return [int]$n.id }}
            if ($mp -and $n.name -like "*($mp)") {{ return [int]$n.id }}
        }}
    }} catch {{}}
    return $null
}}

function Set-NetboxNICMac {{
    param([int]$NicId,[string]$MacPretty)
    $mo=Ensure-NetboxMac -MacPretty $MacPretty -NicId $NicId
    if (-not $mo) {{ return }}
    if ($mo.assigned_object_id -ne $NicId -or $mo.assigned_object_type -ne "virtualization.vminterface") {{
        $mp=@{{assigned_object_type="virtualization.vminterface";assigned_object_id=$NicId}}|ConvertTo-Json
        try {{Invoke-NB -Uri "$uri/dcim/mac-addresses/$($mo.id)/" -Method PATCH -Body $mp|Out-Null}}
        catch {{Write-Host "  [WARN] MAC reassign failed: $($_.Exception.Message)"}}
    }}
    $pp=@{{primary_mac_address=$mo.id}}|ConvertTo-Json
    try {{Invoke-NB -Uri "$uri/virtualization/interfaces/$NicId/" -Method PATCH -Body $pp|Out-Null}}
    catch {{Write-Host "  [WARN] primary_mac_address set failed: $($_.Exception.Message)"}}
}}

function Create-NetboxNIC {{
    param([Microsoft.HyperV.PowerShell.VMNetworkAdapter]$NetworkAdapter,[int]$VirtualMachineId)
    $mr=Normalize-MacRaw $NetworkAdapter.MacAddress
    $mp=Normalize-MacPretty $NetworkAdapter.MacAddress
    if (-not $mr -or -not $mp) {{
        Write-Host "  [WARN] Invalid MAC for $($NetworkAdapter.Name)"
        return $null
    }}
    $nm="$($NetworkAdapter.Name) ($mp)"
    $b=@{{name=$nm;virtual_machine=$VirtualMachineId}}|ConvertTo-Json
    $nic=$null
    try {{
        $nic=((Invoke-NB -Uri "$uri/virtualization/interfaces/" -Method POST -Body $b).Content|ConvertFrom-Json)
        Write-Host "  Created NIC: $nm (ID $($nic.id))"
    }} catch {{
        Write-Host "  [ERROR] NIC create failed $($NetworkAdapter.Name): $($_.Exception.Message)"
        return $null
    }}
    Set-NetboxNICMac -NicId ([int]$nic.id) -MacPretty $mp
    return [int]$nic.id
}}

function Update-NetboxNIC {{
    param([int]$NicId,[string]$MacPretty,[string]$AdapterName)
    $nm="$AdapterName ($MacPretty)"
    try {{Invoke-NB -Uri "$uri/virtualization/interfaces/$NicId/" -Method PATCH -Body (@{{name=$nm}}|ConvertTo-Json)|Out-Null}}
    catch {{Write-Host "  [WARN] NIC update $NicId failed: $($_.Exception.Message)"; return $false}}
    Set-NetboxNICMac -NicId $NicId -MacPretty $MacPretty
    return $true
}}

function Remove-StaleNetboxNICs {{
    param([string]$VmId,[array]$CurrentMacsRaw)
    try {{$r=((Invoke-NB -Uri "$uri/virtualization/interfaces/?virtual_machine_id=$VmId").Content|ConvertFrom-Json).results}}
    catch {{return}}
    foreach ($n in $r) {{
        $nr=$null
        try {{
            $mr=((Invoke-NB -Uri "$uri/dcim/mac-addresses/?assigned_object_type=virtualization.vminterface&assigned_object_id=$($n.id)").Content|ConvertFrom-Json).results
            if($mr.Count -gt 0){{$nr=Normalize-MacRaw $mr[0].mac_address}}
        }} catch {{}}
        if (-not $nr){{$nr=Normalize-MacRaw $n.mac_address}}
        if (-not $nr -and $n.name -match '\(([0-9a-fA-F:]{{17}})\)\s*$'){{$nr=Normalize-MacRaw $Matches[1]}}
        if (-not $nr -or $CurrentMacsRaw -notcontains $nr) {{
            Write-Host "  Removing stale NIC: $($n.name)"
            try {{Invoke-NB -Uri "$uri/virtualization/interfaces/$($n.id)/" -Method DELETE|Out-Null}} catch {{}}
        }}
    }}
}}

############################################################
# Virtual disk helpers
############################################################

function Get-NetboxVirtualDisks {{
    param([string]$VmId)
    try {{
        return ((Invoke-NB -Uri "$uri/virtualization/virtual-disks/?virtual_machine_id=$VmId").Content|ConvertFrom-Json).results
    }} catch {{ return @() }}
}}

function Sync-NetboxVirtualDisk {{
    param([string]$VmId,[string]$VmName,[string]$DiskPath,[int64]$DiskBytes,[int]$Index,$ExistingDisks)
    $dn=($VmName+"-disk$Index") -replace '[^a-zA-Z0-9\-]','-'
    $sg=[int][Math]::Ceiling($DiskBytes/1GB)
    $ex=$ExistingDisks|Where-Object{{$_.name -eq $dn}}|Select-Object -First 1
    $b=@{{name=$dn;size=$sg;virtual_machine=$VmId}}|ConvertTo-Json
    try {{
        if ($ex) {{Invoke-NB -Uri "$uri/virtualization/virtual-disks/$($ex.id)/" -Method PATCH -Body $b|Out-Null; Write-Host "  Updated disk $dn ($sg GB)"}}
        else      {{Invoke-NB -Uri "$uri/virtualization/virtual-disks/" -Method POST -Body $b|Out-Null; Write-Host "  Created disk $dn ($sg GB)"}}
    }} catch {{Write-Host "  [ERROR] Disk sync $dn : $($_.Exception.Message)"}}
}}

function Remove-ObsoleteNetboxVirtualDisks {{
    param([string]$VmId,[string]$VmName,[int]$CurrentDiskCount)
    foreach ($d in (Get-NetboxVirtualDisks -VmId $VmId)) {{
        if ($d.name -match '-disk(\d+)$' -and [int]$Matches[1] -ge $CurrentDiskCount) {{
            Write-Host "  Removing obsolete disk: $($d.name)"
            try {{Invoke-NB -Uri "$uri/virtualization/virtual-disks/$($d.id)/" -Method DELETE|Out-Null}} catch {{}}
        }}
    }}
}}

############################################################
# IP helpers
############################################################

function Get-NetboxIPFull {{
    param([string]$Cidr)
    # Try exact CIDR, then IP-only -- handles existing entries with a
    # different prefix length (e.g. /24 stored, /32 queried)
    foreach ($q in @($Cidr, $Cidr.Split("/")[0])) {{
        try {{
            $enc=[uri]::EscapeDataString($q)
            $r=((Invoke-NB -Uri "$uri/ipam/ip-addresses/?address=$enc").Content|ConvertFrom-Json).results
            if($r.Count -gt 0){{return $r[0]}}
        }} catch {{}}
    }}
    return $null
}}

function Create-NetboxIP {{
    param([System.Net.IPAddress]$IP,[string]$Mask)
    $cidr="$($IP.IPAddressToString)/$Mask"
    $b=@{{address=$cidr;shared=$true}}|ConvertTo-Json
    try {{return ((Invoke-NB -Uri "$uri/ipam/ip-addresses/" -Method POST -Body $b).Content|ConvertFrom-Json)}}
    catch {{Write-Host "  [ERROR] IP create $cidr : $($_.Exception.Message)"; return $null}}
}}

function Ensure-IPShared {{
    param([int]$IpId)
    try {{Invoke-NB -Uri "$uri/ipam/ip-addresses/$IpId/" -Method PATCH -Body (@{{shared=$true}}|ConvertTo-Json)|Out-Null}}
    catch {{Write-Host "  [WARN] shared=true failed on IP $IpId"}}
}}

function Assign-IPToNIC {{
    param([int]$IpId,[int]$NicId)
    # Step 1: clear any existing assignment (NetBox 400s on direct
    # cross-type reassignment, e.g. dcim.interface -> vminterface)
    try {{
        $clearBody=(@{{assigned_object_type=$null;assigned_object_id=$null}}|ConvertTo-Json)
        Invoke-NB -Uri "$uri/ipam/ip-addresses/$IpId/" -Method PATCH -Body $clearBody|Out-Null
    }} catch {{}}
    # Step 2: assign to the VM NIC
    $b=@{{assigned_object_type="virtualization.vminterface";assigned_object_id=$NicId}}|ConvertTo-Json
    try {{
        Invoke-NB -Uri "$uri/ipam/ip-addresses/$IpId/" -Method PATCH -Body $b|Out-Null
        return $true
    }} catch {{
        Write-Host "  [WARN] IP $IpId assign to NIC $NicId failed: $($_.Exception.Message)"
        return $false
    }}
}}

function Set-NetboxVMPrimaryIP {{
    param([int]$VmId,[int]$IpId)
    if (-not $VmId -or -not $IpId) {{ return $false }}
    try {{
        Invoke-NB -Uri "$uri/virtualization/virtual-machines/$VmId/" -Method PATCH -Body (@{{primary_ip4=$IpId}}|ConvertTo-Json)|Out-Null
        return $true
    }} catch {{
        Write-Host "  [ERROR] Primary IP $IpId on VM $VmId failed: $($_.Exception.Message)"
        return $false
    }}
}}

############################################################
# Host MAC / IP helpers (DCIM)
############################################################

function Ensure-HostMac {{
    param([string]$MacPretty,[int]$InterfaceId)
    try {{
        $r=((Invoke-NB -Uri "$uri/dcim/mac-addresses/?mac_address=$MacPretty").Content|ConvertFrom-Json).results
        if ($r.Count -gt 0) {{ return $r[0] }}
    }} catch {{}}
    $b=@{{
        mac_address=$MacPretty
        assigned_object_type="dcim.interface"
        assigned_object_id=$InterfaceId
    }} | ConvertTo-Json
    try {{
        $r=(Invoke-NB -Uri "$uri/dcim/mac-addresses/" -Method POST -Body $b).Content|ConvertFrom-Json
        Write-Host "  Created host MAC $MacPretty (ID $($r.id))"
        return $r
    }} catch {{
        Write-Host "  [ERROR] Host MAC create failed $MacPretty : $($_.Exception.Message)"
        return $null
    }}
}}

function Assign-HostIPToNIC {{
    param([int]$IpId,[int]$NicId)
    # Clear any existing assignment first to avoid cross-type 400 errors
    try {{
        $clearBody=(@{{assigned_object_type=$null;assigned_object_id=$null}}|ConvertTo-Json)
        Invoke-NB -Uri "$uri/ipam/ip-addresses/$IpId/" -Method PATCH -Body $clearBody|Out-Null
    }} catch {{}}
    $b=@{{assigned_object_type="dcim.interface";assigned_object_id=$NicId}}|ConvertTo-Json
    try {{Invoke-NB -Uri "$uri/ipam/ip-addresses/$IpId/" -Method PATCH -Body $b|Out-Null}}
    catch {{Write-Host "  [WARN] Host IP $IpId assign to NIC $NicId failed: $($_.Exception.Message)"}}
}}

############################################################
# MAIN
############################################################

Write-Host "Starting Hyper-V to NetBox sync"
Write-Host ""
Test-NetboxConnectivity

$bios= Get-CimInstance Win32_BIOS
$os  = Get-CimInstance Win32_OperatingSystem

$manufacturerName = $cs.Manufacturer
$modelName        = $cs.Model

Write-Host "Host hardware: $manufacturerName $modelName"
$manufacturer = Get-OrCreateManufacturer -Name $manufacturerName
if (-not $manufacturer -or -not $manufacturer.id) {{
    Write-Host "[ERROR] Cannot resolve manufacturer -- aborting sync"
    exit 1
}}
$deviceType = Get-OrCreateDeviceType -ManufacturerId ([int]$manufacturer.id) -Model $modelName
if (-not $deviceType -or -not $deviceType.id) {{
    Write-Host "[ERROR] Cannot resolve device type -- aborting sync"
    exit 1
}}
$deviceRole   = Get-DeviceRoleByName -Name "Server"

$clusterId = Set-NetboxCluster -Name $clusterName -NetboxHyperVClusterType $NetboxHyperVClusterType
$deviceId  = Set-NetboxDevice -Name $hostName -ClusterId $clusterId -SiteId $SiteId -DeviceTypeId ([int]$deviceType.id) -DeviceRoleId ([int]$deviceRole.id)

$serial = $bios.SerialNumber
$asset  = $cs.IdentifyingNumber
$hostPatch = @{{ serial=$serial; asset_tag=$asset }} | ConvertTo-Json
try {{
    Invoke-NB -Uri "$uri/dcim/devices/$deviceId/" -Method PATCH -Body $hostPatch | Out-Null
    Write-Host "  Updated host serial + asset tag"
}} catch {{ Write-Host "  [WARN] Failed to update host serial/asset: $($_.Exception.Message)" }}

$vcpus       = [int]$cs.NumberOfLogicalProcessors
$memoryBytes = [int64]$cs.TotalPhysicalMemory
$memoryMB    = [int][Math]::Round($memoryBytes / 1MB)
$memoryGB    = [int][Math]::Round($memoryBytes / 1GB)

$diskInfo=@()
try {{
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {{ $diskInfo=Get-PhysicalDisk }}
    else {{ $diskInfo=Get-CimInstance Win32_DiskDrive }}
}} catch {{}}

$diskCount=0; $diskTotalGB=0; $diskDetails=@(); $idx=0
foreach ($d in $diskInfo) {{
    $sizeBytes=0; $media="Unknown"; $iface="Unknown"
    if ($d.PSObject.Properties.Name -contains "Size") {{$sizeBytes=[int64]$d.Size}}
    if ($d.PSObject.Properties.Name -contains "MediaType" -and $d.MediaType) {{$media=[string]$d.MediaType}}
    if ($d.PSObject.Properties.Name -contains "BusType" -and $d.BusType) {{$iface=[string]$d.BusType}}
    elseif ($d.PSObject.Properties.Name -contains "InterfaceType" -and $d.InterfaceType) {{$iface=[string]$d.InterfaceType}}
    if ($sizeBytes -gt 0) {{
        $sizeGB=[int][Math]::Ceiling($sizeBytes/1GB); $diskTotalGB+=$sizeGB
        $diskDetails+=[PSCustomObject]@{{Index=$idx;SizeGB=$sizeGB;Media=$media;Interface=$iface}}; $idx++
    }}
}}
$diskCount=$diskDetails.Count
$maxDiskIndex=if($diskCount -gt 0){{$diskCount-1}}else{{0}}
Ensure-HostCustomFields -MaxDiskIndex $maxDiskIndex

$cf=@{{
    vcpus=$vcpus; memory_mb=$memoryMB; memory_gb=$memoryGB
    disk_total_gb=$diskTotalGB; disk_count=$diskCount
    os_version=$os.Caption; cpu_model=$cs.Model
}}
foreach ($d in $diskDetails) {{
    $i=$d.Index
    $cf["disk_{{0}}_size_gb" -f $i]      = $d.SizeGB
    $cf["disk_{{0}}_media"   -f $i]      = $d.Media
    $cf["disk_{{0}}_interface" -f $i]    = $d.Interface
}}
$cfPatch=@{{custom_fields=$cf}}|ConvertTo-Json
try {{
    Invoke-NB -Uri "$uri/dcim/devices/$deviceId/" -Method PATCH -Body $cfPatch | Out-Null
    Write-Host "  Updated host custom fields (CPU/RAM/Disks/OS)"
}} catch {{ Write-Host "  [WARN] Failed to update host custom fields: $($_.Exception.Message)" }}

Write-Host ""
Write-Host "=== Host NIC Sync ==="

$hostNics=Get-NetAdapter | Where-Object {{$_.Status -eq "Up" -and $_.MacAddress}}
$HostNicMap=@{{}}

function Set-HostInterfacePrimaryMac {{
    param([int]$InterfaceId,[int]$MacId)
    $body=@{{primary_mac_address=$MacId}}|ConvertTo-Json
    try {{
        Invoke-NB -Uri "$uri/dcim/interfaces/$InterfaceId/" -Method PATCH -Body $body|Out-Null
        Write-Host "  Set primary MAC on host interface ID $InterfaceId (MAC ID $MacId)"
    }} catch {{Write-Host "  [WARN] Failed to set primary MAC on host interface $InterfaceId : $($_.Exception.Message)"}}
}}

foreach ($hn in $hostNics) {{
    $raw   =Normalize-MacRaw $hn.MacAddress
    $pretty=Normalize-MacPretty $hn.MacAddress
    if (-not $pretty) {{Write-Host "  [WARN] Invalid MAC for host NIC $($hn.Name)"; continue}}
    $existing=$null
    try {{
        $resp=Invoke-NB -Uri "$uri/dcim/interfaces/?device_id=$deviceId&mac_address=$pretty"
        $existing=(($resp.Content|ConvertFrom-Json).results)[0]
    }} catch {{}}
    if ($existing) {{
        Write-Host "  Updating host NIC $($hn.Name) ($pretty)"
        $patch=@{{name=$hn.Name;mac_address=$pretty}}|ConvertTo-Json
        try {{Invoke-NB -Uri "$uri/dcim/interfaces/$($existing.id)/" -Method PATCH -Body $patch|Out-Null}} catch {{}}
        $nicId=[int]$existing.id
    }} else {{
        Write-Host "  Creating host NIC $($hn.Name) ($pretty)"
        $body=@{{device=$deviceId;name=$hn.Name;type="1000base-t";mac_address=$pretty}}|ConvertTo-Json
        $nicId=$null
        try {{
            $resp=Invoke-NB -Uri "$uri/dcim/interfaces/" -Method POST -Body $body
            $nic=($resp.Content|ConvertFrom-Json); $nicId=[int]$nic.id
        }} catch {{Write-Host "  [ERROR] Failed to create host NIC $($hn.Name)"; continue}}
    }}
    if ($nicId) {{
        $hostMac=Ensure-HostMac -MacPretty $pretty -InterfaceId $nicId
        if ($hostMac -and $hostMac.id) {{
            Set-HostInterfacePrimaryMac -InterfaceId $nicId -MacId ([int]$hostMac.id)
        }}
        $HostNicMap[$hn.ifIndex]=$nicId
    }}
}}

Write-Host ""
Write-Host "=== Host IP Sync ==="

$hostIPs=Get-NetIPAddress -AddressFamily IPv4 | Where-Object {{
    $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -ne "0.0.0.0"
}}
$hostPrimaryIpId=$null

foreach ($ip in $hostIPs) {{
    $ipObj=[System.Net.IPAddress]::Parse($ip.IPAddress)
    # Use the interface prefix length directly for host IPs
    $mask=$ip.PrefixLength; if (-not $mask) {{$mask=32}}
    $cidr="$($ip.IPAddress)/$mask"
    $existing=Get-NetboxIPFull -Cidr $cidr
    if ($existing) {{
        Write-Host "  IP exists: $cidr"
        Ensure-IPShared -IpId $existing.id
        $ipId=[int]$existing.id
    }} else {{
        Write-Host "  Creating host IP $cidr"
        $newIP=Create-NetboxIP -IP $ipObj -Mask $mask
        if (-not $newIP) {{continue}}
        $ipId=[int]$newIP.id
    }}
    $nicId=$null
    if ($HostNicMap.ContainsKey($ip.InterfaceIndex)) {{$nicId=$HostNicMap[$ip.InterfaceIndex]}}
    else {{
        try {{
            $firstNic=((Invoke-NB -Uri "$uri/dcim/interfaces/?device_id=$deviceId").Content|ConvertFrom-Json).results[0]
            if($firstNic){{$nicId=[int]$firstNic.id}}
        }} catch {{}}
    }}
    if ($nicId) {{
        Assign-HostIPToNIC -IpId $ipId -NicId $nicId
        Write-Host "  Assigned $cidr to NIC ID $nicId"
        if (-not $hostPrimaryIpId) {{$hostPrimaryIpId=$ipId}}
    }}
}}

if ($hostPrimaryIpId) {{
    try {{
        Invoke-NB -Uri "$uri/dcim/devices/$deviceId/" -Method PATCH -Body (@{{primary_ip4=$hostPrimaryIpId}}|ConvertTo-Json)|Out-Null
        Write-Host "  Host primary IP set (ID $hostPrimaryIpId)"
    }} catch {{Write-Host "  [WARN] Failed to set host primary IP: $($_.Exception.Message)"}}
}} else {{ Write-Host "  [WARN] No primary IP for host" }}

$prefixes=Get-NetboxIPAMPrefixes
$vms=Get-VM

foreach ($vm in $vms) {{
    $vmName=$vm.VMName
    Write-Host ""
    Write-Host "=== $vmName ==="
    $vmId=Sync-NetboxVM -VM $vm -ClusterId $clusterId -RoleId $NetboxServerRoleID
    if (-not $vmId) {{continue}}

    $nics=Get-VMNetworkAdapter -VMName $vmName
    $curMacs=@()
    foreach ($n in $nics) {{$mr=Normalize-MacRaw $n.MacAddress; if($mr){{$curMacs+=$mr}}}}
    Remove-StaleNetboxNICs -VmId $vmId -CurrentMacsRaw $curMacs

    $exDisks=Get-NetboxVirtualDisks -VmId $vmId
    $drives=Get-VMHardDiskDrive -VMName $vmName
    $di=0
    foreach ($d in $drives) {{
        try {{
            if (Test-Path $d.Path) {{
                $vhd=Get-VHD -Path $d.Path -ErrorAction Stop
                Sync-NetboxVirtualDisk -VmId $vmId -VmName $vmName -DiskPath $d.Path -DiskBytes $vhd.Size -Index $di -ExistingDisks $exDisks
                $di++
            }} else {{Write-Host "  [WARN] VHD path not found: $($d.Path)"}}
        }} catch {{Write-Host "  [ERROR] VHD read $vmName $($d.Path): $($_.Exception.Message)"}}
    }}
    Remove-ObsoleteNetboxVirtualDisks -VmId $vmId -VmName $vmName -CurrentDiskCount $di

    $mgmtIpId=$null
    foreach ($nic in $nics) {{
        $mr=Normalize-MacRaw $nic.MacAddress; $mp=Normalize-MacPretty $nic.MacAddress
        if (-not $mr -or -not $mp) {{Write-Host "  Skipping $($nic.Name) -- invalid MAC"; continue}}
        $nicId=Get-NetboxNIC -VmId $vmId -MacAddress $nic.MacAddress
        if ($nicId) {{
            Write-Host "  Updating NIC $($nic.Name) ($mp)"
            if (-not (Update-NetboxNIC -NicId $nicId -MacPretty $mp -AdapterName $nic.Name)) {{$nicId=$null}}
        }}
        if (-not $nicId) {{
            Write-Host "  Creating NIC $($nic.Name) ($mp)"
            $nicId=Create-NetboxNIC -NetworkAdapter $nic -VirtualMachineId $vmId
        }}
        if (-not $nicId) {{Write-Host "  [ERROR] NIC create failed $($nic.Name)"; continue}}

        $candidates=$nic.IPAddresses|Where-Object{{$_ -and ($_ -notlike "fe80*") -and ($_ -notlike "*:*")}}
        foreach ($ipStr in $candidates) {{
            $ipObj=$null
            try {{$ipObj=[System.Net.IPAddress]::Parse($ipStr)}} catch {{continue}}
            if ($ipObj.IPAddressToString -eq "0.0.0.0") {{continue}}
            if ($ipObj.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {{continue}}
            $mask=Get-NetboxPrefixFromIP -IP $ipObj -Prefixes $prefixes
            if (-not $mask) {{ Write-Host "  [WARN] No IPAM prefix for $($ipObj.IPAddressToString) -- assigning as /32"; $mask = "32" }}
            $cidr="$($ipObj.IPAddressToString)/$mask"
            $exIP=Get-NetboxIPFull -Cidr $cidr
            if ($exIP) {{
                $ipId=[int]$exIP.id
                Ensure-IPShared -IpId $ipId
                if (Assign-IPToNIC -IpId $ipId -NicId $nicId) {{
                    Write-Host "  Assigned/reassigned $cidr to NIC $nicId"
                    if (-not $mgmtIpId) {{$mgmtIpId=$ipId}}
                }}
            }} else {{
                $newIP=Create-NetboxIP -IP $ipObj -Mask $mask
                if (-not $newIP) {{continue}}
                $ipId=[int]$newIP.id
                if (Assign-IPToNIC -IpId $ipId -NicId $nicId) {{
                    Write-Host "  Created and assigned $cidr to NIC $nicId"
                    if (-not $mgmtIpId) {{$mgmtIpId=$ipId}}
                }}
            }}
        }}
    }}
    if ($mgmtIpId) {{
        if (Set-NetboxVMPrimaryIP -VmId $vmId -IpId $mgmtIpId) {{
            Write-Host "  Primary IP set (ID $mgmtIpId)"
        }}
    }} else {{Write-Host "  [WARN] No primary IP for $vmName"}}
}}

Write-Host ""
Write-Host "Sync complete"
""").lstrip('\n')

with open(out_path, 'w') as f:
    f.write(ps1)
print("OK")

GENEOF

    if ! grep -q 'Sync complete' "$ps1_file" 2>/dev/null; then
        log_error "PS1 generation failed"; rm -f "$ps1_file"; pause; return 1
    fi
    log_ok "PS1 script generated: $ps1_file  ($(wc -l < "$ps1_file") lines)"

    # Execution mode -------------------------------------------------------
    local run_mode
    if [[ -n "$_auto_mode" ]]; then
        run_mode="1"  # always execute via WinRM in auto mode
    else
        printf "\n  ${W}How to run the sync?${NC}\n"
        echo "   1) Execute now via WinRM (pywinrm)"
        echo "   2) Save PS1 to file for manual execution"
        echo "   0) Cancel"
        read -rp $'\n  Choice: ' run_mode
    fi

    case "$run_mode" in
    1)  if ! python3 -c "import winrm" 2>/dev/null; then
            log_error "pywinrm not installed: pip3 install pywinrm --break-system-packages"
            rm -f "$ps1_file"; pause; return 1
        fi
        log_info "Connecting to $host_ip:$win_port as $win_user and running PS1..."
        python3 - "$host_ip" "$win_user" "$win_pass" \
                  "$win_port" "$win_proto" "$ps1_file" <<'RUNEOF'
import sys, winrm, base64, uuid

host, user, passwd, port, proto, ps1_path = sys.argv[1:7]

# WinRM rejects large scripts sent as a single run_ps() call with HTTP 500
# (error 2147942606 "filename or extension is too long").
# Fix: base64-encode the PS1, upload in 1800-char chunks, decode on the
# remote host, execute the saved file, then clean up.
try:
    ps1_bytes = open(ps1_path, "rb").read()
    ps1_b64   = base64.b64encode(ps1_bytes).decode("ascii")
    chunks    = [ps1_b64[i:i+1800] for i in range(0, len(ps1_b64), 1800)]

    session = winrm.Session(
        f"{proto}://{host}:{port}/wsman",
        auth=(user, passwd),
        transport="ntlm",
        server_cert_validation="ignore",
        operation_timeout_sec=600,
        read_timeout_sec=620
    )

    uid     = uuid.uuid4().hex[:10]
    tmp_b64 = f"C:\\Windows\\Temp\\nbs_{uid}.b64"
    tmp_ps1 = f"C:\\Windows\\Temp\\nbs_{uid}.ps1"

    print(f"Uploading PS1 ({len(ps1_bytes)} bytes, {len(chunks)} chunks) to {host}...")
    for i, chunk in enumerate(chunks):
        safe = chunk.replace('"', '`"')
        cmd  = (f'Set-Content -Path "{tmp_b64}" -Value "{safe}" -NoNewline -Encoding ASCII'
                if i == 0 else
                f'Add-Content -Path "{tmp_b64}" -Value "{safe}" -NoNewline -Encoding ASCII')
        r = session.run_ps(cmd)
        if r.status_code != 0:
            print(f"Chunk {i} failed: {r.std_err.decode("utf-8","replace")}", file=sys.stderr)
            sys.exit(1)
        if i % 20 == 0:
            print(f"  chunk {i+1}/{len(chunks)}...")

    decode_cmd = (
        f'$b=(Get-Content "{tmp_b64}" -Raw -Encoding ASCII).Trim();'
        f'$x=[System.Convert]::FromBase64String($b);'
        f'[System.IO.File]::WriteAllBytes("{tmp_ps1}",$x);'
        f'Remove-Item "{tmp_b64}" -Force -ErrorAction SilentlyContinue'
    )
    r = session.run_ps(decode_cmd)
    if r.status_code != 0:
        print("Decode failed: " + r.std_err.decode("utf-8","replace"), file=sys.stderr)
        sys.exit(1)

    print(f"Executing on {host}...")
    r = session.run_ps(
        f'Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; & "{tmp_ps1}"'
    )
    if r.std_out:
        print(r.std_out.decode("utf-8","replace"))
    if r.std_err:
        txt = r.std_err.decode("utf-8","replace").strip()
        if txt:
            print("STDERR:", txt[:3000])
    session.run_ps(f'Remove-Item "{tmp_ps1}" -Force -ErrorAction SilentlyContinue')
    sys.exit(r.status_code)
except Exception as e:
    print(f"WinRM error: {e}", file=sys.stderr)
    sys.exit(1)
RUNEOF
        log_info "WinRM execution complete (exit $?)" ;;
    2)  read -rp "  Save PS1 to path [/tmp/hyperv_netbox_sync.ps1]: " save_path
        save_path="${save_path:-/tmp/hyperv_netbox_sync.ps1}"
        cp "$ps1_file" "$save_path"
        log_ok "Saved: $save_path"
        printf "\n  ${W}Manual run steps:${NC}\n"
        printf "  1. Copy %s to the Hyper-V Windows host\n" "$save_path"
        printf "  2. Open PowerShell as Administrator\n"
        printf "  3. Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass\n"
        printf "  4. .\\hyperv_netbox_sync.ps1\n\n" ;;
    0)  log_info "Cancelled" ;;
    esac
    rm -f "$ps1_file"
    [[ -z "$_auto_mode" ]] && pause
}

# -----------------------------------------------------------------------------
# IMPORT / AGENT DEPLOYMENT MENU
# -----------------------------------------------------------------------------
menu_import() {
    while true; do
        banner
        printf "${C}======= Import / Agent Deployment =======${NC}\n\n"
        printf "  ${D}netbox-agent auto-discovers hardware, NICs, IPs, LLDP cables,${NC}\n"
        printf "  ${D}VMs, inventory (CPU/RAM/disk) from Linux hosts.${NC}\n\n"
        echo "   1) Register THIS machine via netbox-agent"
        echo "   2) Deploy agent to a specific host (SSH)"
        echo "   3) Deploy agent to ALL discovered Linux hosts"
        echo "   4) Import Windows Hyper-V host (WinRM)"
        echo "   5) Generate agent config file (netbox_agent.yaml)"
        echo "   6) Show agent config for manual install"
        echo "   7) Sync NetBox Device Type Library (community YAML)"
        echo "   0) Back"
        read -rp $'\nChoice: ' c
        local tip
        case "$c" in
        1) run_agent_local ;;
        2) read -rp "  Host IP: " tip
           valid_ip "$tip" && deploy_agent_remote "$tip" \
               || { printf "${R}  Invalid IP${NC}\n"; pause; } ;;
        3) local latest
           latest=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
           if [[ -z "$latest" ]]; then
               printf "${Y}  No discovery results -- run a scan first${NC}\n"
               pause; continue
           fi
           confirm "Deploy to all Linux hosts in $(basename "$latest")?" \
               && deploy_agents_to_discovered "$latest" ;;
        4) read -rp "  Hyper-V host IP: " tip
           valid_ip "$tip" && import_hyperv_powershell "$tip" \
               || { printf "${R}  Invalid IP${NC}\n"; pause; } ;;
        5) read -rp "  Output path [/etc/netbox_agent.yaml]: " dest
           dest="${dest:-/etc/netbox_agent.yaml}"
           generate_agent_config "$dest" && pause ;;
        6) printf "\n${W}# Install on target Linux machine:${NC}\n"
           printf "pip3 install netbox-agent\n"
           printf "cat > /etc/netbox_agent.yaml << EOF\n"
           generate_agent_config /dev/stdout 2>/dev/null
           printf "EOF\n"
           printf "netbox_agent -c /etc/netbox_agent.yaml --register\n\n"
           pause ;;
        7) import_device_type_library ;;
        0) return ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# DEVICE TYPE LIBRARY IMPORT
# -----------------------------------------------------------------------------
import_device_type_library() {
    log_step "NetBox Device Type Library Import"
    if [[ -z "$NETBOX_API_TOKEN" ]]; then
        log_error "API token not set -- run Deploy NetBox first"
        pause; return 1
    fi

    local dtl_dir="$BASE_DIR/devicetype-library"
    local dtli_dir="$BASE_DIR/Device-Type-Library-Import"

    # 1. Clone / update community device type library
    log_info "Syncing NetBox device type library..."
    if [[ -d "$dtl_dir/.git" ]]; then
        git -C "$dtl_dir" pull -q >> "$LOG_FILE" 2>&1 \
            && log_ok "Library updated" || log_warn "Library update failed (using existing)"
    else
        git clone -q \
            https://github.com/netbox-community/devicetype-library.git \
            "$dtl_dir" >> "$LOG_FILE" 2>&1 \
            && log_ok "Library cloned" || { log_error "Clone failed"; pause; return 1; }
    fi

    # 2. Install Device-Type-Library-Import tool
    log_info "Installing Device-Type-Library-Import..."
    if [[ ! -d "$dtli_dir/.git" ]]; then
        git clone -q \
            https://github.com/netbox-community/Device-Type-Library-Import.git \
            "$dtli_dir" >> "$LOG_FILE" 2>&1 || { log_error "DTLI clone failed"; pause; return 1; }
    else
        git -C "$dtli_dir" pull -q >> "$LOG_FILE" 2>&1 || true
    fi
    pip3 install --break-system-packages --quiet \
        -r "$dtli_dir/requirements.txt" \
        >> "$LOG_FILE" 2>&1 || true

    # 3. Optional: filter to specific vendors
    printf "\n  Import all vendors or specific ones?\n"
    printf "  Examples: cisco juniper fortinet hp dell ubiquiti\n"
    printf "  (blank = import all ~2000 device types)\n"
    read -rp "  Vendors (space-separated, blank=all): " _vendors

    # 4. Run import
    log_info "Running Device-Type-Library-Import..."
    local _dtli_args=(
        "--url" "$NETBOX_API_URL"
        "--token" "$NETBOX_API_TOKEN"
        "--library" "$dtl_dir"
    )
    if [[ -n "${_vendors:-}" ]]; then
        for _v in $_vendors; do
            _dtli_args+=("--vendors" "$_v")
        done
    fi
    cd "$dtli_dir" && python3 dtl_import.py "${_dtli_args[@]}" \
        2>&1 | tee -a "$LOG_FILE" | tail -30
    log_ok "Device Type Library import complete"
    pause
}

# -----------------------------------------------------------------------------
# CREDENTIAL MANAGEMENT MENU
# -----------------------------------------------------------------------------
menu_credentials() {
    while true; do
        banner
        printf "${C}======= Credential Management =======${NC}\n\n"
        local creds; creds=$(read_creds)
        printf "  ${W}SNMP v1/v2c:${NC}\n"
        echo "$creds" | jq -r '.snmp_communities[] | "    * "+.' 2>/dev/null || echo "    (none)"
        printf "\n  ${W}SNMP v3:${NC}\n"
        echo "$creds" | jq -r \
            '.snmp_v3[] | "    * \(.username) [\(.auth_proto)/\(.priv_proto)]"' \
            2>/dev/null || echo "    (none)"
        printf "\n  ${W}SSH:${NC}\n"
        echo "$creds" | jq -r '.ssh_credentials[] | "    * \(.username)"' \
            2>/dev/null || echo "    (none)"
        printf "\n  ${W}Device overrides:${NC}\n"
        echo "$creds" | jq -r \
            '.device_overrides | to_entries[] | "    * \(.key)"' \
            2>/dev/null || echo "    (none)"
        printf "\n  ${W}Windows (WinRM):${NC}\n"
        echo "$creds" | jq -r \
            '.windows_credentials[] | "    * " +
             (if (.domain//"")!="" then .domain+"\\"+.username
              else ".\\"+.username end)' \
            2>/dev/null || echo "    (none)"
        echo ""
        echo "   1) Add SNMP v2c Community"
        echo "   2) Remove SNMP v2c Community"
        echo "   3) Add SNMP v3 Account"
        echo "   4) Add SSH Credential"
        echo "   5) Remove SSH Credential"
        echo "   6) Add Device Override"
        echo "   7) Remove Device Override"
        echo "   8) Import credentials JSON"
        echo "   9) Export credentials (plaintext)"
        echo "  10) Add Windows Credential (workgroup or domain)"
        echo "  11) Remove Windows Credential"
        echo "   0) Back"
        read -rp $'\nChoice: ' c
        local v3e sshe deve
        case "$c" in
        1)  read -rp "  Community: " x
            write_creds "$(echo "$creds" | jq ".snmp_communities += [\"$x\"]")"
            log_info "Added: $x" ;;
        2)  read -rp "  Remove: " x
            write_creds "$(echo "$creds" \
                | jq "del(.snmp_communities[] | select(.==\"$x\"))")" ;;
        3)  read -rp "  Username: " u
            read -rp "  Auth proto [SHA]: " ap; ap=${ap:-SHA}
            read -rsp "  Auth pass: " ap2; echo
            read -rp "  Priv proto [AES]: " pp; pp=${pp:-AES}
            read -rsp "  Priv pass: " pp2; echo
            v3e=$(jq -n --arg u "$u" --arg ap "$ap" --arg ap2 "$ap2" \
                --arg pp "$pp" --arg pp2 "$pp2" \
                '{username:$u,auth_proto:$ap,auth_pass:$ap2,priv_proto:$pp,priv_pass:$pp2}')
            write_creds "$(echo "$creds" | jq ".snmp_v3 += [$v3e]")" ;;
        4)  read -rp "  Username: " u
            read -rsp "  Password (blank=key): " p; echo
            read -rp "  Key file (blank=password): " k
            read -rsp "  Enable pass (opt): " e; echo
            sshe=$(jq -n --arg u "$u" --arg p "$p" --arg k "$k" --arg e "$e" \
                '{username:$u,password:(if $p!="" then $p else null end),
                  key_file:(if $k!="" then $k else null end),
                  enable_pass:(if $e!="" then $e else null end)}')
            write_creds "$(echo "$creds" | jq ".ssh_credentials += [$sshe]")" ;;
        5)  read -rp "  Remove username: " u
            write_creds "$(echo "$creds" \
                | jq "del(.ssh_credentials[] | select(.username==\"$u\"))")" ;;
        6)  read -rp "  Device IP: " dip
            read -rp "  SNMP community: " dc
            read -rp "  SSH username: " du
            read -rsp "  SSH password: " dp; echo
            read -rp "  SSH key file: " dk
            printf "  Windows (leave blank to skip):\n"
            read -rp "  Windows username: " dwu
            read -rsp "  Windows password: " dwp; echo
            read -rp "  Windows domain (blank=workgroup): " dwd
            deve=$(jq -n \
                --arg c "$dc" --arg u "$du" --arg p "$dp" --arg k "$dk" \
                --arg wu "$dwu" --arg wp "$dwp" --arg wd "$dwd" \
                '{snmp_community:(if $c!="" then $c else null end),
                  ssh_username:(if $u!="" then $u else null end),
                  ssh_password:(if $p!="" then $p else null end),
                  ssh_key:(if $k!="" then $k else null end),
                  windows_username:(if $wu!="" then $wu else null end),
                  windows_password:(if $wp!="" then $wp else null end),
                  windows_domain:(if $wd!="" then $wd else "" end)}')
            write_creds "$(echo "$creds" \
                | jq ".device_overrides[\"$dip\"] = $deve")" ;;
        7)  read -rp "  Device IP: " dip
            write_creds "$(echo "$creds" \
                | jq "del(.device_overrides[\"$dip\"])")" ;;
        8)  read -rp "  JSON file: " jf
            if [[ -f "$jf" ]]; then write_creds "$(cat "$jf")"
                log_info "Imported: $jf"
            else printf "${R}  Not found${NC}\n"; sleep 1; fi ;;
        9)  printf "${R}  WARNING: plaintext export!${NC}\n"
            confirm "Continue?" || continue
            read -rp "  Output file: " of
            read_creds > "$of"; chmod 600 "$of"; log_warn "Exported: $of" ;;
        10) local wtype wdomain wuser wpass wine
            printf "  1) Workgroup / local  2) Domain\n"
            read -rp "  Type [1]: " wtype; wtype="${wtype:-1}"
            wdomain=""
            [[ "$wtype" == "2" ]] && read -rp "  Domain: " wdomain
            read -rp "  Username: " wuser
            read -rsp "  Password: " wpass; echo
            wine=$(jq -n --arg u "$wuser" --arg p "$wpass" --arg d "$wdomain" \
                '{username:$u,password:$p,domain:$d}')
            write_creds "$(echo "$creds" | jq ".windows_credentials += [$wine]")"
            log_info "Added Windows: ${wdomain:+$wdomain\\}$wuser" ;;
        11) read -rp "  Remove username (exact): " wuser
            write_creds "$(echo "$creds" \
                | jq "del(.windows_credentials[] | select(.username==\"$wuser\"))")"
            log_info "Removed Windows credential: $wuser" ;;
        0)  return ;;
        esac
        pause
    done
}

# -----------------------------------------------------------------------------
# DISCOVERY SETTINGS MENU
# -----------------------------------------------------------------------------
menu_disc_settings() {
    while true; do
        banner
        printf "${C}======= Discovery Settings =======${NC}\n\n"
        printf "  1) Scan Timeout      ${W}%ss${NC}\n" "$SCAN_TIMEOUT"
        printf "  2) SNMP Timeout      ${W}%ss${NC}\n" "$SNMP_TIMEOUT"
        printf "  3) SSH Timeout       ${W}%ss${NC}\n" "$SSH_TIMEOUT"
        printf "  4) Parallel Threads  ${W}%s${NC}\n"  "$MAX_THREADS"
        printf "  5) Default Site      ${W}%s${NC}\n"  "$DEFAULT_SITE_NAME"
        printf "  6) NetBox Port       ${W}%s${NC}\n"  "$NETBOX_PORT"
        printf "  7) Debug Mode        ${W}%s${NC}\n"  \
            "$([ $DEBUG_MODE -eq 1 ] && echo ON || echo OFF)"
        echo "  8) Schedule Recurring Scan (cron)"
        echo "  9) View Scheduled Scans"
        echo "  0) Back"
        read -rp $'\nChoice: ' c
        case "$c" in
        1) read -rp "  Scan timeout (s): "  SCAN_TIMEOUT;       save_config ;;
        2) read -rp "  SNMP timeout (s): "  SNMP_TIMEOUT;       save_config ;;
        3) read -rp "  SSH timeout (s): "   SSH_TIMEOUT;        save_config ;;
        4) read -rp "  Threads: "           MAX_THREADS;        save_config ;;
        5) read -rp "  Site name: "         DEFAULT_SITE_NAME;  save_config ;;
        6) read -rp "  Port: " NETBOX_PORT
           NETBOX_API_URL="http://$(get_host_ip):${NETBOX_PORT}";    save_config ;;
        7) (( DEBUG_MODE ^= 1 ));                               save_config ;;
        8) read -rp "  Networks (CIDRs or file): " snet
           read -rp "  Cron (e.g. 0 2 * * *): " scron
           (crontab -l 2>/dev/null
            echo "$scron root $SCRIPT_PATH --auto-scan '$snet' \
>> $LOG_DIR/cron.log 2>&1") | crontab -
           log_info "Scheduled: [$scron] $snet" ;;
        9) crontab -l 2>/dev/null | grep "auto-scan" || echo "  (none)" ;;
        0) return ;;
        esac
        pause
    done
}

# -----------------------------------------------------------------------------
# NETBOX MANAGEMENT MENU
# -----------------------------------------------------------------------------
menu_netbox_mgmt() {
    while true; do
        banner
        printf "${C}======= NetBox Management =======${NC}\n\n"
        local nb_st="Stopped"
        $DOCKER_COMPOSE -f "$NETBOX_DIR/docker-compose.yml" \
            ps 2>/dev/null | grep -q "Up" && nb_st="Running"
        printf "  Status   : ${W}%s${NC}\n"  "$nb_st"
        printf "  URL      : ${W}%s${NC}\n"  "$NETBOX_API_URL"
        printf "  Token    : ${W}%s${NC}\n"  "${NETBOX_API_TOKEN:-<not set>}"
        printf "  Admin PW : ${W}%s${NC}\n"  \
            "${NETBOX_ADMIN_PASS:-see $BASE_DIR/netbox-credentials.txt}"
        echo ""
        echo "   1) Start NetBox"
        echo "   2) Stop NetBox"
        echo "   3) Restart NetBox"
        echo "   4) View NetBox Logs (live)"
        echo "   5) Set API Token manually"
        echo "   6) Regenerate API Token (Django shell)"
        echo "   7) Backup Database"
        echo "   8) Restore Database"
        echo "   9) Update NetBox"
        echo "  10) Show Container Status"
        echo "   0) Back"
        read -rp $'\nChoice: ' c
        case "$c" in
        1)  cd "$NETBOX_DIR" && $DOCKER_COMPOSE up -d >> "$LOG_FILE" 2>&1
            log_ok "NetBox started" ;;
        2)  confirm "Stop NetBox?" || { pause; continue; }
            cd "$NETBOX_DIR" && $DOCKER_COMPOSE down >> "$LOG_FILE" 2>&1
            log_ok "NetBox stopped" ;;
        3)  cd "$NETBOX_DIR" && $DOCKER_COMPOSE restart >> "$LOG_FILE" 2>&1
            log_ok "NetBox restarted" ;;
        4)  printf "${D}(Ctrl+C to exit)${NC}\n"
            cd "$NETBOX_DIR" && $DOCKER_COMPOSE logs -f --tail=50 netbox ;;
        5)  read -rp "  Token: " NETBOX_API_TOKEN; save_config ;;
        6)  cd "$NETBOX_DIR"
            local regen_py regen_result
            regen_py="
from users.models import Token
from django.contrib.auth.models import User
u=User.objects.get(username='admin')
t=Token.objects.create(user=u)
print('TOKEN:'+str(t.key))"
            regen_result=$(cd "$NETBOX_DIR" && $DOCKER_COMPOSE exec -T netbox \
                python manage.py shell << PYEOF 2>/dev/null | grep '^TOKEN:'
${regen_py}
PYEOF
            )
            if [[ "$regen_result" == TOKEN:* ]]; then
                NETBOX_API_TOKEN="${regen_result#TOKEN:}"; save_config
                log_ok "New token: ${NETBOX_API_TOKEN:0:12}..."
                sed -i "s|^API Token:.*|API Token: ${NETBOX_API_TOKEN}|" \
                    "$BASE_DIR/netbox-credentials.txt" 2>/dev/null || true
            else log_error "Token generation failed"; fi ;;
        7)  local bk="$BASE_DIR/backup_$(date +%Y%m%d_%H%M%S).sql.gz"
            cd "$NETBOX_DIR" && $DOCKER_COMPOSE exec -T postgres \
                pg_dump -U netbox netbox | gzip > "$bk"
            log_ok "Backup: $bk" ;;
        8)  read -rp "  Backup file (.sql.gz): " bkf
            [[ ! -f "$bkf" ]] && { printf "${R}  Not found${NC}\n"; pause; continue; }
            confirm "Overwrite current DB?" || continue
            cd "$NETBOX_DIR"
            $DOCKER_COMPOSE exec -T postgres psql -U netbox -c \
                "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" \
                netbox >> "$LOG_FILE" 2>&1
            zcat "$bkf" | $DOCKER_COMPOSE exec -T postgres \
                psql -U netbox netbox >> "$LOG_FILE" 2>&1
            log_ok "Restored: $bkf" ;;
        9)  cd "$NETBOX_DIR" && git pull -q \
                && $DOCKER_COMPOSE pull >> "$LOG_FILE" 2>&1
            $DOCKER_COMPOSE up -d >> "$LOG_FILE" 2>&1
            log_ok "Update complete" ;;
        10) cd "$NETBOX_DIR" && $DOCKER_COMPOSE ps ;;
        0)  return ;;
        esac
        pause
    done
}

# -----------------------------------------------------------------------------
# LOG VIEWER MENU
# -----------------------------------------------------------------------------
menu_logs() {
    while true; do
        banner
        printf "${C}======= Log Viewer =======${NC}\n\n"
        echo "  1) Tail today's log (live)"
        echo "  2) Full today's log"
        echo "  3) List log files"
        echo "  4) List discovery results"
        echo "  5) View latest result summary"
        echo "  6) Search logs"
        echo "  7) Clear today's log"
        echo "  0) Back"
        read -rp $'\nChoice: ' c
        local latest cnt
        case "$c" in
        1) tail -f "$LOG_FILE" ;;
        2) less "$LOG_FILE" 2>/dev/null || more "$LOG_FILE" ;;
        3) ls -lh "$LOG_DIR"/*.log 2>/dev/null || echo "  (none)" ;;
        4) ls -lh "$DISCOVERY_DIR"/results_*.json 2>/dev/null \
               | awk '{print NR") "$NF" "$5}' || echo "  (none)" ;;
        5) latest=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
           [[ -z "$latest" ]] && { echo "  No results"; pause; continue; }
           cnt=$(jq '.hosts | length' "$latest")
           printf "\n${W}%s${NC}  (hosts: %s)\n\n" "$latest" "$cnt"
           printf "  %-16s %-28s %-16s %-16s %s\n" IP Hostname Role Manufacturer OS
           printf "  %s\n" "$(printf '%0.s-' {1..88})"
           jq -r '.hosts[] | [.ip,.hostname,.device_role,
               .manufacturer,(.os // "N/A")] | @tsv' "$latest" 2>/dev/null \
               | while IFS=$'\t' read -r i h r m o; do
                   printf "  %-16s %-28s %-16s %-16s %s\n" \
                       "$i" "${h:0:27}" "${r:0:15}" "${m:0:15}" "${o:0:26}"
                 done | head -80 ;;
        6) read -rp "  Search: " st
           grep --color=always -i "$st" "$LOG_DIR"/*.log 2>/dev/null | tail -50 ;;
        7) confirm "Clear?" || continue; > "$LOG_FILE"; log_info "Cleared" ;;
        0) return ;;
        esac
        pause
    done
}

# -----------------------------------------------------------------------------
# DISCOVERY RUNNER MENU
# -----------------------------------------------------------------------------
menu_discovery() {
    while true; do
        banner
        printf "${C}======= Network Discovery =======${NC}\n\n"
        echo "  1) Discover Network(s)"
        echo "     (single CIDR, comma-separated CIDRs, or file path)"
        echo "  2) Scan Single Host"
        echo "  3) Scan Host List from File"
        echo "     (IPs and/or CIDRs; # comments; whitespace stripped)"
        echo "  4) Map Switchports (SNMP)"
        echo "  5) View Latest Results"
        echo "  6) Sync Last Results to NetBox"
        echo "  7) Full Auto: Discover + Sync"
        echo "  0) Back"
        read -rp $'\nChoice: ' c
        local input sip hf swip latest cnt
        case "$c" in
        1)  printf "  Enter target(s):\n"
            printf "  Examples: 192.168.1.0/24\n"
            printf "            192.168.1.0/24,10.0.0.0/8\n"
            printf "            /path/to/subnets.txt\n"
            read -rp "  > " input
            if [[ -z "$input" ]]; then
                printf "${R}  No input${NC}\n"; pause; continue
            fi
            # Parse targets
            local target_list; target_list=$(parse_targets "$input")
            if [[ -z "$target_list" ]]; then
                printf "${R}  No valid targets found in input${NC}\n"
                pause; continue
            fi
            local target_count; target_count=$(echo "$target_list" | wc -l)
            log_info "Parsed $target_count target(s)"
            printf "  Targets:\n"
            echo "$target_list" | while read -r t; do printf "    - %s\n" "$t"; done
            echo ""
            init_scan_session "$input"
            # Run discovery for all targets
            local targets_arr=()
            while IFS= read -r t; do targets_arr+=("$t"); done <<< "$target_list"
            discover_targets "${targets_arr[@]}"
            if [[ -s "$LIVE_HOSTS_FILE" ]]; then
                scan_all_hosts
                log_ok "Results: $DISC_RESULTS"
                confirm "  Sync to NetBox?" && sync_to_netbox "$DISC_RESULTS"
            else
                printf "  ${Y}No live hosts found${NC}\n"
            fi ;;
        2)  read -rp "  IP: " sip
            if valid_ip "$sip"; then
                init_scan_session "$sip"
                echo "$sip" > "$LIVE_HOSTS_FILE"
                scan_all_hosts
                jq '.hosts[0] | del(.ports,.interfaces,.mac_port_map,.arp_entries)' \
                    "$DISC_RESULTS" 2>/dev/null || cat "$DISC_RESULTS"
            else printf "${R}  Invalid IP${NC}\n"; fi ;;
        3)  printf "  File format: one IP or CIDR per line\n"
            printf "  Lines starting with # are comments\n"
            printf "  Inline comments and whitespace are stripped\n"
            read -rp "  File path: " hf
            if [[ ! -f "$hf" ]]; then
                printf "${R}  File not found${NC}\n"; pause; continue
            fi
            init_scan_session "file:$hf"
            expand_host_file "$hf" > "$LIVE_HOSTS_FILE"
            cnt=$(wc -l < "$LIVE_HOSTS_FILE")
            log_info "Loaded $cnt hosts/IPs from $hf"
            if [[ "$cnt" -eq 0 ]]; then
                printf "${Y}  No valid IPs in file${NC}\n"; pause; continue
            fi
            scan_all_hosts
            confirm "  Sync to NetBox?" && sync_to_netbox "$DISC_RESULTS" ;;
        4)  read -rp "  Switch IP: " swip
            valid_ip "$swip" && map_switchports "$swip" \
                || printf "${R}  Invalid IP${NC}\n" ;;
        5)  latest=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
            [[ -z "$latest" ]] && { echo "  No results"; pause; continue; }
            cnt=$(jq '.hosts | length' "$latest")
            printf "\n${W}%s  (%s hosts)${NC}\n\n" "$latest" "$cnt"
            printf "  %-16s %-28s %-16s %-16s %s\n" IP Hostname Role Manufacturer OS
            jq -r '.hosts[] | [.ip,.hostname,.device_role,
                .manufacturer,(.os // "N/A")] | @tsv' "$latest" 2>/dev/null \
                | while IFS=$'\t' read -r i h r m o; do
                    printf "  %-16s %-28s %-16s %-16s %s\n" \
                        "$i" "${h:0:27}" "${r:0:15}" "${m:0:15}" "${o:0:26}"
                  done | head -80 ;;
        6)  sync_to_netbox ;;
        7)  printf "  Enter target(s) (CIDR, comma-separated, or file):\n"
            read -rp "  > " input
            if [[ -z "$input" ]]; then
                printf "${R}  No input${NC}\n"; pause; continue
            fi
            local target_list; target_list=$(parse_targets "$input")
            if [[ -z "$target_list" ]]; then
                printf "${R}  No valid targets${NC}\n"; pause; continue
            fi
            init_scan_session "$input"
            local targets_arr=()
            while IFS= read -r t; do targets_arr+=("$t"); done <<< "$target_list"
            discover_targets "${targets_arr[@]}"
            if [[ -s "$LIVE_HOSTS_FILE" ]]; then
                scan_all_hosts
                sync_to_netbox "$DISC_RESULTS"
            else
                printf "  ${Y}No live hosts found${NC}\n"
            fi ;;
        0)  return ;;
        esac
        pause
    done
}

# -----------------------------------------------------------------------------
# MAIN MENU
# -----------------------------------------------------------------------------
main_menu() {
    while true; do
        banner
        local nb_st="Stopped" dk_st="Missing"
        $DOCKER_COMPOSE -f "$NETBOX_DIR/docker-compose.yml" \
            ps 2>/dev/null | grep -q "Up" && nb_st="Running"
        cmd_exists docker && dk_st="OK"
        printf "  NetBox: ${W}%s${NC}   Docker: ${W}%s${NC}   User: ${D}%s${NC}\n" \
            "$nb_st" "$dk_st" "$REAL_USER"
        printf "  Token : ${D}%s...${NC}\n" "${NETBOX_API_TOKEN:0:12}"
        echo ""
        printf "${C}  +--------------------------------------------+${NC}\n"
        printf "${C}  |${NC}  ${W}1${NC}  Install / Update Dependencies        ${C}|${NC}\n"
        printf "${C}  |${NC}  ${W}2${NC}  Deploy / Update NetBox               ${C}|${NC}\n"
        printf "${C}  |${NC}  ${W}3${NC}  Discovery Settings                   ${C}|${NC}\n"
        printf "${C}  |${NC}  ${W}4${NC}  Manage Credentials                   ${C}|${NC}\n"
        printf "${C}  |${NC}  ${W}5${NC}  Run Network Discovery                ${C}|${NC}\n"
        printf "${C}  |${NC}  ${W}6${NC}  NetBox Management                    ${C}|${NC}\n"
        printf "${C}  |${NC}  ${W}7${NC}  View Logs                            ${C}|${NC}\n"
        printf "${C}  |${NC}  ${W}8${NC}  Quick Setup (Install + Deploy)       ${C}|${NC}\n"
        printf "${C}  |${NC}  ${W}9${NC}  Import / Agent Deployment            ${C}|${NC}\n"
        printf "${C}  |${NC}  ${W}0${NC}  Exit                                 ${C}|${NC}\n"
        printf "${C}  +--------------------------------------------+${NC}\n\n"
        read -rp "  Choice: " ch
        case "$ch" in
        1) install_deps ;;
        2) deploy_netbox ;;
        3) menu_disc_settings ;;
        4) menu_credentials ;;
        5) menu_discovery ;;
        6) menu_netbox_mgmt ;;
        7) menu_logs ;;
        8) install_deps && deploy_netbox ;;
        9) menu_import ;;
        0) printf "\n  ${G}Goodbye!${NC}\n\n"; log_info "Session ended"; exit 0 ;;
        *) printf "  ${R}Invalid choice${NC}\n"; sleep 1 ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------
main() {
    check_root "$@"
    init_dirs
    load_config
    init_creds
    detect_docker_compose
    log_info "================================================"
    log_info "NetBox Discovery Suite v${SCRIPT_VERSION} started"
    log_info "User: $(id -un) (real: $REAL_USER)  PID: $$  Compose: $DOCKER_COMPOSE"
    log_info "================================================"

    # Non-interactive: cron auto-scan (accepts multi-target input)
    if [[ "${1:-}" == "--auto-scan" && -n "${2:-}" ]]; then
        local target_list; target_list=$(parse_targets "$2")
        if [[ -n "$target_list" ]]; then
            init_scan_session "$2"
            local targets_arr=()
            while IFS= read -r t; do targets_arr+=("$t"); done <<< "$target_list"
            discover_targets "${targets_arr[@]}"
            [[ -s "$LIVE_HOSTS_FILE" ]] \
                && scan_all_hosts && sync_to_netbox "$DISC_RESULTS"
        fi
        log_info "Auto-scan complete"; exit 0
    fi

    # Non-interactive: single host scan
    if [[ "${1:-}" == "--scan" && -n "${2:-}" ]]; then
        init_scan_session "$2"
        echo "$2" > "$LIVE_HOSTS_FILE"
        scan_all_hosts
        jq '.' "$DISC_RESULTS"
        exit 0
    fi

    main_menu
}

main "$@"
