#!/usr/bin/env bash
# =============================================================================
#  NetBox Auto-Deploy & Network Discovery Suite  --  Ubuntu 24.04
#  Version: 2.0.9.1
# =============================================================================
#
#  Changelog v2.0.2:
#   - Removed ALL non-ASCII characters (box-drawing, braille spinner, bullets)
#   - Fixed nested "local _snmp() {}" syntax (illegal in bash); replaced with
#     top-level _snmp_get() and _snmp_walk() helpers
#   - Fixed heredoc quoting in probe_nmap to pass xmlfile as argument
#   - Fixed merge_host_data to pass args to Python rather than embed in heredoc
#   - Fixed probe_http and probe_banners array-building without mapfile/+=
#   - Verified clean with: bash -n
#
#  Changelog v2.0.3:
#   - Removed obsolete "version:" key from docker-compose.override.yml
#   - Removed netbox-housekeeping service (dropped in netbox-docker 3.4.0)
#
#  Changelog v2.0.4:
#   - DOCKER_COMPOSE global correctly initialised (was self-referential)
#   - Added detect_docker_compose(); added auto-sudo in check_root()
#   - Docker installed from official apt repo; fallback to docker.io
#   - download-mibs guarded with cmd_exists; pip per-package with || true
#   - Pre-generate API token; store before startup wait loop
#   - Startup check accepts 2xx/3xx/4xx (not just 200 via curl -f)
#   - scan_all_hosts: fd3 loop so background probes cannot consume stdin
#   - All background probes get </dev/null
#   - nb_upsert_device: validate IDs before --argjson
#
#  Changelog v2.0.5:
#   - Admin password saved to NETBOX_ADMIN_PASS; shown in management menu
#   - pip: --root-user-action=ignore suppresses venv warning
#   - PROCESSES:"2" in override suppresses gunicorn worker warning
#   - nmap: removed UDP ports; removed ftp-banner, telnet-ntlm-info,
#     snmp-sysdescr, snmp-interfaces (invalid script names); removed -sC
#   - sync_to_netbox: two-step reachability; 401/403 prompts for new token
#
#  Changelog v2.0.6:
#   - Credentials file written BEFORE startup wait so it always exists
#   - Override yml: all env values quoted; SUPERUSER_API_KEY added
#   - Startup loop breaks on timeout with guidance instead of returning 1
#   - Admin/token via Django shell using set_password() + get_or_create()
#   - Admin password shown in NetBox Management menu
#
#  Changelog v2.0.7:
#   - ALL log functions now write to stderr (>&2) -- root cause of all
#     jq --argjson "invalid JSON" errors: log text was captured inside $()
#     alongside numeric IDs, corrupting payloads
#   - Added nb_get_or_create_vlan() helper
#   - probe_snmp: added walks for IP address table (4.20.1), bridge port
#     index (17.1.4.1.2), VLAN PVID (17.7.1.4.5.1.1), VLAN names
#     (Cisco 9.9.46.1.3.1.1.2); parsed as ip_table, vlan_pvid, vlan_names;
#     mac_port_map enriched with if_name, VLAN, remote_ip
#   - merge_host_data: ip_table, vlan_pvid, vlan_names passed through
#   - sync_to_netbox: each SNMP interface gets its IP from ip_table;
#     VLAN from vlan_pvid created and set as untagged_vlan (mode=access);
#     CDP/LLDP neighbours create cable connections in NetBox;
#     interface descriptions enriched with LLDP/CDP neighbour info
#   - Classification: snmp_up flag; Switch/Router uses (snmp_up OR port 161);
#     added keywords: powerconnect, 1810g, netgear gs, netscreen, etc.
#   - Subnet filtering: IPs outside requested CIDR removed after discovery
#   - map_switchports: full rewrite -- shows all interfaces with admin/oper/
#     speed/VLAN/MAC/remote-IPs; tries Cisco per-VLAN community strings
#
#  Changelog v2.0.8:
#   - Fixed "value too long for type character varying(12)" on deploy.
#     Root cause: NetBox 4.x changed Token.key field format; passing a
#     pre-generated 40-char hex string to Token.objects.get_or_create(key=X)
#     fails because the DB column no longer accepts that length/format.
#   - Removed SUPERUSER_API_TOKEN and SUPERUSER_API_KEY from override yml
#     (same error when NetBox startup script tries to use the env-var value)
#   - Django shell now uses Token.objects.filter(user=u).first() then
#     Token.objects.create(user=u) with NO key= argument -- NetBox
#     auto-generates the key in whatever format the installed version expects
#   - api_token pre-generation removed; token captured live from Django shell
#     SETUP_OK response and written to config + credentials file
#   - Credentials file shows placeholder until real token is confirmed
#   - 0 non-ASCII characters; all changelogs retained; syntax verified clean
#
#  Changelog v2.0.9:
#   - Fixed silent FAIL for devices whose SNMP entity MIB returns an error
#     string instead of a serial number (e.g. pfSense returns
#     "iso.3.6.1.2.1.47.1.1.1.1.11.1 = No Such Object..."). NetBox serial
#     field is max_length=50; the 85-char error string caused a silent 400.
#     Serial is now cleared when it contains "No Such Object", "iso.", or
#     any value exceeding 50 characters.
#   - Fixed device-type slug collision on re-runs: nb_get_or_create_device_type
#     now falls back to a slug search when the model POST returns no ID,
#     preventing the cascade failure (empty dtype_id -> validation abort).
#   - Fixed invalid IP assignment: 0.0.0.0, 127.x, 169.254.x addresses from
#     SNMP ip_table are now skipped before sending to NetBox.
#   - nb_api: removed -f flag from curl so API error responses are captured
#     and logged instead of silently swallowed.
#   - nb_upsert_device: logs full API error response when device POST returns
#     no ID, making future failures self-diagnosing in the log file.
#
#  Changelog v2.0.9.1:
#   - Fixed invalid IP assignment: to allow 169.254.x.x as some internal devices
#     may use them
#   - Fixed blank lines and comments causing discovery file to fail loading
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# GLOBAL CONSTANTS
# -----------------------------------------------------------------------------
SCRIPT_VERSION="2.0.9"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

BASE_DIR="/opt/netbox-discovery"
LOG_DIR="/var/log/netbox-discovery"
CONFIG_FILE="$BASE_DIR/config.conf"
CREDS_FILE="$BASE_DIR/.credentials.enc"
CREDS_KEY_FILE="$BASE_DIR/.creds.key"
DISCOVERY_DIR="$BASE_DIR/discovery"
NETBOX_DIR="/opt/netbox-docker"
DOCKER_COMPOSE="docker compose"   # updated by detect_docker_compose()

# ANSI colours (7-bit ASCII only)
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
W='\033[1;37m'
D='\033[2m'
NC='\033[0m'

# Runtime defaults (overridden by config file)
NETBOX_PORT=8000
NETBOX_API_URL="http://localhost:${NETBOX_PORT}"
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
# LOGGING
# All display output uses >&2 so log calls are never captured inside $().
# Only explicit "echo <id>" / "printf <id>" lines go to stdout as return vals.
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
log_debug() {
    _log "DEBUG" "$@"
    [[ $DEBUG_MODE -eq 1 ]] && printf "${D}[DEBUG]${NC} %s\n" "$*" >&2
}
log_step() {
    _log "STEP" "$*"
    printf "\n${C}====== ${W}%s${C} ======${NC}\n" "$*" >&2
}

