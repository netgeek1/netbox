#!/usr/bin/env bash
# =============================================================================
#  NetBox Auto-Deploy & Network Discovery Suite
#  For Ubuntu 24.04
#  Version: 2.0.0
#
#  Features:
#   - Deploys NetBox via Docker Compose
#   - Multi-protocol discovery: ICMP, ARP, SNMP, SSH, HTTP/HTTPS, CDP/LLDP,
#     NetBIOS/SMB, mDNS, DNS, Netcat banner grab, FTP, Telnet
#   - Switchport mapping via SNMP Bridge MIB
#   - Credential store (AES-256 encrypted): SNMP v1/v2c/v3, SSH, per-device
#   - Auto-sync discovered devices into NetBox via REST API
#   - Fully menu-driven with comprehensive logging
#   - Cron scheduling for recurring scans
# =============================================================================

set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# GLOBAL CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_VERSION="2.0.0"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

BASE_DIR="/opt/netbox-discovery"
LOG_DIR="/var/log/netbox-discovery"
CONFIG_FILE="$BASE_DIR/config.conf"
CREDS_FILE="$BASE_DIR/.credentials.enc"
CREDS_KEY_FILE="$BASE_DIR/.creds.key"
DISCOVERY_DIR="$BASE_DIR/discovery"
NETBOX_DIR="/opt/netbox-docker"

# ── Colours ──
R='\033[0;31m'   # Red
G='\033[0;32m'   # Green
Y='\033[1;33m'   # Yellow
B='\033[0;34m'   # Blue
C='\033[0;36m'   # Cyan
W='\033[1;37m'   # White/Bold
D='\033[2m'      # Dim
NC='\033[0m'     # Reset

# ── Runtime defaults (overridden by config file) ──
NETBOX_PORT=8000
NETBOX_API_URL="http://localhost:${NETBOX_PORT}"
NETBOX_API_TOKEN=""
DEFAULT_SITE_NAME="Default Site"
SCAN_TIMEOUT=5
SNMP_TIMEOUT=3
SSH_TIMEOUT=10
MAX_THREADS=20
DEBUG_MODE=0

# ── Log file (rotated daily) ──
LOG_FILE="$LOG_DIR/discovery-$(date +%Y%m%d).log"

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────
_log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [%-5s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null
}

log_info()  { _log "INFO"  "$@"; echo -e "${G}[INFO]${NC}  $*"; }
log_warn()  { _log "WARN"  "$@"; echo -e "${Y}[WARN]${NC}  $*"; }
log_error() { _log "ERROR" "$@"; echo -e "${R}[ERROR]${NC} $*" >&2; }
log_ok()    { _log "OK"    "$@"; echo -e "${G}[OK]${NC}    $*"; }
log_debug() { _log "DEBUG" "$@"; [[ $DEBUG_MODE -eq 1 ]] && echo -e "${D}[DEBUG]${NC} $*"; }

log_step() {
    local msg="$*"
    _log "STEP" "$msg"
    echo -e "\n${C}══════ ${W}${msg}${C} ══════${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# UTILITIES
# ─────────────────────────────────────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || { log_error "Run as root (sudo $0)"; exit 1; }
}

pause() { echo; read -rp "  Press [Enter] to continue..."; }

confirm() {
    local prompt="${1:-Are you sure?}"
    local resp
    read -rp "  $prompt [y/N] " resp
    [[ "${resp,,}" == "y" ]]
}

cmd_exists() { command -v "$1" &>/dev/null; }

# Spinner: spinner <pid>
spinner() {
    local pid=$1
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s ' "${chars:$((i % ${#chars})):1}"
        sleep 0.1
        (( i++ ))
    done
    printf '\r     \r'
}

# Format bytes to human readable
fmt_bytes() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then printf '%.1f GB' "$(echo "scale=1;$bytes/1073741824" | bc)"
    elif (( bytes >= 1048576   )); then printf '%.1f MB' "$(echo "scale=1;$bytes/1048576"    | bc)"
    elif (( bytes >= 1024      )); then printf '%.1f KB' "$(echo "scale=1;$bytes/1024"       | bc)"
    else printf '%d B' "$bytes"
    fi
}

# IP validation
valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra o <<< "$ip"
    for oct in "${o[@]}"; do (( oct <= 255 )) || return 1; done
    return 0
}

