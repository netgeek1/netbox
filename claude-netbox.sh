#!/usr/bin/env bash
# =============================================================================
#  NetBox Auto-Deploy & Network Discovery Suite
#  For Ubuntu 24.04
#  Version: 2.0.2
#
#  Changelog v2.0.2:
#   - Removed ALL non-ASCII characters (box-drawing, braille spinner, bullets)
#   - Fixed nested function declaration: removed "local _snmp() {}" syntax
#     which is illegal in bash; replaced with two top-level helper functions
#     _snmp_get() and _snmp_walk() that accept ip/token/timeout as arguments
#   - Fixed heredoc quoting inside probe_nmap to pass xmlfile as argument
#   - Fixed merge_host_data to pass args to Python rather than embed in heredoc
#   - Fixed probe_http and probe_banners array-building without mapfile/+=
#   - Replaced all Unicode box/arrow chars with plain ASCII equivalents
#   - Verified clean with: bash -n netbox-discovery.sh
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# GLOBAL CONSTANTS
# -----------------------------------------------------------------------------
SCRIPT_VERSION="2.0.3"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

BASE_DIR="/opt/netbox-discovery"
LOG_DIR="/var/log/netbox-discovery"
CONFIG_FILE="$BASE_DIR/config.conf"
CREDS_FILE="$BASE_DIR/.credentials.enc"
CREDS_KEY_FILE="$BASE_DIR/.creds.key"
DISCOVERY_DIR="$BASE_DIR/discovery"
NETBOX_DIR="/opt/netbox-docker"

# -- Colours (pure ANSI escape codes, no Unicode) --
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
W='\033[1;37m'
D='\033[2m'
NC='\033[0m'

# -- Runtime defaults (overridden by config file) --
NETBOX_PORT=8000
NETBOX_API_URL="http://localhost:${NETBOX_PORT}"
NETBOX_API_TOKEN=""
DEFAULT_SITE_NAME="Default Site"
SCAN_TIMEOUT=5
SNMP_TIMEOUT=3
SSH_TIMEOUT=10
MAX_THREADS=20
DEBUG_MODE=0

LOG_FILE="$LOG_DIR/discovery-$(date +%Y%m%d).log"

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
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
    _log "STEP" "$*"
    echo -e "\n${C}====== ${W}${*}${C} ======${NC}"
}

# -----------------------------------------------------------------------------
# UTILITIES
# -----------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || { log_error "Run as root: sudo $0"; exit 1; }
}

pause() { echo; read -rp "  Press [Enter] to continue..."; }

confirm() {
    local prompt="${1:-Are you sure?}"
    local resp
    read -rp "  $prompt [y/N] " resp
    [[ "${resp,,}" == "y" ]]
}

cmd_exists() { command -v "$1" &>/dev/null; }

spinner() {
    local pid=$1
    local i=0
    local chars='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s ' "${chars:$((i % 4)):1}"
        sleep 0.1
        (( i++ ))
    done
    printf '\r     \r'
}

valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octs <<< "$ip"
    local oct
    for oct in "${octs[@]}"; do (( oct <= 255 )) || return 1; done
    return 0
}

valid_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]
}

# -----------------------------------------------------------------------------
# BANNER  (pure ASCII)
# -----------------------------------------------------------------------------
banner() {
    clear
    echo -e "${C}"
    echo "  +======================================================================+"
    echo "  |   NetBox Auto-Deploy and Network Discovery Suite v${SCRIPT_VERSION}          |"
    echo "  |   Ubuntu 24.04  --  Multi-Protocol  --  Auto-Sync to NetBox         |"
    echo "  +======================================================================+"
    echo -e "${NC}"
    echo -e "  ${D}Log   : $LOG_FILE${NC}"
    echo -e "  ${D}Config: $CONFIG_FILE${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# DIRECTORY & CONFIG
# -----------------------------------------------------------------------------
init_dirs() {
    mkdir -p "$BASE_DIR" "$LOG_DIR" "$DISCOVERY_DIR"
    chmod 700 "$BASE_DIR"
    chmod 755 "$LOG_DIR"
    touch "$LOG_FILE"
}

save_config() {
    cat > "$CONFIG_FILE" <<CONF
# NetBox Discovery Suite Configuration - Generated: $(date)
NETBOX_PORT=${NETBOX_PORT}
NETBOX_API_URL=${NETBOX_API_URL}
NETBOX_API_TOKEN=${NETBOX_API_TOKEN}
DEFAULT_SITE_NAME=${DEFAULT_SITE_NAME}
SCAN_TIMEOUT=${SCAN_TIMEOUT}
SNMP_TIMEOUT=${SNMP_TIMEOUT}
SSH_TIMEOUT=${SSH_TIMEOUT}
MAX_THREADS=${MAX_THREADS}
DEBUG_MODE=${DEBUG_MODE}
CONF
    chmod 600 "$CONFIG_FILE"
    log_info "Configuration saved"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    NETBOX_API_URL="http://localhost:${NETBOX_PORT}"
}

# -----------------------------------------------------------------------------
# ENCRYPTED CREDENTIAL STORE  (AES-256-CBC via openssl)
# -----------------------------------------------------------------------------
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

get_communities_for() {
    local ip="$1"
    local creds; creds=$(read_creds)
    local ov
    ov=$(echo "$creds" | jq -r ".device_overrides[\"$ip\"].snmp_community // empty" 2>/dev/null)
    if [[ -n "$ov" ]]; then
        echo "$ov"
    else
        echo "$creds" | jq -r '.snmp_communities[]' 2>/dev/null || echo "public"
    fi
}

get_ssh_creds_for() {
    local ip="$1"
    local creds; creds=$(read_creds)
    local ov
    ov=$(echo "$creds" | jq -r ".device_overrides[\"$ip\"] // empty" 2>/dev/null)
    if [[ -n "$ov" && "$ov" != "null" ]]; then
        echo "$ov" | jq -c \
            '{username:.ssh_username,password:.ssh_password,key_file:.ssh_key,enable_pass:.enable_pass}'
    else
        echo "$creds" | jq -c '.ssh_credentials[]' 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# DEPENDENCY INSTALLATION
# -----------------------------------------------------------------------------
install_deps() {
    log_step "Installing System Dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >> "$LOG_FILE" 2>&1

    local pkgs=(
        docker.io docker-compose-v2
        git curl wget ipcalc bc
        nmap masscan arp-scan fping
        snmp snmpd snmp-mibs-downloader
        sshpass openssh-client
        lldpd telnet
        samba-common-bin nbtscan
        dnsutils bind9-dnsutils
        avahi-daemon avahi-utils
        jq python3 python3-pip python3-dev
        netcat-openbsd openssl whois traceroute tcpdump
    )

    local failed=()
    local pkg
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -l "$pkg" &>/dev/null; then
            echo -ne "  Installing ${W}${pkg}${NC} ... "
            if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
                echo -e "${G}OK${NC}"
            else
                echo -e "${R}FAILED${NC}"
                failed+=("$pkg")
            fi
        fi
    done

    echo -ne "  Downloading SNMP MIBs ... "
    download-mibs >> "$LOG_FILE" 2>&1 || true
    sed -i '/^mibs/d' /etc/snmp/snmp.conf 2>/dev/null || true
    echo "mibs +ALL" >> /etc/snmp/snmp.conf 2>/dev/null || true
    echo -e "${G}OK${NC}"

    log_info "Installing Python network libraries..."
    pip3 install --break-system-packages --quiet \
        netmiko napalm pysnmp paramiko requests pynetbox scapy \
        >> "$LOG_FILE" 2>&1 || log_warn "Some Python packages failed"

    local svc
    for svc in docker lldpd avahi-daemon; do
        systemctl enable "$svc" >> "$LOG_FILE" 2>&1 || true
        systemctl start  "$svc" >> "$LOG_FILE" 2>&1 || true
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_warn "Failed packages: ${failed[*]}"
    else
        log_ok "All dependencies installed"
    fi
    pause
}

# -----------------------------------------------------------------------------
# NETBOX DOCKER DEPLOYMENT
# -----------------------------------------------------------------------------
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

    # v2.0.3: Removed obsolete top-level "version:" key (Compose v2 warns/ignores it).
    # Removed netbox-housekeeping service: dropped in netbox-docker 3.4.0 because
    # NetBox 4.4.0+ handles housekeeping internally. Including it with no image/build
    # causes "invalid compose project" errors on current releases.
    cat > docker-compose.override.yml <<DCEOF
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
DCEOF

    log_info "Pulling Docker images (may take several minutes)..."
    docker compose pull >> "$LOG_FILE" 2>&1 &
    spinner $!
    wait $! || { log_error "docker compose pull failed"; pause; return 1; }

    log_info "Starting NetBox containers..."
    docker compose up -d >> "$LOG_FILE" 2>&1 &
    spinner $!
    wait $!

    echo -ne "  Waiting for NetBox to initialize "
    local retries=0
    until curl -sf "http://localhost:${NETBOX_PORT}/api/" &>/dev/null; do
        sleep 5; echo -n "."; (( retries++ ))
        if (( retries > 36 )); then
            echo -e "\n${R}Timeout -- NetBox did not start within 3 minutes.${NC}"
            pause; return 1
        fi
    done
    echo -e " ${G}Ready!${NC}"

    log_info "Creating API token..."
    NETBOX_API_TOKEN=$(docker compose exec -T netbox \
        python manage.py shell -c \
        "from users.models import Token; from django.contrib.auth.models import User; \
u=User.objects.get(username='admin'); t,_=Token.objects.get_or_create(user=u); print(t.key)" \
        2>/dev/null | tail -1)
    save_config

    local creds_out="$BASE_DIR/netbox-credentials.txt"
    cat > "$creds_out" <<CREDEOF
NetBox Access Credentials
=========================
URL:       http://localhost:${NETBOX_PORT}
Username:  admin
Password:  ${admin_pass}
API Token: ${NETBOX_API_TOKEN}

KEEP THIS FILE SECURE -- DELETE AFTER NOTING CREDENTIALS
CREDEOF
    chmod 600 "$creds_out"

    echo ""
    echo -e "${G}+----------------------------------------------+${NC}"
    echo -e "${G}|  NetBox Deployed Successfully!               |${NC}"
    echo -e "${G}+----------------------------------------------+${NC}"
    echo -e "  URL:      ${W}http://localhost:${NETBOX_PORT}${NC}"
    echo -e "  User:     ${W}admin${NC}"
    echo -e "  Password: ${W}${admin_pass}${NC}"
    echo -e "  Token:    ${W}${NETBOX_API_TOKEN}${NC}"
    echo -e "  Saved to: ${D}${creds_out}${NC}"
    pause
}

# -----------------------------------------------------------------------------
# NETBOX REST API HELPERS
# -----------------------------------------------------------------------------
nb_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    if [[ -z "$NETBOX_API_TOKEN" ]]; then
        log_error "NetBox API token not set."
        return 1
    fi
    local args=(-sf -X "$method"
        -H "Authorization: Token $NETBOX_API_TOKEN"
        -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${NETBOX_API_URL}/api/${endpoint}" 2>>"$LOG_FILE"
}

nb_get()   { nb_api GET   "$1"; }
nb_post()  { nb_api POST  "$1" "${2:-}"; }
nb_patch() { nb_api PATCH "$1" "${2:-}"; }

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' \
        | tr -dc '[:alnum:]-' | sed 's/-\+/-/g'
}