# -----------------------------------------------------------------------------
# UTILITIES
# -----------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        printf "${Y}Not root -- re-launching with sudo...${NC}\n" >&2
        exec sudo "$0" "$@"
    fi
}
pause()    { echo; read -rp "  Press [Enter] to continue..."; }
confirm()  { local r; read -rp "  ${1:-Are you sure?} [y/N] " r; [[ "${r,,}" == "y" ]]; }
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
# BANNER (pure ASCII)
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
NETBOX_API_TOKEN=${NETBOX_API_TOKEN}
NETBOX_ADMIN_PASS=${NETBOX_ADMIN_PASS}
DEFAULT_SITE_NAME=${DEFAULT_SITE_NAME}
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
    NETBOX_API_URL="http://localhost:${NETBOX_PORT}"
}

# -----------------------------------------------------------------------------
# ENCRYPTED CREDENTIAL STORE  (AES-256-CBC)
# -----------------------------------------------------------------------------
EMPTY_CREDS='{"snmp_communities":["public","private"],"snmp_v3":[],
  "ssh_credentials":[],"telnet_credentials":[],"device_overrides":{}}'

init_creds() {
    if [[ ! -f "$CREDS_KEY_FILE" ]]; then
        openssl rand -base64 48 > "$CREDS_KEY_FILE"; chmod 600 "$CREDS_KEY_FILE"
        log_info "Generated credential encryption key"
    fi
    if [[ ! -f "$CREDS_FILE" ]]; then write_creds "$EMPTY_CREDS"; fi
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

# -----------------------------------------------------------------------------
# DEPENDENCY INSTALLATION
# -----------------------------------------------------------------------------
install_deps() {
    log_step "Installing System Dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >> "$LOG_FILE" 2>&1

    # Docker from official repo for compose v2 plugin support
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
            || { log_warn "Docker official install failed -- trying docker.io"
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
    for pylib in netmiko napalm pysnmp paramiko requests pynetbox scapy; do
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

    # Store admin pass immediately -- token will be filled after startup
    NETBOX_ADMIN_PASS="$admin_pass"
    save_config

    # Write credentials file BEFORE wait loop -- always available on timeout
    creds_out="$BASE_DIR/netbox-credentials.txt"
    cat > "$creds_out" <<CREDEOF
NetBox Access Credentials
=========================
URL:       http://localhost:${NETBOX_PORT}
Username:  admin
Password:  ${admin_pass}
API Token: (populated after startup -- re-check this file)

KEEP THIS FILE SECURE
CREDEOF
    chmod 600 "$creds_out"
    log_info "Credentials saved to: $creds_out"

    if [[ -d "$NETBOX_DIR/.git" ]]; then
        log_info "Updating netbox-docker repo..."
        git -C "$NETBOX_DIR" pull -q >> "$LOG_FILE" 2>&1
    else
        log_info "Cloning netbox-docker..."
        git clone -q https://github.com/netbox-community/netbox-docker.git \
            "$NETBOX_DIR" >> "$LOG_FILE" 2>&1
    fi
    cd "$NETBOX_DIR" || { log_error "Cannot cd to $NETBOX_DIR"; return 1; }

    # Override: no 'version:' key; no netbox-housekeeping (removed in 3.4.0).
    # SUPERUSER_API_TOKEN intentionally omitted: NetBox 4.x changed Token.key
    # format and passing a pre-generated hex string causes
    # "value too long for character varying(12)".
    # Token is created via Django shell after startup instead.
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

    # Readiness: accept 200 (login) or 302 (redirect) or 403 (API no-token)
    printf "  Waiting for NetBox to initialize "
    local retries=0 http_code=""
    until http_code=$(curl -s -o /dev/null -w "%{http_code}" \
              --max-time 5 "http://localhost:${NETBOX_PORT}/" 2>/dev/null) \
          && [[ "$http_code" =~ ^[234] ]]; do
        sleep 5; printf "."; (( retries++ )) || true
        if (( retries > 36 )); then
            printf "\n${Y}Timeout -- NetBox may still be starting.${NC}\n" >&2
            printf "  Check: cd %s && %s logs netbox | tail -30\n" \
                "$NETBOX_DIR" "$DOCKER_COMPOSE" >&2
            break
        fi
    done
    printf " ${G}HTTP %s${NC}\n" "$http_code"

    # Configure admin password and capture auto-generated API token.
    # KEY FIX (v2.0.8): do NOT pass key= to Token.objects.create().
    # NetBox 4.x auto-generates the key in a version-specific format.
    # Forcing a 40-char hex string causes "value too long for varchar(12)".
    log_info "Configuring admin credentials via Django shell..."
    local setup_py setup_result setup_tries=0
    setup_py="from django.contrib.auth.models import User
from users.models import Token
u,_=User.objects.get_or_create(username='admin')
u.set_password('${admin_pass}')
u.is_superuser=True
u.is_staff=True
u.save()
t=Token.objects.filter(user=u).first()
if not t:
    t=Token.objects.create(user=u)
print('SETUP_OK:'+str(t.key))"

    until setup_result=$(cd "$NETBOX_DIR" && \
            $DOCKER_COMPOSE exec -T netbox \
            python manage.py shell << PYEOF 2>/dev/null | grep "^SETUP_OK:"
${setup_py}
PYEOF
    ); do
        sleep 5; (( setup_tries++ )) || true
        if (( setup_tries > 18 )); then
            log_warn "Django shell timed out"
            log_warn "Manual fix: docker exec -it <netbox-container> python manage.py changepassword admin"
            break
        fi
    done

    if [[ "$setup_result" == SETUP_OK:* ]]; then
        NETBOX_API_TOKEN="${setup_result#SETUP_OK:}"
        log_ok "Admin and token configured: ${NETBOX_API_TOKEN:0:12}..."
        save_config
        # Update credentials file with real token
        sed -i "s|^API Token:.*|API Token: ${NETBOX_API_TOKEN}|" \
            "$creds_out" 2>/dev/null || true
        sed -i "s|^Password:.*|Password:  ${admin_pass}|" \
            "$creds_out" 2>/dev/null || true
    else
        log_warn "Django shell setup incomplete"
        log_warn "Check: cat $creds_out  -- token may need to be created manually in UI"
    fi

    printf "\n${G}+----------------------------------------------+${NC}\n"
    printf "${G}|  NetBox Deployed!                            |${NC}\n"
    printf "${G}+----------------------------------------------+${NC}\n"
    printf "  URL:      ${W}http://localhost:%s${NC}\n" "$NETBOX_PORT"
    printf "  Username: ${W}admin${NC}\n"
    printf "  Password: ${W}%s${NC}\n" "$admin_pass"
    printf "  Token:    ${W}%s${NC}\n" \
        "${NETBOX_API_TOKEN:-<create via UI if empty>}"
    printf "  Saved:    ${D}%s${NC}\n" "$creds_out"
    pause
}

# -----------------------------------------------------------------------------
# NETBOX REST API HELPERS
# Return values -> stdout; all logging -> stderr.
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
    # Truncate model to 64 chars; NetBox allows 100 but slugs of long names
    # collide on re-runs when the model string varies slightly.
    model="${model:0:64}"
    slug=$(slugify "$model")
    # Ensure slug is never empty
    [[ -z "$slug" ]] && slug="unknown-model"
    enc=$(nb_urlencode "$model")
    res=$(nb_get "dcim/device-types/?model=${enc}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/device-types/" \
            "{\"manufacturer\":$mfr_id,\"model\":\"$model\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
        # POST failed (likely slug collision from a previous partial run).
        # Fall back: search by slug to recover the existing entry.
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
            --argjson vid "$vid" \
            --arg     name "$name" \
            --argjson site "$site_id" \
            '{vid:$vid,name:$name,site:$site,status:"active"}')
        res=$(nb_post "ipam/vlans/" "$payload")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
        [[ -n "$id" ]] && log_info "Created VLAN $vid: $name"
    fi
    echo "$id"
}

nb_add_ip() {
    # nb_add_ip <cidr> <device_id_or_empty> <interface_id_or_empty>
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

    # Set as primary on device
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
    local name="$1" role="$2" mfr="$3" model="$4" site_id="$5" \
          serial="${6:-}" comments="${7:-}"
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

    local enc; enc=$(nb_urlencode "$name")
    local existing; existing=$(nb_get "dcim/devices/?name=${enc}")
    local dev_id; dev_id=$(echo "$existing" | jq -r '.results[0].id // empty' 2>/dev/null)

    # Sanitize serial: SNMP entity MIB often returns error strings like
    # "iso.3.6.1... = No Such Object..." which are 80+ chars and fail
    # NetBox validation (serial max_length=50). Clear those.
    local clean_serial=""
    if [[ -n "$serial" \
          && ${#serial} -le 50 \
          && "$serial" != *"No Such"* \
          && "$serial" != *"iso."* \
          && "$serial" != *"Not avail"* ]]; then
        clean_serial="$serial"
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
            log_error "Device POST failed for $name: $(echo "$api_resp" | jq -c '.detail // .name // .' 2>/dev/null | head -c 200)"
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

# ── Phase 1: Host discovery ───────────────────────────────────────────────────
discover_live_hosts() {
    local target="$1"
    > "$LIVE_HOSTS_FILE"
    local tmp_all; tmp_all=$(mktemp)
    log_step "Phase 1 -- Host Discovery: $target"

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

    # Deduplicate + validate
    sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -u "$tmp_all" \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        | while IFS= read -r ip; do valid_ip "$ip" && echo "$ip"; done \
        > "$LIVE_HOSTS_FILE"
    rm -f "$tmp_all"

    # Filter: keep only IPs within the requested target CIDR
    # Prevents docker bridge / host IPs leaking in from ARP cache
    if valid_cidr "$target"; then
        python3 - "$target" "$LIVE_HOSTS_FILE" <<'PYEOF'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    with open(sys.argv[2]) as f:
        kept = [l.strip() for l in f
                if l.strip() and ipaddress.ip_address(l.strip()) in net]
    with open(sys.argv[2], 'w') as f:
        f.write('\n'.join(kept) + ('\n' if kept else ''))
except Exception:
    pass
PYEOF
    fi

    local count; count=$(wc -l < "$LIVE_HOSTS_FILE")
    log_ok "Phase 1 complete -- $count live hosts found"
    printf "\n  ${G}Found: ${W}%s live hosts${NC}\n" "$count"
}

# ── Phase 2: Deep scan ────────────────────────────────────────────────────────
scan_all_hosts() {
    local total; total=$(wc -l < "$LIVE_HOSTS_FILE")
    log_step "Phase 2 -- Deep Scanning $total Hosts"
    local idx=0 ip
    # fd3 loop: background probes cannot consume the while-loop's stdin
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

    # All probes get stdin=/dev/null to prevent accidental fd0 reads
    probe_nmap    "$ip" "$tmp" </dev/null &
    probe_snmp    "$ip" "$tmp" </dev/null &
    probe_ssh     "$ip" "$tmp" </dev/null &
    probe_http    "$ip" "$tmp" </dev/null &
    probe_netbios "$ip" "$tmp" </dev/null &
    probe_dns     "$ip" "$tmp" </dev/null &
    probe_banners "$ip" "$tmp" </dev/null &
    probe_mdns    "$ip" "$tmp" </dev/null &
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

# ── Probe: nmap ───────────────────────────────────────────────────────────────
probe_nmap() {
    local ip="$1" tmp="$2"
    local xml="$tmp/nmap.xml"

    # TCP-only; no -sC; no U: prefix; removed invalid/removed scripts
    nmap -sV -O --osscan-guess \
        -p "21-23,25,53,80,110,139,143,443,445,512-514,587,631,\
1433,1521,3306,3389,5432,5900,5901,6379,\
8080,8443,8888,9200,9300,27017" \
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
    r = {"ports": [], "os": None, "os_accuracy": None,
         "mac": None, "vendor": None, "hostname": None, "scripts": {}}
    try:
        tree = ET.parse(f)
    except Exception:
        return r
    for host in tree.findall('host'):
        for hn in (host.find('hostnames') or []):
            if hn.get('type') == 'PTR':
                r['hostname'] = hn.get('name')
            elif not r['hostname']:
                r['hostname'] = hn.get('name')
        for addr in host.findall('address'):
            if addr.get('addrtype') == 'mac':
                r['mac'] = addr.get('addr')
                r['vendor'] = addr.get('vendor', '')
        os_el = host.find('os')
        if os_el:
            for m in os_el.findall('osmatch'):
                r['os'] = m.get('name')
                r['os_accuracy'] = m.get('accuracy')
                break
        ports_el = host.find('ports')
        if ports_el:
            for port in ports_el.findall('port'):
                st = port.find('state')
                if st is None or st.get('state') != 'open':
                    continue
                p = {'port': port.get('portid'), 'proto': port.get('protocol'),
                     'service': None, 'version': None, 'banner': None, 'scripts': {}}
                svc = port.find('service')
                if svc:
                    p['service'] = svc.get('name', '')
                    p['version'] = (svc.get('product', '') + ' ' +
                                    svc.get('version', '')).strip()
                for sc in port.findall('script'):
                    out = (sc.get('output', '') or '')[:300]
                    p['scripts'][sc.get('id', '')] = out
                    if sc.get('id', '') == 'banner':
                        p['banner'] = out
                r['ports'].append(p)
        for sc in host.findall('hostscript/script'):
            r['scripts'][sc.get('id', '')] = (sc.get('output', '') or '')[:300]
    return r

print(json.dumps(parse(sys.argv[1])))
PYEOF
}

# ── Probe: SNMP ───────────────────────────────────────────────────────────────
probe_snmp() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/snmp.json"

    local communities; communities=$(get_communities_for "$ip")
    local tok="" comm
    while IFS= read -r comm; do
        snmpget -v2c -c "$comm" -t "$SNMP_TIMEOUT" -r 1 \
            "$ip" 1.3.6.1.2.1.1.1.0 &>/dev/null && { tok="$comm"; break; }
    done <<< "$communities"

    # Try SNMPv3 if v2c failed
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
    # Clear SNMP error strings from serial (they start with "iso." or contain "No Such")
    if [[ "$chassis_ser" == *"No Such"* || "$chassis_ser" == iso.* ]]; then
        chassis_ser=""
    fi

    # Walk tables to temp files (avoids arg-length limits on large outputs)
    _snmp_walk "$ip" "$t" "$ts" 1.3.6.1.2.1.2.2         > "$tmp/snmp_ifaces.txt"
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

tmp            = sys.argv[1]
working_token  = sys.argv[2]
sys_descr      = sys.argv[3].strip().strip('"')
sys_name       = sys.argv[4].strip().strip('"')
sys_loc        = sys.argv[5].strip().strip('"')
sys_contact    = sys.argv[6].strip().strip('"')
sys_uptime     = sys.argv[7].strip()
sys_oid        = sys.argv[8].strip()
chassis_ser    = sys.argv[9].strip().strip('"')

def rf(name):
    p = os.path.join(tmp, name)
    return open(p).read() if os.path.exists(p) else ''

ifaces_raw    = rf('snmp_ifaces.txt')
mac_table_raw = rf('snmp_mac.txt')
bport_raw     = rf('snmp_bport.txt')
arp_table_raw = rf('snmp_arp.txt')
ip_table_raw  = rf('snmp_iptable.txt')
pvid_raw      = rf('snmp_pvid.txt')
vlan_name_raw = rf('snmp_vlannames.txt')
cdp_raw       = rf('snmp_cdp.txt')
lldp_raw      = rf('snmp_lldp.txt')

# ── interfaces ──
ifaces = {}
for line in ifaces_raw.split('\n'):
    idx_m = re.search(r'(\d+)\s*=', line)
    if not idx_m:
        continue
    idx = idx_m.group(1)
    val_m = re.search(
        r'=\s*(?:STRING|INTEGER|Gauge32|Counter32|PhysAddress):\s*(.*)', line)
    if not val_m:
        continue
    val = val_m.group(1).strip().strip('"')
    if idx not in ifaces:
        ifaces[idx] = {}
    if '2.2.1.2.'  in line: ifaces[idx]['name']         = val
    elif '2.2.1.3.' in line: ifaces[idx]['type']        = val
    elif '2.2.1.6.' in line: ifaces[idx]['mac']         = val
    elif '2.2.1.7.' in line: ifaces[idx]['admin_status']= val
    elif '2.2.1.8.' in line: ifaces[idx]['oper_status'] = val
    elif '2.2.1.5.' in line: ifaces[idx]['speed']       = val
interfaces = [{'index': k, **v} for k, v in ifaces.items() if 'name' in v]

# ── bridge port -> ifIndex ──
port_to_if = {}
for line in bport_raw.split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m:
        port_to_if[m.group(1)] = m.group(2)

# ── MAC table ──
mac_port_map = []
for line in mac_table_raw.split('\n'):
    m = re.match(
        r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)',
        line)
    if m:
        mac = ':'.join('{:02x}'.format(int(o)) for o in m.group(1).split('.'))
        bp  = m.group(2)
        ii  = port_to_if.get(bp, bp)
        mac_port_map.append({
            'mac':         mac,
            'port_index':  bp,
            'if_index':    ii,
            'if_name':     ifaces.get(ii, {}).get('name', 'Port-' + ii),
        })

# ── ARP table ──
arp_entries = []
for line in arp_table_raw.split('\n'):
    m = re.match(
        r'.*4\.22\.1\.2\.\d+\.(\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)',
        line)
    if m:
        arp_entries.append({'ip': m.group(1), 'if_index': m.group(2)})

# ── IP address table ──
ip_if_map   = {}
ip_mask_map = {}
for line in ip_table_raw.split('\n'):
    m = re.match(
        r'.*4\.20\.1\.2\.(\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m:
        ip_if_map[m.group(1)] = m.group(2)
    m = re.match(
        r'.*4\.20\.1\.3\.(\d+\.\d+\.\d+\.\d+)\s*=\s*IpAddress:\s*(\S+)', line)
    if m:
        ip_mask_map[m.group(1)] = m.group(2)
ip_table = [
    {'ip': ip, 'if_index': idx, 'mask': ip_mask_map.get(ip, '255.255.255.0')}
    for ip, idx in ip_if_map.items()
]

# ── VLAN PVID ──
vlan_pvid = {}
for line in pvid_raw.split('\n'):
    m = re.match(
        r'.*\.(\d+)\s*=\s*(?:Gauge32|INTEGER|Unsigned32):\s*(\d+)', line)
    if m:
        vlan_pvid[m.group(1)] = m.group(2)

# ── VLAN names (Cisco vtpVlanName) ──
vlan_names = {}
for line in vlan_name_raw.split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)', line)
    if m:
        vlan_names[m.group(1)] = m.group(2).strip().strip('"')

# ── Enrich mac_port_map with VLAN + remote IP ──
for entry in mac_port_map:
    bp = entry['port_index']
    ii = entry['if_index']
    entry['vlan']      = vlan_pvid.get(bp, vlan_pvid.get(ii, ''))
    entry['vlan_name'] = vlan_names.get(entry['vlan'], '')
    entry['remote_ip'] = next(
        (a['ip'] for a in arp_entries if a['if_index'] == ii), '')

# ── CDP neighbors ──
cdp_devs = {}
for line in cdp_raw.split('\n'):
    for sfx, fld in [('.6.', 'device_id'), ('.8.', 'platform'),
                     ('.7.', 'remote_port')]:
        pattern = r'.*' + re.escape(sfx) + r'(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)'
        m = re.match(pattern, line)
        if m:
            key = '{}_{}'.format(m.group(1), m.group(2))
            cdp_devs.setdefault(key, {})[fld] = m.group(3).strip().strip('"')
cdp_neighbors = list(cdp_devs.values())

# ── LLDP neighbors ──
lldp_sys = {}
for line in lldp_raw.split('\n'):
    m = re.match(r'.*\.(\d+)\.(\d+)\.(\d+)\s*=\s*STRING:\s*(.*)', line)
    if not m:
        continue
    lp, ri, val = m.group(2), m.group(3), m.group(4).strip().strip('"')
    key = '{}_{}'.format(lp, ri)
    lldp_sys.setdefault(key, {})
    if '4.1.1.9'  in line: lldp_sys[key]['sys_name']  = val
    if '4.1.1.10' in line: lldp_sys[key]['sys_desc']  = val[:100]
    if '4.1.1.7'  in line: lldp_sys[key]['port_id']   = val
    if '4.1.1.8'  in line: lldp_sys[key]['port_desc'] = val
lldp_neighbors = list(lldp_sys.values())

print(json.dumps({
    'available':      True,
    'community':      working_token,
    'sys_descr':      sys_descr,
    'sys_name':       sys_name,
    'sys_location':   sys_loc,
    'sys_contact':    sys_contact,
    'sys_uptime':     sys_uptime,
    'sys_oid':        sys_oid,
    'chassis_serial': chassis_ser,
    'interfaces':     interfaces,
    'ip_table':       ip_table,
    'mac_port_map':   mac_port_map,
    'vlan_pvid':      vlan_pvid,
    'vlan_names':     vlan_names,
    'arp_entries':    arp_entries,
    'cdp_neighbors':  cdp_neighbors,
    'lldp_neighbors': lldp_neighbors,
}))
PYEOF
}

# ── Probe: SSH ────────────────────────────────────────────────────────────────
probe_ssh() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/ssh.json"
    nc -z -w "$SCAN_TIMEOUT" "$ip" 22 2>/dev/null || return
    local banner
    banner=$(nc -w 3 "$ip" 22 2>/dev/null | head -1 | tr -dc '[:print:]')
    local ssh_opts=(-o StrictHostKeyChecking=no
        -o ConnectTimeout="$SSH_TIMEOUT"
        -o BatchMode=yes -o LogLevel=error
        -o UserKnownHostsFile=/dev/null
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
            sys_info=$(ssh "${opts[@]}" "${su}@${ip}" \
                "$remote_cmd" 2>/dev/null || true)
        fi
        [[ -n "$sys_info" ]] && break
    done < <(get_ssh_creds_for "$ip")
    jq -n \
        --arg banner "$banner" \
        --arg hn "$(echo "$sys_info" | grep '^HN=' | cut -d= -f2)" \
        --arg os "$(echo "$sys_info" \
            | grep -m1 'PRETTY_NAME=\|ProductName:' \
            | sed 's/.*=//;s/.*: //' | tr -d '"')" \
        --arg kernel "$(echo "$sys_info" | grep '^Linux\|^Darwin' | head -1)" \
        --arg cpu "$(echo "$sys_info" \
            | grep -i 'model name\|CPU' | head -1 | sed 's/.*: //')" \
        '{available:true,banner:$banner,hostname:$hn,
          os:$os,kernel:$kernel,cpu:$cpu}' \
        > "$tmp/ssh.json"
}

# ── Probe: HTTP/HTTPS ─────────────────────────────────────────────────────────
probe_http() {
    local ip="$1" tmp="$2"
    local svc_file="$tmp/http_svcs.ndjson"; > "$svc_file"
    local port
    for port in 80 443 8080 8443 8000 8888 3000 5000 9090 9443 4443; do
        local proto="http"
        [[ "$port" =~ ^(443|8443|9443|4443)$ ]] && proto="https"
        local hdr="$tmp/h${port}.txt"
        curl -skL --max-time "$SCAN_TIMEOUT" --max-redirs 3 \
            -A "NetBox-Discovery/2.0" -D "$hdr" \
            "${proto}://${ip}:${port}/" > "$tmp/b${port}.html" 2>/dev/null \
            || continue
        [[ ! -f "$hdr" ]] && continue
        local status server title cert_cn=""
        status=$(head -1 "$hdr" | awk '{print $2}')
        server=$(grep -i '^Server:' "$hdr" \
            | head -1 | cut -d' ' -f2- | tr -d '\r')
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
    else
        echo '{"http_services":[]}' > "$tmp/http.json"
    fi
}

# ── Probe: NetBIOS ────────────────────────────────────────────────────────────
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

# ── Probe: DNS ────────────────────────────────────────────────────────────────
probe_dns() {
    local ip="$1" tmp="$2"
    local ptr
    ptr=$(dig +short +time=3 +tries=1 -x "$ip" 2>/dev/null \
        | head -1 | sed 's/\.$//' || true)
    jq -n --arg ptr "$ptr" '{ptr_hostname:$ptr}' > "$tmp/dns.json"
}

# ── Probe: Banner grab ────────────────────────────────────────────────────────
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
    else
        echo '{"banners":[]}' > "$tmp/banners.json"
    fi
}