# CIDR validation
valid_cidr() {
    local net="$1"
    [[ "$net" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────────────────────
banner() {
    clear
    echo -e "${C}"
    cat <<'EOF'
  ╔══════════════════════════════════════════════════════════════════════╗
  ║   ███╗   ██╗███████╗████████╗██████╗  ██████╗ ██╗  ██╗            ║
  ║   ████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██╔═══██╗╚██╗██╔╝            ║
  ║   ██╔██╗ ██║█████╗     ██║   ██████╔╝██║   ██║ ╚███╔╝             ║
  ║   ██║╚██╗██║██╔══╝     ██║   ██╔══██╗██║   ██║ ██╔██╗             ║
  ║   ██║ ╚████║███████╗   ██║   ██████╔╝╚██████╔╝██╔╝ ██╗            ║
  ║   ╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═════╝  ╚═════╝ ╚═╝  ╚═╝            ║
  ║            Auto-Deploy & Network Discovery Suite v2.0               ║
  ╚══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "  ${D}Log: $LOG_FILE${NC}"
    echo -e "  ${D}Config: $CONFIG_FILE${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# DIRECTORY & CONFIG SETUP
# ─────────────────────────────────────────────────────────────────────────────
init_dirs() {
    mkdir -p "$BASE_DIR" "$LOG_DIR" "$DISCOVERY_DIR"
    chmod 700 "$BASE_DIR"
    chmod 755 "$LOG_DIR"
    touch "$LOG_FILE"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# NetBox Discovery Suite Configuration
# Generated: $(date)
NETBOX_PORT=${NETBOX_PORT}
NETBOX_API_URL=${NETBOX_API_URL}
NETBOX_API_TOKEN=${NETBOX_API_TOKEN}
DEFAULT_SITE_NAME=${DEFAULT_SITE_NAME}
SCAN_TIMEOUT=${SCAN_TIMEOUT}
SNMP_TIMEOUT=${SNMP_TIMEOUT}
SSH_TIMEOUT=${SSH_TIMEOUT}
MAX_THREADS=${MAX_THREADS}
DEBUG_MODE=${DEBUG_MODE}
EOF
    chmod 600 "$CONFIG_FILE"
    log_info "Configuration saved"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    NETBOX_API_URL="http://localhost:${NETBOX_PORT}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ENCRYPTED CREDENTIAL STORE
# ─────────────────────────────────────────────────────────────────────────────
# Format (JSON, AES-256-CBC encrypted):
# {
#   "snmp_communities": ["public","private"],
#   "snmp_v3": [{"username":"","auth_proto":"SHA","auth_pass":"","priv_proto":"AES","priv_pass":""}],
#   "ssh_credentials": [{"username":"","password":"","key_file":"","enable_pass":""}],
#   "telnet_credentials": [{"username":"","password":""}],
#   "device_overrides": {
#     "192.168.1.1": {"snmp_community":"","ssh_username":"","ssh_password":"","ssh_key":""}
#   }
# }

EMPTY_CREDS='{"snmp_communities":["public","private"],"snmp_v3":[],"ssh_credentials":[],"telnet_credentials":[],"device_overrides":{}}'

init_creds() {
    if [[ ! -f "$CREDS_KEY_FILE" ]]; then
        openssl rand -base64 48 > "$CREDS_KEY_FILE"
        chmod 600 "$CREDS_KEY_FILE"
        log_info "Generated credential encryption key"
    fi
    if [[ ! -f "$CREDS_FILE" ]]; then
        write_creds "$EMPTY_CREDS"
        log_info "Initialized credential store"
    fi
}

read_creds() {
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -pass file:"$CREDS_KEY_FILE" -in "$CREDS_FILE" 2>/dev/null \
        || echo "$EMPTY_CREDS"
}

write_creds() {
    local json="$1"
    echo "$json" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -pass file:"$CREDS_KEY_FILE" -out "$CREDS_FILE" 2>/dev/null
    chmod 600 "$CREDS_FILE"
}

# Get community strings for a specific IP (with device override)
get_communities_for() {
    local ip="$1"
    local creds; creds=$(read_creds)
    local override_community
    override_community=$(echo "$creds" | jq -r ".device_overrides[\"$ip\"].snmp_community // empty" 2>/dev/null)
    if [[ -n "$override_community" ]]; then
        echo "$override_community"
    else
        echo "$creds" | jq -r '.snmp_communities[]' 2>/dev/null || echo "public"
    fi
}

# Get SSH creds for a specific IP (with device override)
get_ssh_creds_for() {
    local ip="$1"
    local creds; creds=$(read_creds)
    local override
    override=$(echo "$creds" | jq -r ".device_overrides[\"$ip\"] // empty" 2>/dev/null)
    if [[ -n "$override" && "$override" != "null" ]]; then
        echo "$override" | jq -c '{username: .ssh_username, password: .ssh_password, key_file: .ssh_key, enable_pass: .enable_pass}'
    else
        echo "$creds" | jq -c '.ssh_credentials[]' 2>/dev/null
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DEPENDENCY INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────
install_deps() {
    log_step "Installing System Dependencies"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >> "$LOG_FILE" 2>&1

    local pkgs=(
        # Container runtime
        docker.io docker-compose-v2
        # Core network tools
        git curl wget ipcalc bc
        # Nmap — comprehensive port/service/OS scanner
        nmap
        # Masscan — ultra-fast port scanner
        masscan
        # ARP scanner
        arp-scan
        # SNMP tools (v1/v2c/v3)
        snmp snmpd snmp-mibs-downloader libsnmp-dev
        # SSH automation
        sshpass openssh-client
        # LLDP daemon (sends/receives LLDP on local interfaces)
        lldpd
        # Telnet client
        telnet
        # NetBIOS / SMB
        samba-common-bin nbtscan
        # DNS tools
        dnsutils bind9-dnsutils
        # mDNS / Bonjour
        avahi-daemon avahi-utils
        # JSON processor
        jq
        # Python 3 + pip
        python3 python3-pip python3-venv python3-dev
        # Misc
        netcat-openbsd openssl fping whois traceroute arp
        # Network packet tools
        tcpdump
    )

    local failed=()
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -l "$pkg" &>/dev/null; then
            echo -ne "  Installing ${W}${pkg}${NC}... "
            if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
                echo -e "${G}OK${NC}"
            else
                echo -e "${R}FAILED${NC}"
                failed+=("$pkg")
            fi
        else
            log_debug "$pkg already installed"
        fi
    done

    # Enable SNMP MIBs (download them)
    echo -ne "  Downloading SNMP MIBs... "
    download-mibs >> "$LOG_FILE" 2>&1 || true
    sed -i '/^mibs/d' /etc/snmp/snmp.conf 2>/dev/null || true
    echo "mibs +ALL" >> /etc/snmp/snmp.conf 2>/dev/null || true
    echo -e "${G}OK${NC}"

    # Python libraries for advanced scanning
    log_info "Installing Python network libraries..."
    pip3 install --break-system-packages --quiet \
        netmiko napalm pysnmp pysnmplib paramiko \
        requests pynetbox scapy >> "$LOG_FILE" 2>&1 \
        || log_warn "Some Python packages failed — check log"

    # Enable services
    for svc in docker lldpd avahi-daemon; do
        systemctl enable "$svc" >> "$LOG_FILE" 2>&1 || true
        systemctl start  "$svc" >> "$LOG_FILE" 2>&1 || true
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_warn "Failed packages: ${failed[*]}"
    else
        log_ok "All dependencies installed successfully"
    fi
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
# NETBOX DOCKER DEPLOYMENT
# ─────────────────────────────────────────────────────────────────────────────
deploy_netbox() {
    log_step "Deploying NetBox via Docker Compose"

    if ! cmd_exists docker; then
        log_error "Docker not installed. Run Option 1 first."
        pause; return 1
    fi

    local admin_pass
    admin_pass="NetBox@$(openssl rand -hex 5)"
    local secret_key
    secret_key=$(openssl rand -base64 60 | tr -d '\n/+=' | head -c 50)

    if [[ -d "$NETBOX_DIR/.git" ]]; then
        log_info "Updating existing netbox-docker repo..."
        git -C "$NETBOX_DIR" pull -q >> "$LOG_FILE" 2>&1
    else
        log_info "Cloning netbox-docker..."
        git clone -q https://github.com/netbox-community/netbox-docker.git \
            "$NETBOX_DIR" >> "$LOG_FILE" 2>&1
    fi

    cd "$NETBOX_DIR" || { log_error "Cannot cd to $NETBOX_DIR"; return 1; }

    # Write docker-compose override
    cat > docker-compose.override.yml <<DCEOF
version: '3.4'
services:
  netbox:
    ports:
      - "${NETBOX_PORT}:8080"
    environment:
      SUPERUSER_NAME: admin
      SUPERUSER_PASSWORD: ${admin_pass}
      SUPERUSER_EMAIL: admin@netbox.local
      SECRET_KEY: ${secret_key}
  netbox-worker:
    environment:
      SECRET_KEY: ${secret_key}
  netbox-housekeeping:
    environment:
      SECRET_KEY: ${secret_key}
DCEOF

    log_info "Pulling Docker images (may take several minutes)..."
    docker compose pull >> "$LOG_FILE" 2>&1 &
    spinner $!
    wait $! || { log_error "docker compose pull failed"; pause; return 1; }

    log_info "Starting NetBox containers..."
    docker compose up -d >> "$LOG_FILE" 2>&1 &
    spinner $!
    wait $!

    # Wait for NetBox to become healthy
    echo -ne "  Waiting for NetBox to initialize "
    local retries=0
    until curl -sf "http://localhost:${NETBOX_PORT}/api/" &>/dev/null; do
        sleep 5; echo -n "."; (( retries++ ))
        if (( retries > 36 )); then
            echo -e "\n${R}Timeout — NetBox did not start in 3 minutes${NC}"
            echo "  Check logs: docker compose -f $NETBOX_DIR/docker-compose.yml logs netbox"
            pause; return 1
        fi
    done
    echo -e " ${G}Ready!${NC}"

    # Generate API token via Django shell
    log_info "Creating API token..."
    NETBOX_API_TOKEN=$(docker compose exec -T netbox \
        python manage.py shell -c \
        "from users.models import Token; from django.contrib.auth.models import User; \
         u=User.objects.get(username='admin'); \
         t,_=Token.objects.get_or_create(user=u); print(t.key)" \
        2>/dev/null | tail -1)
    save_config

    # Save credentials to file
    local creds_out="$BASE_DIR/netbox-credentials.txt"
    cat > "$creds_out" <<CREDEOF
NetBox Access Credentials
=========================
URL:       http://localhost:${NETBOX_PORT}
Username:  admin
Password:  ${admin_pass}
API Token: ${NETBOX_API_TOKEN}

KEEP THIS FILE SECURE — DELETE AFTER NOTING CREDENTIALS
CREDEOF
    chmod 600 "$creds_out"

    echo -e "\n${G}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${G}║           NetBox Deployed Successfully!       ║${NC}"
    echo -e "${G}╚══════════════════════════════════════════════╝${NC}"
    echo -e "  URL:      ${W}http://localhost:${NETBOX_PORT}${NC}"
    echo -e "  User:     ${W}admin${NC}"
    echo -e "  Password: ${W}${admin_pass}${NC}"
    echo -e "  Token:    ${W}${NETBOX_API_TOKEN}${NC}"
    echo -e "  ${D}(Saved to $creds_out)${NC}"
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
# NETBOX REST API HELPERS
# ─────────────────────────────────────────────────────────────────────────────
nb_api() {
    local method="$1" endpoint="$2"
    local data="${3:-}"
    local url="${NETBOX_API_URL}/api/${endpoint}"

    if [[ -z "$NETBOX_API_TOKEN" ]]; then
        log_error "NetBox API token not set. Configure via NetBox Management menu."
        return 1
    fi

    local args=(-sf -X "$method"
        -H "Authorization: Token $NETBOX_API_TOKEN"
        -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")

    curl "${args[@]}" "$url" 2>>"$LOG_FILE"
}

nb_get()    { nb_api GET   "$1"; }
nb_post()   { nb_api POST  "$1" "${2:-}"; }
nb_patch()  { nb_api PATCH "$1" "${2:-}"; }

# Slugify a string
slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -dc '[:alnum:]-' | sed 's/-\+/-/g'
}

# ── Get or create NetBox objects ──
nb_get_or_create_site() {
    local name="${DEFAULT_SITE_NAME}"
    local slug; slug=$(slugify "$name")
    local res; res=$(nb_get "dcim/sites/?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name'))")")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/sites/" "{\"name\":\"$name\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty')
        log_info "Created NetBox site: $name (ID: $id)"
    fi
    echo "$id"
}

nb_get_or_create_manufacturer() {
    local name="$1"
    local slug; slug=$(slugify "$name")
    local res; res=$(nb_get "dcim/manufacturers/?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name'))")")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/manufacturers/" "{\"name\":\"$name\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty')
    fi
    echo "$id"
}

nb_get_or_create_device_type() {
    local mfr_id="$1" model="$2"
    local slug; slug=$(slugify "$model")
    local res; res=$(nb_get "dcim/device-types/?model=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$model'))")")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/device-types/" \
            "{\"manufacturer\":$mfr_id,\"model\":\"$model\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty')
    fi
    echo "$id"
}

nb_get_or_create_role() {
    local name="$1" color="${2:-2196f3}"
    local slug; slug=$(slugify "$name")
    local res; res=$(nb_get "dcim/device-roles/?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name'))")")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/device-roles/" \
            "{\"name\":\"$name\",\"slug\":\"$slug\",\"color\":\"$color\"}")
        id=$(echo "$res" | jq -r '.id // empty')
    fi
    echo "$id"
}

nb_get_or_create_vlan() {
    local vid="$1" name="${2:-VLAN-$1}" site_id="$3"
    local res; res=$(nb_get "ipam/vlans/?vid=$vid")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        res=$(nb_post "ipam/vlans/" \
            "{\"vid\":$vid,\"name\":\"$name\",\"site\":$site_id}")
        id=$(echo "$res" | jq -r '.id // empty')
    fi
    echo "$id"
}

nb_add_ip() {
    local ip="$1" device_id="${2:-}" iface_id="${3:-}"
    [[ "$ip" != */* ]] && ip="${ip}/32"
    local existing; existing=$(nb_get "ipam/ip-addresses/?address=${ip}")
    local ip_id; ip_id=$(echo "$existing" | jq -r '.results[0].id // empty')

    local payload
    payload=$(jq -n --arg addr "$ip" \
        '{address: $addr, status: "active"}')

    if [[ -n "$iface_id" && "$iface_id" != "null" ]]; then
        payload=$(echo "$payload" | jq \
            ".assigned_object_type=\"dcim.interface\" | .assigned_object_id=$iface_id")
    fi

    if [[ -z "$ip_id" ]]; then
        local res; res=$(nb_post "ipam/ip-addresses/" "$payload")
        ip_id=$(echo "$res" | jq -r '.id // empty')
    fi

    # Set as primary IP on device
    if [[ -n "$device_id" && -n "$ip_id" ]]; then
        nb_patch "dcim/devices/${device_id}/" \
            "{\"primary_ip4\":$ip_id}" >/dev/null
    fi
    echo "$ip_id"
}

nb_add_interface() {
    local device_id="$1" if_name="$2"
    local if_type="${3:-other}" mac="${4:-}" desc="${5:-}"
    local existing; existing=$(nb_get "dcim/interfaces/?device_id=$device_id&name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$if_name'))")")
    local id; id=$(echo "$existing" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        local payload
        payload=$(jq -n \
            --argjson dev "$device_id" \
            --arg name "$if_name" \
            --arg type "$if_type" \
            --arg mac "$mac" \
            --arg desc "$desc" \
            '{device:$dev, name:$name, type:$type, description:$desc,
              mac_address: (if $mac != "" and $mac != "null" then $mac else null end)}')
        local res; res=$(nb_post "dcim/interfaces/" "$payload")
        id=$(echo "$res" | jq -r '.id // empty')
    fi
    echo "$id"
}

nb_create_cable() {
    local a_iface_id="$1" b_iface_id="$2" label="${3:-}"
    nb_post "dcim/cables/" \
        "{\"a_terminations\":[{\"object_type\":\"dcim.interface\",\"object_id\":$a_iface_id}],
          \"b_terminations\":[{\"object_type\":\"dcim.interface\",\"object_id\":$b_iface_id}],
          \"label\":\"$label\"}" >/dev/null
}

nb_upsert_device() {
    local name="$1" ip="$2" role="$3" mfr="$4" model="$5" site_id="$6"
    local os="${7:-}" serial="${8:-}" comments="${9:-}"

    local mfr_id role_id dtype_id
    mfr_id=$(nb_get_or_create_manufacturer "$mfr")
    dtype_id=$(nb_get_or_create_device_type "$mfr_id" "$model")
    role_id=$(nb_get_or_create_role "$role")

    local existing; existing=$(nb_get "dcim/devices/?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name'))")")
    local dev_id; dev_id=$(echo "$existing" | jq -r '.results[0].id // empty')

    local payload
    payload=$(jq -n \
        --arg name "$name" \
        --argjson dt "$dtype_id" \
        --argjson role "$role_id" \
        --argjson site "$site_id" \
        --arg serial "$serial" \
        --arg comments "$comments" \
        '{name:$name, device_type:$dt, role:$role, site:$site,
          status:"active", serial:$serial, comments:$comments}')

    if [[ -z "$dev_id" ]]; then
        local res; res=$(nb_post "dcim/devices/" "$payload")
        dev_id=$(echo "$res" | jq -r '.id // empty')
        log_info "Created device in NetBox: $name (ID: $dev_id)"
    else
        nb_patch "dcim/devices/${dev_id}/" "$payload" >/dev/null
        log_info "Updated device in NetBox: $name (ID: $dev_id)"
    fi

    # Add custom field for OS if supported
    if [[ -n "$os" && -n "$dev_id" ]]; then
        nb_patch "dcim/devices/${dev_id}/" \
            "{\"comments\":\"OS: $os\\n$comments\"}" >/dev/null 2>&1 || true
    fi

    echo "$dev_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# DISCOVERY ENGINE
# ─────────────────────────────────────────────────────────────────────────────

DISC_RESULTS=""   # path to current results JSON file
LIVE_HOSTS_FILE="$DISCOVERY_DIR/live_hosts.txt"

init_scan_session() {
    local target="$1"
    DISC_RESULTS="$DISCOVERY_DIR/results_$(date +%Y%m%d_%H%M%S).json"
    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg target "$target" \
        '{scan_time: $ts, target: $target, hosts: []}' \
        > "$DISC_RESULTS"
    log_info "Scan session initialized: $DISC_RESULTS"
}

append_host() {
    local host_json="$1"
    local tmp; tmp=$(mktemp)
    jq ".hosts += [$host_json]" "$DISC_RESULTS" > "$tmp" && mv "$tmp" "$DISC_RESULTS"
}

# ── Phase 1: Host Discovery ──────────────────────────────────────────────────
discover_live_hosts() {
    local target="$1"
    > "$LIVE_HOSTS_FILE"
    local tmp_all; tmp_all=$(mktemp)

    log_step "Phase 1 — Host Discovery: $target"

    # 1. ARP scan (fastest, LAN only)
    echo -ne "  ${W}ARP scan${NC} ............... "
    if cmd_exists arp-scan; then
        arp-scan --localnet --quiet 2>/dev/null \
            | awk '/^[0-9]/{print $1}' >> "$tmp_all"
        arp-scan "$target" --quiet 2>/dev/null \
            | awk '/^[0-9]/{print $1}' >> "$tmp_all" 2>/dev/null || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped (not installed)${NC}"; fi

    # 2. fping sweep
    echo -ne "  ${W}fping ICMP sweep${NC} ....... "
    if cmd_exists fping; then
        fping -a -g "$target" 2>/dev/null >> "$tmp_all" || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    # 3. nmap ping sweep (ICMP + TCP SYN + ACK)
    echo -ne "  ${W}nmap ping sweep${NC} ........ "
    if cmd_exists nmap; then
        nmap -sn -PE -PS22,80,443,8080,8443 -PA80,443 \
            --host-timeout 10s "$target" -oG - 2>/dev/null \
            | awk '/Up$/{print $2}' >> "$tmp_all"
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    # 4. masscan fast port scan for host discovery
    echo -ne "  ${W}masscan fast scan${NC} ...... "
    if cmd_exists masscan; then
        masscan "$target" -p22,80,443,8080,161,23 --rate=2000 \
            --wait 2 -oG - 2>/dev/null \
            | awk '/open/{print $6}' >> "$tmp_all" || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    # 5. SNMP broadcast / sweep
    echo -ne "  ${W}SNMP sweep${NC} ............. "
    while IFS= read -r comm; do
        fping -a -g "$target" 2>/dev/null | while read -r ip; do
            snmpget -v2c -c "$comm" -t 1 -r 0 "$ip" \
                1.3.6.1.2.1.1.1.0 &>/dev/null && echo "$ip" >> "$tmp_all"
        done &
    done < <(get_communities_for "0.0.0.0")
    wait
    echo -e "${G}done${NC}"

    # 6. mDNS/Bonjour
    echo -ne "  ${W}mDNS discovery${NC} ......... "
    if cmd_exists avahi-browse; then
        timeout 8 avahi-browse -atr --no-fail 2>/dev/null \
            | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' >> "$tmp_all" || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    # 7. NetBIOS
    echo -ne "  ${W}NetBIOS scan${NC} ........... "
    if cmd_exists nbtscan; then
        nbtscan -q "$target" 2>/dev/null \
            | awk '/^[0-9]/{print $1}' >> "$tmp_all" || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    # 8. ARP cache (passive)
    echo -ne "  ${W}ARP cache${NC} .............. "
    ip neigh show 2>/dev/null | awk '/REACHABLE|STALE|DELAY/{print $1}' >> "$tmp_all"
    arp -n 2>/dev/null | awk 'NR>1 && $3!="(incomplete)"{print $1}' >> "$tmp_all"
    echo -e "${G}done${NC}"

    # Deduplicate, validate, sort
    sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -u "$tmp_all" \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        | while IFS= read -r ip; do valid_ip "$ip" && echo "$ip"; done \
        > "$LIVE_HOSTS_FILE"
    rm -f "$tmp_all"

    local count; count=$(wc -l < "$LIVE_HOSTS_FILE")
    log_ok "Phase 1 complete — $count live hosts found"
    echo -e "\n  ${G}Found: ${W}${count} live hosts${NC}"
}

# ── Phase 2: Per-host deep scan ───────────────────────────────────────────────
scan_all_hosts() {
    local total; total=$(wc -l < "$LIVE_HOSTS_FILE")
    log_step "Phase 2 — Deep Scanning $total Hosts"

    local idx=0
    while IFS= read -r ip; do
        (( idx++ ))
        printf "\n  ${C}[%d/%d]${NC} ${W}%s${NC}\n" "$idx" "$total" "$ip"
        scan_single_host "$ip"
    done < "$LIVE_HOSTS_FILE"

    log_ok "Phase 2 complete"
}

scan_single_host() {
    local ip="$1"
    local tmp; tmp=$(mktemp -d)

    # Launch all probe modules in parallel
    probe_nmap      "$ip" "$tmp" &
    probe_snmp      "$ip" "$tmp" &
    probe_ssh       "$ip" "$tmp" &
    probe_http      "$ip" "$tmp" &
    probe_netbios   "$ip" "$tmp" &
    probe_lldp_cdp  "$ip" "$tmp" &
    probe_dns       "$ip" "$tmp" &
    probe_banners   "$ip" "$tmp" &
    probe_mdns      "$ip" "$tmp" &
    wait

    # Merge all probe output into one host record
    local host_json
    host_json=$(merge_host_data "$ip" "$tmp")

    # Append to session results
    append_host "$host_json"

    # Summary line
    local role os hostname
    hostname=$(echo "$host_json" | jq -r '.hostname // "?"')
    role=$(echo "$host_json" | jq -r '.device_role // "?"')
    os=$(echo "$host_json" | jq -r '.os // ""')
    printf "    ${G}✓${NC} %-16s  %-30s  %-18s  %s\n" \
        "$ip" "$hostname" "$role" "$os"

    rm -rf "$tmp"
}

# ── Probe: nmap ───────────────────────────────────────────────────────────────
probe_nmap() {
    local ip="$1" tmp="$2"
    local xml="$tmp/nmap.xml"

    nmap -sV -sC -O --osscan-guess \
        -p "T:1-1024,T:1433,T:1521,T:3306,T:3389,T:5432,T:5900-5901,T:6379,T:8080,T:8443,T:8888,T:9200,T:9300,T:27017,U:53,U:67,U:68,U:69,U:123,U:161,U:162,U:500,U:514,U:5353" \
        --script "banner,ssh-hostkey,ssh2-enum-algos,snmp-info,snmp-sysdescr,snmp-interfaces,\
http-title,http-server-header,http-auth-finder,ssl-cert,ssl-enum-ciphers,\
nbstat,smb-security-mode,smb2-security-mode,dns-service-discovery,\
ftp-banner,telnet-ntlm-info,imap-capabilities,pop3-capabilities,\
rdp-enum-encryption,vnc-info,ms-sql-info,mysql-info,mongodb-info" \
        -T4 --host-timeout 90s --max-retries 2 \
        -oX "$xml" "$ip" >> "$LOG_FILE" 2>&1 || true

    # Convert XML to JSON
    python3 - <<PYEOF > "$tmp/nmap.json" 2>/dev/null
import xml.etree.ElementTree as ET, json, sys

def parse():
    try:
        tree = ET.parse('$xml')
    except Exception:
        return {"ports":[], "os":None, "mac":None, "vendor":None, "hostname":None, "scripts":{}}

    result = {"ports":[], "os":None, "os_accuracy":None,
              "mac":None, "vendor":None, "hostname":None, "scripts":{}}

    for host in tree.findall('host'):
        # Hostnames
        for hn in (host.find('hostnames') or []):
            if hn.get('type') == 'PTR':
                result['hostname'] = hn.get('name')
            elif not result['hostname']:
                result['hostname'] = hn.get('name')

        # Addresses
        for addr in host.findall('address'):
            if addr.get('addrtype') == 'mac':
                result['mac'] = addr.get('addr')
                result['vendor'] = addr.get('vendor','')

        # OS
        os_el = host.find('os')
        if os_el is not None:
            for m in os_el.findall('osmatch'):
                result['os'] = m.get('name')
                result['os_accuracy'] = m.get('accuracy')
                break

        # Ports
        ports_el = host.find('ports')
        if ports_el is not None:
            for port in ports_el.findall('port'):
                state = port.find('state')
                if state is None or state.get('state') != 'open':
                    continue
                p = {'port': port.get('portid'),
                     'proto': port.get('protocol'),
                     'service': None, 'version': None,
                     'banner': None, 'scripts': {}}
                svc = port.find('service')
                if svc is not None:
                    p['service'] = svc.get('name','')
                    prod = svc.get('product','')
                    ver  = svc.get('version','')
                    p['version'] = f"{prod} {ver}".strip()
                for sc in port.findall('script'):
                    sid = sc.get('id','')
                    out = (sc.get('output','') or '')[:300]
                    p['scripts'][sid] = out
                    if sid == 'banner':
                        p['banner'] = out
                result['ports'].append(p)

        # Host-level scripts
        for sc in host.findall('hostscript/script'):
            result['scripts'][sc.get('id','')] = sc.get('output','')[:300]

    return result

print(json.dumps(parse()))
PYEOF
}

# ── Probe: SNMP (v1/v2c + v3) ────────────────────────────────────────────────
probe_snmp() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/snmp.json"

    local communities; communities=$(get_communities_for "$ip")
    local working_comm=""

    while IFS= read -r comm; do
        if snmpget -v2c -c "$comm" -t "$SNMP_TIMEOUT" -r 1 \
            "$ip" 1.3.6.1.2.1.1.1.0 &>/dev/null; then
            working_comm="$comm"
            break
        fi
    done <<< "$communities"

    # Try SNMPv3 if v2c failed
    local creds; creds=$(read_creds)
    if [[ -z "$working_comm" ]]; then
        while IFS= read -r v3cred; do
            local u ap apass pp ppass
            u=$(echo "$v3cred"     | jq -r '.username')
            ap=$(echo "$v3cred"    | jq -r '.auth_proto // "SHA"')
            apass=$(echo "$v3cred" | jq -r '.auth_pass')
            pp=$(echo "$v3cred"    | jq -r '.priv_proto // "AES"')
            ppass=$(echo "$v3cred" | jq -r '.priv_pass')

            if snmpget -v3 -u "$u" -l authPriv \
                -a "$ap" -A "$apass" \
                -x "$pp" -X "$ppass" \
                -t "$SNMP_TIMEOUT" -r 1 \
                "$ip" 1.3.6.1.2.1.1.1.0 &>/dev/null; then
                working_comm="v3:$u:$ap:$apass:$pp:$ppass"
                break
            fi
        done < <(echo "$creds" | jq -c '.snmp_v3[]' 2>/dev/null || true)
    fi

    [[ -z "$working_comm" ]] && return

    # Build snmpwalk command prefix
    local snmp_args=()
    if [[ "$working_comm" == v3:* ]]; then
        IFS=: read -r _ u ap apass pp ppass <<< "$working_comm"
        snmp_args=(-v3 -u "$u" -l authPriv -a "$ap" -A "$apass" -x "$pp" -X "$ppass")
    else
        snmp_args=(-v2c -c "$working_comm")
    fi

    # Collect key OIDs
    local _snmp() { snmpget "${snmp_args[@]}" -t "$SNMP_TIMEOUT" -r 1 "$ip" "$1" 2>/dev/null | sed 's/.*: //'; }

    local sys_descr sys_name sys_loc sys_contact sys_uptime sys_oid
    sys_descr=$(  _snmp 1.3.6.1.2.1.1.1.0)
    sys_name=$(   _snmp 1.3.6.1.2.1.1.5.0)
    sys_loc=$(    _snmp 1.3.6.1.2.1.1.6.0)
    sys_contact=$(  _snmp 1.3.6.1.2.1.1.4.0)
    sys_uptime=$(  _snmp 1.3.6.1.2.1.1.3.0)
    sys_oid=$(    _snmp 1.3.6.1.2.1.1.2.0)

    # Interface table
    local ifaces_raw; ifaces_raw=$(snmpwalk "${snmp_args[@]}" -t "$SNMP_TIMEOUT" -r 1 \
        "$ip" 1.3.6.1.2.1.2.2 2>/dev/null || true)

    # MAC address table (bridge MIB)
    local mac_table; mac_table=$(snmpwalk "${snmp_args[@]}" -t "$SNMP_TIMEOUT" -r 1 \
        "$ip" 1.3.6.1.2.1.17.4.3.1 2>/dev/null || true)

    # ARP table
    local arp_table; arp_table=$(snmpwalk "${snmp_args[@]}" -t "$SNMP_TIMEOUT" -r 1 \
        "$ip" 1.3.6.1.2.1.4.22.1 2>/dev/null || true)

    # Chassis ID (entity MIB)
    local chassis_serial; chassis_serial=$(snmpget "${snmp_args[@]}" -t "$SNMP_TIMEOUT" -r 1 \
        "$ip" 1.3.6.1.2.1.47.1.1.1.1.11.1 2>/dev/null | sed 's/.*: //' || true)

    # CDP neighbors (Cisco)
    local cdp_raw; cdp_raw=$(snmpwalk "${snmp_args[@]}" -t "$SNMP_TIMEOUT" -r 1 \
        "$ip" 1.3.6.1.4.1.9.9.23.1.2.1.1 2>/dev/null || true)

    # LLDP neighbors
    local lldp_raw; lldp_raw=$(snmpwalk "${snmp_args[@]}" -t "$SNMP_TIMEOUT" -r 1 \
        "$ip" 1.0.8802.1.1.2.1.4 2>/dev/null || true)

    python3 - <<PYEOF > "$tmp/snmp.json" 2>/dev/null
import re, json

working_comm = """$working_comm"""

sys_descr   = """${sys_descr//\"/\'}""".strip().strip('"')
sys_name    = """${sys_name//\"/\'}""".strip().strip('"')
sys_loc     = """${sys_loc//\"/\'}""".strip().strip('"')
sys_contact = """${sys_contact//\"/\'}""".strip().strip('"')
sys_uptime  = """${sys_uptime//\"/\'}""".strip()
sys_oid     = """${sys_oid//\"/\'}""".strip()
chassis_ser = """${chassis_serial//\"/\'}""".strip().strip('"')

ifaces_raw = """${ifaces_raw}"""
mac_table_raw = """${mac_table}"""
arp_table_raw = """${arp_table}"""
cdp_raw    = """${cdp_raw}"""
lldp_raw   = """${lldp_raw}"""

# Parse interfaces
ifaces = {}
for line in ifaces_raw.split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*(STRING|INTEGER|Gauge32|Counter32|PhysAddress):\s*(.*)', line)
    if m:
        oid_leaf, dtype, val = m.groups()
        val = val.strip().strip('"')
        if oid_leaf not in ifaces:
            ifaces[oid_leaf] = {}
        if '2.2.1.2' in line:  ifaces[oid_leaf]['name'] = val
        if '2.2.1.3' in line:  ifaces[oid_leaf]['type'] = val
        if '2.2.1.6' in line:  ifaces[oid_leaf]['mac'] = val
        if '2.2.1.7' in line:  ifaces[oid_leaf]['admin_status'] = val
        if '2.2.1.8' in line:  ifaces[oid_leaf]['oper_status'] = val
        if '2.2.1.5' in line:  ifaces[oid_leaf]['speed'] = val
        if '2.2.1.13' in line: ifaces[oid_leaf]['in_discards'] = val

interfaces = [{'index': k, **v} for k, v in ifaces.items() if 'name' in v]

# Parse MAC bridge table
mac_port_map = []
for line in mac_table_raw.split('\n'):
    m = re.match(r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m:
        mac_dec, port_idx = m.groups()
        mac = ':'.join(f'{int(o):02x}' for o in mac_dec.split('.'))
        mac_port_map.append({'mac': mac, 'port_index': port_idx})

# Parse ARP table
arp_entries = []
for line in arp_table_raw.split('\n'):
    m = re.match(r'.*4\.22\.1\.2\.\d+\.(\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m:
        arp_ip, if_idx = m.groups()
        arp_entries.append({'ip': arp_ip, 'if_index': if_idx})

# Parse CDP neighbors
cdp_neighbors = []
cdp_devices = {}
for line in cdp_raw.split('\n'):
    # Device ID: OID 1.3.6.1.4.1.9.9.23.1.2.1.1.6
    m = re.match(r'.*\.6\.(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)', line)
    if m:
        local_if, remote_if, val = m.groups()
        key = f"{local_if}_{remote_if}"
        if key not in cdp_devices: cdp_devices[key] = {}
        cdp_devices[key]['device_id'] = val.strip().strip('"')
    # Platform: 1.3.6.1.4.1.9.9.23.1.2.1.1.8
    m = re.match(r'.*\.8\.(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)', line)
    if m:
        local_if, remote_if, val = m.groups()
        key = f"{local_if}_{remote_if}"
        if key not in cdp_devices: cdp_devices[key] = {}
        cdp_devices[key]['platform'] = val.strip().strip('"')
    # Remote port: 1.3.6.1.4.1.9.9.23.1.2.1.1.7
    m = re.match(r'.*\.7\.(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)', line)
    if m:
        local_if, remote_if, val = m.groups()
        key = f"{local_if}_{remote_if}"
        if key not in cdp_devices: cdp_devices[key] = {}
        cdp_devices[key]['remote_port'] = val.strip().strip('"')

cdp_neighbors = list(cdp_devices.values())

# Parse LLDP neighbors
lldp_neighbors = []
lldp_sys = {}
for line in lldp_raw.split('\n'):
    m = re.match(r'.*\.9\.(\d+)\.(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)', line)
    if m:
        time_mark, local_port, rem_idx, val = m.groups()
        key = f"{local_port}_{rem_idx}"
        if key not in lldp_sys: lldp_sys[key] = {}
        if '4.1.1.9' in line: lldp_sys[key]['sys_name'] = val.strip().strip('"')
        if '4.1.1.10' in line: lldp_sys[key]['sys_desc'] = val.strip().strip('"')[:100]
        if '4.1.1.7' in line: lldp_sys[key]['port_id'] = val.strip().strip('"')
        if '4.1.1.8' in line: lldp_sys[key]['port_desc'] = val.strip().strip('"')

lldp_neighbors = list(lldp_sys.values())

result = {
    "available": True,
    "community": working_comm,
    "sys_descr": sys_descr,
    "sys_name": sys_name,
    "sys_location": sys_loc,
    "sys_contact": sys_contact,
    "sys_uptime": sys_uptime,
    "sys_oid": sys_oid,
    "chassis_serial": chassis_ser,
    "interfaces": interfaces,
    "mac_port_map": mac_port_map,
    "arp_entries": arp_entries,
    "cdp_neighbors": cdp_neighbors,
    "lldp_neighbors": lldp_neighbors,
}

print(json.dumps(result))
PYEOF
}

# ── Probe: SSH ────────────────────────────────────────────────────────────────
probe_ssh() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/ssh.json"

    # Quick port check
    nc -z -w "$SCAN_TIMEOUT" "$ip" 22 2>/dev/null || return

    local banner
    banner=$(nc -w 3 "$ip" 22 2>/dev/null | head -1 | tr -dc '[:print:]')

    local sys_info="" hostname="" os_info="" kernel="" cpu="" mem="" ifaces=""
    local remote_cmd='echo "HOSTNAME=$(hostname)"; uname -a; \
        cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null || uname -v; \
        ip -j addr 2>/dev/null || ip addr 2>/dev/null || ifconfig 2>/dev/null; \
        lscpu 2>/dev/null | head -5; \
        free -h 2>/dev/null | head -2; \
        cat /proc/version 2>/dev/null | head -1'

    local ssh_base_opts=(-o StrictHostKeyChecking=no
        -o ConnectTimeout="$SSH_TIMEOUT"
        -o BatchMode=yes
        -o LogLevel=error
        -o UserKnownHostsFile=/dev/null
        -o PreferredAuthentications="publickey,password"
        -o PubkeyAuthentication=yes)

    while IFS= read -r cred_json; do
        [[ -z "$cred_json" || "$cred_json" == "null" ]] && continue
        local u p k e
        u=$(echo "$cred_json" | jq -r '.username // empty')
        p=$(echo "$cred_json" | jq -r '.password // empty')
        k=$(echo "$cred_json" | jq -r '.key_file // empty')
        e=$(echo "$cred_json" | jq -r '.enable_pass // empty')

        [[ -z "$u" ]] && continue

        local opts=("${ssh_base_opts[@]}")
        [[ -n "$k" && -f "$k" ]] && opts+=(-i "$k")

        if [[ -n "$p" ]]; then
            sys_info=$(sshpass -p "$p" ssh "${opts[@]}" \
                "${u}@${ip}" "$remote_cmd" 2>/dev/null || true)
        else
            sys_info=$(ssh "${opts[@]}" \
                "${u}@${ip}" "$remote_cmd" 2>/dev/null || true)
        fi

        if [[ -n "$sys_info" ]]; then
            hostname=$(echo "$sys_info" | grep '^HOSTNAME=' | cut -d= -f2)
            os_info=$(echo "$sys_info" | grep -m1 'PRETTY_NAME=\|ProductName:' | sed 's/.*=//;s/.*: //' | tr -d '"')
            kernel=$(echo "$sys_info" | grep '^Linux\|^Darwin' | head -1)
            cpu=$(echo "$sys_info" | grep -i 'model name\|CPU' | head -1 | sed 's/.*: //')
            mem=$(echo "$sys_info" | grep '^Mem:' | awk '{print $2}')
            break
        fi
    done < <(get_ssh_creds_for "$ip")

    # Network device detection — try show commands
    local net_info=""
    if [[ -z "$sys_info" ]]; then
        local net_cmd='show version 2>/dev/null || show sys version 2>/dev/null || display version 2>/dev/null'
        while IFS= read -r cred_json; do
            [[ -z "$cred_json" ]] && continue
            local u p k
            u=$(echo "$cred_json" | jq -r '.username // empty')
            p=$(echo "$cred_json" | jq -r '.password // empty')
            k=$(echo "$cred_json" | jq -r '.key_file // empty')

            local opts=(-o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT"
                -o LogLevel=error -o UserKnownHostsFile=/dev/null)
            [[ -n "$k" && -f "$k" ]] && opts+=(-i "$k")

            if [[ -n "$p" ]]; then
                net_info=$(sshpass -p "$p" ssh "${opts[@]}" \
                    "${u}@${ip}" "$net_cmd" 2>/dev/null | head -20 || true)
            else
                net_info=$(ssh "${opts[@]}" \
                    "${u}@${ip}" "$net_cmd" 2>/dev/null | head -20 || true)
            fi
            [[ -n "$net_info" ]] && break
        done < <(get_ssh_creds_for "$ip")
    fi

    jq -n \
        --arg avail "true" \
        --arg banner "$banner" \
        --arg hostname "$hostname" \
        --arg os "$os_info" \
        --arg kernel "$kernel" \
        --arg cpu "$cpu" \
        --arg mem "$mem" \
        --arg net_info "$net_info" \
        '{available:true, banner:$banner, hostname:$hostname,
          os:$os, kernel:$kernel, cpu:$cpu, mem_total:$mem,
          net_device_info:$net_info}' \
        > "$tmp/ssh.json"
}

# ── Probe: HTTP/HTTPS ─────────────────────────────────────────────────────────
probe_http() {
    local ip="$1" tmp="$2"
    local services=()

    for port in 80 443 8080 8443 8000 8888 3000 3001 5000 9090 9443 4443 7443 10443; do
        local proto="http"
        [[ "$port" =~ ^(443|8443|9443|4443|7443|10443)$ ]] && proto="https"

        local hdr_file="$tmp/hdr_${port}.txt"
        local body
        body=$(curl -skL \
            --max-time "$SCAN_TIMEOUT" \
            --max-redirs 3 \
            -A "Mozilla/5.0 NetBox-Discovery/2.0" \
            -D "$hdr_file" \
            "${proto}://${ip}:${port}/" 2>/dev/null) || continue

        [[ ! -f "$hdr_file" ]] && continue

        local status server title powered_by redirect_url cert_cn cert_exp
        status=$(head -1 "$hdr_file" | awk '{print $2}')
        server=$(grep -i '^Server:' "$hdr_file" | head -1 | cut -d' ' -f2- | tr -d '\r')
        powered_by=$(grep -i '^X-Powered-By:' "$hdr_file" | head -1 | cut -d' ' -f2- | tr -d '\r')
        redirect_url=$(grep -i '^Location:' "$hdr_file" | head -1 | cut -d' ' -f2- | tr -d '\r')
        title=$(echo "$body" | grep -oi '<title[^>]*>[^<]*</title>' | sed 's/<[^>]*>//g' | head -1 | xargs)

        # TLS certificate details
        if [[ "$proto" == "https" ]]; then
            local cert_info
            cert_info=$(echo | openssl s_client -connect "${ip}:${port}" \
                -servername "$ip" 2>/dev/null | openssl x509 -noout \
                -subject -issuer -enddate 2>/dev/null || true)
            cert_cn=$(echo "$cert_info" | grep subject | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1)
            cert_exp=$(echo "$cert_info" | grep notAfter | cut -d= -f2-)
        fi

        services+=("$(jq -n \
            --argjson port "$port" \
            --arg proto "$proto" \
            --arg status "${status:-?}" \
            --arg server "$server" \
            --arg title "$title" \
            --arg powered_by "$powered_by" \
            --arg cert_cn "${cert_cn:-}" \
            --arg cert_exp "${cert_exp:-}" \
            '{port:$port, proto:$proto, status:$status, server:$server,
              title:$title, powered_by:$powered_by,
              cert_cn:$cert_cn, cert_exp:$cert_exp}')")
    done

    printf '%s\n' "${services[@]}" | jq -s '{http_services:.}' \
        > "$tmp/http.json" 2>/dev/null \
        || echo '{"http_services":[]}' > "$tmp/http.json"
}

# ── Probe: NetBIOS / SMB ──────────────────────────────────────────────────────
probe_netbios() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/netbios.json"

    cmd_exists nmblookup || return
    nc -z -w 2 "$ip" 139 2>/dev/null || nc -z -w 2 "$ip" 445 2>/dev/null || return

    local nb_raw
    nb_raw=$(nmblookup -A "$ip" 2>/dev/null || true)
    [[ -z "$nb_raw" ]] && return

    local netbios_name workgroup
    netbios_name=$(echo "$nb_raw" | awk '/<00>/ && !/GROUP/{print $1; exit}')
    workgroup=$(echo "$nb_raw" | awk '/<00>.*GROUP/{print $1; exit}')

    # SMB share enumeration
    local shares=""
    if cmd_exists smbclient; then
        while IFS= read -r cred_json; do
            local u p
            u=$(echo "$cred_json" | jq -r '.username // empty')
            p=$(echo "$cred_json" | jq -r '.password // empty')
            [[ -z "$u" ]] && continue
            shares=$(smbclient -L "//${ip}" -U "${u}%${p}" \
                --no-pass 2>/dev/null | grep -E '^\s+\w' | awk '{print $1}' || true)
            [[ -n "$shares" ]] && break
        done < <(get_ssh_creds_for "$ip")
    fi

    jq -n \
        --arg name "$netbios_name" \
        --arg wg "$workgroup" \
        --arg shares "$shares" \
        '{available:true, netbios_name:$name, workgroup:$wg, smb_shares:$shares}' \
        > "$tmp/netbios.json"
}

# ── Probe: LLDP / CDP (local + remote SNMP) ───────────────────────────────────
probe_lldp_cdp() {
    local ip="$1" tmp="$2"
    # SNMP-based LLDP/CDP is handled inside probe_snmp
    # Here we capture local LLDP daemon output if this is the management host
    echo '{"local_lldp":[]}' > "$tmp/lldp_local.json"

    if cmd_exists lldpctl; then
        lldpctl -f json 2>/dev/null > "$tmp/lldp_local.json" || true
    fi
}

# ── Probe: DNS ────────────────────────────────────────────────────────────────
probe_dns() {
    local ip="$1" tmp="$2"
    local ptr_name
    ptr_name=$(dig +short +time=3 +tries=1 -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//' || true)
    jq -n --arg ptr "$ptr_name" '{ptr_hostname:$ptr}' > "$tmp/dns.json"
}

# ── Probe: Banner grab (Telnet, FTP, SMTP, POP3, IMAP, etc.) ─────────────────
probe_banners() {
    local ip="$1" tmp="$2"
    local banners=()

    for port in 21 23 25 110 143 515 631 5060; do
        local banner
        banner=$(timeout 3 bash -c "echo '' | nc -w 3 $ip $port 2>/dev/null | head -1 | tr -dc '[:print:]'" 2>/dev/null || true)
        if [[ -n "$banner" && ${#banner} -gt 4 ]]; then
            banners+=("$(jq -n --argjson p "$port" --arg b "$banner" '{port:$p,banner:$b}')")
        fi
    done

    printf '%s\n' "${banners[@]}" | jq -s '{banners:.}' \
        > "$tmp/banners.json" 2>/dev/null \
        || echo '{"banners":[]}' > "$tmp/banners.json"
}

# ── Probe: mDNS service lookup ────────────────────────────────────────────────
probe_mdns() {
    local ip="$1" tmp="$2"
    echo '{"mdns":[]}' > "$tmp/mdns.json"
    cmd_exists avahi-resolve || return

    local mdns_name
    mdns_name=$(avahi-resolve -a "$ip" 2>/dev/null | awk '{print $2}' || true)
    jq -n --arg n "$mdns_name" '{mdns_hostname:$n}' > "$tmp/mdns.json"
}

# ── Merge all probe results into one host record ──────────────────────────────
merge_host_data() {
    local ip="$1" tmp="$2"

    python3 - <<PYEOF
import json, os, re

ip = "$ip"
probes = {}
for f in ['nmap','snmp','ssh','http','netbios','dns','banners','mdns']:
    p = f'$tmp/{f}.json'
    if os.path.exists(p):
        try:
            with open(p) as fh:
                probes[f] = json.load(fh)
        except:
            probes[f] = {}

nmap    = probes.get('nmap',   {})
snmp    = probes.get('snmp',   {})
ssh     = probes.get('ssh',    {})
http    = probes.get('http',   {})
nb      = probes.get('netbios',{})
dns     = probes.get('dns',    {})
bnr     = probes.get('banners',{})
mdns    = probes.get('mdns',   {})

host = {
    "ip": ip,
    "hostname": None,
    "mac": None,
    "vendor": None,
    "os": None,
    "os_accuracy": None,
    "device_role": "Endpoint",
    "manufacturer": "Unknown",
    "model": "Unknown",
    "serial": "",
    "platform_detail": "",
    "ports": nmap.get("ports", []),
    "interfaces": snmp.get("interfaces", []),
    "mac_port_map": snmp.get("mac_port_map", []),
    "arp_entries": snmp.get("arp_entries", []),
    "http_services": http.get("http_services", []),
    "banners": bnr.get("banners", []),
    "cdp_neighbors": snmp.get("cdp_neighbors", []),
    "lldp_neighbors": snmp.get("lldp_neighbors", []),
    "snmp_details": {},
    "ssh_details": {},
    "discovery_methods": [],
}

# ── Hostname resolution (priority: SNMP > SSH > nmap > DNS > mDNS > NetBIOS) ──
for src in [
    snmp.get('sys_name'),
    ssh.get('hostname'),
    nmap.get('hostname'),
    dns.get('ptr_hostname'),
    mdns.get('mdns_hostname'),
    nb.get('netbios_name'),
]:
    if src and src.strip() and src.lower() not in ('none','null',''):
        host['hostname'] = src.strip()
        break
if not host['hostname']:
    host['hostname'] = f"device-{ip.replace('.', '-')}"

# ── Physical address ──
host['mac']    = nmap.get('mac')
host['vendor'] = nmap.get('vendor','')
if not host['vendor'] and snmp.get('interfaces'):
    for iface in snmp['interfaces']:
        if iface.get('mac') and not iface['mac'].startswith('00:00:00'):
            host['mac'] = host['mac'] or iface['mac']
            break

# ── OS ──
host['os']          = nmap.get('os') or ssh.get('os') or ''
host['os_accuracy'] = nmap.get('os_accuracy')

# ── Serial (SNMP entity MIB) ──
host['serial'] = snmp.get('chassis_serial','')

# ── Discovery methods ──
if nmap.get('ports'):       host['discovery_methods'].append('nmap')
if snmp.get('available'):   host['discovery_methods'].append('snmp')
if ssh.get('available'):    host['discovery_methods'].append('ssh')
if http.get('http_services'): host['discovery_methods'].append('http')
if nb.get('available'):     host['discovery_methods'].append('netbios')
if dns.get('ptr_hostname'): host['discovery_methods'].append('dns')
if bnr.get('banners'):      host['discovery_methods'].append('banner')

# ── Device classification ──
sys_descr = (snmp.get('sys_descr') or '').lower()
os_str    = (host['os'] or '').lower()
ssh_net   = (ssh.get('net_device_info') or '').lower()
open_ports = {str(p.get('port','')) for p in host['ports']}
services   = {(p.get('service') or '').lower() for p in host['ports']}
http_titles = ' '.join(s.get('title','') for s in host['http_services']).lower()

network_keywords = ['cisco', 'juniper', 'arista', 'extreme', 'brocade', 'foundry',
                    'h3c', 'huawei', 'mikrotik', 'ubiquiti', 'netgear', 'meraki',
                    'ios', 'junos', 'eos ', 'comware', 'routeros', 'vyos', 'pfsense',
                    'opnsense', 'fortigate', 'fortios', 'palo alto', 'checkpoint',
                    'sonic', 'arubaos', 'procurve']

firewall_kw = ['firewall','fortigate','fortios','palo alto','checkpoint','asa','fwsm',
               'sonicwall','opnsense','pfsense']
router_kw   = ['router','gateway','ios xe','ios xr','junos','routeros','vyos','bird']
switch_kw   = ['switch','catalyst','nexus','eos','comware','procurve','arubaos','ex series',
                'ex-series','qfx','sfp','spanning-tree']
ap_kw       = ['access point','aironet','unifi','airmax','ap ','lightweight ap']
server_kw   = ['linux','ubuntu','debian','centos','rhel','fedora','windows server',
                'esxi','vmware','proxmox','freebsd','openshift']
printer_kw  = ['printer','jetdirect','oki','xerox','ricoh','canon','brother','lexmark']
ups_kw      = ['ups','apc','eaton','powerware','uninterruptible']
camera_kw   = ['camera','axis','hikvision','dahua','hanwha','vivotek','ipcam']

combined = sys_descr + ' ' + ssh_net + ' ' + os_str + ' ' + http_titles

if any(k in combined for k in firewall_kw):
    host['device_role'] = 'Firewall'
elif any(k in combined for k in router_kw) and '161' in open_ports:
    host['device_role'] = 'Router'
elif any(k in combined for k in switch_kw) and '161' in open_ports:
    host['device_role'] = 'Switch'
elif any(k in combined for k in ap_kw):
    host['device_role'] = 'Wireless AP'
elif any(k in combined for k in network_keywords):
    host['device_role'] = 'Network Device'
elif any(k in combined for k in printer_kw) or '9100' in open_ports:
    host['device_role'] = 'Printer'
elif any(k in combined for k in ups_kw):
    host['device_role'] = 'UPS'
elif any(k in combined for k in camera_kw):
    host['device_role'] = 'IP Camera'
elif '3389' in open_ports or 'windows' in os_str:
    host['device_role'] = 'Server'
    host['manufacturer'] = 'Microsoft'
elif any(k in combined for k in server_kw):
    host['device_role'] = 'Server'
elif '5060' in open_ports or 'sip' in services:
    host['device_role'] = 'IP Phone'
elif 'voip' in combined or 'pbx' in combined:
    host['device_role'] = 'IP Phone'
elif '445' in open_ports or nb.get('available'):
    host['device_role'] = 'Workstation'

# ── Manufacturer detection ──
vendor = host.get('vendor','')
if vendor and vendor not in ('','null','None'):
    host['manufacturer'] = vendor
else:
    mfr_map = {
        'cisco':'Cisco', 'juniper':'Juniper', 'arista':'Arista',
        'extreme':'Extreme Networks', 'hp ':'HP', 'hewlett':'HP',
        'dell':'Dell', 'microsoft':'Microsoft', 'vmware':'VMware',
        'apple':'Apple', 'ubiquiti':'Ubiquiti', 'mikrotik':'MikroTik',
        'fortigate':'Fortinet', 'fortinet':'Fortinet', 'palo alto':'Palo Alto',
        'checkpoint':'Check Point', 'apc':'APC', 'eaton':'Eaton',
        'axis':'Axis', 'hikvision':'Hikvision', 'supermicro':'Supermicro',
        'synology':'Synology', 'qnap':'QNAP', 'netgear':'Netgear',
        'h3c':'H3C', 'huawei':'Huawei', 'meraki':'Cisco Meraki',
        'brocade':'Brocade', 'foundry':'Foundry Networks',
    }
    for k, v in mfr_map.items():
        if k in combined:
            host['manufacturer'] = v
            break

# ── Model ──
sys_descr_full = snmp.get('sys_descr','') or ''
if sys_descr_full:
    # Use first 120 chars of sys_descr as model hint
    host['model'] = sys_descr_full[:120].strip()
elif ssh.get('net_device_info'):
    ver_line = [l for l in ssh['net_device_info'].split('\n')
                if l.strip() and len(l) > 5]
    if ver_line:
        host['model'] = ver_line[0][:120].strip()
else:
    host['model'] = host['os'][:80] if host['os'] else 'Unknown'

# ── Store detail references ──
host['snmp_details'] = {
    'sys_location': snmp.get('sys_location',''),
    'sys_contact':  snmp.get('sys_contact',''),
    'sys_oid':      snmp.get('sys_oid',''),
    'sys_uptime':   snmp.get('sys_uptime',''),
}
host['ssh_details'] = {
    'cpu':      ssh.get('cpu',''),
    'mem_total':ssh.get('mem_total',''),
    'kernel':   ssh.get('kernel',''),
    'banner':   ssh.get('banner',''),
}

print(json.dumps(host))
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# SWITCHPORT MAPPING
# ─────────────────────────────────────────────────────────────────────────────
map_switchports() {
    local switch_ip="$1"
    log_step "Switchport Mapping: $switch_ip"

    local community
    community=$(get_communities_for "$switch_ip" | head -1)

    python3 - <<PYEOF
import subprocess, json, re, sys

ip        = "$switch_ip"
community = "$community"
timeout   = "$SNMP_TIMEOUT"

def walk(oid):
    try:
        r = subprocess.run(
            ['snmpwalk','-v2c','-c',community,'-t',timeout,'-r1',ip,oid],
            capture_output=True, text=True, timeout=30)
        return r.stdout
    except:
        return ''

print("  Fetching interface table...", file=sys.stderr)
# IF-MIB: interface names
if_names = {}
for line in walk('1.3.6.1.2.1.2.2.1.2').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)', line)
    if m: if_names[m.group(1)] = m.group(2).strip().strip('"')

# IF-MIB: interface admin/oper status
if_status = {}
for line in walk('1.3.6.1.2.1.2.2.1.7').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m: if_status[m.group(1)] = 'up' if m.group(2)=='1' else 'down'

# Bridge MIB: MAC → port index
print("  Fetching bridge MAC table...", file=sys.stderr)
mac_to_port = {}
for line in walk('1.3.6.1.2.1.17.4.3.1.2').split('\n'):
    m = re.match(r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m:
        mac = ':'.join(f'{int(o):02x}' for o in m.group(1).split('.'))
        mac_to_port[mac] = m.group(2)

# Bridge port → IF index
port_to_if = {}
for line in walk('1.3.6.1.2.1.17.1.4.1.2').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m: port_to_if[m.group(1)] = m.group(2)

# VLAN for each port (dot1qPvid)
port_vlan = {}
for line in walk('1.3.6.1.2.1.17.7.1.4.5.1.1').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*(?:Gauge32|INTEGER|Unsigned32):\s*(\d+)', line)
    if m: port_vlan[m.group(1)] = m.group(2)

# VLAN names (Cisco: vtpVlanName)
vlan_names = {}
for line in walk('1.3.6.1.4.1.9.9.46.1.3.1.1.2').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)', line)
    if m: vlan_names[m.group(1)] = m.group(2).strip().strip('"')

# ARP table: IP → MAC
arp_table = {}
for line in walk('1.3.6.1.2.1.4.22.1.2').split('\n'):
    m = re.match(r'.*\.(\d+\.\d+\.\d+\.\d+)\s*=\s*STRING:\s*(.+)', line)
    if m: arp_table[m.group(2).strip()] = m.group(1)

# Build port map
port_entries = []
for mac, bridge_port in mac_to_port.items():
    if_idx  = port_to_if.get(bridge_port, bridge_port)
    if_name = if_names.get(if_idx, f'Port-{if_idx}')
    status  = if_status.get(if_idx,'?')
    vlan    = port_vlan.get(bridge_port, port_vlan.get(if_idx,'?'))
    vlan_name = vlan_names.get(str(vlan),'')
    remote_ip = arp_table.get(mac, '')

    port_entries.append({
        'mac': mac,
        'bridge_port': bridge_port,
        'if_index': if_idx,
        'if_name': if_name,
        'status': status,
        'vlan': vlan,
        'vlan_name': vlan_name,
        'remote_ip': remote_ip,
    })

# Sort by interface name
port_entries.sort(key=lambda x: x['if_name'])

result = {
    'switch_ip':    ip,
    'port_map':     port_entries,
    'interface_count': len(if_names),
    'mac_count':    len(mac_to_port),
    'vlan_names':   vlan_names,
}

out_file = "$DISCOVERY_DIR/switchport_${switch_ip//\./-}_$(date +%Y%m%d_%H%M%S).json"
with open(out_file, 'w') as f:
    json.dump(result, f, indent=2)

print(f"  Saved: {out_file}", file=sys.stderr)

# Pretty print summary
print(f"\n  Switch: {ip}")
print(f"  Interfaces: {len(if_names)}")
print(f"  MAC entries: {len(mac_to_port)}")
print(f"  VLANs: {list(vlan_names.values())}")
print()
print(f"  {'Interface':<24} {'Status':<8} {'VLAN':<8} {'VLAN Name':<18} {'MAC':<18} {'Remote IP'}")
print(f"  {'-'*24} {'-'*8} {'-'*8} {'-'*18} {'-'*18} {'-'*16}")
for e in port_entries[:60]:
    print(f"  {e['if_name']:<24} {e['status']:<8} {str(e['vlan']):<8} "
          f"{e['vlan_name']:<18} {e['mac']:<18} {e['remote_ip']}")
if len(port_entries) > 60:
    print(f"  ... and {len(port_entries)-60} more (see JSON file)")
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# SYNC TO NETBOX
# ─────────────────────────────────────────────────────────────────────────────
sync_to_netbox() {
    local results_file="${1:-}"

    if [[ -z "$results_file" ]]; then
        results_file=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
    fi

    if [[ ! -f "$results_file" ]]; then
        log_error "No discovery results found. Run discovery first."
        pause; return 1
    fi

    log_step "Syncing to NetBox: $(basename "$results_file")"

    if [[ -z "$NETBOX_API_TOKEN" ]]; then
        echo -e "${Y}No API token configured.${NC}"
        read -rp "  Enter NetBox API Token: " NETBOX_API_TOKEN
        save_config
    fi

    # Test API
    if ! nb_get "dcim/sites/" &>/dev/null; then
        log_error "Cannot reach NetBox API at $NETBOX_API_URL"
        pause; return 1
    fi

    local site_id
    site_id=$(nb_get_or_create_site)
    log_info "Using site ID: $site_id"

    local total; total=$(jq '.hosts | length' "$results_file")
    local ok=0 fail=0 idx=0

    while IFS= read -r host; do
        (( idx++ ))
        local ip hostname role mfr model os serial comments
        ip=$(echo "$host"       | jq -r '.ip')
        hostname=$(echo "$host" | jq -r '.hostname // "unknown"')
        role=$(echo "$host"     | jq -r '.device_role // "Endpoint"')
        mfr=$(echo "$host"      | jq -r '.manufacturer // "Unknown"')
        model=$(echo "$host"    | jq -r '.model // "Unknown"' | head -c 100)
        os=$(echo "$host"       | jq -r '.os // ""')
        serial=$(echo "$host"   | jq -r '.serial // ""')

        # Build comments from details
        local loc contact uptime cpu mem
        loc=$(echo "$host"     | jq -r '.snmp_details.sys_location // ""')
        contact=$(echo "$host" | jq -r '.snmp_details.sys_contact // ""')
        uptime=$(echo "$host"  | jq -r '.snmp_details.sys_uptime // ""')
        cpu=$(echo "$host"     | jq -r '.ssh_details.cpu // ""')
        mem=$(echo "$host"     | jq -r '.ssh_details.mem_total // ""')

        comments="Discovered by NetBox Discovery Suite\n"
        [[ -n "$loc"     ]] && comments+="Location: $loc\n"
        [[ -n "$contact" ]] && comments+="Contact: $contact\n"
        [[ -n "$uptime"  ]] && comments+="Uptime: $uptime\n"
        [[ -n "$cpu"     ]] && comments+="CPU: $cpu\n"
        [[ -n "$mem"     ]] && comments+="Memory: $mem\n"
        comments+="Discovery methods: $(echo "$host" | jq -r '.discovery_methods | join(", ")')"

        printf "  ${C}[%d/%d]${NC} ${W}%-16s${NC} %-32s %-18s " \
            "$idx" "$total" "$ip" "$hostname" "$role"

        local dev_id
        dev_id=$(nb_upsert_device "$hostname" "$ip" "$role" \
            "$mfr" "$model" "$site_id" "$os" "$serial" "$comments" 2>>"$LOG_FILE")

        if [[ -n "$dev_id" && "$dev_id" != "null" ]]; then
            echo -e "${G}✓${NC}"
            (( ok++ ))

            # Add management interface and IP
            local mgmt_if_id
            mgmt_if_id=$(nb_add_interface "$dev_id" "mgmt0" "other" \
                "$(echo "$host" | jq -r '.mac // ""')" "Management")

            nb_add_ip "$ip" "$dev_id" "$mgmt_if_id" >/dev/null

            # Add SNMP interfaces
            while IFS= read -r iface; do
                local if_name if_mac if_type
                if_name=$(echo "$iface" | jq -r '.name // "if"')
                if_mac=$(echo "$iface"  | jq -r '.mac // ""')
                if_type=$(echo "$iface" | jq -r '.type // "other"')

                # Map SNMP ifType to NetBox type
                local nb_if_type="other"
                case "$if_type" in
                    6)   nb_if_type="1000base-t" ;;
                    53)  nb_if_type="1000base-x-sfp" ;;
                    161) nb_if_type="ieee802-11a" ;;
                    131) nb_if_type="ieee802-11g" ;;
                    24)  nb_if_type="other" ;;  # softwareLoopback
                esac

                nb_add_interface "$dev_id" "$if_name" "$nb_if_type" \
                    "$if_mac" "" >/dev/null 2>&1 || true
            done < <(echo "$host" | jq -c '.interfaces[]?' 2>/dev/null || true)

            # Add CDP/LLDP neighbor info as comments on the device
            local neighbors
            neighbors=$(echo "$host" | jq -r '
                (.cdp_neighbors[]? | "CDP: \(.device_id // "") via \(.remote_port // "")"),
                (.lldp_neighbors[]? | "LLDP: \(.sys_name // "") via \(.port_desc // "")")
            ' 2>/dev/null | head -10 || true)
            if [[ -n "$neighbors" ]]; then
                nb_patch "dcim/devices/${dev_id}/" \
                    "{\"comments\":$(echo -e "$comments\n--- Neighbors ---\n$neighbors" | jq -Rs .)}" \
                    >/dev/null 2>&1 || true
            fi

        else
            echo -e "${R}✗${NC}"
            log_error "Failed to sync: $hostname ($ip)"
            (( fail++ ))
        fi

    done < <(jq -c '.hosts[]' "$results_file")

    echo -e "\n  ${G}Complete:${NC} $ok synced  ${R}$fail failed${NC}  of $total total"
    log_info "Sync complete: ok=$ok fail=$fail total=$total"
    pause
}

# ─────────────────────────────────────────────────────────────────────────────
# CREDENTIAL MANAGEMENT MENU
# ─────────────────────────────────────────────────────────────────────────────
menu_credentials() {
    while true; do
        banner
        echo -e "${C}═══════ Credential Management ═══════${NC}\n"

        local creds; creds=$(read_creds)

        echo -e "  ${W}SNMP v1/v2c Communities:${NC}"
        echo "$creds" | jq -r '.snmp_communities[]' 2>/dev/null \
            | while read -r c; do echo -e "    ${D}•${NC} $c"; done

        echo -e "\n  ${W}SNMP v3 Accounts:${NC}"
        echo "$creds" | jq -r '.snmp_v3[] | "    • \(.username) [\(.auth_proto)/\(.priv_proto)]"' \
            2>/dev/null || echo -e "    ${D}(none)${NC}"

        echo -e "\n  ${W}SSH Credentials:${NC}"
        echo "$creds" | jq -r \
            '.ssh_credentials[] | "    • \(.username) / \(if .password then "password" else "key: \(.key_file)" end)"' \
            2>/dev/null || echo -e "    ${D}(none)${NC}"

        echo -e "\n  ${W}Telnet Credentials:${NC}"
        echo "$creds" | jq -r '.telnet_credentials[] | "    • \(.username)"' \
            2>/dev/null || echo -e "    ${D}(none)${NC}"

        echo -e "\n  ${W}Device Overrides:${NC}"
        echo "$creds" | jq -r \
            '.device_overrides | to_entries[] | "    • \(.key) → \(.value.ssh_username // "?")"' \
            2>/dev/null || echo -e "    ${D}(none)${NC}"

        echo -e "\n${Y}Options:${NC}"
        echo "  1) Add SNMP v2c Community"
        echo "  2) Remove SNMP v2c Community"
        echo "  3) Add SNMP v3 Account"
        echo "  4) Add SSH Credential"
        echo "  5) Remove SSH Credential"
        echo "  6) Add Telnet Credential"
        echo "  7) Add/Update Device Override"
        echo "  8) Remove Device Override"
        echo "  9) Import credentials from JSON file"
        echo " 10) Export credentials (plaintext!)"
        echo "  0) Back"

        read -rp $'\nChoice: ' choice
        case "$choice" in
        1)
            read -rp "  Community string: " c
            [[ -z "$c" ]] && continue
            write_creds "$(echo "$creds" | jq ".snmp_communities += [\"$c\"]")"
            log_info "Added SNMP community: $c"
            ;;
        2)
            read -rp "  Community to remove: " c
            write_creds "$(echo "$creds" | jq "del(.snmp_communities[] | select(. == \"$c\"))")"
            log_info "Removed SNMP community: $c"
            ;;
        3)
            read -rp "  Username: " v3u
            read -rp "  Auth protocol (MD5/SHA/SHA256): " v3ap; v3ap=${v3ap:-SHA}
            read -rsp "  Auth password: " v3apass; echo
            read -rp "  Priv protocol (DES/AES/AES256): " v3pp; v3pp=${v3pp:-AES}
            read -rsp "  Priv password: " v3ppass; echo
            local v3_entry
            v3_entry=$(jq -n --arg u "$v3u" --arg ap "$v3ap" --arg apass "$v3apass" \
                --arg pp "$v3pp" --arg ppass "$v3ppass" \
                '{username:$u, auth_proto:$ap, auth_pass:$apass, priv_proto:$pp, priv_pass:$ppass}')
            write_creds "$(echo "$creds" | jq ".snmp_v3 += [$v3_entry]")"
            log_info "Added SNMPv3 user: $v3u"
            ;;
        4)
            read -rp "  Username: " su
            read -rsp "  Password (blank for key auth): " sp; echo
            read -rp "  SSH key file (blank if using password): " sk
            read -rsp "  Enable password (optional): " sep; echo
            local ssh_entry
            ssh_entry=$(jq -n --arg u "$su" --arg p "$sp" --arg k "$sk" --arg e "$sep" \
                '{username:$u,
                  password:(if $p != "" then $p else null end),
                  key_file:(if $k != "" then $k else null end),
                  enable_pass:(if $e != "" then $e else null end)}')
            write_creds "$(echo "$creds" | jq ".ssh_credentials += [$ssh_entry]")"
            log_info "Added SSH credential: $su"
            ;;
        5)
            read -rp "  Username to remove: " su
            write_creds "$(echo "$creds" | jq "del(.ssh_credentials[] | select(.username == \"$su\"))")"
            log_info "Removed SSH credential: $su"
            ;;
        6)
            read -rp "  Telnet username: " tu
            read -rsp "  Telnet password: " tp; echo
            local tn_entry
            tn_entry=$(jq -n --arg u "$tu" --arg p "$tp" '{username:$u, password:$p}')
            write_creds "$(echo "$creds" | jq ".telnet_credentials += [$tn_entry]")"
            log_info "Added Telnet credential: $tu"
            ;;
        7)
            read -rp "  Device IP: " dip
            read -rp "  SNMP Community (blank to skip): " dc
            read -rp "  SSH Username (blank to skip): " du
            read -rsp "  SSH Password (blank to skip): " dp; echo
            read -rp "  SSH Key file (blank to skip): " dk
            local dev_ov
            dev_ov=$(jq -n --arg c "$dc" --arg u "$du" --arg p "$dp" --arg k "$dk" \
                '{snmp_community:(if $c!="" then $c else null end),
                  ssh_username:(if $u!="" then $u else null end),
                  ssh_password:(if $p!="" then $p else null end),
                  ssh_key:(if $k!="" then $k else null end)}')
            write_creds "$(echo "$creds" | jq ".device_overrides[\"$dip\"] = $dev_ov")"
            log_info "Set device override: $dip"
            ;;
        8)
            read -rp "  Device IP to remove: " dip
            write_creds "$(echo "$creds" | jq "del(.device_overrides[\"$dip\"])")"
            log_info "Removed device override: $dip"
            ;;
        9)
            read -rp "  JSON file path: " jf
            if [[ -f "$jf" ]]; then
                write_creds "$(cat "$jf")"
                log_info "Credentials imported from: $jf"
            else
                echo -e "${R}File not found${NC}"; sleep 1
            fi
            ;;
        10)
            echo -e "${R}WARNING: Exports plaintext credentials!${NC}"
            confirm "Continue?" || continue
            read -rp "  Output file path: " of
            read_creds > "$of"
            chmod 600 "$of"
            log_warn "Credentials exported (plaintext): $of"
            ;;
        0) return ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# DISCOVERY SETTINGS MENU
# ─────────────────────────────────────────────────────────────────────────────
menu_discovery_settings() {
    while true; do
        banner
        echo -e "${C}═══════ Discovery Settings ═══════${NC}\n"
        echo -e "  1) Scan Timeout        ${W}${SCAN_TIMEOUT}s${NC}"
        echo -e "  2) SNMP Timeout        ${W}${SNMP_TIMEOUT}s${NC}"
        echo -e "  3) SSH Timeout         ${W}${SSH_TIMEOUT}s${NC}"
        echo -e "  4) Parallel Threads    ${W}${MAX_THREADS}${NC}"
        echo -e "  5) Default Site Name   ${W}${DEFAULT_SITE_NAME}${NC}"
        echo -e "  6) NetBox Port         ${W}${NETBOX_PORT}${NC}"
        echo -e "  7) Debug Mode          ${W}$([ $DEBUG_MODE -eq 1 ] && echo ON || echo OFF)${NC}"
        echo -e "  8) Schedule Recurring Scan (cron)"
        echo -e "  9) View Scheduled Scans"
        echo -e "  0) Back"

        read -rp $'\nChoice: ' c
        case "$c" in
        1) read -rp "  Scan timeout (s): " SCAN_TIMEOUT; save_config ;;
        2) read -rp "  SNMP timeout (s): " SNMP_TIMEOUT; save_config ;;
        3) read -rp "  SSH timeout (s): "  SSH_TIMEOUT;  save_config ;;
        4) read -rp "  Parallel threads: " MAX_THREADS;  save_config ;;
        5) read -rp "  Site name: " DEFAULT_SITE_NAME;   save_config ;;
        6) read -rp "  NetBox port: " NETBOX_PORT
           NETBOX_API_URL="http://localhost:${NETBOX_PORT}"; save_config ;;
        7) (( DEBUG_MODE ^= 1 )); save_config ;;
        8)
            read -rp "  Network to scan (CIDR): " snet
            read -rp "  Cron schedule (e.g. '0 2 * * *'): " scron
            local entry="$scron root $SCRIPT_PATH --auto-scan '$snet' >> $LOG_DIR/cron.log 2>&1"
            (crontab -l 2>/dev/null; echo "$entry") | crontab -
            log_info "Scheduled: [$scron] $snet"
            ;;
        9)
            echo -e "\n${W}Scheduled Scans:${NC}"
            crontab -l 2>/dev/null | grep "netbox-discovery\|auto-scan" \
                || echo "  (none)"
            ;;
        0) return ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# NETBOX MANAGEMENT MENU
# ─────────────────────────────────────────────────────────────────────────────
menu_netbox_mgmt() {
    while true; do
        banner
        echo -e "${C}═══════ NetBox Management ═══════${NC}\n"

        local nb_ok=false
        curl -sf "${NETBOX_API_URL}/api/" &>/dev/null && nb_ok=true

        if $nb_ok; then
            echo -e "  Status:    ${G}● Running${NC}"
        else
            echo -e "  Status:    ${R}● Unreachable${NC}"
        fi
        echo -e "  URL:       ${W}${NETBOX_API_URL}${NC}"
        echo -e "  Token:     ${W}${NETBOX_API_TOKEN:-<not set>}${NC}"
        echo ""
        echo "  1) Start NetBox"
        echo "  2) Stop NetBox"
        echo "  3) Restart NetBox"
        echo "  4) View NetBox Logs (live)"
        echo "  5) Set API Token manually"
        echo "  6) Generate New API Token"
        echo "  7) Backup Database"
        echo "  8) Restore Database"
        echo "  9) Update NetBox"
        echo " 10) Show Container Status"
        echo "  0) Back"

        read -rp $'\nChoice: ' c
        case "$c" in
        1)
            log_info "Starting NetBox..."
            cd "$NETBOX_DIR" && docker compose up -d >> "$LOG_FILE" 2>&1
            echo -e "${G}Started${NC}"
            ;;
        2)
            confirm "Stop NetBox?" || { pause; continue; }
            cd "$NETBOX_DIR" && docker compose down >> "$LOG_FILE" 2>&1
            echo -e "${Y}Stopped${NC}"
            ;;
        3)
            cd "$NETBOX_DIR" && docker compose restart >> "$LOG_FILE" 2>&1
            echo -e "${G}Restarted${NC}"
            ;;
        4)
            echo -e "${D}(Ctrl+C to exit)${NC}"
            cd "$NETBOX_DIR" && docker compose logs -f --tail=50 netbox
            ;;
        5)
            read -rp "  API Token: " NETBOX_API_TOKEN
            save_config
            ;;
        6)
            log_info "Generating new token..."
            NETBOX_API_TOKEN=$(cd "$NETBOX_DIR" && docker compose exec -T netbox \
                python manage.py shell -c \
                "from users.models import Token; from django.contrib.auth.models import User; \
                 u=User.objects.get(username='admin'); t=Token.objects.create(user=u); print(t.key)" \
                2>/dev/null | tail -1)
            save_config
            echo -e "  New token: ${W}$NETBOX_API_TOKEN${NC}"
            ;;
        7)
            local bk="$BASE_DIR/backup_$(date +%Y%m%d_%H%M%S).sql.gz"
            log_info "Backing up database..."
            cd "$NETBOX_DIR" && docker compose exec -T postgres \
                pg_dump -U netbox netbox | gzip > "$bk"
            log_ok "Backup: $bk ($(du -sh "$bk" | cut -f1))"
            echo -e "  ${G}Saved:${NC} $bk"
            ;;
        8)
            read -rp "  Backup file path (.sql.gz): " bkf
            if [[ -f "$bkf" ]]; then
                confirm "Restore will OVERWRITE the current database. Continue?" || continue
                cd "$NETBOX_DIR"
                docker compose exec -T postgres psql -U netbox -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" netbox >> "$LOG_FILE" 2>&1
                zcat "$bkf" | docker compose exec -T postgres psql -U netbox netbox >> "$LOG_FILE" 2>&1
                log_ok "Database restored from $bkf"
            else
                echo -e "${R}File not found${NC}"
            fi
            ;;
        9)
            log_info "Updating NetBox..."
            cd "$NETBOX_DIR" && git pull -q && docker compose pull >> "$LOG_FILE" 2>&1
            docker compose up -d >> "$LOG_FILE" 2>&1
            log_ok "Update complete"
            ;;
        10)
            cd "$NETBOX_DIR" && docker compose ps
            ;;
        0) return ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# LOG VIEWER MENU
# ─────────────────────────────────────────────────────────────────────────────
menu_logs() {
    while true; do
        banner
        echo -e "${C}═══════ Log Viewer ═══════${NC}\n"
        echo "  1) Tail today's log (live)"
        echo "  2) View full today's log"
        echo "  3) List all log files"
        echo "  4) List discovery result files"
        echo "  5) View a discovery result file"
        echo "  6) Search logs"
        echo "  7) Clear today's log"
        echo "  0) Back"

        read -rp $'\nChoice: ' c
        case "$c" in
        1) tail -f "$LOG_FILE" ;;
        2) less "$LOG_FILE" 2>/dev/null || more "$LOG_FILE" ;;
        3)
            echo -e "\n${W}Log files:${NC}"
            ls -lh "$LOG_DIR"/*.log 2>/dev/null || echo "  (none)"
            ;;
        4)
            echo -e "\n${W}Discovery results:${NC}"
            ls -lh "$DISCOVERY_DIR"/results_*.json 2>/dev/null \
                | awk '{print NR")", $NF, $5}' || echo "  (none)"
            ;;
        5)
            local latest; latest=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
            if [[ -z "$latest" ]]; then echo "  No results found"; pause; continue; fi
            echo -e "\n${W}File:${NC} $latest"
            local count; count=$(jq '.hosts | length' "$latest")
            echo -e "${W}Hosts:${NC} $count\n"
            printf "  %-16s %-32s %-18s %-16s %s\n" \
                "IP" "Hostname" "Role" "Manufacturer" "OS"
            printf "  %-16s %-32s %-18s %-16s %s\n" \
                "────────────────" "────────────────────────────────" \
                "──────────────────" "────────────────" "──────────────────────"
            jq -r '.hosts[] | [.ip, .hostname, .device_role, .manufacturer, (.os // "")] | @tsv' \
                "$latest" 2>/dev/null \
                | while IFS=$'\t' read -r ip hn role mfr os; do
                    printf "  %-16s %-32s %-18s %-16s %s\n" \
                        "$ip" "${hn:0:31}" "${role:0:17}" "${mfr:0:15}" "${os:0:30}"
                done | head -80
            ;;
        6)
            read -rp "  Search term: " st
            grep --color=always -i "$st" "$LOG_DIR"/*.log 2>/dev/null | tail -50
            ;;
        7)
            confirm "Clear today's log?" || { continue; }
            > "$LOG_FILE"
            log_info "Log cleared"
            ;;
        0) return ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# DISCOVERY RUNNER MENU
# ─────────────────────────────────────────────────────────────────────────────
menu_discovery() {
    while true; do
        banner
        echo -e "${C}═══════ Network Discovery ═══════${NC}\n"
        echo "  1) Discover Network (CIDR range)"
        echo "  2) Scan Single Host"
        echo "  3) Scan Host List from File"
        echo "  4) Map Switchports"
        echo "  5) View Last Results Summary"
        echo "  6) Sync Last Results → NetBox"
        echo "  7) Full Auto: Discover + Sync"
        echo "  0) Back"

        read -rp $'\nChoice: ' c
        case "$c" in
        1)
            read -rp "  Network (CIDR, e.g. 192.168.1.0/24): " net
            if valid_cidr "$net" || valid_ip "${net%%/*}"; then
                init_scan_session "$net"
                discover_live_hosts "$net"
                if [[ -s "$LIVE_HOSTS_FILE" ]]; then
                    scan_all_hosts
                    log_ok "Results: $DISC_RESULTS"
                    echo -e "\n  ${G}Results saved:${NC} $DISC_RESULTS"
                    confirm "  Sync to NetBox now?" && sync_to_netbox "$DISC_RESULTS"
                fi
            else
                echo -e "${R}  Invalid network${NC}"
            fi
            ;;
        2)
            read -rp "  IP address: " sip
            if valid_ip "$sip"; then
                init_scan_session "$sip"
                echo "$sip" > "$LIVE_HOSTS_FILE"
                scan_all_hosts
                echo -e "\n${W}Result:${NC}"
                jq '.hosts[0] | del(.ports,.interfaces,.mac_port_map,.arp_entries)' \
                    "$DISC_RESULTS" 2>/dev/null || cat "$DISC_RESULTS"
            else
                echo -e "${R}  Invalid IP${NC}"
            fi
            ;;
        3)
            read -rp "  Host file path (one IP per line): " hf
            if [[ -f "$hf" ]]; then
                init_scan_session "file:$hf"
                grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "$hf" > "$LIVE_HOSTS_FILE"
                local cnt; cnt=$(wc -l < "$LIVE_HOSTS_FILE")
                log_info "Loaded $cnt hosts from $hf"
                scan_all_hosts
                echo -e "\n  ${G}Complete:${NC} $DISC_RESULTS"
                confirm "  Sync to NetBox?" && sync_to_netbox "$DISC_RESULTS"
            else
                echo -e "${R}  File not found${NC}"
            fi
            ;;
        4)
            read -rp "  Switch IP: " swip
            if valid_ip "$swip"; then
                map_switchports "$swip"
            else
                echo -e "${R}  Invalid IP${NC}"
            fi
            ;;
        5)
            local latest; latest=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
            if [[ -z "$latest" ]]; then echo "  No results yet"; pause; continue; fi
            echo -e "\n${W}File:${NC} $latest"
            echo -e "${W}Hosts:$(jq '.hosts|length' "$latest")${NC}\n"
            printf "  %-16s %-32s %-18s %-16s %s\n" IP Hostname Role Manufacturer OS
            jq -r '.hosts[] | [.ip,.hostname,.device_role,.manufacturer,(.os//"N/A")] | @tsv' \
                "$latest" 2>/dev/null \
                | while IFS=$'\t' read -r ip hn role mfr os; do
                    printf "  %-16s %-32s %-18s %-16s %s\n" \
                        "$ip" "${hn:0:31}" "${role:0:17}" "${mfr:0:15}" "${os:0:28}"
                done | head -80
            ;;
        6) sync_to_netbox ;;
        7)
            read -rp "  Network (CIDR): " net
            if valid_cidr "$net" || valid_ip "${net%%/*}"; then
                init_scan_session "$net"
                discover_live_hosts "$net"
                [[ -s "$LIVE_HOSTS_FILE" ]] && scan_all_hosts && sync_to_netbox "$DISC_RESULTS"
            else
                echo -e "${R}  Invalid network${NC}"
            fi
            ;;
        0) return ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN MENU
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        banner

        # Status bar
        local nb_status docker_status
        docker ps --filter "name=netbox" --format "{{.Status}}" 2>/dev/null | grep -q Up \
            && nb_status="${G}● NetBox: Running${NC}" \
            || nb_status="${R}● NetBox: Stopped${NC}"
        cmd_exists docker \
            && docker_status="${G}● Docker: OK${NC}" \
            || docker_status="${R}● Docker: Missing${NC}"

        echo -e "  $nb_status   $docker_status   ${D}Token: ${NETBOX_API_TOKEN:0:12}...${NC}"
        echo ""
        echo -e "${C}  ┌──────────────────────────────────────────┐${NC}"
        echo -e "${C}  │${NC}  ${W}1${NC}  Install / Update Dependencies        ${C}│${NC}"
        echo -e "${C}  │${NC}  ${W}2${NC}  Deploy / Update NetBox               ${C}│${NC}"
        echo -e "${C}  │${NC}  ${W}3${NC}  Discovery Settings                   ${C}│${NC}"
        echo -e "${C}  │${NC}  ${W}4${NC}  Manage Credentials                   ${C}│${NC}"
        echo -e "${C}  │${NC}  ${W}5${NC}  Run Network Discovery                ${C}│${NC}"
        echo -e "${C}  │${NC}  ${W}6${NC}  NetBox Management                    ${C}│${NC}"
        echo -e "${C}  │${NC}  ${W}7${NC}  View Logs                            ${C}│${NC}"
        echo -e "${C}  │${NC}  ${W}8${NC}  Quick Setup (Install + Deploy)       ${C}│${NC}"
        echo -e "${C}  │${NC}  ${W}0${NC}  Exit                                 ${C}│${NC}"
        echo -e "${C}  └──────────────────────────────────────────┘${NC}"
        echo ""

        read -rp "  Choice: " ch
        case "$ch" in
        1) install_deps ;;
        2) deploy_netbox ;;
        3) menu_discovery_settings ;;
        4) menu_credentials ;;
        5) menu_discovery ;;
        6) menu_netbox_mgmt ;;
        7) menu_logs ;;
        8)
            log_step "Quick Setup"
            install_deps
            deploy_netbox
            ;;
        0)
            echo -e "\n  ${G}Goodbye!${NC}\n"
            log_info "Session ended"
            exit 0
            ;;
        *)
            echo -e "  ${R}Invalid choice${NC}"
            sleep 1
            ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────
main() {
    check_root
    init_dirs
    load_config
    init_creds
    log_info "════════════════════════════════════════"
    log_info "NetBox Discovery Suite v${SCRIPT_VERSION} started"
    log_info "User: $(id -un)  PID: $$"
    log_info "════════════════════════════════════════"

    # Non-interactive auto-scan mode (for cron jobs)
    if [[ "${1:-}" == "--auto-scan" && -n "${2:-}" ]]; then
        local target="$2"
        log_info "Auto-scan mode: $target"
        init_scan_session "$target"
        discover_live_hosts "$target"
        if [[ -s "$LIVE_HOSTS_FILE" ]]; then
            scan_all_hosts
            sync_to_netbox "$DISC_RESULTS"
        fi
        log_info "Auto-scan complete"
        exit 0
    fi

    # Single-host quick scan
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