nb_urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

nb_get_or_create_site() {
    local name="$DEFAULT_SITE_NAME"
    local slug; slug=$(slugify "$name")
    local enc; enc=$(nb_urlencode "$name")
    local res; res=$(nb_get "dcim/sites/?name=${enc}")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/sites/" "{\"name\":\"$name\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty')
        log_info "Created site: $name (ID: $id)"
    fi
    echo "$id"
}

nb_get_or_create_manufacturer() {
    local name="$1"
    local slug; slug=$(slugify "$name")
    local enc; enc=$(nb_urlencode "$name")
    local res; res=$(nb_get "dcim/manufacturers/?name=${enc}")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/manufacturers/" \
            "{\"name\":\"$name\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty')
    fi
    echo "$id"
}

nb_get_or_create_device_type() {
    local mfr_id="$1" model="$2"
    local slug; slug=$(slugify "$model")
    local enc; enc=$(nb_urlencode "$model")
    local res; res=$(nb_get "dcim/device-types/?model=${enc}")
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
    local enc; enc=$(nb_urlencode "$name")
    local res; res=$(nb_get "dcim/device-roles/?name=${enc}")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/device-roles/" \
            "{\"name\":\"$name\",\"slug\":\"$slug\",\"color\":\"$color\"}")
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
    payload=$(jq -n --arg addr "$ip" '{address:$addr,status:"active"}')
    if [[ -n "$iface_id" && "$iface_id" != "null" ]]; then
        payload=$(echo "$payload" | jq \
            ".assigned_object_type=\"dcim.interface\" | .assigned_object_id=$iface_id")
    fi
    if [[ -z "$ip_id" ]]; then
        local res; res=$(nb_post "ipam/ip-addresses/" "$payload")
        ip_id=$(echo "$res" | jq -r '.id // empty')
    fi
    if [[ -n "$device_id" && -n "$ip_id" ]]; then
        nb_patch "dcim/devices/${device_id}/" "{\"primary_ip4\":$ip_id}" >/dev/null
    fi
    echo "$ip_id"
}

nb_add_interface() {
    local device_id="$1" if_name="$2" if_type="${3:-other}" mac="${4:-}" desc="${5:-}"
    local enc; enc=$(nb_urlencode "$if_name")
    local existing; existing=$(nb_get "dcim/interfaces/?device_id=$device_id&name=${enc}")
    local id; id=$(echo "$existing" | jq -r '.results[0].id // empty')
    if [[ -z "$id" ]]; then
        local payload
        payload=$(jq -n \
            --argjson dev "$device_id" \
            --arg name "$if_name" \
            --arg type "$if_type" \
            --arg mac  "$mac" \
            --arg desc "$desc" \
            '{device:$dev,name:$name,type:$type,description:$desc,
              mac_address:(if $mac!="" and $mac!="null" then $mac else null end)}')
        local res; res=$(nb_post "dcim/interfaces/" "$payload")
        id=$(echo "$res" | jq -r '.id // empty')
    fi
    echo "$id"
}

nb_upsert_device() {
    local name="$1" ip="$2" role="$3" mfr="$4" model="$5" site_id="$6"
    local os="${7:-}" serial="${8:-}" comments="${9:-}"

    local mfr_id dtype_id role_id
    mfr_id=$(nb_get_or_create_manufacturer "$mfr")
    dtype_id=$(nb_get_or_create_device_type "$mfr_id" "$model")
    role_id=$(nb_get_or_create_role "$role")

    local enc; enc=$(nb_urlencode "$name")
    local existing; existing=$(nb_get "dcim/devices/?name=${enc}")
    local dev_id; dev_id=$(echo "$existing" | jq -r '.results[0].id // empty')

    local payload
    payload=$(jq -n \
        --arg name     "$name" \
        --argjson dt   "$dtype_id" \
        --argjson role "$role_id" \
        --argjson site "$site_id" \
        --arg serial   "$serial" \
        --arg comments "$comments" \
        '{name:$name,device_type:$dt,role:$role,site:$site,
          status:"active",serial:$serial,comments:$comments}')

    if [[ -z "$dev_id" ]]; then
        local res; res=$(nb_post "dcim/devices/" "$payload")
        dev_id=$(echo "$res" | jq -r '.id // empty')
        log_info "Created device: $name (ID: $dev_id)"
    else
        nb_patch "dcim/devices/${dev_id}/" "$payload" >/dev/null
        log_info "Updated device: $name (ID: $dev_id)"
    fi
    echo "$dev_id"
}

# -----------------------------------------------------------------------------
# SNMP HELPERS  (top-level functions -- bash does not allow "local func()")
# FIX v2.0.2: Replaced illegal "local _snmp() {...}" nested function with
#             two proper top-level functions _snmp_get / _snmp_walk.
# -----------------------------------------------------------------------------
_snmp_get() {
    # _snmp_get <ip> <token> <timeout> <oid>
    # token format: "community_string" OR "v3:<user>:<ap>:<apass>:<pp>:<ppass>"
    local ip="$1" token="$2" tout="$3" oid="$4"
    if [[ "$token" == v3:* ]]; then
        local v3user v3ap v3apass v3pp v3ppass
        IFS=':' read -r _ v3user v3ap v3apass v3pp v3ppass <<< "$token"
        snmpget -v3 -u "$v3user" -l authPriv \
            -a "$v3ap" -A "$v3apass" \
            -x "$v3pp" -X "$v3ppass" \
            -t "$tout" -r 1 "$ip" "$oid" 2>/dev/null \
            | sed 's/.*: //' || true
    else
        snmpget -v2c -c "$token" -t "$tout" -r 1 "$ip" "$oid" 2>/dev/null \
            | sed 's/.*: //' || true
    fi
}

_snmp_walk() {
    # _snmp_walk <ip> <token> <timeout> <oid>
    local ip="$1" token="$2" tout="$3" oid="$4"
    if [[ "$token" == v3:* ]]; then
        local v3user v3ap v3apass v3pp v3ppass
        IFS=':' read -r _ v3user v3ap v3apass v3pp v3ppass <<< "$token"
        snmpwalk -v3 -u "$v3user" -l authPriv \
            -a "$v3ap" -A "$v3apass" \
            -x "$v3pp" -X "$v3ppass" \
            -t "$tout" -r 1 "$ip" "$oid" 2>/dev/null || true
    else
        snmpwalk -v2c -c "$token" -t "$tout" -r 1 "$ip" "$oid" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# DISCOVERY ENGINE
# -----------------------------------------------------------------------------
DISC_RESULTS=""
LIVE_HOSTS_FILE="$DISCOVERY_DIR/live_hosts.txt"

init_scan_session() {
    local target="$1"
    DISC_RESULTS="$DISCOVERY_DIR/results_$(date +%Y%m%d_%H%M%S).json"
    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg target "$target" \
        '{scan_time:$ts,target:$target,hosts:[]}' > "$DISC_RESULTS"
    log_info "Scan session: $DISC_RESULTS"
}

append_host() {
    local host_json="$1"
    local tmp; tmp=$(mktemp)
    jq ".hosts += [$host_json]" "$DISC_RESULTS" > "$tmp" \
        && mv "$tmp" "$DISC_RESULTS"
}

# -- Phase 1: Host Discovery --------------------------------------------------
discover_live_hosts() {
    local target="$1"
    > "$LIVE_HOSTS_FILE"
    local tmp_all; tmp_all=$(mktemp)

    log_step "Phase 1 -- Host Discovery: $target"

    echo -ne "  ${W}ARP scan${NC} .................. "
    if cmd_exists arp-scan; then
        arp-scan --localnet --quiet 2>/dev/null \
            | awk '/^[0-9]/{print $1}' >> "$tmp_all"
        arp-scan "$target" --quiet 2>/dev/null \
            | awk '/^[0-9]/{print $1}' >> "$tmp_all" 2>/dev/null || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    echo -ne "  ${W}fping ICMP sweep${NC} .......... "
    if cmd_exists fping; then
        fping -a -g "$target" 2>/dev/null >> "$tmp_all" || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    echo -ne "  ${W}nmap ping sweep${NC} ........... "
    if cmd_exists nmap; then
        nmap -sn -PE -PS22,80,443,8080 -PA80,443 \
            --host-timeout 10s "$target" -oG - 2>/dev/null \
            | awk '/Up$/{print $2}' >> "$tmp_all"
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    echo -ne "  ${W}masscan port sweep${NC} ........ "
    if cmd_exists masscan; then
        masscan "$target" -p22,80,443,8080,161,23 \
            --rate=2000 --wait 2 -oG - 2>/dev/null \
            | awk '/open/{print $6}' >> "$tmp_all" || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    echo -ne "  ${W}SNMP community sweep${NC} ...... "
    local comm
    while IFS= read -r comm; do
        fping -a -g "$target" 2>/dev/null | while read -r ip; do
            snmpget -v2c -c "$comm" -t 1 -r 0 "$ip" \
                1.3.6.1.2.1.1.1.0 &>/dev/null && echo "$ip" >> "$tmp_all"
        done &
    done < <(get_communities_for "0.0.0.0")
    wait
    echo -e "${G}done${NC}"

    echo -ne "  ${W}mDNS/Bonjour discovery${NC} .... "
    if cmd_exists avahi-browse; then
        timeout 8 avahi-browse -atr --no-fail 2>/dev/null \
            | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' >> "$tmp_all" || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    echo -ne "  ${W}NetBIOS scan${NC} .............. "
    if cmd_exists nbtscan; then
        nbtscan -q "$target" 2>/dev/null \
            | awk '/^[0-9]/{print $1}' >> "$tmp_all" || true
        echo -e "${G}done${NC}"
    else echo -e "${Y}skipped${NC}"; fi

    echo -ne "  ${W}ARP cache (passive)${NC} ....... "
    ip neigh show 2>/dev/null \
        | awk '/REACHABLE|STALE|DELAY/{print $1}' >> "$tmp_all"
    arp -n 2>/dev/null \
        | awk 'NR>1 && $3!="(incomplete)"{print $1}' >> "$tmp_all"
    echo -e "${G}done${NC}"

    # Deduplicate, validate, sort
    sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -u "$tmp_all" \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        | while IFS= read -r ip; do
            valid_ip "$ip" && echo "$ip"
          done > "$LIVE_HOSTS_FILE"
    rm -f "$tmp_all"

    local count; count=$(wc -l < "$LIVE_HOSTS_FILE")
    log_ok "Phase 1 complete -- $count live hosts found"
    echo -e "\n  ${G}Found: ${W}${count} live hosts${NC}"
}

# -- Phase 2: Deep scan -------------------------------------------------------
scan_all_hosts() {
    local total; total=$(wc -l < "$LIVE_HOSTS_FILE")
    log_step "Phase 2 -- Deep Scanning $total Hosts"
    local idx=0
    local ip
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

    probe_nmap    "$ip" "$tmp" &
    probe_snmp    "$ip" "$tmp" &
    probe_ssh     "$ip" "$tmp" &
    probe_http    "$ip" "$tmp" &
    probe_netbios "$ip" "$tmp" &
    probe_dns     "$ip" "$tmp" &
    probe_banners "$ip" "$tmp" &
    probe_mdns    "$ip" "$tmp" &
    wait

    local host_json
    host_json=$(merge_host_data "$ip" "$tmp")
    append_host "$host_json"

    local hostname role os
    hostname=$(echo "$host_json" | jq -r '.hostname // "?"')
    role=$(echo "$host_json"     | jq -r '.device_role // "?"')
    os=$(echo "$host_json"       | jq -r '.os // ""')
    printf "    ${G}OK${NC}  %-16s  %-28s  %-16s  %s\n" \
        "$ip" "$hostname" "$role" "$os"

    rm -rf "$tmp"
}

# -- Probe: nmap ---------------------------------------------------------------
probe_nmap() {
    local ip="$1" tmp="$2"
    local xml="$tmp/nmap.xml"

    nmap -sV -sC -O --osscan-guess \
        -p "T:1-1024,T:1433,T:1521,T:3306,T:3389,T:5432,T:5900,T:5901,\
T:6379,T:8080,T:8443,T:8888,T:9200,T:9300,T:27017,\
U:53,U:67,U:68,U:69,U:123,U:161,U:162,U:500,U:514,U:5353" \
        --script "banner,ssh-hostkey,snmp-info,snmp-sysdescr,snmp-interfaces,\
http-title,http-server-header,ssl-cert,nbstat,smb-security-mode,\
ftp-banner,telnet-ntlm-info,dns-service-discovery,ms-sql-info,\
mysql-info,mongodb-info,rdp-enum-encryption,vnc-info" \
        -T4 --host-timeout 90s --max-retries 2 \
        -oX "$xml" "$ip" >> "$LOG_FILE" 2>&1 || true

    # FIX v2.0.2: pass xml path as sys.argv[1] rather than embedding in heredoc
    python3 /dev/stdin "$xml" <<'PYEOF' > "$tmp/nmap.json" 2>/dev/null
import xml.etree.ElementTree as ET, json, sys

def parse(xmlfile):
    result = {"ports": [], "os": None, "os_accuracy": None,
              "mac": None, "vendor": None, "hostname": None, "scripts": {}}
    try:
        tree = ET.parse(xmlfile)
    except Exception:
        return result

    for host in tree.findall('host'):
        for hn in (host.find('hostnames') or []):
            if hn.get('type') == 'PTR':
                result['hostname'] = hn.get('name')
            elif not result['hostname']:
                result['hostname'] = hn.get('name')

        for addr in host.findall('address'):
            if addr.get('addrtype') == 'mac':
                result['mac']    = addr.get('addr')
                result['vendor'] = addr.get('vendor', '')

        os_el = host.find('os')
        if os_el is not None:
            for m in os_el.findall('osmatch'):
                result['os']          = m.get('name')
                result['os_accuracy'] = m.get('accuracy')
                break

        ports_el = host.find('ports')
        if ports_el is not None:
            for port in ports_el.findall('port'):
                state = port.find('state')
                if state is None or state.get('state') != 'open':
                    continue
                p = {'port': port.get('portid'), 'proto': port.get('protocol'),
                     'service': None, 'version': None, 'banner': None, 'scripts': {}}
                svc = port.find('service')
                if svc is not None:
                    p['service'] = svc.get('name', '')
                    p['version'] = (svc.get('product', '') + ' ' + svc.get('version', '')).strip()
                for sc in port.findall('script'):
                    sid = sc.get('id', '')
                    out = (sc.get('output', '') or '')[:300]
                    p['scripts'][sid] = out
                    if sid == 'banner':
                        p['banner'] = out
                result['ports'].append(p)

        for sc in host.findall('hostscript/script'):
            result['scripts'][sc.get('id', '')] = sc.get('output', '')[:300]

    return result

print(json.dumps(parse(sys.argv[1])))
PYEOF
}

# -- Probe: SNMP ---------------------------------------------------------------
probe_snmp() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/snmp.json"

    local communities; communities=$(get_communities_for "$ip")
    local working_token=""
    local comm

    while IFS= read -r comm; do
        if snmpget -v2c -c "$comm" -t "$SNMP_TIMEOUT" -r 1 \
            "$ip" 1.3.6.1.2.1.1.1.0 &>/dev/null; then
            working_token="$comm"
            break
        fi
    done <<< "$communities"

    # Try SNMPv3 if v2c failed
    if [[ -z "$working_token" ]]; then
        local creds; creds=$(read_creds)
        local v3cred
        while IFS= read -r v3cred; do
            local v3u v3ap v3apass v3pp v3ppass
            v3u=$(echo "$v3cred"    | jq -r '.username')
            v3ap=$(echo "$v3cred"   | jq -r '.auth_proto // "SHA"')
            v3apass=$(echo "$v3cred"| jq -r '.auth_pass')
            v3pp=$(echo "$v3cred"   | jq -r '.priv_proto // "AES"')
            v3ppass=$(echo "$v3cred"| jq -r '.priv_pass')
            if snmpget -v3 -u "$v3u" -l authPriv \
                -a "$v3ap" -A "$v3apass" \
                -x "$v3pp" -X "$v3ppass" \
                -t "$SNMP_TIMEOUT" -r 1 "$ip" 1.3.6.1.2.1.1.1.0 &>/dev/null; then
                working_token="v3:${v3u}:${v3ap}:${v3apass}:${v3pp}:${v3ppass}"
                break
            fi
        done < <(echo "$creds" | jq -c '.snmp_v3[]' 2>/dev/null || true)
    fi

    [[ -z "$working_token" ]] && return

    local t="$working_token"
    local tout="$SNMP_TIMEOUT"

    # Collect key OIDs using the top-level _snmp_get helper
    local sys_descr sys_name sys_loc sys_contact sys_uptime sys_oid chassis_serial
    sys_descr=$(      _snmp_get "$ip" "$t" "$tout" 1.3.6.1.2.1.1.1.0)
    sys_name=$(       _snmp_get "$ip" "$t" "$tout" 1.3.6.1.2.1.1.5.0)
    sys_loc=$(        _snmp_get "$ip" "$t" "$tout" 1.3.6.1.2.1.1.6.0)
    sys_contact=$(    _snmp_get "$ip" "$t" "$tout" 1.3.6.1.2.1.1.4.0)
    sys_uptime=$(     _snmp_get "$ip" "$t" "$tout" 1.3.6.1.2.1.1.3.0)
    sys_oid=$(        _snmp_get "$ip" "$t" "$tout" 1.3.6.1.2.1.1.2.0)
    chassis_serial=$( _snmp_get "$ip" "$t" "$tout" 1.3.6.1.2.1.47.1.1.1.1.11.1)

    local ifaces_raw mac_table arp_table cdp_raw lldp_raw
    ifaces_raw=$(_snmp_walk "$ip" "$t" "$tout" 1.3.6.1.2.1.2.2)
    mac_table=$(  _snmp_walk "$ip" "$t" "$tout" 1.3.6.1.2.1.17.4.3.1)
    arp_table=$(  _snmp_walk "$ip" "$t" "$tout" 1.3.6.1.2.1.4.22.1)
    cdp_raw=$(    _snmp_walk "$ip" "$t" "$tout" 1.3.6.1.4.1.9.9.23.1.2.1.1)
    lldp_raw=$(   _snmp_walk "$ip" "$t" "$tout" 1.0.8802.1.1.2.1.4)

    # Write all raw data to temp files so Python reads files (avoids arg-length limits)
    echo "$ifaces_raw"  > "$tmp/snmp_ifaces.txt"
    echo "$mac_table"   > "$tmp/snmp_mac.txt"
    echo "$arp_table"   > "$tmp/snmp_arp.txt"
    echo "$cdp_raw"     > "$tmp/snmp_cdp.txt"
    echo "$lldp_raw"    > "$tmp/snmp_lldp.txt"

    python3 /dev/stdin \
        "$working_token" \
        "$sys_descr" "$sys_name" "$sys_loc" "$sys_contact" \
        "$sys_uptime" "$sys_oid" "$chassis_serial" \
        "$tmp" \
        <<'PYEOF' > "$tmp/snmp.json" 2>/dev/null
import re, json, sys, os

working_token  = sys.argv[1]
sys_descr      = sys.argv[2].strip().strip('"')
sys_name       = sys.argv[3].strip().strip('"')
sys_loc        = sys.argv[4].strip().strip('"')
sys_contact    = sys.argv[5].strip().strip('"')
sys_uptime     = sys.argv[6].strip()
sys_oid        = sys.argv[7].strip()
chassis_ser    = sys.argv[8].strip().strip('"')
tmp            = sys.argv[9]

def read_file(name):
    p = os.path.join(tmp, name)
    if os.path.exists(p):
        with open(p) as f:
            return f.read()
    return ''

ifaces_raw    = read_file('snmp_ifaces.txt')
mac_table_raw = read_file('snmp_mac.txt')
arp_table_raw = read_file('snmp_arp.txt')
cdp_raw       = read_file('snmp_cdp.txt')
lldp_raw      = read_file('snmp_lldp.txt')

# Parse interfaces
ifaces = {}
for line in ifaces_raw.split('\n'):
    idx_m = re.search(r'(\d+)\s*=', line)
    if not idx_m:
        continue
    idx = idx_m.group(1)
    val_m = re.search(r'=\s*(?:STRING|INTEGER|Gauge32|Counter32|PhysAddress):\s*(.*)', line)
    if not val_m:
        continue
    val = val_m.group(1).strip().strip('"')
    if idx not in ifaces:
        ifaces[idx] = {}
    if '2.2.1.2.' in line:  ifaces[idx]['name']         = val
    elif '2.2.1.3.' in line: ifaces[idx]['type']        = val
    elif '2.2.1.6.' in line: ifaces[idx]['mac']         = val
    elif '2.2.1.7.' in line: ifaces[idx]['admin_status']= val
    elif '2.2.1.8.' in line: ifaces[idx]['oper_status'] = val
    elif '2.2.1.5.' in line: ifaces[idx]['speed']       = val

interfaces = [{'index': k, **v} for k, v in ifaces.items() if 'name' in v]

# Bridge MAC table
mac_port_map = []
for line in mac_table_raw.split('\n'):
    m = re.match(
        r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m:
        mac = ':'.join('{:02x}'.format(int(o)) for o in m.group(1).split('.'))
        mac_port_map.append({'mac': mac, 'port_index': m.group(2)})

# ARP table
arp_entries = []
for line in arp_table_raw.split('\n'):
    m = re.match(
        r'.*4\.22\.1\.2\.\d+\.(\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m:
        arp_entries.append({'ip': m.group(1), 'if_index': m.group(2)})

# CDP neighbors
cdp_devices = {}
for line in cdp_raw.split('\n'):
    for suffix, field in [('.6.', 'device_id'), ('.8.', 'platform'), ('.7.', 'remote_port')]:
        pattern = r'.*' + re.escape(suffix) + r'(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)'
        m = re.match(pattern, line)
        if m:
            key = '{}_{}'.format(m.group(1), m.group(2))
            cdp_devices.setdefault(key, {})[field] = m.group(3).strip().strip('"')
cdp_neighbors = list(cdp_devices.values())

# LLDP neighbors
lldp_sys = {}
for line in lldp_raw.split('\n'):
    m = re.match(r'.*\.(\d+)\.(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)', line)
    if m:
        lp, ri, val = m.group(2), m.group(3), m.group(4).strip().strip('"')
        key = '{}_{}'.format(lp, ri)
        lldp_sys.setdefault(key, {})
        if '4.1.1.9'  in line: lldp_sys[key]['sys_name']  = val
        if '4.1.1.10' in line: lldp_sys[key]['sys_desc']  = val[:100]
        if '4.1.1.7'  in line: lldp_sys[key]['port_id']   = val
        if '4.1.1.8'  in line: lldp_sys[key]['port_desc'] = val
lldp_neighbors = list(lldp_sys.values())

print(json.dumps({
    "available":      True,
    "community":      working_token,
    "sys_descr":      sys_descr,
    "sys_name":       sys_name,
    "sys_location":   sys_loc,
    "sys_contact":    sys_contact,
    "sys_uptime":     sys_uptime,
    "sys_oid":        sys_oid,
    "chassis_serial": chassis_ser,
    "interfaces":     interfaces,
    "mac_port_map":   mac_port_map,
    "arp_entries":    arp_entries,
    "cdp_neighbors":  cdp_neighbors,
    "lldp_neighbors": lldp_neighbors,
}))
PYEOF
}

# -- Probe: SSH ----------------------------------------------------------------
probe_ssh() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/ssh.json"

    nc -z -w "$SCAN_TIMEOUT" "$ip" 22 2>/dev/null || return

    local banner
    banner=$(nc -w 3 "$ip" 22 2>/dev/null | head -1 | tr -dc '[:print:]')

    local ssh_base_opts=(
        -o StrictHostKeyChecking=no
        -o ConnectTimeout="$SSH_TIMEOUT"
        -o BatchMode=yes
        -o LogLevel=error
        -o UserKnownHostsFile=/dev/null
        -o PreferredAuthentications=publickey,password
    )

    local remote_cmd
    remote_cmd='printf "HOSTNAME="; hostname; uname -a; cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null; ip addr 2>/dev/null || ifconfig 2>/dev/null; lscpu 2>/dev/null | head -5; free -h 2>/dev/null | head -2'

    local sys_info="" cred_json
    while IFS= read -r cred_json; do
        [[ -z "$cred_json" || "$cred_json" == "null" ]] && continue
        local su sp sk
        su=$(echo "$cred_json" | jq -r '.username  // empty')
        sp=$(echo "$cred_json" | jq -r '.password  // empty')
        sk=$(echo "$cred_json" | jq -r '.key_file  // empty')
        [[ -z "$su" ]] && continue

        local opts=("${ssh_base_opts[@]}")
        [[ -n "$sk" && -f "$sk" ]] && opts+=(-i "$sk")

        if [[ -n "$sp" ]]; then
            sys_info=$(sshpass -p "$sp" ssh "${opts[@]}" \
                "${su}@${ip}" "$remote_cmd" 2>/dev/null || true)
        else
            sys_info=$(ssh "${opts[@]}" "${su}@${ip}" "$remote_cmd" 2>/dev/null || true)
        fi
        [[ -n "$sys_info" ]] && break
    done < <(get_ssh_creds_for "$ip")

    local hostname os_info kernel cpu mem
    hostname=$(echo "$sys_info" | grep '^HOSTNAME=' | cut -d= -f2)
    os_info=$(echo "$sys_info"  \
        | grep -m1 'PRETTY_NAME=\|ProductName:' \
        | sed 's/.*=//;s/.*: //' | tr -d '"')
    kernel=$(echo "$sys_info"   | grep '^Linux\|^Darwin' | head -1)
    cpu=$(echo "$sys_info"      | grep -i 'model name\|CPU' | head -1 | sed 's/.*: //')
    mem=$(echo "$sys_info"      | grep '^Mem:' | awk '{print $2}')

    # Network device fallback -- try show version
    local net_info=""
    if [[ -z "$sys_info" ]]; then
        local net_cmd='show version 2>/dev/null || display version 2>/dev/null'
        while IFS= read -r cred_json; do
            [[ -z "$cred_json" ]] && continue
            local su sp sk
            su=$(echo "$cred_json" | jq -r '.username // empty')
            sp=$(echo "$cred_json" | jq -r '.password // empty')
            sk=$(echo "$cred_json" | jq -r '.key_file // empty')
            local opts=("${ssh_base_opts[@]}")
            [[ -n "$sk" && -f "$sk" ]] && opts+=(-i "$sk")
            if [[ -n "$sp" ]]; then
                net_info=$(sshpass -p "$sp" ssh "${opts[@]}" \
                    "${su}@${ip}" "$net_cmd" 2>/dev/null | head -20 || true)
            else
                net_info=$(ssh "${opts[@]}" "${su}@${ip}" "$net_cmd" \
                    2>/dev/null | head -20 || true)
            fi
            [[ -n "$net_info" ]] && break
        done < <(get_ssh_creds_for "$ip")
    fi

    jq -n \
        --arg banner  "$banner" \
        --arg hn      "$hostname" \
        --arg os      "$os_info" \
        --arg kernel  "$kernel" \
        --arg cpu     "$cpu" \
        --arg mem     "$mem" \
        --arg netinfo "$net_info" \
        '{available:true,banner:$banner,hostname:$hn,os:$os,
          kernel:$kernel,cpu:$cpu,mem_total:$mem,
          net_device_info:$netinfo}' > "$tmp/ssh.json"
}

# -- Probe: HTTP/HTTPS ---------------------------------------------------------
# FIX v2.0.2: Build JSON by writing one entry per line to a temp file,
#             then slurp -- avoids bash array issues in subshells.
probe_http() {
    local ip="$1" tmp="$2"
    local svc_file="$tmp/http_svcs.ndjson"
    > "$svc_file"

    local port
    for port in 80 443 8080 8443 8000 8888 3000 5000 9090 9443 4443; do
        local proto="http"
        [[ "$port" =~ ^(443|8443|9443|4443)$ ]] && proto="https"

        local hdr_file="$tmp/hdr_${port}.txt"
        curl -skL \
            --max-time "$SCAN_TIMEOUT" \
            --max-redirs 3 \
            -A "Mozilla/5.0 NetBox-Discovery/2.0" \
            -D "$hdr_file" \
            "${proto}://${ip}:${port}/" > "$tmp/body_${port}.html" 2>/dev/null \
            || continue
        [[ ! -f "$hdr_file" ]] && continue

        local status server title powered_by cert_cn cert_exp
        status=$(head -1 "$hdr_file" | awk '{print $2}')
        server=$(grep -i '^Server:' "$hdr_file" | head -1 | cut -d' ' -f2- | tr -d '\r')
        powered_by=$(grep -i '^X-Powered-By:' "$hdr_file" | head -1 | cut -d' ' -f2- | tr -d '\r')
        title=$(grep -oi '<title[^>]*>[^<]*</title>' "$tmp/body_${port}.html" \
            | sed 's/<[^>]*>//g' | head -1 | xargs 2>/dev/null || true)
        cert_cn=""; cert_exp=""

        if [[ "$proto" == "https" ]]; then
            local cert_info
            cert_info=$(echo | openssl s_client \
                -connect "${ip}:${port}" -servername "$ip" 2>/dev/null \
                | openssl x509 -noout -subject -enddate 2>/dev/null || true)
            cert_cn=$(echo "$cert_info" \
                | grep subject | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 || true)
            cert_exp=$(echo "$cert_info" | grep notAfter | cut -d= -f2- || true)
        fi

        jq -n \
            --argjson port "$port" \
            --arg proto    "$proto" \
            --arg status   "${status:-?}" \
            --arg server   "$server" \
            --arg title    "$title" \
            --arg powered  "$powered_by" \
            --arg cert_cn  "${cert_cn:-}" \
            --arg cert_exp "${cert_exp:-}" \
            '{port:$port,proto:$proto,status:$status,server:$server,
              title:$title,powered_by:$powered,
              cert_cn:$cert_cn,cert_exp:$cert_exp}' >> "$svc_file"
    done

    if [[ -s "$svc_file" ]]; then
        jq -s '{http_services:.}' "$svc_file" > "$tmp/http.json" 2>/dev/null \
            || echo '{"http_services":[]}' > "$tmp/http.json"
    else
        echo '{"http_services":[]}' > "$tmp/http.json"
    fi
}

# -- Probe: NetBIOS / SMB ------------------------------------------------------
probe_netbios() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/netbios.json"
    cmd_exists nmblookup || return
    nc -z -w 2 "$ip" 139 2>/dev/null \
        || nc -z -w 2 "$ip" 445 2>/dev/null || return

    local nb_raw
    nb_raw=$(nmblookup -A "$ip" 2>/dev/null || true)
    [[ -z "$nb_raw" ]] && return

    local netbios_name workgroup
    netbios_name=$(echo "$nb_raw" | awk '/<00>/ && !/GROUP/{print $1; exit}')
    workgroup=$(echo "$nb_raw"    | awk '/<00>.*GROUP/{print $1; exit}')

    local shares="" cred_json
    if cmd_exists smbclient; then
        while IFS= read -r cred_json; do
            local su sp
            su=$(echo "$cred_json" | jq -r '.username // empty')
            sp=$(echo "$cred_json" | jq -r '.password // empty')
            [[ -z "$su" ]] && continue
            shares=$(smbclient -L "//${ip}" -U "${su}%${sp}" \
                --no-pass 2>/dev/null \
                | grep -E '^\s+\w' | awk '{print $1}' || true)
            [[ -n "$shares" ]] && break
        done < <(get_ssh_creds_for "$ip")
    fi

    jq -n \
        --arg name   "$netbios_name" \
        --arg wg     "$workgroup" \
        --arg shares "$shares" \
        '{available:true,netbios_name:$name,workgroup:$wg,smb_shares:$shares}' \
        > "$tmp/netbios.json"
}