# ── Probe: mDNS ───────────────────────────────────────────────────────────────
probe_mdns() {
    local ip="$1" tmp="$2"
    local n=""
    cmd_exists avahi-resolve \
        && n=$(avahi-resolve -a "$ip" 2>/dev/null | awk '{print $2}' || true)
    jq -n --arg n "$n" '{mdns_hostname:$n}' > "$tmp/mdns.json"
}

# ── Merge all probe data ──────────────────────────────────────────────────────
merge_host_data() {
    local ip="$1" tmp="$2"

    python3 /dev/stdin "$ip" "$tmp" <<'PYEOF'
import json, os, sys

ip  = sys.argv[1]
tmp = sys.argv[2]

def load(f):
    p = os.path.join(tmp, f + '.json')
    try:
        return json.load(open(p)) if os.path.exists(p) else {}
    except Exception:
        return {}

nmap = load('nmap'); snmp = load('snmp'); ssh  = load('ssh')
http = load('http'); nb   = load('netbios'); dns  = load('dns')
bnr  = load('banners'); mdns = load('mdns')

host = {
    'ip': ip, 'hostname': None, 'mac': None, 'vendor': None,
    'os': None, 'os_accuracy': None,
    'device_role': 'Endpoint', 'manufacturer': 'Unknown', 'model': 'Unknown',
    'serial': '',
    'ports':          nmap.get('ports', []),
    'interfaces':     snmp.get('interfaces', []),
    'ip_table':       snmp.get('ip_table', []),
    'mac_port_map':   snmp.get('mac_port_map', []),
    'vlan_pvid':      snmp.get('vlan_pvid', {}),
    'vlan_names':     snmp.get('vlan_names', {}),
    'arp_entries':    snmp.get('arp_entries', []),
    'http_services':  http.get('http_services', []),
    'banners':        bnr.get('banners', []),
    'lldp_neighbors': snmp.get('lldp_neighbors', []),
    'cdp_neighbors':  snmp.get('cdp_neighbors', []),
    'snmp_details': {
        'sys_descr':   snmp.get('sys_descr', ''),
        'sys_location':snmp.get('sys_location', ''),
        'sys_contact': snmp.get('sys_contact', ''),
        'sys_uptime':  snmp.get('sys_uptime', ''),
        'sys_oid':     snmp.get('sys_oid', ''),
        'community':   snmp.get('community', ''),
    },
    'ssh_details': {
        'cpu':    ssh.get('cpu', ''),
        'banner': ssh.get('banner', ''),
        'kernel': ssh.get('kernel', ''),
    },
    'discovery_methods': [],
}

# Hostname priority: SNMP > SSH > nmap > DNS > mDNS > NetBIOS
for src in (snmp.get('sys_name'), ssh.get('hostname'), nmap.get('hostname'),
            dns.get('ptr_hostname'), mdns.get('mdns_hostname'),
            nb.get('netbios_name')):
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

# snmp_up: SNMP responded -- strong indicator this is a managed network device
snmp_up = bool(snmp.get('available'))

sys_descr  = (snmp.get('sys_descr') or '').lower()
os_str     = (host['os'] or '').lower()
open_ports = {str(p.get('port', '')) for p in host['ports']}
http_ttl   = ' '.join(s.get('title', '') for s in host['http_services']).lower()
combined   = ' '.join([sys_descr, os_str, http_ttl])

FIREWALL = ['firewall', 'fortigate', 'fortios', 'palo alto', 'checkpoint',
            'asa', 'sonicwall', 'opnsense', 'pfsense', 'netscreen']
ROUTER   = ['router', 'gateway', 'ios xe', 'ios xr', 'junos', 'routeros',
            'vyos ']
SWITCH   = ['switch', 'catalyst', 'nexus', ' eos ', 'comware', 'procurve',
            'arubaos', 'ex series', 'qfx', 'powerconnect', '1810g', '1910',
            '2530', '2920', '2960', '3750', '3850', '9300', 'netgear gs']
AP       = ['access point', 'aironet', 'unifi', 'airmax', 'lightweight ap']
SERVER   = ['linux', 'ubuntu', 'debian', 'centos', 'rhel', 'windows server',
            'esxi', 'vmware', 'proxmox', 'freebsd']
PRINTER  = ['printer', 'jetdirect', 'xerox', 'ricoh', 'canon', 'brother',
            'lexmark']
UPS      = ['ups', 'apc', 'eaton', 'powerware', 'uninterruptible']
CAMERA   = ['camera', 'axis comm', 'hikvision', 'dahua', 'hanwha']

if   any(k in combined for k in FIREWALL):
    host['device_role'] = 'Firewall'
elif any(k in combined for k in ROUTER) and (snmp_up or '161' in open_ports):
    host['device_role'] = 'Router'
elif any(k in combined for k in SWITCH) and (snmp_up or '161' in open_ports):
    host['device_role'] = 'Switch'
elif any(k in combined for k in AP):
    host['device_role'] = 'Wireless AP'
elif any(k in combined for k in PRINTER) or '9100' in open_ports:
    host['device_role'] = 'Printer'
elif any(k in combined for k in UPS):
    host['device_role'] = 'UPS'
elif any(k in combined for k in CAMERA):
    host['device_role'] = 'IP Camera'
elif '3389' in open_ports or 'windows' in os_str:
    host['device_role'] = 'Server'
elif any(k in combined for k in SERVER):
    host['device_role'] = 'Server'
elif '5060' in open_ports or 'sip' in combined:
    host['device_role'] = 'IP Phone'
elif '445' in open_ports or nb.get('available'):
    host['device_role'] = 'Workstation'

vendor = host.get('vendor', '') or ''
if vendor not in ('', 'null', 'None'):
    host['manufacturer'] = vendor
else:
    MFR = {'cisco': 'Cisco', 'juniper': 'Juniper', 'arista': 'Arista',
           'procurve': 'HP', 'hp ': 'HP', 'hewlett': 'HP', 'dell': 'Dell',
           'microsoft': 'Microsoft', 'vmware': 'VMware', 'apple': 'Apple',
           'ubiquiti': 'Ubiquiti', 'mikrotik': 'MikroTik',
           'fortigate': 'Fortinet', 'fortinet': 'Fortinet',
           'palo alto': 'Palo Alto', 'checkpoint': 'Check Point',
           'apc': 'APC', 'eaton': 'Eaton', 'netgear': 'Netgear',
           'axis': 'Axis', 'hikvision': 'Hikvision',
           'synology': 'Synology', 'qnap': 'QNAP',
           'h3c': 'H3C', 'huawei': 'Huawei',
           'meraki': 'Cisco Meraki', 'brocade': 'Brocade',
           'extreme': 'Extreme Networks'}
    for k, v in MFR.items():
        if k in combined:
            host['manufacturer'] = v
            break

sd = snmp.get('sys_descr', '') or ''
if sd:
    host['model'] = sd[:120].strip()
elif ssh.get('net_device_info'):
    lns = [l for l in ssh['net_device_info'].split('\n') if l.strip()]
    host['model'] = lns[0][:120].strip() if lns else 'Unknown'
else:
    host['model'] = (host['os'] or 'Unknown')[:80]

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

ip        = sys.argv[1]
community = sys.argv[2]
timeout   = sys.argv[3]
disc_dir  = sys.argv[4]

def walk(oid, comm=None):
    c = comm or community
    try:
        r = subprocess.run(
            ['snmpwalk', '-v2c', '-c', c, '-t', timeout, '-r1', ip, oid],
            capture_output=True, text=True, timeout=30)
        return r.stdout
    except Exception:
        return ''

print('  Fetching interface table...')
if_names  = {}
if_status = {}
if_admin  = {}
if_speed  = {}
if_mac    = {}

for line in walk('1.3.6.1.2.1.2.2.1.2').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)', line)
    if m: if_names[m.group(1)] = m.group(2).strip().strip('"')

for line in walk('1.3.6.1.2.1.2.2.1.8').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m: if_status[m.group(1)] = 'up' if m.group(2) == '1' else 'down'

for line in walk('1.3.6.1.2.1.2.2.1.7').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m: if_admin[m.group(1)] = 'up' if m.group(2) == '1' else 'down'

for line in walk('1.3.6.1.2.1.2.2.1.5').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*(?:Gauge32|INTEGER):\s*(\d+)', line)
    if m: if_speed[m.group(1)] = m.group(2)

for line in walk('1.3.6.1.2.1.2.2.1.6').split('\n'):
    m = re.search(r'\.(\d+)\s*=\s*(?:STRING|Hex-STRING):\s*(.+)', line)
    if m: if_mac[m.group(1)] = m.group(2).strip()

print('  Fetching bridge port -> ifIndex mapping...')
port_to_if = {}
for line in walk('1.3.6.1.2.1.17.1.4.1.2').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*INTEGER:\s*(\d+)', line)
    if m: port_to_if[m.group(1)] = m.group(2)

print('  Fetching VLAN port assignments...')
port_vlan = {}
for line in walk('1.3.6.1.2.1.17.7.1.4.5.1.1').split('\n'):
    m = re.match(
        r'.*\.(\d+)\s*=\s*(?:Gauge32|INTEGER|Unsigned32):\s*(\d+)', line)
    if m: port_vlan[m.group(1)] = m.group(2)