# -- Probe: DNS ----------------------------------------------------------------
probe_dns() {
    local ip="$1" tmp="$2"
    local ptr_name
    ptr_name=$(dig +short +time=3 +tries=1 -x "$ip" 2>/dev/null \
        | head -1 | sed 's/\.$//' || true)
    jq -n --arg ptr "$ptr_name" '{ptr_hostname:$ptr}' > "$tmp/dns.json"
}

# -- Probe: Banner grab --------------------------------------------------------
# FIX v2.0.2: Write one JSON object per file instead of building array in bash.
probe_banners() {
    local ip="$1" tmp="$2"
    local bnr_file="$tmp/banners.ndjson"
    > "$bnr_file"

    local port
    for port in 21 23 25 110 143 515 631 5060; do
        local banner
        banner=$(timeout 3 bash -c \
            "printf '' | nc -w 3 $ip $port 2>/dev/null \
             | head -1 | tr -dc '[:print:]'" 2>/dev/null || true)
        if [[ -n "$banner" && ${#banner} -gt 4 ]]; then
            jq -n --argjson p "$port" --arg b "$banner" \
                '{port:$p,banner:$b}' >> "$bnr_file"
        fi
    done

    if [[ -s "$bnr_file" ]]; then
        jq -s '{banners:.}' "$bnr_file" > "$tmp/banners.json" 2>/dev/null \
            || echo '{"banners":[]}' > "$tmp/banners.json"
    else
        echo '{"banners":[]}' > "$tmp/banners.json"
    fi
}

# -- Probe: mDNS ---------------------------------------------------------------
probe_mdns() {
    local ip="$1" tmp="$2"
    local mdns_name=""
    if cmd_exists avahi-resolve; then
        mdns_name=$(avahi-resolve -a "$ip" 2>/dev/null | awk '{print $2}' || true)
    fi
    jq -n --arg n "$mdns_name" '{mdns_hostname:$n}' > "$tmp/mdns.json"
}

# -- Merge all probe results ---------------------------------------------------
# FIX v2.0.2: pass ip and tmp as argv so the heredoc is a clean quoted string.
merge_host_data() {
    local ip="$1" tmp="$2"

    python3 /dev/stdin "$ip" "$tmp" <<'PYEOF'
import json, os, sys

ip  = sys.argv[1]
tmp = sys.argv[2]

probes = {}
for f in ('nmap', 'snmp', 'ssh', 'http', 'netbios', 'dns', 'banners', 'mdns'):
    p = os.path.join(tmp, f + '.json')
    if os.path.exists(p):
        try:
            with open(p) as fh:
                probes[f] = json.load(fh)
        except Exception:
            probes[f] = {}

nmap = probes.get('nmap',    {})
snmp = probes.get('snmp',    {})
ssh  = probes.get('ssh',     {})
http = probes.get('http',    {})
nb   = probes.get('netbios', {})
dns  = probes.get('dns',     {})
bnr  = probes.get('banners', {})
mdns = probes.get('mdns',    {})

host = {
    'ip':               ip,
    'hostname':         None,
    'mac':              None,
    'vendor':           None,
    'os':               None,
    'os_accuracy':      None,
    'device_role':      'Endpoint',
    'manufacturer':     'Unknown',
    'model':            'Unknown',
    'serial':           '',
    'ports':            nmap.get('ports', []),
    'interfaces':       snmp.get('interfaces', []),
    'mac_port_map':     snmp.get('mac_port_map', []),
    'arp_entries':      snmp.get('arp_entries', []),
    'http_services':    http.get('http_services', []),
    'banners':          bnr.get('banners', []),
    'cdp_neighbors':    snmp.get('cdp_neighbors', []),
    'lldp_neighbors':   snmp.get('lldp_neighbors', []),
    'snmp_details':     {},
    'ssh_details':      {},
    'discovery_methods': [],
}

# Hostname resolution (priority order)
for src in (snmp.get('sys_name'), ssh.get('hostname'),
            nmap.get('hostname'), dns.get('ptr_hostname'),
            mdns.get('mdns_hostname'), nb.get('netbios_name')):
    if src and src.strip() and src.lower() not in ('none', 'null', ''):
        host['hostname'] = src.strip()
        break
if not host['hostname']:
    host['hostname'] = 'device-' + ip.replace('.', '-')

host['mac']          = nmap.get('mac')
host['vendor']       = nmap.get('vendor', '')
host['os']           = nmap.get('os') or ssh.get('os') or ''
host['os_accuracy']  = nmap.get('os_accuracy')
host['serial']       = snmp.get('chassis_serial', '')

if nmap.get('ports'):         host['discovery_methods'].append('nmap')
if snmp.get('available'):     host['discovery_methods'].append('snmp')
if ssh.get('available'):      host['discovery_methods'].append('ssh')
if http.get('http_services'): host['discovery_methods'].append('http')
if nb.get('available'):       host['discovery_methods'].append('netbios')
if dns.get('ptr_hostname'):   host['discovery_methods'].append('dns')
if bnr.get('banners'):        host['discovery_methods'].append('banner')

sys_descr   = (snmp.get('sys_descr') or '').lower()
os_str      = (host['os'] or '').lower()
ssh_net     = (ssh.get('net_device_info') or '').lower()
open_ports  = {str(p.get('port', '')) for p in host['ports']}
http_titles = ' '.join(s.get('title', '') for s in host['http_services']).lower()
combined    = ' '.join([sys_descr, ssh_net, os_str, http_titles])

FIREWALL = ['firewall','fortigate','fortios','palo alto','checkpoint','asa','sonicwall','opnsense','pfsense']
ROUTER   = ['router','gateway','ios xe','ios xr','junos','routeros','vyos']
SWITCH   = ['switch','catalyst','nexus',' eos ','comware','procurve','arubaos','ex series','qfx']
AP       = ['access point','aironet','unifi','airmax','lightweight ap']
SERVER   = ['linux','ubuntu','debian','centos','rhel','windows server','esxi','vmware','proxmox','freebsd']
PRINTER  = ['printer','jetdirect','xerox','ricoh','canon','brother']
UPS      = ['ups','apc','eaton','powerware']
CAMERA   = ['camera','axis comm','hikvision','dahua']

if   any(k in combined for k in FIREWALL):  host['device_role'] = 'Firewall'
elif any(k in combined for k in ROUTER) and '161' in open_ports: host['device_role'] = 'Router'
elif any(k in combined for k in SWITCH) and '161' in open_ports: host['device_role'] = 'Switch'
elif any(k in combined for k in AP):        host['device_role'] = 'Wireless AP'
elif any(k in combined for k in PRINTER) or '9100' in open_ports: host['device_role'] = 'Printer'
elif any(k in combined for k in UPS):       host['device_role'] = 'UPS'
elif any(k in combined for k in CAMERA):    host['device_role'] = 'IP Camera'
elif '3389' in open_ports or 'windows' in os_str: host['device_role'] = 'Server'
elif any(k in combined for k in SERVER):    host['device_role'] = 'Server'
elif '5060' in open_ports or 'sip' in combined:   host['device_role'] = 'IP Phone'
elif '445' in open_ports or nb.get('available'):   host['device_role'] = 'Workstation'

vendor = host.get('vendor', '') or ''
if vendor and vendor not in ('', 'null', 'None'):
    host['manufacturer'] = vendor
else:
    MFR = {'cisco':'Cisco','juniper':'Juniper','arista':'Arista',
           'extreme':'Extreme Networks','hewlett':'HP','dell':'Dell',
           'microsoft':'Microsoft','vmware':'VMware','apple':'Apple',
           'ubiquiti':'Ubiquiti','mikrotik':'MikroTik','fortigate':'Fortinet',
           'fortinet':'Fortinet','palo alto':'Palo Alto','checkpoint':'Check Point',
           'apc':'APC','eaton':'Eaton','axis':'Axis','hikvision':'Hikvision',
           'synology':'Synology','qnap':'QNAP','netgear':'Netgear',
           'h3c':'H3C','huawei':'Huawei','meraki':'Cisco Meraki','brocade':'Brocade'}
    for k, v in MFR.items():
        if k in combined:
            host['manufacturer'] = v
            break

full_descr = snmp.get('sys_descr', '') or ''
if full_descr:
    host['model'] = full_descr[:120].strip()
elif ssh.get('net_device_info'):
    lines = [l for l in ssh['net_device_info'].split('\n') if l.strip()]
    host['model'] = lines[0][:120].strip() if lines else 'Unknown'
else:
    host['model'] = (host['os'] or 'Unknown')[:80]

host['snmp_details'] = {
    'sys_location': snmp.get('sys_location', ''),
    'sys_contact':  snmp.get('sys_contact',  ''),
    'sys_oid':      snmp.get('sys_oid',      ''),
    'sys_uptime':   snmp.get('sys_uptime',   ''),
}
host['ssh_details'] = {
    'cpu':      ssh.get('cpu',       ''),
    'mem_total':ssh.get('mem_total', ''),
    'kernel':   ssh.get('kernel',    ''),
    'banner':   ssh.get('banner',    ''),
}

print(json.dumps(host))
PYEOF
}

# -----------------------------------------------------------------------------
# SWITCHPORT MAPPING
# -----------------------------------------------------------------------------
map_switchports() {
    local switch_ip="$1"
    log_step "Switchport Mapping: $switch_ip"

    local community
    community=$(get_communities_for "$switch_ip" | head -1)

    python3 /dev/stdin "$switch_ip" "$community" "$SNMP_TIMEOUT" "$DISCOVERY_DIR" <<'PYEOF'
import subprocess, json, re, sys

ip        = sys.argv[1]
community = sys.argv[2]
timeout   = sys.argv[3]
disc_dir  = sys.argv[4]

def walk(oid):
    try:
        r = subprocess.run(
            ['snmpwalk', '-v2c', '-c', community,
             '-t', timeout, '-r1', ip, oid],
            capture_output=True, text=True, timeout=30)
        return r.stdout
    except Exception:
        return ''

print('  Fetching interface table...', file=sys.stderr)
if_names  = {}
if_status = {}

for line in walk('1.3.6.1.2.1.2.2.1.2').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)', line)
    if m: if_names[m.group(1)] = m.group(2).strip().strip('"')

for line in walk('1.3.6.1.2.1.2.2.1.8').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m: if_status[m.group(1)] = 'up' if m.group(2) == '1' else 'down'

print('  Fetching bridge MAC table...', file=sys.stderr)
mac_to_port = {}
for line in walk('1.3.6.1.2.1.17.4.3.1.2').split('\n'):
    m = re.match(
        r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m:
        mac = ':'.join('{:02x}'.format(int(o)) for o in m.group(1).split('.'))
        mac_to_port[mac] = m.group(2)

port_to_if = {}
for line in walk('1.3.6.1.2.1.17.1.4.1.2').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m: port_to_if[m.group(1)] = m.group(2)

port_vlan  = {}
for line in walk('1.3.6.1.2.1.17.7.1.4.5.1.1').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*(?:Gauge32|INTEGER|Unsigned32):\s*(\d+)', line)
    if m: port_vlan[m.group(1)] = m.group(2)

vlan_names = {}
for line in walk('1.3.6.1.4.1.9.9.46.1.3.1.1.2').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)', line)
    if m: vlan_names[m.group(1)] = m.group(2).strip().strip('"')

arp_table = {}
for line in walk('1.3.6.1.2.1.4.22.1.2').split('\n'):
    m = re.match(r'.*\.(\d+\.\d+\.\d+\.\d+)\s*=\s*STRING:\s*(.+)', line)
    if m: arp_table[m.group(2).strip()] = m.group(1)

port_entries = []
for mac, bridge_port in mac_to_port.items():
    if_idx  = port_to_if.get(bridge_port, bridge_port)
    if_name = if_names.get(if_idx, 'Port-' + if_idx)
    status  = if_status.get(if_idx, '?')
    vlan    = port_vlan.get(bridge_port, port_vlan.get(if_idx, '?'))
    vlan_nm = vlan_names.get(str(vlan), '')
    rem_ip  = arp_table.get(mac, '')
    port_entries.append({
        'mac': mac, 'bridge_port': bridge_port,
        'if_index': if_idx, 'if_name': if_name,
        'status': status, 'vlan': vlan,
        'vlan_name': vlan_nm, 'remote_ip': rem_ip,
    })

port_entries.sort(key=lambda x: x['if_name'])

out_file = disc_dir + '/switchport_' + ip.replace('.', '-') + '.json'
with open(out_file, 'w') as f:
    json.dump({'switch_ip': ip, 'port_map': port_entries,
               'interface_count': len(if_names),
               'mac_count': len(mac_to_port),
               'vlan_names': vlan_names}, f, indent=2)

print('  Saved: ' + out_file)
print('\n  Switch    : ' + ip)
print('  Interfaces: {}'.format(len(if_names)))
print('  MAC entries: {}'.format(len(mac_to_port)))
print('  VLANs     : ' + ', '.join(vlan_names.values()))
print()
hdr = '  {:<24} {:<8} {:<8} {:<18} {:<18} {}'.format(
    'Interface','Status','VLAN','VLAN Name','MAC','Remote IP')
print(hdr)
print('  ' + '-'*90)
for e in port_entries[:60]:
    print('  {:<24} {:<8} {:<8} {:<18} {:<18} {}'.format(
        e['if_name'], e['status'], str(e['vlan']),
        e['vlan_name'], e['mac'], e['remote_ip']))
if len(port_entries) > 60:
    print('  ... and {} more (see JSON file)'.format(len(port_entries) - 60))
PYEOF
}

# -----------------------------------------------------------------------------
# SYNC TO NETBOX
# -----------------------------------------------------------------------------
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

    if ! nb_get "dcim/sites/" &>/dev/null; then
        log_error "Cannot reach NetBox API at $NETBOX_API_URL"
        pause; return 1
    fi

    local site_id
    site_id=$(nb_get_or_create_site)
    log_info "Using site ID: $site_id"

    local total; total=$(jq '.hosts | length' "$results_file")
    local ok=0 fail=0 idx=0

    local host
    while IFS= read -r host; do
        (( idx++ ))
        local ip hostname role mfr model os serial
        local loc contact uptime cpu mem comments dmethods
        ip=$(echo "$host"       | jq -r '.ip')
        hostname=$(echo "$host" | jq -r '.hostname // "unknown"')
        role=$(echo "$host"     | jq -r '.device_role // "Endpoint"')
        mfr=$(echo "$host"      | jq -r '.manufacturer // "Unknown"')
        model=$(echo "$host"    | jq -r '.model // "Unknown"' | cut -c1-100)
        os=$(echo "$host"       | jq -r '.os // ""')
        serial=$(echo "$host"   | jq -r '.serial // ""')
        loc=$(echo "$host"      | jq -r '.snmp_details.sys_location // ""')
        contact=$(echo "$host"  | jq -r '.snmp_details.sys_contact // ""')
        uptime=$(echo "$host"   | jq -r '.snmp_details.sys_uptime // ""')
        cpu=$(echo "$host"      | jq -r '.ssh_details.cpu // ""')
        mem=$(echo "$host"      | jq -r '.ssh_details.mem_total // ""')
        dmethods=$(echo "$host" | jq -r '.discovery_methods | join(", ")')

        comments="Discovered by NetBox Discovery Suite v${SCRIPT_VERSION}"
        [[ -n "$loc"      ]] && comments="${comments}; Location: $loc"
        [[ -n "$contact"  ]] && comments="${comments}; Contact: $contact"
        [[ -n "$uptime"   ]] && comments="${comments}; Uptime: $uptime"
        [[ -n "$cpu"      ]] && comments="${comments}; CPU: $cpu"
        [[ -n "$mem"      ]] && comments="${comments}; Mem: $mem"
        comments="${comments}; Discovery: $dmethods"

        printf "  ${C}[%d/%d]${NC} ${W}%-16s${NC} %-30s %-16s " \
            "$idx" "$total" "$ip" "$hostname" "$role"

        local dev_id
        dev_id=$(nb_upsert_device "$hostname" "$ip" "$role" \
            "$mfr" "$model" "$site_id" "$os" "$serial" "$comments" \
            2>>"$LOG_FILE")

        if [[ -n "$dev_id" && "$dev_id" != "null" ]]; then
            echo -e "${G}OK${NC}"
            (( ok++ ))

            local mac_addr mgmt_if_id
            mac_addr=$(echo "$host" | jq -r '.mac // ""')
            mgmt_if_id=$(nb_add_interface "$dev_id" "mgmt0" "other" \
                "$mac_addr" "Management")
            nb_add_ip "$ip" "$dev_id" "$mgmt_if_id" >/dev/null

            # Add SNMP interfaces
            local iface
            while IFS= read -r iface; do
                local if_name if_mac if_type nb_type
                if_name=$(echo "$iface" | jq -r '.name // "if"')
                if_mac=$(echo "$iface"  | jq -r '.mac // ""')
                if_type=$(echo "$iface" | jq -r '.type // "other"')
                nb_type="other"
                case "$if_type" in
                    6)   nb_type="1000base-t"     ;;
                    53)  nb_type="1000base-x-sfp" ;;
                    161) nb_type="ieee802-11a"     ;;
                esac
                nb_add_interface "$dev_id" "$if_name" \
                    "$nb_type" "$if_mac" "" >/dev/null 2>&1 || true
            done < <(echo "$host" | jq -c '.interfaces[]?' 2>/dev/null || true)

        else
            echo -e "${R}FAIL${NC}"
            log_error "Failed to sync: $hostname ($ip)"
            (( fail++ ))
        fi

    done < <(jq -c '.hosts[]' "$results_file")

    echo -e "\n  ${G}Complete:${NC} $ok synced  ${R}$fail failed${NC}  (total: $total)"
    log_info "Sync complete: ok=$ok fail=$fail total=$total"
    pause
}