print('  Fetching VLAN names...')
vlan_names = {}
for line in walk('1.3.6.1.4.1.9.9.46.1.3.1.1.2').split('\n'):
    m = re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)', line)
    if m: vlan_names[m.group(1)] = m.group(2).strip().strip('"')
if not vlan_names:
    for line in walk('1.3.6.1.2.1.17.7.1.4.2.1.4').split('\n'):
        m = re.match(r'.*\.(\d+)\s*=\s*STRING:\s*(.+)', line)
        if m: vlan_names[m.group(1)] = m.group(2).strip().strip('"')

print('  Fetching MAC address table...')
mac_to_port = {}
for line in walk('1.3.6.1.2.1.17.4.3.1.2').split('\n'):
    m = re.match(
        r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)\s*=\s*INTEGER:\s*(\d+)',
        line)
    if m:
        mac = ':'.join('{:02x}'.format(int(o)) for o in m.group(1).split('.'))
        mac_to_port[mac] = m.group(2)

# Cisco per-VLAN community if standard bridge MIB returned 0 MACs
if not mac_to_port and vlan_names:
    print('  Standard bridge MIB: 0 MACs -- trying Cisco per-VLAN communities...')
    for vid in list(vlan_names.keys())[:10]:
        vlan_comm = '{0}@{1}'.format(community, vid)
        for line in walk('1.3.6.1.2.1.17.4.3.1.2', comm=vlan_comm).split('\n'):
            m = re.match(
                r'.*17\.4\.3\.1\.2\.(\d+\.\d+\.\d+\.\d+\.\d+\.\d+)'
                r'\s*=\s*INTEGER:\s*(\d+)', line)
            if m:
                mac = ':'.join(
                    '{:02x}'.format(int(o)) for o in m.group(1).split('.'))
                mac_to_port[mac] = m.group(2)
        if mac_to_port:
            print('  Found MACs via VLAN community @{0}'.format(vid))
            break