# -----------------------------------------------------------------------------
# CREDENTIAL MANAGEMENT MENU
# -----------------------------------------------------------------------------
menu_credentials() {
    while true; do
        banner
        echo -e "${C}======= Credential Management =======${NC}\n"
        local creds; creds=$(read_creds)

        echo -e "  ${W}SNMP v1/v2c Communities:${NC}"
        echo "$creds" | jq -r '.snmp_communities[]' 2>/dev/null \
            | while read -r c; do echo "    * $c"; done

        echo -e "\n  ${W}SNMP v3 Accounts:${NC}"
        echo "$creds" | jq -r \
            '.snmp_v3[] | "    * \(.username) [\(.auth_proto)/\(.priv_proto)]"' \
            2>/dev/null || echo "    (none)"

        echo -e "\n  ${W}SSH Credentials:${NC}"
        echo "$creds" | jq -r \
            '.ssh_credentials[] | "    * \(.username)"' \
            2>/dev/null || echo "    (none)"

        echo -e "\n  ${W}Telnet Credentials:${NC}"
        echo "$creds" | jq -r \
            '.telnet_credentials[] | "    * \(.username)"' \
            2>/dev/null || echo "    (none)"

        echo -e "\n  ${W}Device Overrides:${NC}"
        echo "$creds" | jq -r \
            '.device_overrides | to_entries[] | "    * \(.key)"' \
            2>/dev/null || echo "    (none)"

        echo ""
        echo "   1) Add SNMP v2c Community"
        echo "   2) Remove SNMP v2c Community"
        echo "   3) Add SNMP v3 Account"
        echo "   4) Add SSH Credential"
        echo "   5) Remove SSH Credential"
        echo "   6) Add Telnet Credential"
        echo "   7) Add/Update Device Override"
        echo "   8) Remove Device Override"
        echo "   9) Import credentials from JSON file"
        echo "  10) Export credentials (plaintext)"
        echo "   0) Back"

        read -rp $'\nChoice: ' choice
        local cred_json v3_entry ssh_entry tn_entry dev_ov
        case "$choice" in
        1)  read -rp "  Community string: " c
            [[ -z "$c" ]] && continue
            write_creds "$(echo "$creds" | jq ".snmp_communities += [\"$c\"]")"
            log_info "Added SNMP community: $c" ;;
        2)  read -rp "  Community to remove: " c
            write_creds "$(echo "$creds" | jq "del(.snmp_communities[] | select(. == \"$c\"))")"
            log_info "Removed: $c" ;;
        3)  read -rp "  Username: " v3u
            read -rp "  Auth protocol [SHA]: " v3ap;  v3ap=${v3ap:-SHA}
            read -rsp "  Auth password: " v3apass;    echo
            read -rp "  Priv protocol [AES]: " v3pp;  v3pp=${v3pp:-AES}
            read -rsp "  Priv password: " v3ppass;    echo
            v3_entry=$(jq -n \
                --arg u "$v3u" --arg ap "$v3ap" --arg apass "$v3apass" \
                --arg pp "$v3pp" --arg ppass "$v3ppass" \
                '{username:$u,auth_proto:$ap,auth_pass:$apass,priv_proto:$pp,priv_pass:$ppass}')
            write_creds "$(echo "$creds" | jq ".snmp_v3 += [$v3_entry]")"
            log_info "Added SNMPv3: $v3u" ;;
        4)  read -rp "  Username: " su
            read -rsp "  Password (blank=key auth): " sp; echo
            read -rp "  SSH key file (blank if using password): " sk
            read -rsp "  Enable password (optional): " sep; echo
            ssh_entry=$(jq -n \
                --arg u "$su" --arg p "$sp" --arg k "$sk" --arg e "$sep" \
                '{username:$u,
                  password:(if $p!="" then $p else null end),
                  key_file:(if $k!="" then $k else null end),
                  enable_pass:(if $e!="" then $e else null end)}')
            write_creds "$(echo "$creds" | jq ".ssh_credentials += [$ssh_entry]")"
            log_info "Added SSH: $su" ;;
        5)  read -rp "  Username to remove: " su
            write_creds "$(echo "$creds" | jq "del(.ssh_credentials[] | select(.username == \"$su\"))")"
            log_info "Removed SSH: $su" ;;
        6)  read -rp "  Telnet username: " tu
            read -rsp "  Telnet password: " tp; echo
            tn_entry=$(jq -n --arg u "$tu" --arg p "$tp" '{username:$u,password:$p}')
            write_creds "$(echo "$creds" | jq ".telnet_credentials += [$tn_entry]")"
            log_info "Added Telnet: $tu" ;;
        7)  read -rp "  Device IP: " dip
            read -rp "  SNMP Community (blank to skip): " dc
            read -rp "  SSH Username (blank to skip): " du
            read -rsp "  SSH Password (blank to skip): " dp; echo
            read -rp "  SSH Key file (blank to skip): " dk
            dev_ov=$(jq -n \
                --arg c "$dc" --arg u "$du" --arg p "$dp" --arg k "$dk" \
                '{snmp_community:(if $c!="" then $c else null end),
                  ssh_username:(if $u!="" then $u else null end),
                  ssh_password:(if $p!="" then $p else null end),
                  ssh_key:(if $k!="" then $k else null end)}')
            write_creds "$(echo "$creds" | jq ".device_overrides[\"$dip\"] = $dev_ov")"
            log_info "Set device override: $dip" ;;
        8)  read -rp "  Device IP to remove: " dip
            write_creds "$(echo "$creds" | jq "del(.device_overrides[\"$dip\"])")"
            log_info "Removed override: $dip" ;;
        9)  read -rp "  JSON file path: " jf
            if [[ -f "$jf" ]]; then
                write_creds "$(cat "$jf")"
                log_info "Imported: $jf"
            else
                echo -e "${R}  File not found${NC}"; sleep 1
            fi ;;
        10) echo -e "${R}  WARNING: Exports plaintext credentials!${NC}"
            confirm "Continue?" || continue
            read -rp "  Output file path: " of
            read_creds > "$of"; chmod 600 "$of"
            log_warn "Credentials exported: $of" ;;
        0)  return ;;
        esac
        pause
    done
}

# -----------------------------------------------------------------------------
# DISCOVERY SETTINGS MENU
# -----------------------------------------------------------------------------
menu_discovery_settings() {
    while true; do
        banner
        echo -e "${C}======= Discovery Settings =======${NC}\n"
        echo -e "  1) Scan Timeout      ${W}${SCAN_TIMEOUT}s${NC}"
        echo -e "  2) SNMP Timeout      ${W}${SNMP_TIMEOUT}s${NC}"
        echo -e "  3) SSH Timeout       ${W}${SSH_TIMEOUT}s${NC}"
        echo -e "  4) Parallel Threads  ${W}${MAX_THREADS}${NC}"
        echo -e "  5) Default Site Name ${W}${DEFAULT_SITE_NAME}${NC}"
        echo -e "  6) NetBox Port       ${W}${NETBOX_PORT}${NC}"
        echo -e "  7) Debug Mode        ${W}$([ $DEBUG_MODE -eq 1 ] && echo ON || echo OFF)${NC}"
        echo -e "  8) Schedule Recurring Scan (cron)"
        echo -e "  9) View Scheduled Scans"
        echo -e "  0) Back"

        read -rp $'\nChoice: ' c
        case "$c" in
        1) read -rp "  Scan timeout (s): "  SCAN_TIMEOUT;        save_config ;;
        2) read -rp "  SNMP timeout (s): "  SNMP_TIMEOUT;        save_config ;;
        3) read -rp "  SSH timeout (s): "   SSH_TIMEOUT;         save_config ;;
        4) read -rp "  Parallel threads: "  MAX_THREADS;         save_config ;;
        5) read -rp "  Site name: "         DEFAULT_SITE_NAME;   save_config ;;
        6) read -rp "  NetBox port: " NETBOX_PORT
           NETBOX_API_URL="http://localhost:${NETBOX_PORT}";     save_config ;;
        7) (( DEBUG_MODE ^= 1 ));                                save_config ;;
        8) read -rp "  Network to scan (CIDR): " snet
           read -rp "  Cron schedule (e.g. 0 2 * * *): " scron
           local entry="${scron} root ${SCRIPT_PATH} --auto-scan '${snet}' >> ${LOG_DIR}/cron.log 2>&1"
           ( crontab -l 2>/dev/null; echo "$entry" ) | crontab -
           log_info "Scheduled: [$scron] $snet" ;;
        9) echo -e "\n${W}Scheduled Scans:${NC}"
           crontab -l 2>/dev/null | grep "netbox-discovery\|auto-scan" \
               || echo "  (none)" ;;
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
        echo -e "${C}======= NetBox Management =======${NC}\n"

        local nb_status="Stopped"
        docker ps --filter "name=netbox" --format "{{.Status}}" 2>/dev/null \
            | grep -q Up && nb_status="Running"

        echo -e "  Status : ${W}${nb_status}${NC}"
        echo -e "  URL    : ${W}${NETBOX_API_URL}${NC}"
        echo -e "  Token  : ${W}${NETBOX_API_TOKEN:-<not set>}${NC}"
        echo ""
        echo "   1) Start NetBox"
        echo "   2) Stop NetBox"
        echo "   3) Restart NetBox"
        echo "   4) View NetBox Logs (live)"
        echo "   5) Set API Token"
        echo "   6) Generate New API Token"
        echo "   7) Backup Database"
        echo "   8) Restore Database"
        echo "   9) Update NetBox"
        echo "  10) Show Container Status"
        echo "   0) Back"

        read -rp $'\nChoice: ' c
        case "$c" in
        1)  cd "$NETBOX_DIR" && docker compose up -d >> "$LOG_FILE" 2>&1
            log_ok "NetBox started" ;;
        2)  confirm "Stop NetBox?" || { pause; continue; }
            cd "$NETBOX_DIR" && docker compose down >> "$LOG_FILE" 2>&1
            log_ok "NetBox stopped" ;;
        3)  cd "$NETBOX_DIR" && docker compose restart >> "$LOG_FILE" 2>&1
            log_ok "NetBox restarted" ;;
        4)  echo -e "${D}(Ctrl+C to exit)${NC}"
            cd "$NETBOX_DIR" && docker compose logs -f --tail=50 netbox ;;
        5)  read -rp "  API Token: " NETBOX_API_TOKEN; save_config ;;
        6)  NETBOX_API_TOKEN=$(cd "$NETBOX_DIR" && \
                docker compose exec -T netbox python manage.py shell -c \
                "from users.models import Token; \
from django.contrib.auth.models import User; \
u=User.objects.get(username='admin'); \
t=Token.objects.create(user=u); print(t.key)" \
                2>/dev/null | tail -1)
            save_config
            echo -e "  New token: ${W}$NETBOX_API_TOKEN${NC}" ;;
        7)  local bk="$BASE_DIR/backup_$(date +%Y%m%d_%H%M%S).sql.gz"
            log_info "Backing up..."
            cd "$NETBOX_DIR" && docker compose exec -T postgres \
                pg_dump -U netbox netbox | gzip > "$bk"
            log_ok "Backup: $bk" ;;
        8)  read -rp "  Backup file (.sql.gz): " bkf
            if [[ -f "$bkf" ]]; then
                confirm "Restore will OVERWRITE the current database. Continue?" || continue
                cd "$NETBOX_DIR"
                docker compose exec -T postgres psql -U netbox -c \
                    "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" \
                    netbox >> "$LOG_FILE" 2>&1
                zcat "$bkf" | docker compose exec -T postgres \
                    psql -U netbox netbox >> "$LOG_FILE" 2>&1
                log_ok "Database restored"
            else
                echo -e "${R}  File not found${NC}"
            fi ;;
        9)  log_info "Updating NetBox..."
            cd "$NETBOX_DIR" && git pull -q \
                && docker compose pull >> "$LOG_FILE" 2>&1
            docker compose up -d >> "$LOG_FILE" 2>&1
            log_ok "Update complete" ;;
        10) cd "$NETBOX_DIR" && docker compose ps ;;
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
        echo -e "${C}======= Log Viewer =======${NC}\n"
        echo "  1) Tail today's log (live)"
        echo "  2) View full today's log"
        echo "  3) List all log files"
        echo "  4) List discovery result files"
        echo "  5) View latest discovery result"
        echo "  6) Search logs"
        echo "  7) Clear today's log"
        echo "  0) Back"

        read -rp $'\nChoice: ' c
        case "$c" in
        1) tail -f "$LOG_FILE" ;;
        2) less "$LOG_FILE" 2>/dev/null || more "$LOG_FILE" ;;
        3) echo -e "\n${W}Log files:${NC}"
           ls -lh "$LOG_DIR"/*.log 2>/dev/null || echo "  (none)" ;;
        4) echo -e "\n${W}Discovery results:${NC}"
           ls -lh "$DISCOVERY_DIR"/results_*.json 2>/dev/null \
               | awk '{print NR") "$NF" "$5}' || echo "  (none)" ;;
        5) local latest
           latest=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
           if [[ -z "$latest" ]]; then echo "  No results found"; pause; continue; fi
           echo -e "\n${W}File  : $latest${NC}"
           local cnt; cnt=$(jq '.hosts | length' "$latest")
           echo -e "${W}Hosts : $cnt${NC}\n"
           printf "  %-16s %-30s %-18s %-16s %s\n" \
               "IP" "Hostname" "Role" "Manufacturer" "OS"
           printf "  %-16s %-30s %-18s %-16s %s\n" \
               "----------------" "------------------------------" \
               "------------------" "----------------" "--------------------"
           jq -r '.hosts[] | [.ip,.hostname,.device_role,.manufacturer,(.os//"N/A")] | @tsv' \
               "$latest" 2>/dev/null \
               | while IFS=$'\t' read -r ip hn role mfr os; do
                   printf "  %-16s %-30s %-18s %-16s %s\n" \
                       "$ip" "${hn:0:29}" "${role:0:17}" "${mfr:0:15}" "${os:0:28}"
                 done | head -80 ;;
        6) read -rp "  Search term: " st
           grep --color=always -i "$st" "$LOG_DIR"/*.log 2>/dev/null | tail -50 ;;
        7) confirm "Clear today's log?" || continue
           > "$LOG_FILE"
           log_info "Log cleared" ;;
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
        echo -e "${C}======= Network Discovery =======${NC}\n"
        echo "  1) Discover Network (CIDR range)"
        echo "  2) Scan Single Host"
        echo "  3) Scan Host List from File"
        echo "  4) Map Switchports (SNMP Bridge MIB)"
        echo "  5) View Latest Results"
        echo "  6) Sync Last Results -> NetBox"
        echo "  7) Full Auto: Discover + Sync"
        echo "  0) Back"

        read -rp $'\nChoice: ' c
        case "$c" in
        1)  read -rp "  Network CIDR (e.g. 192.168.1.0/24): " net
            if valid_cidr "$net" || valid_ip "${net%%/*}"; then
                init_scan_session "$net"
                discover_live_hosts "$net"
                if [[ -s "$LIVE_HOSTS_FILE" ]]; then
                    scan_all_hosts
                    log_ok "Results: $DISC_RESULTS"
                    confirm "  Sync to NetBox now?" && sync_to_netbox "$DISC_RESULTS"
                fi
            else echo -e "${R}  Invalid network${NC}"; fi ;;
        2)  read -rp "  IP address: " sip
            if valid_ip "$sip"; then
                init_scan_session "$sip"
                echo "$sip" > "$LIVE_HOSTS_FILE"
                scan_all_hosts
                echo -e "\n${W}Result:${NC}"
                jq '.hosts[0] | del(.ports,.interfaces,.mac_port_map,.arp_entries)' \
                    "$DISC_RESULTS" 2>/dev/null || cat "$DISC_RESULTS"
            else echo -e "${R}  Invalid IP${NC}"; fi ;;
        3)  read -rp "  Host file (one IP per line): " hf
            if [[ -f "$hf" ]]; then
                init_scan_session "file:$hf"
                grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "$hf" > "$LIVE_HOSTS_FILE"
                local cnt; cnt=$(wc -l < "$LIVE_HOSTS_FILE")
                log_info "Loaded $cnt hosts from $hf"
                scan_all_hosts
                confirm "  Sync to NetBox?" && sync_to_netbox "$DISC_RESULTS"
            else echo -e "${R}  File not found${NC}"; fi ;;
        4)  read -rp "  Switch IP: " swip
            if valid_ip "$swip"; then
                map_switchports "$swip"
            else echo -e "${R}  Invalid IP${NC}"; fi ;;
        5)  local latest
            latest=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
            if [[ -z "$latest" ]]; then echo "  No results yet"; pause; continue; fi
            local cnt; cnt=$(jq '.hosts | length' "$latest")
            echo -e "\n${W}File: $latest  Hosts: $cnt${NC}\n"
            printf "  %-16s %-30s %-18s %-16s %s\n" \
                IP Hostname Role Manufacturer OS
            jq -r '.hosts[] | [.ip,.hostname,.device_role,.manufacturer,(.os//"N/A")] | @tsv' \
                "$latest" 2>/dev/null \
                | while IFS=$'\t' read -r ip hn role mfr os; do
                    printf "  %-16s %-30s %-18s %-16s %s\n" \
                        "$ip" "${hn:0:29}" "${role:0:17}" "${mfr:0:15}" "${os:0:28}"
                  done | head -80 ;;
        6)  sync_to_netbox ;;
        7)  read -rp "  Network CIDR: " net
            if valid_cidr "$net" || valid_ip "${net%%/*}"; then
                init_scan_session "$net"
                discover_live_hosts "$net"
                if [[ -s "$LIVE_HOSTS_FILE" ]]; then
                    scan_all_hosts
                    sync_to_netbox "$DISC_RESULTS"
                fi
            else echo -e "${R}  Invalid network${NC}"; fi ;;
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

        local nb_status="Stopped"
        docker ps --filter "name=netbox" --format "{{.Status}}" 2>/dev/null \
            | grep -q Up && nb_status="Running"
        local dk_status="Missing"
        cmd_exists docker && dk_status="OK"

        echo -e "  NetBox: ${W}${nb_status}${NC}   Docker: ${W}${dk_status}${NC}"
        echo -e "  Token : ${D}${NETBOX_API_TOKEN:0:12}...${NC}"
        echo ""
        echo -e "${C}  +--------------------------------------------+${NC}"
        echo -e "${C}  |${NC}  ${W}1${NC}  Install / Update Dependencies        ${C}|${NC}"
        echo -e "${C}  |${NC}  ${W}2${NC}  Deploy / Update NetBox               ${C}|${NC}"
        echo -e "${C}  |${NC}  ${W}3${NC}  Discovery Settings                   ${C}|${NC}"
        echo -e "${C}  |${NC}  ${W}4${NC}  Manage Credentials                   ${C}|${NC}"
        echo -e "${C}  |${NC}  ${W}5${NC}  Run Network Discovery                ${C}|${NC}"
        echo -e "${C}  |${NC}  ${W}6${NC}  NetBox Management                    ${C}|${NC}"
        echo -e "${C}  |${NC}  ${W}7${NC}  View Logs                            ${C}|${NC}"
        echo -e "${C}  |${NC}  ${W}8${NC}  Quick Setup (Install + Deploy)       ${C}|${NC}"
        echo -e "${C}  |${NC}  ${W}0${NC}  Exit                                 ${C}|${NC}"
        echo -e "${C}  +--------------------------------------------+${NC}"
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
        8) install_deps && deploy_netbox ;;
        0) echo -e "\n  ${G}Goodbye!${NC}\n"
           log_info "Session ended"
           exit 0 ;;
        *) echo -e "  ${R}Invalid choice${NC}"; sleep 1 ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------
main() {
    check_root
    init_dirs
    load_config
    init_creds
    log_info "================================================"
    log_info "NetBox Discovery Suite v${SCRIPT_VERSION} started"
    log_info "User: $(id -un)  PID: $$"
    log_info "================================================"

    # Non-interactive cron mode
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

    # Non-interactive single-host mode
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