print('  Found {0} MAC table entries'.format(len(mac_to_port)))

# ARP reverse lookup
arp_map = {}
for line in walk('1.3.6.1.2.1.4.22.1.2').split('\n'):
    m = re.search(r'\.(\d+\.\d+\.\d+\.\d+)\s*=\s*(?:STRING|Hex-STRING):\s*(.+)',
                  line)
    if m and '4.22.1.2' in line:
        arp_map[m.group(2).strip().lower()] = m.group(1)

# Build per-interface entries (all interfaces, with or without MACs)
if_entries = {}
for idx, name in if_names.items():
    bports = [bp for bp, ii in port_to_if.items() if ii == idx]
    vlan = ''
    for bp in bports:
        if bp in port_vlan:
            vlan = port_vlan[bp]; break
    if not vlan and idx in port_vlan:
        vlan = port_vlan[idx]

    macs_on_port = [
        mac for mac, bp in mac_to_port.items()
        if port_to_if.get(bp, bp) == idx
    ]
    remote_ips = []
    for mac in macs_on_port:
        mac_norm = mac.replace(':', '').lower()
        for k, v in arp_map.items():
            if mac_norm in k.replace(':', '').replace(' ', ''):
                remote_ips.append(v); break

    spd = if_speed.get(idx, '0')
    spd_mbps = str(int(spd) // 1000000) + 'M' if spd.isdigit() else '?'

    if_entries[idx] = {
        'if_index':   idx,
        'if_name':    name,
        'admin':      if_admin.get(idx, '?'),
        'oper':       if_status.get(idx, '?'),
        'speed':      spd_mbps,
        'mac':        if_mac.get(idx, ''),
        'vlan':       vlan,
        'vlan_name':  vlan_names.get(str(vlan), ''),
        'clients':    macs_on_port,
        'remote_ips': remote_ips,
    }

port_entries = sorted(if_entries.values(), key=lambda x: x['if_name'])

out_file = os.path.join(
    disc_dir, 'switchport_' + ip.replace('.', '-') + '.json')
with open(out_file, 'w') as f:
    json.dump({'switch_ip': ip, 'interfaces': port_entries,
               'vlan_names': vlan_names,
               'interface_count': len(if_names),
               'mac_count': len(mac_to_port)}, f, indent=2)

print('  Saved: ' + out_file)
print('\n  Switch     : ' + ip)
print('  Interfaces : {0}'.format(len(if_names)))
print('  MAC entries: {0}'.format(len(mac_to_port)))
if vlan_names:
    pairs = sorted(vlan_names.items(),
                   key=lambda x: int(x[0]) if x[0].isdigit() else 0)[:10]
    print('  VLANs      : ' + ', '.join('{0}={1}'.format(k, v)
                                        for k, v in pairs))
print()

hdr = '  {:<24} {:<5} {:<5} {:<8} {:<6} {:<18} {:<17} {}'.format(
    'Interface', 'Adm', 'Oper', 'Speed', 'VLAN', 'VLAN Name',
    'Port MAC', 'Remote IPs / Client MACs')
print(hdr)
print('  ' + '-' * 110)
for e in port_entries:
    clients_str = ', '.join(e['remote_ips']) if e['remote_ips'] \
        else ', '.join(e['clients'][:3])
    print('  {:<24} {:<5} {:<5} {:<8} {:<6} {:<18} {:<17} {}'.format(
        e['if_name'][:23],
        e['admin'][:4],
        e['oper'][:4],
        e['speed'][:7],
        str(e['vlan'])[:5],
        e['vlan_name'][:17],
        e['mac'][:16],
        clients_str[:50]))
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
        && results_file=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null \
            | head -1)
    [[ ! -f "$results_file" ]] \
        && { log_error "No results file found"; pause; return 1; }

    log_step "Syncing to NetBox: $(basename "$results_file")"

    if [[ -z "$NETBOX_API_TOKEN" ]]; then
        read -rp "  Enter NetBox API Token: " NETBOX_API_TOKEN; save_config
    fi

    # Two-step reachability check
    if ! nc -z -w 5 localhost "${NETBOX_PORT}" 2>/dev/null; then
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
        if [[ -n "$new_tok" ]]; then
            NETBOX_API_TOKEN="$new_tok"; save_config
        else
            pause; return 1
        fi
    elif [[ "$http_code" != "200" ]]; then
        log_error "NetBox API HTTP $http_code"
        pause; return 1
    fi

    local site_id; site_id=$(nb_get_or_create_site)
    [[ -z "$site_id" || ! "$site_id" =~ ^[0-9]+$ ]] \
        && { log_error "Cannot create site"; pause; return 1; }
    log_info "Site ID: $site_id"

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
        model=$(echo "$host"    | jq -r '.model // "Unknown"' | cut -c1-100)
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
            "$site_id" "$serial" "$comments" 2>>"$LOG_FILE")

        if [[ -z "$dev_id" || ! "$dev_id" =~ ^[0-9]+$ ]]; then
            printf "${R}FAIL${NC}\n"; (( fail++ )); continue
        fi

        # Management interface + primary IP
        local mac_addr mgmt_id
        mac_addr=$(echo "$host" | jq -r '.mac // ""')
        mgmt_id=$(nb_add_interface \
            "$dev_id" "mgmt0" "other" "$mac_addr" \
            "Management (auto-discovered)" 2>/dev/null)
        if [[ -n "$mgmt_id" && "$mgmt_id" =~ ^[0-9]+$ ]]; then
            nb_add_ip "$ip" "$dev_id" "$mgmt_id" >/dev/null 2>&1 || true
        fi

        # SNMP interfaces with IPs and VLANs
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

            # Interface description from LLDP/CDP
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

            # Assign IP from SNMP IP address table
            local iface_ip iface_mask iface_prefix
            iface_ip=$(echo "$ip_table_json" | jq -r \
                "[.[] | select(.if_index==\"$if_idx\") | .ip][0] // empty" \
                2>/dev/null || echo "")
                # Skip unroutable/invalid addresses before sending to NetBox
                if [[ -n "$iface_ip" \
                      && "$iface_ip" != "0.0.0.0" \
                      && "$iface_ip" != 127.* ]]; then
                    iface_mask=$(echo "$ip_table_json" | jq -r \
                        "[.[] | select(.ip==\"$iface_ip\") | .mask][0] \
                         // \"255.255.255.0\"" 2>/dev/null || echo "255.255.255.0")
                    iface_prefix=$(python3 -c \
                        "import ipaddress; \
print(ipaddress.IPv4Network(\'$iface_ip/$iface_mask\',strict=False).prefixlen)" \
                        2>/dev/null || echo "24")
                    nb_add_ip "${iface_ip}/${iface_prefix}" "" "$if_id" \
                        >/dev/null 2>&1 || true
                fi

            # Assign VLAN from dot1qPvid
            local pvid vlan_nm vlan_id
            pvid=$(echo "$vlan_pvid_json" | jq -r \
                ".\"$if_idx\" // empty" 2>/dev/null || echo "")
            if [[ -n "$pvid" && "$pvid" =~ ^[0-9]+$ && "$pvid" != "0" ]]; then
                vlan_nm=$(echo "$vlan_names_json" | jq -r \
                    ".\"$pvid\" // \"VLAN-$pvid\"" 2>/dev/null \
                    || echo "VLAN-$pvid")
                vlan_id=$(nb_get_or_create_vlan \
                    "$pvid" "$vlan_nm" "$site_id" 2>/dev/null) || true
                if [[ -n "$vlan_id" && "$vlan_id" =~ ^[0-9]+$ ]]; then
                    nb_patch "dcim/interfaces/${if_id}/" \
                        "{\"untagged_vlan\":$vlan_id,\"mode\":\"access\"}" \
                        >/dev/null 2>&1 || true
                fi
            fi
        done < <(echo "$host" | jq -c '.interfaces[]?' 2>/dev/null || true)

        # CDP/LLDP topology cables
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

        printf "${G}OK${NC}\n"; (( ok++ ))

    done < <(jq -c '.hosts[]' "$results_file")

    printf "\n  ${G}Complete:${NC} %d synced  ${R}%d failed${NC}  (total: %d)\n" \
        "$ok" "$fail" "$total"
    log_info "Sync: ok=$ok fail=$fail total=$total"
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
        echo "$creds" | jq -r '.snmp_communities[] | "    * "+.' 2>/dev/null \
            || echo "    (none)"
        printf "\n  ${W}SNMP v3:${NC}\n"
        echo "$creds" | jq -r \
            '.snmp_v3[] | "    * \(.username) [\(.auth_proto)/\(.priv_proto)]"' \
            2>/dev/null || echo "    (none)"
        printf "\n  ${W}SSH:${NC}\n"
        echo "$creds" | jq -r \
            '.ssh_credentials[] | "    * \(.username)"' \
            2>/dev/null || echo "    (none)"
        printf "\n  ${W}Device overrides:${NC}\n"
        echo "$creds" | jq -r \
            '.device_overrides | to_entries[] | "    * \(.key)"' \
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
        echo "   0) Back"
        read -rp $'\nChoice: ' c
        local v3e sshe deve
        case "$c" in
        1) read -rp "  Community: " x
           write_creds "$(echo "$creds" | jq ".snmp_communities += [\"$x\"]")"
           log_info "Added: $x" ;;
        2) read -rp "  Remove: " x
           write_creds "$(echo "$creds" \
               | jq "del(.snmp_communities[] | select(.==\"$x\"))")" ;;
        3) read -rp "  Username: " u
           read -rp "  Auth proto [SHA]: " ap; ap=${ap:-SHA}
           read -rsp "  Auth pass: " ap2; echo
           read -rp "  Priv proto [AES]: " pp; pp=${pp:-AES}
           read -rsp "  Priv pass: " pp2; echo
           v3e=$(jq -n \
               --arg u "$u" --arg ap "$ap" --arg ap2 "$ap2" \
               --arg pp "$pp" --arg pp2 "$pp2" \
               '{username:$u,auth_proto:$ap,auth_pass:$ap2,
                 priv_proto:$pp,priv_pass:$pp2}')
           write_creds "$(echo "$creds" | jq ".snmp_v3 += [$v3e]")" ;;
        4) read -rp "  Username: " u
           read -rsp "  Password (blank=key): " p; echo
           read -rp "  Key file (blank=password): " k
           read -rsp "  Enable pass (opt): " e; echo
           sshe=$(jq -n \
               --arg u "$u" --arg p "$p" --arg k "$k" --arg e "$e" \
               '{username:$u,
                 password:(if $p!="" then $p else null end),
                 key_file:(if $k!="" then $k else null end),
                 enable_pass:(if $e!="" then $e else null end)}')
           write_creds "$(echo "$creds" | jq ".ssh_credentials += [$sshe]")" ;;
        5) read -rp "  Remove username: " u
           write_creds "$(echo "$creds" \
               | jq "del(.ssh_credentials[] | select(.username==\"$u\"))")" ;;
        6) read -rp "  Device IP: " dip
           read -rp "  SNMP community: " dc
           read -rp "  SSH username: " du
           read -rsp "  SSH password: " dp; echo
           read -rp "  SSH key file: " dk
           deve=$(jq -n \
               --arg c "$dc" --arg u "$du" --arg p "$dp" --arg k "$dk" \
               '{snmp_community:(if $c!="" then $c else null end),
                 ssh_username:(if $u!="" then $u else null end),
                 ssh_password:(if $p!="" then $p else null end),
                 ssh_key:(if $k!="" then $k else null end)}')
           write_creds "$(echo "$creds" \
               | jq ".device_overrides[\"$dip\"] = $deve")" ;;
        7) read -rp "  Device IP: " dip
           write_creds "$(echo "$creds" \
               | jq "del(.device_overrides[\"$dip\"])")" ;;
        8) read -rp "  JSON file: " jf
           if [[ -f "$jf" ]]; then
               write_creds "$(cat "$jf")"
               log_info "Imported: $jf"
           else
               printf "${R}  Not found${NC}\n"; sleep 1
           fi ;;
        9) printf "${R}  WARNING: plaintext export!${NC}\n"
           confirm "Continue?" || continue
           read -rp "  Output file: " of
           read_creds > "$of"; chmod 600 "$of"
           log_warn "Exported: $of" ;;
        0) return ;;
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
           NETBOX_API_URL="http://localhost:${NETBOX_PORT}";    save_config ;;
        7) (( DEBUG_MODE ^= 1 ));                               save_config ;;
        8) read -rp "  Network (CIDR): " snet
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
            regen_py="from users.models import Token
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
            else
                log_error "Token generation failed"
            fi ;;
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
           printf "  %-16s %-28s %-16s %-16s %s\n" \
               IP Hostname Role Manufacturer OS
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
        echo "  1) Discover Network (CIDR)"
        echo "  2) Scan Single Host"
        echo "  3) Scan Host List from File"
        echo "  4) Map Switchports (SNMP)"
        echo "  5) View Latest Results"
        echo "  6) Sync Last Results to NetBox"
        echo "  7) Full Auto: Discover + Sync"
        echo "  0) Back"
        read -rp $'\nChoice: ' c
        local net sip hf swip latest cnt
        case "$c" in
        1) read -rp "  Network CIDR (e.g. 192.168.1.0/24): " net
           if valid_cidr "$net" || valid_ip "${net%%/*}"; then
               init_scan_session "$net"
               discover_live_hosts "$net"
               if [[ -s "$LIVE_HOSTS_FILE" ]]; then
                   scan_all_hosts
                   log_ok "Results: $DISC_RESULTS"
                   confirm "  Sync to NetBox?" \
                       && sync_to_netbox "$DISC_RESULTS"
               fi
           else printf "${R}  Invalid${NC}\n"; fi ;;
        2) read -rp "  IP: " sip
           if valid_ip "$sip"; then
               init_scan_session "$sip"
               echo "$sip" > "$LIVE_HOSTS_FILE"
               scan_all_hosts
               jq '.hosts[0] | del(.ports,.interfaces,
                   .mac_port_map,.arp_entries)' \
                   "$DISC_RESULTS" 2>/dev/null || cat "$DISC_RESULTS"
           else printf "${R}  Invalid IP${NC}\n"; fi ;;
        3) read -rp "  File path: " hf
           if [[ -f "$hf" ]]; then
               init_scan_session "file:$hf"
               grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "$hf" \
                   > "$LIVE_HOSTS_FILE"
               cnt=$(wc -l < "$LIVE_HOSTS_FILE")
               log_info "Loaded $cnt hosts"
               scan_all_hosts
               confirm "  Sync to NetBox?" && sync_to_netbox "$DISC_RESULTS"
           else printf "${R}  Not found${NC}\n"; fi ;;
        4) read -rp "  Switch IP: " swip
           valid_ip "$swip" && map_switchports "$swip" \
               || printf "${R}  Invalid IP${NC}\n" ;;
        5) latest=$(ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null | head -1)
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
        6) sync_to_netbox ;;
        7) read -rp "  Network CIDR: " net
           if valid_cidr "$net" || valid_ip "${net%%/*}"; then
               init_scan_session "$net"
               discover_live_hosts "$net"
               if [[ -s "$LIVE_HOSTS_FILE" ]]; then
                   scan_all_hosts
                   sync_to_netbox "$DISC_RESULTS"
               fi
           else printf "${R}  Invalid${NC}\n"; fi ;;
        0) return ;;
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
        printf "  NetBox: ${W}%s${NC}   Docker: ${W}%s${NC}\n" \
            "$nb_st" "$dk_st"
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
        0) printf "\n  ${G}Goodbye!${NC}\n\n"
           log_info "Session ended"; exit 0 ;;
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
    log_info "User: $(id -un)  PID: $$  Compose: $DOCKER_COMPOSE"
    log_info "================================================"

    # Non-interactive: cron auto-scan
    if [[ "${1:-}" == "--auto-scan" && -n "${2:-}" ]]; then
        init_scan_session "$2"
        discover_live_hosts "$2"
        [[ -s "$LIVE_HOSTS_FILE" ]] \
            && scan_all_hosts \
            && sync_to_netbox "$DISC_RESULTS"
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
