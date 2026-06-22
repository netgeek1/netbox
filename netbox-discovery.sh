#!/usr/bin/env bash
# =============================================================================
#  NetBox Auto-Deploy & Network Discovery Suite  --  Ubuntu 24.04
#  Version: 2.5.49
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# GLOBAL CONSTANTS
# -----------------------------------------------------------------------------
SCRIPT_VERSION="2.5.49"
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
REAL_USER="${SUDO_USER:-$(id -un)}"   # actual user even when run via sudo

BASE_DIR="/opt/netbox-discovery"
LOG_DIR="/var/log/netbox-discovery"
CONFIG_FILE="$BASE_DIR/config.conf"
CREDS_FILE="$BASE_DIR/.credentials.enc"
CREDS_KEY_FILE="$BASE_DIR/.creds.key"
DISCOVERY_DIR="$BASE_DIR/discovery"

# Newest RAW scan results file, excluding our own derived outputs
# (results_*.plan.json / *.reconciled.json / *.plan.reconciled.json). Without
# this, ls -t would re-select the plan/reconciled files the writer just wrote
# back into the same directory, feeding a plan file into the reconciler (0/0/0).
latest_scan_file() {
    ls -t "$DISCOVERY_DIR"/results_*.json 2>/dev/null \
        | grep -vE '\.(plan|reconciled)\.json$' | head -1
}

nb_sync_vm_disk() {
    # Create/update a NetBox virtual disk for a VM (size in GB). NetBox 4.x
    # aggregates the VM's total disk from these objects.
    local vm_id="$1" name="$2" size_gb="$3"
    [[ "$vm_id" =~ ^[0-9]+$ && "$size_gb" =~ ^[0-9]+$ ]] || return 0
    # NetBox 4.x VirtualDisk.size (and VM.disk) are in MB, not GB -- sending the
    # GB number made a 60 GB disk show as 60 MB. Convert GB -> MB.
    local size_mb=$(( size_gb * 1024 ))
    local enc; enc=$(nb_urlencode "$name")
    local existing; existing=$(nb_get \
        "virtualization/virtual-disks/?virtual_machine_id=${vm_id}&name=${enc}")
    local did; did=$(echo "$existing" | jq -r '.results[0].id // empty' 2>/dev/null)
    local payload; payload=$(jq -n --arg n "$name" \
        --argjson s "$size_mb" --argjson vm "$vm_id" \
        '{name:$n,size:$s,virtual_machine:$vm}')
    if [[ -n "$did" && "$did" =~ ^[0-9]+$ ]]; then
        nb_patch "virtualization/virtual-disks/${did}/" "$payload" >/dev/null 2>&1 || true
    else
        nb_post "virtualization/virtual-disks/" "$payload" >/dev/null 2>&1 || true
    fi
}
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
# RAW_CAPTURE=1 archives every probe's raw output (nmap XML, RustScan raw,
# container JSON, per-probe *.json, OS fingerprints) per host instead of
# discarding the temp dir. Lets the full discovery evidence be reviewed.
RAW_CAPTURE=1
# When testing stored credentials against an IP: 1 = stop at the first credential
# that passes (quick "is it reachable" check); 0 = test every protocol and
# highlight which fail (useful for catching one specific bad credential).
CRED_TEST_STOP_ON_PASS=1

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
RAW_CAPTURE=${RAW_CAPTURE}
CRED_TEST_STOP_ON_PASS=${CRED_TEST_STOP_ON_PASS}
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
# Install a systemd unit that brings the NetBox compose stack up on boot. Docker
# is already enabled at boot (install_deps), but a oneshot 'up -d' unit guarantees
# the stack starts regardless of per-container restart policy.
setup_netbox_autostart() {
    local unit="/etc/systemd/system/netbox-discovery.service"
    local SUDO=""
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        if sudo -n true 2>/dev/null; then SUDO="sudo"
        else log_warn "Root required to install the boot unit; re-run with sudo."; return 1; fi
    fi
    local docker_bin up_cmd down_cmd
    docker_bin="$(command -v docker || echo /usr/bin/docker)"
    if [[ "$DOCKER_COMPOSE" == "docker compose" ]]; then
        up_cmd="$docker_bin compose up -d"; down_cmd="$docker_bin compose stop"
    else
        local dc_bin; dc_bin="$(command -v docker-compose || echo /usr/local/bin/docker-compose)"
        up_cmd="$dc_bin up -d"; down_cmd="$dc_bin stop"
    fi
    $SUDO tee "$unit" >/dev/null <<UNIT
[Unit]
Description=NetBox (netbox-discovery) auto-start
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${NETBOX_DIR}
ExecStart=${up_cmd}
ExecStop=${down_cmd}
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
    $SUDO systemctl daemon-reload >> "$LOG_FILE" 2>&1
    if $SUDO systemctl enable netbox-discovery.service >> "$LOG_FILE" 2>&1; then
        log_ok "NetBox auto-start enabled (systemd unit: netbox-discovery.service)"
    else
        log_error "Failed to enable netbox-discovery.service"; return 1
    fi
}

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

    # Make NetBox come back up automatically after a host reboot.
    setup_netbox_autostart || log_warn "Auto-start not configured (enable later from the Management menu)."

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
    local url="${NETBOX_API_URL}/api/${endpoint}"
    # Full HTTP trace (method/endpoint/request body + status/response body) when a
    # sync enables it -- stdout still carries ONLY the response body so callers'
    # jq parsing is unchanged.
    if [[ "${NB_HTTP_LOG:-0}" == "1" && -n "${NB_HTTP_LOG_FILE:-}" ]]; then
        local raw code body
        raw=$(curl "${args[@]}" -w $'\n__NBCODE__:%{http_code}' "$url" 2>>"$LOG_FILE")
        code="${raw##*__NBCODE__:}"
        body="${raw%$'\n'__NBCODE__:*}"
        {
            printf '[%s] %s %s\n' "$(date '+%F %T')" "$method" "$endpoint"
            [[ -n "$data" ]] && printf '    > req: %s\n' "$data"
            printf '    < %s: %s\n' "$code" "${body:-<empty>}"
        } >> "$NB_HTTP_LOG_FILE" 2>/dev/null
        printf '%s' "$body"
    else
        curl "${args[@]}" "$url" 2>>"$LOG_FILE"
    fi
}
nb_get()   { nb_api GET   "$1"; }
nb_post()  { nb_api POST  "$1" "${2:-}"; }
nb_patch() { nb_api PATCH "$1" "${2:-}"; }
nb_delete(){ nb_api DELETE "$1"; }

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
    local name="$1" slug enc res id slug_enc
    slug=$(slugify "$name"); enc=$(nb_urlencode "$name")
    res=$(nb_get "dcim/manufacturers/?name=${enc}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        res=$(nb_post "dcim/manufacturers/" \
            "{\"name\":\"$name\",\"slug\":\"$slug\"}")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
        # POST failed -- almost always a slug collision with an existing
        # manufacturer whose NAME differs but slugs the same, e.g. WinRM's
        # 'Hewlett-Packard' vs the OUI table's 'Hewlett Packard' (both ->
        # 'hewlett-packard'). The name lookup missed, the POST 409'd, and the
        # device upsert then failed with 'Invalid manufacturer ID'. Recover the
        # existing manufacturer by slug.
        if [[ -z "$id" ]]; then
            slug_enc=$(nb_urlencode "$slug")
            res=$(nb_get "dcim/manufacturers/?slug=${slug_enc}")
            id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
        fi
    fi
    echo "$id"
}

nb_get_or_create_device_type() {
    local mfr_id="$1" model="$2" slug enc res id slug_enc mfr_slug
    # Truncate to 64 chars; long model names from sys_descr drift between
    # runs and cause slug collisions on the second attempt
    model="${model:0:64}"
    enc=$(nb_urlencode "$model")
    # Match by manufacturer_id + model, NOT model alone. A shared model such as
    # 'Unknown' under one vendor must never be reused for a different vendor --
    # that dragged correctly-identified devices (Wyze Labs, Roku, ...) onto HP's
    # 'Unknown' device type.
    res=$(nb_get "dcim/device-types/?manufacturer_id=${mfr_id}&model=${enc}")
    id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        # device-type slug is GLOBALLY unique in NetBox, so scope it to the
        # manufacturer; otherwise two vendors' identical model (e.g. 'Unknown')
        # collide and the recovery-by-slug returns the wrong vendor's type.
        mfr_slug=$(nb_get "dcim/manufacturers/${mfr_id}/" | jq -r '.slug // empty' 2>/dev/null)
        slug=$(slugify "${mfr_slug}-${model}")
        [[ -z "$slug" ]] && slug="${mfr_slug:-mfr${mfr_id}}-unknown-model"
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
    local ip_bare="${ip%/*}"
    # Match by host address (any mask) so an existing object with a different
    # prefix is reassigned rather than triggering an enforce_unique duplicate.
    local enc; enc=$(nb_urlencode "$ip_bare")
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

# NetBox 4.x MAC model: MACs are first-class /dcim/mac-addresses/ objects bound
# to an interface (the legacy interface.mac_address field was removed in 4.2, so
# on 4.6 it is silently dropped). This creates the MAC object for the given
# interface (idempotent: reuses one already on that interface) and sets it as the
# interface's primary_mac_address. Handles both device and VM interfaces. All
# output is captured/redirected and warnings go to stderr, so it is safe to call
# inside nb_add_interface's command substitution.
nb_ensure_mac_address() {
    local obj_type="$1" obj_id="$2" mac="$3"
    [[ -z "$mac" || "$mac" == "null" || ! "$obj_id" =~ ^[0-9]+$ ]] && return 0
    mac=$(echo "$mac" | tr 'A-F' 'a-f')
    local enc; enc=$(nb_urlencode "$mac")
    local existing mid
    existing=$(nb_get "dcim/mac-addresses/?mac_address=${enc}")
    mid=$(echo "$existing" | jq -r --argjson i "$obj_id" --arg t "$obj_type" \
        '[.results[] | select(.assigned_object_id==$i and .assigned_object_type==$t)][0].id // empty' 2>/dev/null)
    if [[ -z "$mid" ]]; then
        local res
        res=$(nb_post "dcim/mac-addresses/" "$(jq -n --arg m "$mac" --arg t "$obj_type" --argjson i "$obj_id" \
            '{mac_address:$m,assigned_object_type:$t,assigned_object_id:$i}')")
        mid=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
        if [[ -z "$mid" ]]; then
            log_warn "mac create failed ($mac on $obj_type $obj_id): $(echo "$res" | tr '\n' ' ' | head -c 160)"
            return 1
        fi
    fi
    local ep="dcim/interfaces"
    [[ "$obj_type" == "virtualization.vminterface" ]] && ep="virtualization/interfaces"
    nb_patch "${ep}/${obj_id}/" "{\"primary_mac_address\":$mid}" >/dev/null 2>&1 || true
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
            --arg     desc "$desc" \
            '{device:$dev,name:$name,type:$type,description:$desc}')
        local res; res=$(nb_post "dcim/interfaces/" "$payload")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
    fi
    [[ -n "$id" && -n "$mac" && "$mac" != "null" ]] && \
        nb_ensure_mac_address "dcim.interface" "$id" "$mac"
    echo "$id"
}

nb_upsert_device() {
    # primary_ip (8th arg): IP-first dedup -- find existing device by IP,
    # update in-place, rename auto-gen name to real hostname if richer.
    local name="$1" role="$2" mfr="$3" model="$4" site_id="$5" \
          serial="${6:-}" comments="${7:-}" primary_ip="${8:-}"
    local mfr_id dtype_id role_id
    # An unidentified MODEL under a KNOWN manufacturer: label the device type with
    # the manufacturer name instead of a shared 'Unknown' (e.g. 'Wyze Labs/Wyze
    # Labs'). Keeps each vendor's type distinct and avoids inheriting another
    # vendor's 'Unknown' type. A truly-unknown vendor (mfr 'Unknown') is left as
    # 'Unknown', so it correctly becomes the 'Unknown/Unknown' device type.
    if [[ ( -z "$model" || "$model" == "Unknown" ) && -n "$mfr" && "$mfr" != "Unknown" ]]; then
        model="$mfr"
    fi
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
    # ------ Normalized short-name dedup (FQDN <-> NetBIOS) ----------------------------------------------------------------------------------------------------------
    # Match by short hostname, case-insensitive, so "server01.certifiedgeeks.net"
    # and "SERVER01" resolve to the same device instead of duplicating.
    if [[ -z "$dev_id" || ! "$dev_id" =~ ^[0-9]+$ ]]; then
        local _short; _short=$(echo "$name" | cut -d. -f1 | tr 'A-Z' 'a-z')
        if [[ -n "$_short" ]]; then
            local _se; _se=$(nb_urlencode "$_short")
            local _cand; _cand=$(nb_get "dcim/devices/?name__ic=${_se}&limit=50")
            dev_id=$(echo "$_cand" | jq -r --arg s "$_short" \
                '[.results[] | select((.name|split(".")[0]|ascii_downcase)==$s)][0].id // empty' \
                2>/dev/null)
            if [[ -n "$dev_id" && "$dev_id" =~ ^[0-9]+$ ]]; then
                local _en; _en=$(nb_get "dcim/devices/${dev_id}/" | jq -r '.name // empty' 2>/dev/null)
                log_info "Merged by short-name: '$name' -> existing '$_en' (ID: $dev_id)"
                # Keep the existing richer name unless it is an auto-gen placeholder
                local _ap="^device-[0-9]+-[0-9]+-[0-9]+-[0-9]+$"
                if [[ -n "$_en" && ! "$_en" =~ $_ap ]]; then name="$_en"; fi
            fi
        fi
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
    # The 'lldp-auto:' label prefix is the version-proof marker for a tool-managed
    # cable (a plain string field NetBox cannot reject). A tag is also attempted
    # for NetBox-side filtering, but tag-write format varies by version, so if the
    # tagged POST is rejected we retry WITHOUT the tag -- tagging must never block
    # the cable from being created. Errors are surfaced, not swallowed.
    local base resp id
    base=$(jq -nc --argjson a "$a_id" --argjson b "$b_id" --arg lbl "$label" \
        '{a_terminations:[{object_type:"dcim.interface",object_id:$a}],
          b_terminations:[{object_type:"dcim.interface",object_id:$b}],
          status:"connected", label:$lbl}')
    resp=$(nb_post "dcim/cables/" "$(echo "$base" | jq -c '. + {tags:[{name:"lldp-auto"}]}')")
    id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        resp=$(nb_post "dcim/cables/" "$base")            # retry untagged
        id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
    fi
    if [[ -z "$id" ]]; then
        log_warn "cable create failed (if $a_id <-> if $b_id): $(echo "$resp" | tr '\n' ' ' | head -c 240)"
        return 1
    fi
    echo "$id"; return 0
}

# Idempotent tag creator (used to mark tool-managed LLDP cables).
nb_ensure_tag() {
    local name="$1" slug="$2"
    local enc; enc=$(nb_urlencode "$slug")
    local ex; ex=$(nb_get "extras/tags/?slug=${enc}")
    local id; id=$(echo "$ex" | jq -r '.results[0].id // empty' 2>/dev/null)
    [[ -z "$id" ]] && nb_post "extras/tags/" "{\"name\":\"$name\",\"slug\":\"$slug\"}" >/dev/null 2>&1 || true
}

nb_dev_id_by_name() {
    local nm="$1"; [[ -z "$nm" ]] && return
    local enc; enc=$(nb_urlencode "$nm")
    nb_get "dcim/devices/?name=${enc}" | jq -r '.results[0].id // empty' 2>/dev/null
}
nb_dev_id_by_serial() {
    local sn="$1"; [[ -z "$sn" ]] && return
    local enc; enc=$(nb_urlencode "$sn")
    nb_get "dcim/devices/?serial=${enc}" | jq -r '.results[0].id // empty' 2>/dev/null
}

# Reconcile ONE LLDP cable between local and remote interface IDs. Only ever
# touches cables tagged 'lldp-auto'. Returns 0 if it created or replaced a
# cable, 1 if it left things as-is (already correct, or a manual cable it must
# not disturb). This is what makes a moved cable self-correct instead of leaving
# a stale link: a wrong lldp-auto cable on the local port is deleted + recreated.
nb_reconcile_cable() {
    local lif="$1" rif="$2" label="${3:-}"
    # Inspect BOTH endpoints. If either already carries the exact lif<->rif cable
    # -> no-op. An lldp-auto cable on either end that does NOT join exactly these
    # two ports is stale (a moved/renamed link, e.g. the old neighbor-abbreviated
    # interface from a prior run) and is removed so the correct cable can form.
    # A manual cable on an endpoint is respected -- we skip rather than steal it.
    local end cab_id cab is_auto joins
    for end in "$lif" "$rif"; do
        cab_id=$(nb_get "dcim/interfaces/${end}/" | jq -r '(.cable.id // .cable) // empty' 2>/dev/null)
        [[ -z "$cab_id" || ! "$cab_id" =~ ^[0-9]+$ ]] && continue
        cab=$(nb_get "dcim/cables/${cab_id}/")
        joins=$(echo "$cab" | jq -r --argjson a "$lif" --argjson b "$rif" \
            '([(.a_terminations[]?,.b_terminations[]?).object_id]|sort)==([$a,$b]|sort)' 2>/dev/null)
        [[ "$joins" == "true" ]] && return 1   # already exactly correct
        is_auto=$(echo "$cab" | jq -r \
            'any(.tags[]?; .slug=="lldp-auto" or .name=="lldp-auto") or (((.label)//"")|startswith("lldp-auto:"))' 2>/dev/null)
        if [[ "$is_auto" == "true" ]]; then
            nb_delete "dcim/cables/${cab_id}/" >/dev/null 2>&1   # stale auto-cable
        else
            log_info "  cable skip: endpoint busy with manual cable (if $lif/$rif)"
            return 1
        fi
    done
    nb_create_cable "$lif" "$rif" "$label"
}

# Remove lldp-auto cables on a device whose local interface is no longer in the
# current link set ($keep = space-separated local interface IDs). This is the
# 'remove' half of reconcile: a port that LLDP no longer reports loses its
# auto-cable. Manual (untagged) cables are never enumerated here.
nb_prune_lldp_cables() {
    local dev_id="$1" keep="$2"
    local cabs; cabs=$(nb_get "dcim/cables/?device_id=${dev_id}")
    local n; n=$(echo "$cabs" | jq '.results | length' 2>/dev/null || echo 0)
    [[ ! "$n" =~ ^[0-9]+$ || "$n" -eq 0 ]] && return
    local row cid is_auto lifids lid k stale
    while IFS= read -r row; do
        is_auto=$(echo "$row" | jq -r \
            'any(.tags[]?; .slug=="lldp-auto" or .name=="lldp-auto") or (((.label) // "") | startswith("lldp-auto:"))' 2>/dev/null)
        [[ "$is_auto" != "true" ]] && continue   # only prune tool-managed cables
        cid=$(jq -r '.id' <<<"$row")
        lifids=$(jq -r --argjson dev "$dev_id" \
            '[(.a_terminations[]?,.b_terminations[]?)
              | select((.object.device.id // -1)==$dev) | .object_id] | .[]' <<<"$row" 2>/dev/null)
        stale=1
        for lid in $lifids; do
            for k in $keep; do [[ "$lid" == "$k" ]] && stale=0; done
        done
        [[ "$stale" -eq 1 ]] && nb_delete "dcim/cables/${cid}/" >/dev/null 2>&1
    done < <(echo "$cabs" | jq -c '.results[]')
}

# Idempotent custom field creator -- only POSTs if field does not yet exist
nb_ensure_custom_field() {
    local name="$1" label="$2" type="${3:-text}" obj_types="${4:-dcim.device}"
    local otj; otj=$(printf '%s' "$obj_types" | jq -R 'split(",")')
    local enc; enc=$(nb_urlencode "$name")
    local res; res=$(nb_get "extras/custom-fields/?name=${enc}")
    local id; id=$(echo "$res" | jq -r '.results[0].id // empty' 2>/dev/null)
    if [[ -z "$id" ]]; then
        nb_post "extras/custom-fields/" \
            "$(jq -nc --arg n "$name" --arg l "$label" --arg t "$type" --argjson ot "$otj" \
                '{name:$n,label:$l,type:$t,object_types:$ot}')" \
            >/dev/null 2>&1 || true
        return 0
    fi
    # Reconcile the type of a pre-existing field. An earlier build created some
    # fields with the wrong type (e.g. memory_gb as 'text'); sending an integer to
    # a text field 400s the ENTIRE custom_fields PATCH, silently dropping every
    # field. A type PATCH is unreliable once the field holds a value, so delete +
    # recreate to guarantee the type (the value is rewritten this same run).
    local cur; cur=$(echo "$res" \
        | jq -r '(.results[0].type|objects|.value) // (.results[0].type|strings) // empty' 2>/dev/null)
    if [[ -n "$cur" && "$cur" != "$type" ]]; then
        log_info "Custom field '$name' is '$cur', expected '$type' -- recreating"
        nb_delete "extras/custom-fields/${id}/" >/dev/null 2>&1 || true
        nb_post "extras/custom-fields/" \
            "$(jq -nc --arg n "$name" --arg l "$label" --arg t "$type" --argjson ot "$otj" \
                '{name:$n,label:$l,type:$t,object_types:$ot}')" \
            >/dev/null 2>&1 || true
        return 0
    fi
    # If more than one object type is requested (discovered_ports spans devices
    # and VMs), make sure an already-existing field covers them. We set the full
    # requested set directly -- this tool owns these fields -- which is robust to
    # how the API represents object_types on read.
    if [[ "$obj_types" == *,* ]]; then
        nb_patch "extras/custom-fields/${id}/" "{\"object_types\":$otj}" >/dev/null 2>&1 || true
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
        | jq -r --argjson c "$cluster_id" \
            'first(.results[] | select(.cluster.id == $c) | .id) // empty' \
            2>/dev/null)
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
            --arg     desc "$desc" \
            '{virtual_machine:$vm,name:$name,description:$desc}')
        local res; res=$(nb_post "virtualization/interfaces/" "$payload")
        id=$(echo "$res" | jq -r '.id // empty' 2>/dev/null)
    fi
    [[ -n "$id" && -n "$mac" && "$mac" != "null" ]] && \
        nb_ensure_mac_address "virtualization.vminterface" "$id" "$mac"
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
ARP_MAP_FILE="$DISCOVERY_DIR/arp_map.txt"

# arp_lookup <ip> -> prints the MAC (lowercase, colon-sep) seen for ip during
# Phase 1 ARP discovery, or nothing. Last entry wins (cache may be fresher).
arp_lookup() {
    [[ -f "$ARP_MAP_FILE" ]] || return 0
    awk -v ip="$1" '$1==ip{m=$2} END{if(m)print tolower(m)}' "$ARP_MAP_FILE"
}

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
    # IP->MAC map captured during discovery. Phase 1 sees MACs via ARP that the
    # deep scan (-Pn) and SSH/SNMP probes often miss; propagating them lets the
    # reconciler match nmap-only hosts (no captured MAC) to Hyper-V VMs by MAC.
    : > "$ARP_MAP_FILE"

    printf "  ${W}ARP scan${NC} .................. "
    if cmd_exists arp-scan; then
        arp-scan --localnet --quiet 2>/dev/null \
            | awk '/^[0-9]/{print $1; print $1, $2 > "'"$ARP_MAP_FILE"'"}' \
            >> "$tmp_all"
        arp-scan "$target" --quiet 2>/dev/null \
            | awk '/^[0-9]/{print $1; print $1, $2 >> "'"$ARP_MAP_FILE"'"}' \
            >> "$tmp_all" 2>/dev/null || true
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
    ip neigh show 2>/dev/null \
        | awk '/REACHABLE|STALE|DELAY/{print $1;
               if($5 ~ /:/) print $1, $5 > "'"$ARP_MAP_FILE"'.tmp"}' \
        >> "$tmp_all"
    arp -n 2>/dev/null \
        | awk 'NR>1&&$3!="(incomplete)"{print $1;
               if($3 ~ /:/) print $1, $3 > "'"$ARP_MAP_FILE"'.tmp"}' \
        >> "$tmp_all"
    # merge cache MACs into the map without clobbering arp-scan entries
    [[ -f "$ARP_MAP_FILE.tmp" ]] && cat "$ARP_MAP_FILE.tmp" >> "$ARP_MAP_FILE" \
        && rm -f "$ARP_MAP_FILE.tmp"
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
    # Start a raw-capture session aligned with this run (one folder per scan).
    if [[ "${RAW_CAPTURE:-0}" == "1" ]]; then
        RAW_CAPTURE_SESSION="$(date +%Y%m%d_%H%M%S)_$$"
        log_info "Raw capture: $DISCOVERY_DIR/raw/$RAW_CAPTURE_SESSION/"
    fi
    local idx=0 ip
    while IFS= read -r ip <&3; do
        (( idx++ )) || true
        printf "\n  ${C}[%d/%d]${NC} ${W}%s${NC}\n" "$idx" "$total" "$ip"
        scan_single_host "$ip"
    done 3< "$LIVE_HOSTS_FILE"
    log_ok "Phase 2 complete"
    if [[ "${RAW_CAPTURE:-0}" == "1" && -n "$RAW_CAPTURE_SESSION" ]]; then
        local rawdir="$DISCOVERY_DIR/raw/$RAW_CAPTURE_SESSION"
        local bundle="$DISCOVERY_DIR/raw_${RAW_CAPTURE_SESSION}.tar.gz"
        tar -czf "$bundle" -C "$DISCOVERY_DIR/raw" "$RAW_CAPTURE_SESSION" 2>/dev/null \
            && log_info "Raw capture bundled: $bundle" \
            || log_info "Raw capture saved: $rawdir/"
        printf "  ${D}Share everything discovered:  sudo cat %s | (or attach the .tar.gz)${NC}\n" "$bundle"
    fi
}

# Archive every probe's raw output for one host into a reviewable folder.
# Layout:  $DISCOVERY_DIR/raw/<session>/<ip>/
#   nmap.xml nmap_udp.xml nmap_disc.xml   (nmap raw XML, all passes)
#   nmap.json snmp.json ssh.json http.json netbios.json dns.json
#   banner.json mdns.json winrm.json      (per-probe parsed JSON)
#   kasanaa_raw.json                      (raw SNMP container output)
#   merged.json                           (final merged host record)
#   nmap.txt nmap_udp.txt                 (human-readable nmap, if nmap present)
#   MANIFEST.txt                          (index + quick classification summary)
RAW_CAPTURE_SESSION=""
archive_raw_capture() {
    local ip="$1" tmp="$2" host_json="$3"
    # One session dir per scan run (timestamp set on first host of the run)
    [[ -z "$RAW_CAPTURE_SESSION" ]] && \
        RAW_CAPTURE_SESSION="$(date +%Y%m%d_%H%M%S)_$$"
    local dst="$DISCOVERY_DIR/raw/$RAW_CAPTURE_SESSION/${ip//[^0-9A-Za-z._-]/_}"
    mkdir -p "$dst" 2>/dev/null || { log_warn "raw-capture: cannot create $dst"; return; }

    # Copy every file the probes left in the temp dir (json, xml, txt, etc.)
    cp -a "$tmp"/. "$dst"/ 2>/dev/null || true
    # The final merged record
    printf '%s\n' "$host_json" > "$dst/merged.json" 2>/dev/null || true

    # Human-readable nmap renderings of each XML pass (best-effort)
    if cmd_exists xsltproc; then
        for x in nmap nmap_udp nmap_disc; do
            [[ -f "$dst/$x.xml" ]] && xsltproc "$dst/$x.xml" \
                > "$dst/$x.txt" 2>/dev/null || true
        done
    fi

    # Manifest: file index + a quick summary of the classification-relevant bits
    {
        echo "# Raw discovery capture"
        echo "host:        $ip"
        echo "session:     $RAW_CAPTURE_SESSION"
        echo "captured:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "script_ver:  $SCRIPT_VERSION"
        echo
        echo "## Files"
        (cd "$dst" && ls -la) 2>/dev/null
        echo
        echo "## Classification summary (from merged.json)"
        echo "$host_json" | jq -r '
            "device_role:   \(.device_role)",
            "manufacturer:  \(.manufacturer)",
            "model:         \(.model)",
            "os:            \(.os)",
            "serial:        \(.serial)",
            "scan_tier:     \(.scan_tier)",
            "discovery:     \(.discovery_methods | join(", "))",
            "open_ports:    \([.ports[]? | "\(.port)/\(.proto)"] | join(", "))",
            "snmp_sys_oid:  \(.snmp_details.sys_oid // "")",
            "snmp_descr:    \(.snmp_details.sys_descr // "")"
        ' 2>/dev/null || echo "(merged.json parse failed)"
    } > "$dst/MANIFEST.txt" 2>/dev/null || true
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
    # Capture the host's MAC from the kernel neighbor/ARP cache. By now we have
    # sent this host probe traffic (nmap/SSH/HTTP), so a same-subnet host is
    # resolved in the cache even when nmap used -Pn and recorded no MAC itself.
    # This is what bridges nmap-only hosts (auto-named Linux VMs with no guest
    # IP reported by Hyper-V, e.g. .235) to their Hyper-V VM by MAC. Falls back
    # to the Phase-1 ARP map if the live cache has no entry.
    local _amac=""
    if cmd_exists ip; then
        _amac=$(ip neigh show "$ip" 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="lladdr"){print $(i+1); exit}}')
    fi
    [[ -z "$_amac" ]] && _amac=$(arp -n "$ip" 2>/dev/null \
        | awk -v ip="$ip" '$1==ip && $3 ~ /:/{print $3; exit}')
    [[ -z "$_amac" ]] && _amac=$(arp_lookup "$ip")
    _amac=$(printf '%s' "$_amac" | tr 'A-F' 'a-f')
    if [[ "$_amac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
        printf '{"mac":"%s"}' "$_amac" > "$tmp/arp.json"
    fi
    local host_json
    host_json=$(merge_host_data "$ip" "$tmp")
    append_host "$host_json"
    local hn role os
    hn=$(echo "$host_json"   | jq -r '.hostname // "?"')
    role=$(echo "$host_json" | jq -r '.device_role // "?"')
    os=$(echo "$host_json"   | jq -r '.os // ""')
    printf "    ${G}OK${NC}  %-16s  %-28s  %-16s  %s\n" "$ip" "$hn" "$role" "$os"
    # Archive ALL raw probe output for this host before cleanup so the
    # full discovery evidence can be reviewed when identification is wrong.
    if [[ "${RAW_CAPTURE:-0}" == "1" ]]; then
        archive_raw_capture "$ip" "$tmp" "$host_json"
    fi
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
    local found_ports=""
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
        [[ -n "$rs_ports" ]] && found_ports="$rs_ports"
        log_info "RustScan found ports: ${rs_ports:-none}"
        echo "[TRACE] rustscan raw: $rs_raw" >> "$LOG_FILE" 2>/dev/null || true
    fi

    # Fast nmap discovery pass when RustScan found nothing. This is what makes
    # heavily-filtered Windows hosts work: a plain -Pn SYN scan (no -sV, no NSE
    # scripts, no -O) finds open ports in seconds, whereas running -sV + scripts
    # against ~40 filtered ports stalls and blows --host-timeout (host aborted,
    # empty result). Mirrors a manual "nmap -Pn <ip>" which completes in <10s.
    if [[ -z "$found_ports" ]]; then
        local disc_xml="$tmp/nmap_disc.xml"
        nmap -Pn -T4 --host-timeout 30s --max-retries 1 \
            -p "$nmap_ports" -oX "$disc_xml" "$ip" >> "$LOG_FILE" 2>&1 || true
        found_ports=$(grep -oP 'portid="\K[0-9]+' "$disc_xml" 2>/dev/null \
            | sort -un | tr "\n" "," | sed "s/,$//") || true
        echo "[TRACE] nmap fast-discovery $ip found: ${found_ports:-none}" >> "$LOG_FILE" 2>/dev/null || true
    fi

    # Deep scan: -sV/-O/scripts only against the confirmed-open ports (fast,
    # since there are few). If discovery found nothing, fall back to probing the
    # critical Windows/mgmt ports so OS/script detection still gets a chance.
    # Raw print port 9100 (JetDirect) prints whatever bytes arrive, so nmap's
    # -sV/banner probes make some printers (e.g. HP) eject a garbage page. Strip
    # 9100 from the version/script scan -- it stays in found_ports and is unioned
    # into the open-port list, so Printer classification is unaffected, but no
    # payload is ever sent to it.
    local scan_ports
    if [[ -n "$found_ports" ]]; then
        scan_ports=$(printf '%s' "$found_ports" | tr ',' '\n' \
            | grep -vx '9100' | paste -sd, -)
    else
        scan_ports="135,139,443,445,3389,5985,5986"
    fi
    # -Pn: skip nmap's own host-discovery. Phase 1 already confirmed the host
    # is live; many Windows hosts block ICMP, so without -Pn nmap declares them
    # "down" and skips port/OS scanning entirely (empty result -> Endpoint).
    if [[ -n "$scan_ports" ]]; then
        nmap -Pn -sV -O --osscan-guess \
            -p "$scan_ports" \
            --script "banner,ssh-hostkey,snmp-info,\
http-title,http-server-header,ssl-cert,\
nbstat,smb-security-mode,dns-service-discovery,\
ms-sql-info,mysql-info,mongodb-info,\
rdp-enum-encryption,rdp-ntlm-info,vnc-info" \
            -T4 --host-timeout 90s --max-retries 2 \
            -oX "$xml" "$ip" >> "$LOG_FILE" 2>&1 || true
    else
        # Only 9100 was open -- skip the deep scan entirely (sending it nothing)
        # and emit an empty nmap.xml so the parser still runs and unions 9100.
        printf '<?xml version="1.0"?>\n<nmaprun></nmaprun>\n' > "$xml"
    fi
    # UDP top-1000 scan (requires root; graceful no-op if not available)
    local udp_xml="$tmp/nmap_udp.xml"
    # UDP scan: top-200 ports, short host-timeout. UDP is slow by nature
    # (no RST on closed ports), so we cap it hard to avoid 90-120s stalls.
    nmap -Pn -sU --top-ports 200 \
        --script "snmp-info" \
        -T4 --host-timeout 30s --max-retries 0 \
        -oX "$udp_xml" "$ip" >> "$LOG_FILE" 2>&1 || true
    python3 /dev/stdin "$xml" "$udp_xml" "${found_ports:-}" <<'PYEOF' > "$tmp/nmap.json" 2>/dev/null
import xml.etree.ElementTree as ET, json, sys, os
def parse(f):
    r = {"ports":[],"os":None,"os_accuracy":None,
         "mac":None,"vendor":None,"hostname":None,"scripts":{}}
    if not f or not os.path.exists(f): return r
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
# Merge TCP result with UDP result (dedup by port+proto)
tcp = parse(sys.argv[1])
udp = parse(sys.argv[2]) if len(sys.argv) > 2 else {"ports":[]}
seen = {(p["port"],p["proto"]) for p in tcp["ports"]}
for p in udp["ports"]:
    if (p["port"],p["proto"]) not in seen:
        tcp["ports"].append(p)
        seen.add((p["port"],p["proto"]))
# Union RustScan/discovery-found TCP ports. RustScan reliably finds open ports
# via fast SYN scan even on host-firewalled boxes where the -sV/-O/script deep
# scan stalls and reports nothing. Without this, RustScan's ports were fed only
# to nmap's -p and then lost when the deep scan aborted -- leaving open_ports
# empty so the classifier could not see the Windows ports.
disc = sys.argv[3] if len(sys.argv) > 3 else ""
for tok in disc.split(","):
    tok = tok.strip()
    if tok.isdigit() and (tok, "tcp") not in seen:
        tcp["ports"].append({"port":tok,"proto":"tcp","service":None,
                             "version":None,"banner":None,"scripts":{}})
        seen.add((tok, "tcp"))
print(json.dumps(tcp))
PYEOF
}

# ?? SNMP detection container (KaSaNaa/SNMP-Network-Discovery) ?????????????????
# The SNMP probe now runs an ephemeral Docker container built from the
# KaSaNaa/SNMP-Network-Discovery project instead of local snmpget/snmpwalk.
# This gives proper SNMPv1/v2c/v3 (USM authPriv) support and structured JSON,
# which is then mapped into the host-record SNMP contract used downstream.
SNMP_DISCO_IMAGE="${SNMP_DISCO_IMAGE:-netbox-disco/snmp-detect:1.1}"
SNMP_DISCO_REPO_REF="${SNMP_DISCO_REPO_REF:-main}"

# Build the detection image once (cached). Returns non-zero if docker is
# unavailable or the build fails, so probe_snmp can fall back gracefully.
snmp_disco_ensure_image() {
    command -v docker &>/dev/null || {
        log_warn "docker not found -- SNMP detection container unavailable"
        return 1; }
    if docker image inspect "$SNMP_DISCO_IMAGE" &>/dev/null; then
        return 0
    fi
    log_info "Building SNMP detection container ($SNMP_DISCO_IMAGE) ..."
    local bd; bd=$(mktemp -d)
    cat > "$bd/Dockerfile" <<'DOCKEREOF'
FROM python:3.12-slim AS build
ARG REPO_REF=main
ARG REPO_URL=https://github.com/KaSaNaa/SNMP-Network-Discovery.git
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt
RUN git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" app \
    || git clone "${REPO_URL}" app

FROM python:3.12-slim
RUN pip install --no-cache-dir "pysnmp==7.1.22" "pyasn1==0.6.1" "cryptography>=40.0.0"
WORKDIR /app
COPY --from=build /opt/app/main.py ./main.py
COPY --from=build /opt/app/core    ./core
# Neutralise eager DB/graph imports so detection needs only the pysnmp stack.
RUN printf '%s\n' \
    'from .snmp_manager import SNMPManager' \
    'from .network_utils import NetworkUtils' \
    > core/__init__.py
# snmp_manager.py logs to ./logs/snmp_errors.log (relative to /app); the
# non-root user cannot create it at runtime, so make it writable at build time.
RUN mkdir -p /app/logs && useradd --create-home --uid 10001 scanner \
    && chown -R scanner:scanner /app/logs
USER scanner
ENTRYPOINT ["python", "main.py"]
CMD ["--help"]
DOCKEREOF
    if docker build --build-arg REPO_REF="$SNMP_DISCO_REPO_REF" \
            -t "$SNMP_DISCO_IMAGE" "$bd" >>"$LOG_FILE" 2>&1; then
        log_ok "SNMP detection container built"
        rm -rf "$bd"; return 0
    fi
    log_error "SNMP detection container build failed (see $LOG_FILE)"
    rm -rf "$bd"; return 1
}

# Run the ephemeral container against one IP. Args after the IP are passed
# straight through to main.py (SNMP version + credentials). Prints JSON.
snmp_disco_run() {
    local ip="$1"; shift
    timeout "$((SNMP_TIMEOUT * 8 + 20))" \
        docker run --rm --network host --security-opt no-new-privileges \
        -e PYTHONWARNINGS=ignore \
        "$SNMP_DISCO_IMAGE" "$ip" "$@" 2>>"$LOG_FILE"
}

# True if the JSON response indicates the device answered SNMP (no error key).
snmp_disco_ok() {
    [[ -n "$1" ]] && echo "$1" | jq -e 'has("error")|not' &>/dev/null
}

# ?? Probe: SNMP ???????????????????????????????????????????????????????????????
probe_snmp() {
    local ip="$1" tmp="$2"
    echo '{"available":false}' > "$tmp/snmp.json"

    snmp_disco_ensure_image || return

    local raw="" label="" _snmp_tok=""

    # 1. Try v2c communities
    local communities; communities=$(get_communities_for "$ip")
    local comm
    while IFS= read -r comm; do
        [[ -z "$comm" ]] && continue
        echo "[TRACE] snmp-disco $ip: trying v2c community '$comm'" >> "$LOG_FILE" 2>/dev/null || true
        raw=$(snmp_disco_run "$ip" --version 2 --community "$comm")
        if snmp_disco_ok "$raw"; then label="v2c:${comm}"; _snmp_tok="$comm"; break; fi
        echo "[TRACE] snmp-disco $ip: v2c '$comm' -> ${raw:-<empty>}" >> "$LOG_FILE" 2>/dev/null || true
    done <<< "$communities"

    # 2. Try SNMPv3 USM credentials from the store
    if [[ -z "$label" ]]; then
        local creds; creds=$(read_creds)
        local v3c
        while IFS= read -r v3c; do
            [[ -z "$v3c" ]] && continue
            local v3u v3ap v3ap2 v3pp v3pp2
            v3u=$(echo "$v3c"   | jq -r '.username')
            v3ap=$(echo "$v3c"  | jq -r '.auth_proto // "SHA"')
            v3ap2=$(echo "$v3c" | jq -r '.auth_pass')
            v3pp=$(echo "$v3c"  | jq -r '.priv_proto // "AES"')
            v3pp2=$(echo "$v3c" | jq -r '.priv_pass')
            echo "[TRACE] snmp-disco $ip: trying v3 user '$v3u' ${v3ap}/${v3pp}" >> "$LOG_FILE" 2>/dev/null || true
            # authPriv (auth + priv) when a priv key is present, else authNoPriv
            if [[ -n "$v3pp2" && "$v3pp2" != "null" ]]; then
                raw=$(snmp_disco_run "$ip" --version 3 --user "$v3u" \
                    --auth_key "$v3ap2" --auth_proto "$v3ap" \
                    --priv_key "$v3pp2" --priv_proto "$v3pp")
            else
                raw=$(snmp_disco_run "$ip" --version 3 --user "$v3u" \
                    --auth_key "$v3ap2" --auth_proto "$v3ap")
            fi
            if snmp_disco_ok "$raw"; then
                label="v3:${v3u}"
                _snmp_tok="v3:${v3u}:${v3ap}:${v3ap2}:${v3pp}:${v3pp2}"
                break
            fi
            echo "[TRACE] snmp-disco $ip: v3 '$v3u' -> ${raw:-<empty>}" >> "$LOG_FILE" 2>/dev/null || true
        done < <(echo "$creds" | jq -c '.snmp_v3[]' 2>/dev/null || true)
    fi

    if [[ -z "$label" ]]; then
        echo "[TRACE] snmp-disco $ip: no SNMP credential succeeded" >> "$LOG_FILE" 2>/dev/null || true
        return
    fi
    echo "[TRACE] snmp-disco $ip: SUCCESS via $label" >> "$LOG_FILE" 2>/dev/null || true

    # 3. Map KaSaNaa JSON -> host-record SNMP contract.
    # NB: the raw JSON is passed via a FILE arg, not piped to stdin -- the
    # python program itself is read from stdin (the heredoc), so reading the
    # JSON from stdin too would conflict (the heredoc wins and json.load gets
    # an empty stream). This was silently discarding all SNMP data.
    printf '%s' "$raw" > "$tmp/kasanaa_raw.json"
    SNMP_LABEL="$label" python3 /dev/stdin "$tmp/kasanaa_raw.json" > "$tmp/snmp.json" 2>>"$LOG_FILE" <<'PYEOF'
import json, os, re, sys

try:
    with open(sys.argv[1]) as _f:
        k = json.load(_f)
except Exception:
    print('{"available":false}'); sys.exit(0)
if not isinstance(k, dict) or 'error' in k:
    print('{"available":false}'); sys.exit(0)

label = os.environ.get('SNMP_LABEL', '')

def _dehex(s):
    # Decode SNMP hex strings like '0x436973...' or '43 69 73 ...' to text
    t = s.strip()
    if t.lower().startswith('0x'):
        t = t[2:]
    compact = t.replace(' ', '')
    if len(compact) >= 4 and len(compact) % 2 == 0 \
            and re.fullmatch(r'[0-9A-Fa-f]+', compact):
        try:
            dec = bytes.fromhex(compact).decode('utf-8', 'replace')
            # keep only if it produced mostly printable text
            printable = sum(c.isprintable() or c in '\r\n\t' for c in dec)
            if dec and printable / len(dec) > 0.8:
                return dec.strip()
        except Exception:
            pass
    return s

def clean(v):
    if v is None: return ''
    s = str(v).strip()
    if s in ('Unknown', 'N/A', 'Unknown (Parsed from sysDescr)'): return ''
    if s.startswith('Unknown ('): return ''
    return _dehex(s)

sys_descr = clean(k.get('Description'))
sys_name  = clean(k.get('Device Name'))
sys_oid   = clean(k.get('System OID'))
if sys_oid.startswith('iso.'): sys_oid = '1.' + sys_oid[4:]
serial    = clean(k.get('Serial Number'))
model     = clean(k.get('Model Number'))
mfr       = clean(k.get('Manufacturer'))
krole     = clean(k.get('Device Type'))   # Router / Switch / Firewall / ''

details = k.get('Details', {}) or {}

# Interfaces from Ports: {name, mac, index, type}
interfaces = []
name_to_idx = {}
for p in details.get('Ports', []) or []:
    nm  = clean(p.get('Interface Name')) or clean(p.get('Interface Number'))
    idx = clean(p.get('Interface Number'))
    mac = clean(p.get('MAC Address'))
    if mac in ('0', '00:00:00:00:00:00'): mac = ''
    interfaces.append({'name': nm or 'if', 'mac': mac,
                       'index': idx or nm, 'type': 'other'})
    if nm: name_to_idx[nm] = idx or nm

# IP table from Network Adapters: {ip, if_index, mask}
ip_table = []
for a in details.get('Network Adapters', []) or []:
    ipa = clean(a.get('IP Address'))
    if not ipa or not re.match(r'^\d+\.\d+\.\d+\.\d+$', ipa): continue
    nm  = clean(a.get('Name'))
    msk = clean(a.get('Netmask')) or '255.255.255.0'
    idx = name_to_idx.get(nm)
    if idx is None:
        # adapter has no matching physical port -> add a logical interface
        idx = nm or ipa
        mac = clean(a.get('MAC Address'))
        if mac in ('0', '00:00:00:00:00:00'): mac = ''
        interfaces.append({'name': nm or ipa, 'mac': mac,
                           'index': idx, 'type': 'other'})
    ip_table.append({'ip': ipa, 'if_index': idx, 'mask': msk})

# Neighbors -> lldp_neighbors / cdp_neighbors
lldp, cdp = [], []
for n in details.get('Neighbors', []) or []:
    proto = (n.get('Protocol') or '').upper()
    nm    = clean(n.get('Neighbor Name'))
    rport = clean(n.get('Remote Port'))
    oif   = clean(n.get('Origin Interface'))
    lif   = clean(n.get('Local Interface Index'))
    if proto == 'CDP':
        cdp.append({'device_id': nm, 'remote_port': rport,
                    'local_port': oif, 'local_if_index': lif})
    else:
        # Keep BOTH sides: remote (sys_name/port_id) AND the local port on THIS
        # device (local_port / local_if_index). The local side is what cabling
        # needs -- "my port X connects to neighbor's port Y" -- and was being
        # dropped, leaving every switch-to-switch link unanchored.
        lldp.append({'sys_name': nm, 'port_id': rport, 'port_desc': rport,
                     'local_port': oif, 'local_if_index': lif})

# Entity inventory (one synthesised root component for model/serial extraction)
entity_inventory = []
if model or serial or sys_descr:
    entity_inventory.append({'desc': sys_descr, 'name': sys_name,
                             'model': model, 'serial': serial, 'sw_rev': ''})

out = {
    'available': True,
    'community': label,
    'sys_descr': sys_descr,
    'sys_name': sys_name,
    'sys_location': '',
    'sys_contact': '',
    'sys_uptime': '',
    'sys_oid': sys_oid,
    'chassis_serial': serial,
    'interfaces': interfaces,
    'ip_table': ip_table,
    'mac_port_map': [],
    'vlan_pvid': {},
    'vlan_names': {},
    'arp_entries': [],
    'cdp_neighbors': cdp,
    'lldp_neighbors': lldp,
    'entity_inventory': entity_inventory,
    'ip_forwarding': False,
    'is_printer_mib': False,
    'hr_is_printer': False,
    # KaSaNaa direct classifications (used as hints in merge_host_data)
    'kasanaa_manufacturer': mfr,
    'kasanaa_model': model,
    'kasanaa_role': krole,
}
print(json.dumps(out))
PYEOF

    # 4. Harvest this device's ARP/neighbor table (IP->MAC for the whole LAN).
    # Routers/firewalls/L3 gateways hold the entire subnet's IP->MAC, which lets
    # the reconciler resolve MACs the L2-blind scanner never sees -- including
    # Hyper-V VMs that report no guest IP (e.g. .235). Walks the classic AT table
    # (1.3.6.1.2.1.3.1.1.2) and the modern ipNetToMediaPhysAddress
    # (1.3.6.1.2.1.4.22.1.2); the last four OID octets are the IPv4 address and
    # the Hex-STRING value is the MAC. Read-only.
    if [[ -n "$_snmp_tok" ]]; then
        { _snmp_walk "$ip" "$_snmp_tok" 5 "1.3.6.1.2.1.3.1.1.2"
          _snmp_walk "$ip" "$_snmp_tok" 5 "1.3.6.1.2.1.4.22.1.2"
        } > "$tmp/arp_walk.txt" 2>/dev/null || true
        python3 /dev/stdin "$tmp/arp_walk.txt" > "$tmp/snmp_arp.json" 2>/dev/null <<'ARPEOF'
import json, re, sys
arp = {}
try:
    lines = open(sys.argv[1]).read().splitlines()
except Exception:
    lines = []
for ln in lines:
    if 'Hex-STRING' not in ln and 'STRING' not in ln:
        continue
    m = re.search(r'(\d+\.\d+\.\d+\.\d+)\s*=.*?((?:[0-9A-Fa-f]{2}[ :-]){5}[0-9A-Fa-f]{2})', ln)
    if not m:
        continue
    ip = m.group(1)
    mac = re.sub(r'[ -]', ':', m.group(2).strip()).lower()
    if len(mac) == 17 and mac != '00:00:00:00:00:00' and ip not in arp:
        arp[ip] = mac
print(json.dumps({'arp_table': [{'ip': k, 'mac': v} for k, v in arp.items()]}))
ARPEOF
    fi
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
PS_BASE = r"""
$ErrorActionPreference = "SilentlyContinue"
$cs   = Get-CimInstance Win32_ComputerSystem  2>$null
$os   = Get-CimInstance Win32_OperatingSystem 2>$null
$bios = Get-CimInstance Win32_BIOS            2>$null
$cpu  = Get-CimInstance Win32_Processor 2>$null | Select-Object -First 1
$nics = Get-NetAdapter 2>$null | Where-Object { $_.Status -eq "Up" } |
        ForEach-Object {
            $if = $_
            $v4 = Get-NetIPAddress -InterfaceIndex $if.ifIndex 2>$null |
                  Where-Object { $_.AddressFamily -eq "IPv4" -and $_.IPAddress -ne "127.0.0.1" }
            # Keep physical NICs (inventory) AND any adapter that actually holds an
            # IPv4 -- on a Hyper-V host the mgmt IP lives on a vEthernet (vSwitch)
            # virtual adapter while the physical NIC bound to the switch has none,
            # so -Physical alone returned NIC IPs as null.
            if ($if.HardwareInterface -or @($v4).Count -gt 0) {
                [ordered]@{ Name=$if.Name; Description=$if.InterfaceDescription;
                            MacAddress=($if.MacAddress -replace "-",":").ToUpper();
                            IPAddresses=@($v4.IPAddress); PrefixLens=@([int[]]$v4.PrefixLength) }
            }
        }
$isHyperV = $false
try { $isHyperV = ($null -ne (Get-Command Get-VM -ErrorAction SilentlyContinue)) } catch {}
$pdisks = @()
try {
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $pd = Get-PhysicalDisk 2>$null
    } else { $pd = Get-CimInstance Win32_DiskDrive 2>$null }
    foreach ($d in $pd) {
        $sz = [int64]0; $md = "Unknown"; $ifc = "Unknown"
        if ($d.Size) { $sz = [int64]$d.Size }
        if ($d.MediaType)        { $md  = [string]$d.MediaType }
        if ($d.BusType)          { $ifc = [string]$d.BusType }
        elseif ($d.InterfaceType){ $ifc = [string]$d.InterfaceType }
        if ($sz -gt 0) {
            $pdisks += [ordered]@{ SizeGB=[int][Math]::Ceiling($sz/1GB);
                                   Media=$md; Interface=$ifc }
        }
    }
} catch {}
[ordered]@{ Hostname=$cs.Name; Domain=$cs.Domain; Manufacturer=$cs.Manufacturer;
            Model=$cs.Model; SerialNumber=$bios.SerialNumber; OS=$os.Caption;
            OSVersion=$os.Version; IsServer=($os.ProductType -ne 1);
            IsHyperV=$isHyperV;
            CPUName=$cpu.Name; CPUCores=[int]$cpu.NumberOfCores;
            LogicalProcessors=[int]$cs.NumberOfLogicalProcessors;
            MemoryGB=[math]::Round($cs.TotalPhysicalMemory/1GB,2);
            PhysicalDisks=@($pdisks);
            NetworkAdapters=@($nics) } | ConvertTo-Json -Depth 4
"""

# Run separately ONLY on Hyper-V hosts. pywinrm run_ps base64-encodes the script
# and runs powershell -EncodedCommand via cmd.exe, whose command line caps at
# 8191 chars; the combined base+VM+neighbor script blew that limit ("The command
# line is too long"), losing the whole WinRM result. Splitting keeps each call
# well under the cap.
PS_HYPERV = r"""
$ErrorActionPreference = "SilentlyContinue"
$adByVm = @{}
Get-VMNetworkAdapter -VMName * 2>$null | ForEach-Object {
    $k = "$($_.VMName)"
    $m = ($_.MacAddress -replace "(..)(?=.)",'$1:').ToUpper()
    if (-not $adByVm.ContainsKey($k)) { $adByVm[$k] = @() }
    $adByVm[$k] += [ordered]@{ Name=$_.Name; MacAddress=$m;
                               SwitchName=$_.SwitchName;
                               IPAddresses=@($_.IPAddresses) }
}
$hvVMs = Get-VM 2>$null | ForEach-Object {
    $vm = $_
    $dbytes = [int64]0
    $dlist = @()
    foreach ($dd in (Get-VMHardDiskDrive -VMName $vm.Name 2>$null)) {
        try {
            if ($dd.Path -and (Test-Path $dd.Path)) {
                $vh = Get-VHD -Path $dd.Path -ErrorAction Stop
                if ($vh -and $vh.Size) { $dbytes += [int64]$vh.Size; $dlist += [int64]$vh.Size }
            }
        } catch {}
    }
    if ($vm.DynamicMemoryEnabled) { $memB = [int64]$vm.MemoryMaximum }
    else                          { $memB = [int64]$vm.MemoryStartup }
    [ordered]@{ Name=$vm.Name; State="$($vm.State)";
                Generation=$vm.Generation;
                ProcessorCount=[int]$vm.ProcessorCount;
                MemoryStartupBytes=$memB;
                DiskBytes=$dbytes;
                Disks=@($dlist);
                VMId="$($vm.VMId)";
                NetworkAdapters=@($adByVm["$($vm.Name)"]) }
}
$neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.State -in 'Reachable','Stale','Permanent' -and
                   $_.LinkLayerAddress -match '^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$' } |
    ForEach-Object {
        [ordered]@{ IP="$($_.IPAddress)";
                    MAC=($_.LinkLayerAddress -replace '-',':').ToLower() }
    }
[ordered]@{ HyperVVMs=@($hvVMs); NeighborTable=@($neighbors) } | ConvertTo-Json -Depth 6
"""

result = None
last_err = ""
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
            operation_timeout_sec=120, read_timeout_sec=130)
        r = sess.run_ps(PS_BASE)
        if r.status_code==0 and r.std_out:
            data = json.loads(r.std_out.decode("utf-8","replace").strip())
            data.update({"available":True,"auth_user":auth_user,"winrm_port":int(port)})
            if data.get("IsHyperV"):
                try:
                    r2 = sess.run_ps(PS_HYPERV)
                    if r2.status_code==0 and r2.std_out:
                        hv = json.loads(r2.std_out.decode("utf-8","replace").strip())
                        data["HyperVVMs"]    = hv.get("HyperVVMs") or []
                        data["NeighborTable"]= hv.get("NeighborTable") or []
                    else:
                        _se2 = (r2.std_err.decode("utf-8","replace")[:300] if getattr(r2,"std_err",None) else "")
                        data["hyperv_error"] = f"status={r2.status_code} stderr={_se2}"
                except Exception as e2:
                    data["hyperv_error"] = f"{type(e2).__name__}: {str(e2)[:300]}"
            result = data; break
        else:
            _se = (r.std_err.decode("utf-8","replace")[:400] if getattr(r,"std_err",None) else "")
            last_err = f"status={r.status_code} stderr={_se}"
    except Exception as e:
        last_err = f"{type(e).__name__}: {str(e)[:400]}"
        continue
with open(out_file,"w") as f:
    json.dump(result or {"available":False,"winrm_error":last_err}, f)
PYEOF
    rm -f "$creds_tmp"
}

# ?? Merge probe data ??????????????????????????????????????????????????????????
merge_host_data() {
    local ip="$1" tmp="$2"
    python3 /dev/stdin "$ip" "$tmp" <<'PYEOF'
import json, os, sys, re, html
ip=sys.argv[1]; tmp=sys.argv[2]
def load(f):
    p=os.path.join(tmp,f+'.json')
    try: return json.load(open(p)) if os.path.exists(p) else {}
    except: return {}
nmap=load('nmap'); snmp=load('snmp'); ssh=load('ssh')
http=load('http'); nb=load('netbios'); dns=load('dns')
bnr=load('banners'); mdns=load('mdns'); winrm=load('winrm')
arp=load('arp')
snmp_arp=load('snmp_arp')

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

def _valid_host(s):
    s = (s or '').strip()
    if not s or len(s) > 253 or s.lower() in ('none', 'null'):
        return False
    if any(c in s for c in ' ;#/'):          # resolver noise, not a hostname
        return False
    _sl = s.lower()
    return not any(b in _sl for b in (
        'communications error', 'timed out', 'connection refused', 'servfail',
        'nxdomain', 'no servers could be reached', '127.0.0.53'))

for src in (snmp.get('sys_name'),ssh.get('hostname'),nmap.get('hostname'),
            dns.get('ptr_hostname'),mdns.get('mdns_hostname'),nb.get('netbios_name')):
    if _valid_host(src):
        host['hostname']=src.strip(); break
if not host['hostname']:
    host['hostname']='device-'+ip.replace('.', '-')

host['mac']=nmap.get('mac') or (arp.get('mac') if isinstance(arp,dict) else None)
host['vendor']=nmap.get('vendor','')
# OS string priority: SNMP sysDescr is authoritative when present (it is the
# device's own self-report, e.g. "FreeBSD OPNsense 14.3", "pfSense 2.4.5",
# "Ubiquiti UniFi UCG-Fiber", "U6-Pro 6.8.2"). nmap's -O guess is frequently
# wrong for network appliances (seen: OPNsense->"Avaya G350", IPMI->"Cisco ASA",
# printer->"3M CT-30 thermostat"), so it is only a fallback.
_snmp_descr=(snmp.get('sys_descr') or '').strip()
# An SSH banner is the host's own self-report and is far more reliable than
# nmap's -O guess (which mis-fingerprints filtered hosts, e.g. a Debian box as
# "3Com OfficeConnect router"). Extract a distro from the OpenSSH banner.
_ssh_banner=(ssh.get('banner') or '').lower()
_ssh_distro=''
for _tok,_name in [('raspbian','Raspbian'),('ubuntu','Ubuntu Linux'),
                   ('debian','Debian Linux'),('freebsd','FreeBSD'),
                   ('centos','CentOS Linux'),('.el7','RHEL/CentOS 7'),
                   ('.el8','RHEL/CentOS 8'),('.el9','RHEL/CentOS 9'),
                   ('amzn','Amazon Linux'),('alpine','Alpine Linux')]:
    if _tok in _ssh_banner: _ssh_distro=_name; break
if _snmp_descr and not _snmp_descr.startswith('iso.'):
    host['os']=_snmp_descr[:120]
    host['os_accuracy']='snmp'
elif _ssh_distro:
    host['os']=_ssh_distro
    host['os_accuracy']='banner'
elif ssh.get('os'):
    host['os']=ssh['os']
    host['os_accuracy']='ssh'
else:
    host['os']=nmap.get('os') or ''
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
    # WinRM host hardware -> SAME shape the collector JSON import produces, so the
    # single writer can populate device custom fields (CPU/RAM/OS/disks) and create
    # host disks for WinRM-scanned hosts, not only collector-imported ones.
    if any(k in winrm for k in ('CPUName','CPUCores','MemoryGB','PhysicalDisks')):
        host['hardware']={
            'cpu_model':winrm.get('CPUName','') or '',
            'cpu_cores':winrm.get('CPUCores'),
            'logical_procs':winrm.get('LogicalProcessors'),
            'memory_gb':winrm.get('MemoryGB'),
            'physical_disks':[{'size_gb':d.get('SizeGB'),'media':d.get('Media'),
                               'interface':d.get('Interface')}
                              for d in (winrm.get('PhysicalDisks') or [])],
        }
    # Read-only Hyper-V VM inventory (name/state/cpu/mem + per-adapter MAC/IPs).
    # Used by the reconciler to map discovered devices to VMs and to create VMs
    # that were not independently IP-scanned. No NetBox writes happen here.
    host['hyperv_vms']=winrm.get('HyperVVMs') or []
    # IP->MAC table as seen from this Hyper-V host (L2-adjacent to its VMs);
    # the reconciler uses it to fill MACs the L2-blind scanner never learned.
    host['neighbor_table']=winrm.get('NeighborTable') or []

if nmap.get('ports'):         host['discovery_methods'].append('nmap')
if snmp.get('available'):     host['discovery_methods'].append('snmp')
if ssh.get('available'):      host['discovery_methods'].append('ssh')
if http.get('http_services'): host['discovery_methods'].append('http')
if nb.get('available'):       host['discovery_methods'].append('netbios')
if dns.get('ptr_hostname'):   host['discovery_methods'].append('dns')
if bnr.get('banners'):        host['discovery_methods'].append('banner')
if winrm.get('available'):    host['discovery_methods'].append('winrm')

# SNMP ARP/neighbor table (router/firewall/gateway holds the whole subnet's
# IP->MAC in one walk). Set for every host -- the L3 device that has it is often
# SNMP-only with no WinRM. The reconciler folds these IP->MAC pairs in to resolve
# MACs the L2-blind scanner never sees.
host['arp_table']=(snmp_arp.get('arp_table') if isinstance(snmp_arp,dict) else None) or []

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
# nmap mis-fingerprints filtered Windows hosts badly (seen: "Linux 2.6.18",
# "Allen Bradley MicroLogix 1100 PLC"). Windows-EXCLUSIVE ports are decisive:
# msrpc(135), RDP(3389), WinRM(5985/6), vmrdp(2179), MSMQ(1801,2103-2107),
# WSD(5357). When any are open and the OS guess isn't already Windows, assert
# "Microsoft Windows" -- fixes role (Workstation/Server) and mfr (Microsoft).
# NetBIOS/SMB (137-139,445) are excluded since Samba serves them on Linux.
_win_ports={'135','3389','5985','5986','2179',
            '1801','2103','2105','2107','5357'}
# Only override when we do NOT have an authoritative SNMP sysDescr. A device
# that answers SNMP with a real OS string (e.g. TrueNAS, which exposes WSD/5357)
# must not be relabeled Windows by a port heuristic.
if (open_ports & _win_ports) and 'windows' not in os_str \
        and not (snmp_up and sys_descr):
    host['os']='Microsoft Windows'; host['os_accuracy']=None
    os_str='microsoft windows'
# Stabilize port-only Windows hosts. Without WinRM/SNMP, nmap's edition guess
# flip-flops between runs ("Windows Server 2008" one scan, generic the next),
# which made the same host alternate Server/Workstation. When the only OS signal
# is a raw nmap guess (numeric accuracy) and Windows-exclusive ports are open,
# normalize to plain "Microsoft Windows" -> deterministically Workstation. Real
# servers are typed via WinRM IsServer (handled earlier) or a device override.
elif (open_ports & _win_ports) and not winrm.get('available') \
        and not (snmp_up and sys_descr) \
        and host.get('os_accuracy') not in ('snmp','banner','ssh',None):
    host['os']='Microsoft Windows'; host['os_accuracy']=None
    os_str='microsoft windows'
http_ttl=' '.join(s.get('title','') for s in host['http_services']).lower()
# Include entity MIB descriptions + model names so devices whose sysDescr
# is sparse (e.g. 'FortiGate-61E') still get classified from entity strings
entity_text=' '.join(
    ' '.join([e.get('desc',''),e.get('model','')])
    for e in snmp.get('entity_inventory',[])
).lower()
# Include nmap port script output (http-title, banners, etc.) in combined
# so devices identified via port scripts (e.g. FortiGate http-title) classify
# Build classification text from CURATED nmap scripts only. 'fingerprint-strings'
# is a raw dump of the full service response (incl. arbitrary HTML bodies); it
# leaks tokens like the CSS font "-apple-system" and the meta tag
# "apple-mobile-web-app-capable" that falsely matched the 'apple' vendor keyword,
# and could match router/printer keywords from any page text. Exclude it (and
# other raw response dumps) from keyword matching.
_skip_scripts={'fingerprint-strings','fingerprint-string','http-html-title'}
nmap_scripts=' '.join(
    str(v) for p in host.get('ports',[])
    for k,v in (p.get('scripts') or {}).items()
    if isinstance(v,str) and k not in _skip_scripts
).lower()
# Service banners (SSH/HTTP/raw) carry strong OS hints, e.g. an SSH banner of
# "SSH-2.0-OpenSSH_8.4p1 Debian-5" identifies a Debian/Linux host even when nmap
# could not fingerprint the OS and there is no SNMP. Fold them into the text.
banner_txt=' '.join([
    str(ssh.get('banner','') or ''),
    str(ssh.get('kernel','') or ''),
    ' '.join(str(b.get('banner','') or '') for b in host.get('banners',[])
             if isinstance(b,dict)),
    ' '.join(str(s.get('server','') or '') for s in host.get('http_services',[])
             if isinstance(s,dict)),
]).lower()
combined=' '.join([sys_descr,os_str,http_ttl,entity_text,nmap_scripts,banner_txt])
# 'trusted_txt' excludes the nmap -O OS guess (often wrong for appliances:
# OPNsense->Avaya, IPMI->Cisco ASA). Appliance-role keyword matches use this
# unless SNMP is up, so a bare nmap guess can't force Firewall/Router/Switch.
trusted_txt=' '.join([sys_descr,http_ttl,entity_text,nmap_scripts,banner_txt])
# Vendor-detection text: include the OS string only when it is trustworthy
# (SNMP sysDescr = 'snmp', or asserted e.g. "Microsoft Windows" = None), NOT a
# raw nmap -O guess (numeric accuracy), so a bogus "Cisco ASA" guess on an IPMI
# BMC does not leak a "Cisco" manufacturer.
_os_acc=host.get('os_accuracy')
mfr_txt=trusted_txt + ((' '+os_str) if _os_acc in (None,'snmp','banner','ssh') else '')
# class_txt: text used for appliance-role keyword matching (RT/SW/AP/PR/UP/CA).
# Like mfr_txt, it includes the OS string ONLY when trustworthy (SNMP sysDescr
# or asserted), never a raw nmap -O guess -- so a bogus "APC Silicon DP320E UPS"
# guess on an IPMI BMC cannot make it a UPS, and "Avaya G350" can't make a
# router. FW keeps its own stricter rule (trusted_txt) just above.
class_txt=mfr_txt
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
    ('1.3.6.1.4.1.12356.103.','Server',     'Fortinet'),   # FortiManager / FortiAnalyzer (mgmt appliances, not firewalls)
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
    ('1.3.6.1.4.1.50536.',  'Server',      'iXsystems'),   # TrueNAS / iXsystems
    # Switches (vendor-specific, added from field data)
    ('1.3.6.1.4.1.4526.',   'Switch',      'Netgear'),     # Netgear managed switches (GS110TP etc.)
    # Generic Cisco (catch-all, must come after specific Cisco entries)
    ('1.3.6.1.4.1.9.',      'Switch',      'Cisco'),       # Cisco (generic)
    # Juniper (catch-all)
    ('1.3.6.1.4.1.2636.',   'Router',      'Juniper'),     # Juniper (generic)
]

ip_forwarding=bool(snmp.get('ip_forwarding',False))
is_printer_mib=bool(snmp.get('is_printer_mib',False))
hr_is_printer=bool(snmp.get('hr_is_printer',False))
# KaSaNaa container direct classifications (used as hints/fallbacks)
k_role=(snmp.get('kasanaa_role') or '').strip()
k_mfr=(snmp.get('kasanaa_manufacturer') or '').strip()
k_model=(snmp.get('kasanaa_model') or '').strip()

# Apply OID-prefix classification before keyword matching.
# Use LONGEST matching prefix (not first match) so a specific entry like
# 1.3.6.1.4.1.12356.106 (FortiSwitch->Switch) wins over the generic
# 1.3.6.1.4.1.12356 (Fortinet->Firewall). Also require a component boundary
# so 1.3.6.1.4.1.9 (Cisco) does not match 1.3.6.1.4.1.99999.
_oid_role=None; _oid_mfr=None
if sys_oid:
    _best_len=-1
    for prefix,role,mfr in OID_MAP:
        _p=prefix.rstrip('.')
        if sys_oid==_p or sys_oid.startswith(_p+'.'):
            if len(_p)>_best_len:
                _best_len=len(_p); _oid_role=role; _oid_mfr=mfr
    # Ubiquiti reports a generic enterprise OID (41112) for UniFi APs that
    # lack a product sub-tree, which the catch-all maps to Router. If the
    # sysDescr names an access point model, correct the role to Wireless AP.
    if _oid_mfr=='Ubiquiti' and _oid_role in ('Router','Firewall'):
        _sd_l=(snmp.get('sys_descr') or '').lower()
        if any(t in _sd_l for t in ('u6-','u7-','u6pro','uap-','uap ',
                'unifi ap','access point','nanostation','litebeam',
                'nanobeam','powerbeam','airmax')):
            _oid_role='Wireless AP'

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
    'vmware','proxmox','freebsd','truenas','freenas','unraid','synology dsm',
    'nas4free','xigmanas','openmediavault']
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

if is_printer_mib or hr_is_printer:
    host['device_role']='Printer'
elif _oid_role:
    # OID-prefix match is authoritative. ipForwarding is a hint, NOT an
    # override -- many routers/firewalls do not expose ipForwarding via SNMP
    # (or the get times out), so it must never demote a definitive OID match.
    host['device_role']=_oid_role
    if _oid_mfr: host['manufacturer']=_oid_mfr
elif any(k in trusted_txt for k in FW) or (snmp_up and any(k in combined for k in FW)):
    host['device_role']='Firewall'
elif any(k in class_txt for k in RT) and (snmp_up or '161' in open_ports
     or '830' in open_ports or '8291' in open_ports):
    host['device_role']='Router'
elif any(k in class_txt for k in SW) and (snmp_up or '161' in open_ports):
    host['device_role']='Switch'
elif any(k in class_txt for k in AP):  host['device_role']='Wireless AP'
elif any(k in class_txt for k in PR) or \
     (len(open_ports & {'9100','515','631'}) >= 2):
    # Printer keyword, OR at least TWO classic printer ports together.
    # 9100 alone is ambiguous (Prometheus node-exporter, custom apps,
    # Docker hosts) so it no longer forces Printer on its own.
    host['device_role']='Printer'
elif any(k in class_txt for k in UP):  host['device_role']='UPS'
elif any(k in class_txt for k in CA):  host['device_role']='IP Camera'
elif 'windows server' in os_str or 'windows server' in combined:
    host['device_role']='Server'
elif 'windows' in os_str or 'windows' in combined:
    # Plain Windows (10/11/etc.) is a Workstation. Checked BEFORE the RDP
    # port rule because Win10/11 workstations commonly have 3389 open --
    # RDP being enabled does not make a desktop a server.
    host['device_role']='Workstation'
elif any(k in class_txt for k in SV):  host['device_role']='Server'
elif open_ports & {'2049','20048','111','21'}:
    # NFS exports (2049 nfsd, 20048 mountd, 111 rpcbind) or FTP (21) indicate a
    # file/server role even when nmap reported no OS. Checked before the SMB
    # Workstation fallback so a Linux NFS+Samba box is a Server, not Workstation.
    host['device_role']='Server'
elif '3389' in open_ports and not open_ports.intersection({'135','139','445'}):
    # RDP open with no Windows/SMB context: treat as a server-ish remote host
    host['device_role']='Server'
elif '5060' in open_ports or 'sip' in combined: host['device_role']='IP Phone'
elif '445' in open_ports or '135' in open_ports or nb.get('available'):
    host['device_role']='Workstation'
elif k_role in ('Router','Switch','Firewall') and snmp_up:
    # KaSaNaa container classified it via SNMP but our OID/keyword tables
    # did not match -- trust the container's L3/L2 determination.
    host['device_role']=k_role
elif ip_forwarding and snmp_up and not any(k in combined for k in SV) \
     and 'linux' not in combined and 'windows' not in os_str:
    # Last-resort only: device forwards IP and answers SNMP but matched no
    # OID/keyword/port signal AND shows no host-OS indicators (Linux/Windows
    # boxes and hypervisors routinely enable forwarding without being routers).
    host['device_role']='Router'

# Suppress an untrusted nmap OS guess for devices we have positively typed as
# network appliances (or identified via SNMP OID). A FortiGate showing
# "Tomato", a FortiAnalyzer showing "Aruba IAP-93 WAP", or a printer showing
# "SGI IRIX64" are bad nmap fingerprints -- appliances don't run those OSes.
# Keep SNMP sysDescr ('snmp') and asserted OS values (os_accuracy None).
# Suppress an untrusted nmap OS guess (numeric accuracy) when it cannot be
# trusted: OID-identified devices whose sysDescr was empty (FortiGate "Tomato",
# FortiAnalyzer "Aruba IAP-93"), and any non-host role (appliances, plus an
# IPMI/BMC Endpoint that nmap guessed as "Cisco Unified Communications"). Real
# host OSes (Server/Workstation) and SNMP/banner/ssh-derived OS are preserved.
if (_oid_role or host['device_role'] not in ('Server','Workstation')) \
        and host.get('os_accuracy') not in ('snmp','banner','ssh', None):
    host['os']=''; host['os_accuracy']=None

vendor=host.get('vendor','') or ''
if host.get('manufacturer','Unknown') not in ('','Unknown'):
    # An authoritative vendor was already set (WinRM Win32_ComputerSystem, or a
    # definitive SNMP OID). Do NOT let the nmap MAC vendor override it -- a
    # Hyper-V host's 00:15:5d NIC makes nmap report 'Microsoft', which was
    # clobbering the real 'HP' on SERVER03/04.
    pass
elif vendor not in ('','null','None'):
    host['manufacturer']=vendor
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
         'extreme':'Extreme Networks','alcatel':'Alcatel-Lucent',
         'opnsense':'Deciso','pfsense':'Netgate','netgate':'Netgate',
         'truenas':'iXsystems','ixsystems':'iXsystems','freenas':'iXsystems',
         'unifi':'Ubiquiti','edgeos':'Ubiquiti','proxmox':'Proxmox',
         'raspbian':'Raspberry Pi','raspberry':'Raspberry Pi'}
    # Skip keyword MFR lookup when OID already identified the vendor;
    # prevents script text from overriding a definitive OID match
    if not _oid_mfr:
        for k,v in MFR.items():
            if k in mfr_txt: host['manufacturer']=v; break
    else:
        host['manufacturer']=_oid_mfr
# KaSaNaa manufacturer as a fallback when nothing else resolved a vendor
if host.get('manufacturer','Unknown') in ('','Unknown') and k_mfr \
        and k_mfr not in ('Unknown','Unknown (Net-SNMP)'):
    host['manufacturer']=k_mfr

# Model extraction priority:
#   1. KaSaNaa container's Model Number (clean ENTITY-MIB model, e.g.
#      "FortiSwitch-224E") -- preferred over the freeform sysDescr text
#   2. entity_inventory sw_rev first word / model
#   3. sysDescr text
#   4. SSH device info / OS string
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

sd=snmp.get('sys_descr','') or ''
# Model from an HTTP management page title: web-managed devices (printers,
# cameras, NAS, appliances) put the model there, e.g. a printer's title is
# "HP Color LaserJet MFP M277dw   192.168.0.41". Clean HTML entities, strip a
# trailing IP, and accept only model-like strings (letters + a digit), not a
# generic page title (Login / Dashboard / etc.).
_http_model=''
for _s in host.get('http_services',[]):
    _t=(_s.get('title') or '').strip()
    if not _t: continue
    _t=html.unescape(_t)
    _t=re.sub(r'\s+',' ',_t).strip()
    _t=re.sub(r'\s*\d{1,3}(?:\.\d{1,3}){3}\s*$','',_t).strip()  # trailing IP
    if (re.search(r'[A-Za-z]',_t) and re.search(r'\d',_t) and 2<len(_t)<=80
            and not re.search(r'\b(login|sign in|sign-in|dashboard|home|'
                              r'index|welcome|error|forbidden|unauthorized|'
                              r'not found|loading|please wait|apache|nginx|'
                              r'iis|lighttpd|tomcat|default page|test page|'
                              r'it works|web server|placeholder)\b',_t,re.I)):
        _http_model=_t; break
_winrm_model = winrm.get('Model') if (isinstance(winrm, dict) and winrm.get('available')) else None
if _winrm_model and str(_winrm_model).strip():
    # WinRM reports the host's own hardware model (e.g. 'HP Z210 Workstation',
    # 'Virtual Machine'); authoritative for Windows hosts. Must win over the
    # SNMP/HTTP/OS fallbacks below, which otherwise clobbered it with the OS.
    host['model']=str(_winrm_model)[:80]
elif k_model and k_model not in ('Unknown',):
    host['model']=k_model[:80]
elif _ent_model:
    host['model']=_ent_model
elif sd:
    host['model']=sd[:120].strip()
elif _http_model:
    host['model']=_http_model
elif ssh.get('net_device_info'):
    lns=[l for l in ssh['net_device_info'].split('\n') if l.strip()]
    host['model']=lns[0][:120].strip() if lns else 'Unknown'
else:
    host['model']=(host['os'] or 'Unknown')[:80]

print(json.dumps(host))
PYEOF
}

# -----------------------------------------------------------------------------
# SWITCHPORT MAPPING
# -----------------------------------------------------------------------------
map_switchports() {
    local switch_ip="$1"
    log_step "Switchport Mapping: $switch_ip"
    local creds; creds=$(read_creds)
    local communities; communities=$(get_communities_for "$switch_ip")
    # Bundle ALL credentials (ordered v2c communities + v3 USM creds) so the
    # walker can try each until one answers -- the old code took only the first
    # community (usually 'public') and had no SNMPv3 support, so any switch on a
    # non-default community or v3-only (e.g. the FortiGate) returned nothing.
    local cred_json
    cred_json=$(jq -n \
        --argjson v2c "$(printf '%s\n' "$communities" | jq -R . | jq -s 'map(select(length>0))')" \
        --argjson v3 "$(echo "$creds" | jq -c '.snmp_v3 // []')" \
        '{v2c:$v2c, v3:$v3}' 2>/dev/null)
    [[ -z "$cred_json" ]] && cred_json='{"v2c":["public"],"v3":[]}'
    python3 /dev/stdin "$switch_ip" "$cred_json" \
            "$SNMP_TIMEOUT" "$DISCOVERY_DIR" <<'PYEOF'
import subprocess, json, re, sys, os
ip=sys.argv[1]; cred_json=sys.argv[2]; timeout=sys.argv[3]; disc_dir=sys.argv[4]
try:
    CREDS=json.loads(cred_json)
except Exception:
    CREDS={'v2c':['public'],'v3':[]}

def _norm_auth(a):
    a=(a or 'SHA').upper().replace('SHA1','SHA').replace('SHA-1','SHA')
    return a
def _norm_priv(p):
    p=(p or 'AES').upper()
    return {'AES128':'AES','AES-128':'AES','AES256':'AES-256','AES192':'AES-192'}.get(p,p)

def _v2c_args(c): return ['-v','2c','-c',c]
def _v3_args(v):
    a=['-v','3','-u',v.get('username','') or '']
    apw=v.get('auth_pass') or ''; ppw=v.get('priv_pass') or ''
    ap=_norm_auth(v.get('auth_proto')); pp=_norm_priv(v.get('priv_proto'))
    if ppw and ppw!='null':
        a+=['-l','authPriv','-a',ap,'-A',apw,'-x',pp,'-X',ppw]
    elif apw and apw!='null':
        a+=['-l','authNoPriv','-a',ap,'-A',apw]
    else:
        a+=['-l','noAuthNoPriv']
    return a

# Discover the working credential once, by reading sysDescr.0.
CANDS=[_v2c_args(c) for c in (CREDS.get('v2c') or [])] \
     + [_v3_args(v) for v in (CREDS.get('v3') or [])]
def _probe(cred):
    try:
        r=subprocess.run(['snmpget',*cred,'-t',timeout,'-r','1',ip,'1.3.6.1.2.1.1.1.0'],
                         capture_output=True,text=True,timeout=15)
        out=r.stdout or ''
        return ('= STRING:' in out) or ('= Hex-STRING:' in out)
    except Exception:
        return False
SNMP_CRED=None
for cand in CANDS:
    if _probe(cand): SNMP_CRED=cand; break
if SNMP_CRED is None:
    print('  No working SNMP credential for {0} (tried {1} v2c + {2} v3)'.format(
        ip, len(CREDS.get('v2c') or []), len(CREDS.get('v3') or [])))
    sys.exit(0)
_lbl = ('v2c '+SNMP_CRED[SNMP_CRED.index('-c')+1]) if '-c' in SNMP_CRED \
       else ('v3 '+SNMP_CRED[SNMP_CRED.index('-u')+1])
print('  SNMP auth: {0}'.format(_lbl))

def walk(oid,cred=None):
    c=cred or SNMP_CRED
    try:
        r=subprocess.run(['snmpwalk',*c,'-t',timeout,'-r','1',ip,oid],
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
    def _vlan_cred(vid):
        c=SNMP_CRED[:]
        if '-c' in c:
            ci=c.index('-c'); c[ci+1]='{0}@{1}'.format(c[ci+1],vid)
        else:
            c=c+['-n','vlan-{0}'.format(vid)]
        return c
    for vid in list(vlan_names.keys())[:10]:
        for line in walk('1.3.6.1.2.1.17.4.3.1.2',cred=_vlan_cred(vid)).split('\n'):
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

# --- LLDP overlay: authoritative switch-to-switch cabling -------------------
# The FDB/bridge mapping above is right for endpoint ports but wrong for
# uplinks/trunks -- a trunk learns every MAC reachable behind it, so it can't
# say which neighbor is on the port. LLDP states it directly (neighbor + local
# port). The main SNMP scan already captures LLDP with the local port into each
# host's lldp_neighbors (handling v3 / FortiSwitch); pull the most recent
# capture for this switch and attach each link to its local port. Falls back
# silently to FDB-only if no capture is available.
import glob
lldp_by_idx={}; lldp_by_name={}; lldp_src=''
try:
    cands=sorted(glob.glob(os.path.join(disc_dir,'results_*.json')),
                 key=os.path.getmtime, reverse=True)
    for rf in cands[:3]:
        rd=json.load(open(rf))
        hosts=(rd.get('hosts') if isinstance(rd,dict) else rd) or []
        match=None
        for h in hosts:
            if h.get('ip')==ip: match=h; break
        if not match: continue
        # This switch's own identity, to drop self-referential LLDP entries
        # (a stack/aggregate interface that reports the switch itself as the
        # neighbor). Real switch-to-switch links -- even where the local port is
        # named after the PEER's serial -- have neighbor != own id and are kept.
        self_ids={str(match.get('hostname') or '').strip().lower(),
                  str(match.get('serial') or '').strip().lower()}
        self_ids.discard('')
        for n in (match.get('lldp_neighbors') or []):
            nb=(n.get('sys_name') or '').strip()
            if nb and nb.lower() in self_ids:
                continue  # self-referential -- not a cable
            li=str(n.get('local_if_index') or '').strip()
            lp=str(n.get('local_port') or '').strip()
            rec={'neighbor':nb,'remote_port':n.get('port_id') or ''}
            if not rec['neighbor'] and not rec['remote_port']: continue
            if li: lldp_by_idx.setdefault(li,rec)
            if lp: lldp_by_name.setdefault(lp.lower(),rec)
        if lldp_by_idx or lldp_by_name:
            lldp_src=os.path.basename(rf); break
except Exception:
    pass

for idx,ent in if_entries.items():
    link=lldp_by_idx.get(str(idx)) or lldp_by_name.get(str(ent['if_name']).lower())
    ent['lldp_neighbor']=link['neighbor'] if link else ''
    ent['lldp_remote_port']=link['remote_port'] if link else ''

port_entries=sorted(if_entries.values(),key=lambda x:x['if_name'])
out_file=os.path.join(disc_dir,'switchport_'+ip.replace('.', '-')+'.json')
with open(out_file,'w') as f:
    json.dump({'switch_ip':ip,'interfaces':port_entries,
               'vlan_names':vlan_names,'interface_count':len(if_names),
               'mac_count':len(mac_to_port),'lldp_source':lldp_src},f,indent=2)

print('  Saved: '+out_file)
print('\n  Switch     : '+ip)
print('  Interfaces : {0}'.format(len(if_names)))
print('  MAC entries: {0}'.format(len(mac_to_port)))
if lldp_src:
    nl=sum(1 for e in port_entries if e.get('lldp_neighbor'))
    print('  LLDP links : {0} (from {1})'.format(nl, lldp_src))
if vlan_names:
    pairs=sorted(vlan_names.items(),key=lambda x:int(x[0]) if x[0].isdigit() else 0)[:10]
    print('  VLANs      : '+', '.join('{0}={1}'.format(k,v) for k,v in pairs))
print()
hdr='  {:<24} {:<5} {:<5} {:<8} {:<6} {:<18} {:<22} {}'.format(
    'Interface','Adm','Oper','Speed','VLAN','VLAN Name','LLDP Neighbor','Remote IPs / Clients')
print(hdr); print('  '+'-'*120)
for e in port_entries:
    cl=', '.join(e['remote_ips']) if e['remote_ips'] else ', '.join(e['clients'][:3])
    nbr=e.get('lldp_neighbor','')
    if nbr and e.get('lldp_remote_port'): nbr=nbr+':'+e['lldp_remote_port']
    print('  {:<24} {:<5} {:<5} {:<8} {:<6} {:<18} {:<22} {}'.format(
        e['if_name'][:23],e['admin'][:4],e['oper'][:4],e['speed'][:7],
        str(e['vlan'])[:5],e['vlan_name'][:17],nbr[:21],cl[:46]))
if not port_entries:
    print('  (No interfaces found -- check SNMP community and device support)')
PYEOF
}


# -----------------------------------------------------------------------------
# PHASE B: RECONCILIATION (collect -> reconcile -> sync)
# -----------------------------------------------------------------------------
# Collapses cross-host duplicates in a results_*.json into a canonical
# device/VM model BEFORE syncing. Pure data transform, no NetBox calls.
# Passes (union-find, transitive): (1) SNMP ip_table ownership folds a secondary
# IP into its owner (192.168.0.2 -> .253); (2) shared interface MAC;
# (3) normalized short hostname (FQDN<->NetBIOS<->dual-homed), excluding generic
# default names so two "iPhone" devices stay separate. Richest record wins
# identity; losers become secondary_ips + sync_as=skip. VM tagging: a Hyper-V
# OUI 00:15:5d interface MAC on a non-hypervisor -> sync_as=vm (OPNsense/pfSense
# /FortiManager/FortiAnalyzer). Writes <results>.reconciled.json.
#
# reconcile_results <results_file> [--preview]
reconcile_results() {
    local results_file="${1:-}"
    [[ -z "$results_file" ]] \
        && results_file=$(latest_scan_file)
    if [[ ! -f "$results_file" ]]; then
        log_error "No results file to reconcile"; return 1
    fi
    local pyf; pyf=$(mktemp --suffix=.py)
    cat > "$pyf" <<'PYEOF'
import json, sys, re, os

HYPERV_OUI = "00:15:5d"
_OUI_CACHE = None
def oui_vendor(mac):
    # Map a MAC's OUI (first 3 octets) to a vendor. The scanner is L3-only, so a
    # device's only MAC is the one this reconciler resolves from the gateway ARP
    # table -- this turns it into a real manufacturer instead of a guessed
    # default. Uses nmap's own prefix file (present wherever nmap runs), with a
    # tiny embedded fallback for the most common virt/SBC prefixes.
    global _OUI_CACHE
    if not mac:
        return ""
    hx = re.sub(r"[^0-9A-Fa-f]", "", str(mac)).upper()
    if len(hx) < 6:
        return ""
    if _OUI_CACHE is None:
        _OUI_CACHE = {}
        for path in ("/usr/share/nmap/nmap-mac-prefixes",
                     "/usr/local/share/nmap/nmap-mac-prefixes",
                     "/opt/homebrew/share/nmap/nmap-mac-prefixes"):
            try:
                if os.path.exists(path):
                    for line in open(path, encoding="utf-8", errors="replace"):
                        line = line.strip()
                        if not line or line.startswith("#"):
                            continue
                        parts = line.split(None, 1)
                        if len(parts) == 2 and len(parts[0]) == 6:
                            _OUI_CACHE[parts[0].upper()] = parts[1].strip()
                    break
            except Exception:
                pass
        for k, v in {"00155D": "Microsoft", "000C29": "VMware",
                     "005056": "VMware", "000569": "VMware",
                     "B827EB": "Raspberry Pi", "DCA632": "Raspberry Pi",
                     "E45F01": "Raspberry Pi"}.items():
            _OUI_CACHE.setdefault(k, v)
    return _OUI_CACHE.get(hx[:6], "")
# Set in __main__; persistent IP<->MAC cache so VM IPs survive a scan where a
# router's ARP entry has aged out (the ARP tables are authoritative but volatile).
CACHE_PATH = None
# Set in __main__; persistent host-identity cache so a host's hostname, role and
# Hyper-V status survive a run where DNS/SNMP/WinRM transiently fail.
ID_CACHE_PATH = None

# Default/generic hostnames shared by many distinct devices -- never a merge key.
# (Two iPhones both mDNS-named "iPhone" are different phones, not one device;
# real unique names like "server03" still merge dual-homed records correctly.)
GENERIC_NAMES = {
    "localhost", "iphone", "ipad", "ipod", "android", "android-2",
    "raspberrypi", "ubuntu", "debian", "kali", "openwrt", "pfsense",
    "esp32", "esp8266", "espressif", "chromecast", "googlehome", "echo",
    "amazon", "fire", "roku", "shield", "switch", "printer", "scanner",
    "nas", "router", "gateway", "ap", "camera", "unknown", "new-host",
    "user-pc", "desktop", "laptop", "windows", "macbook", "imac",
}


def is_auto_name(name):
    if not name:
        return True
    return name.lower().startswith("device-") and \
        name.replace("device-", "").replace("-", "").isdigit()


def short_name(name):
    if not name or is_auto_name(name):
        return ""
    s = name.split(".")[0].strip().lower()
    # generic default names are not unique enough to merge on
    if s in GENERIC_NAMES:
        return ""
    return s


def host_macs(h):
    macs = set()
    for i in h.get("interfaces", []) or []:
        m = (i.get("mac") or "").strip().lower()
        if m and len(m) == 17:
            macs.add(m)
    m = (h.get("mac") or "").strip().lower()    # top-level (ARP-captured) MAC
    if m and len(m) == 17:
        macs.add(m)
    return macs


def ip_table_ips(h):
    """All IPs this host reports owning via SNMP ip_table (skip loopback)."""
    out = []
    for e in h.get("ip_table", []) or []:
        ip = (e.get("ip") or "").strip()
        if not ip or ip.startswith("127.") or ip == "0.0.0.0":
            continue
        out.append(e)
    return out


def richness(h):
    """Higher = more authoritative; decides which record wins a merge group."""
    score = 0
    tier = h.get("scan_tier", 4)
    score += (5 - tier) * 100            # winrm(1) > ssh(2) > snmp(3) > nmap(4)
    if h.get("snmp_details", {}).get("sys_oid"):
        score += 50
    if h.get("winrm_nics"):
        score += 40
    if not is_auto_name(h.get("hostname")):
        score += 30
    score += len(h.get("interfaces", []) or [])
    score += len(h.get("ports", []) or [])
    return score


class UF:
    def __init__(self, items):
        self.p = {x: x for x in items}

    def find(self, x):
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[ra] = rb


def reconcile(data):
    hosts = data.get("hosts", [])

    # ---- Persistent host-identity cache (backfill) --------------------------
    # Discovery is probabilistic: DNS, SNMP sysName and WinRM each fail
    # intermittently, so for a single run a host can lose its hostname (falling
    # back to device-<ip>), its role, or its is_hyperv flag + VM inventory (which
    # then drops the cluster and orphans its VMs). Carry the last KNOWN-GOOD
    # identity across runs: anything missing THIS run is backfilled from cache;
    # a real value found this run always wins and refreshes the cache (saved at
    # the end of reconcile()).
    def _is_fallback_name(hn, ip):
        return (not hn) or hn == ('device-' + (ip or '').replace('.', '-'))
    def _valid_host(s):
        s = (s or '').strip()
        if not s or len(s) > 253 or s.lower() in ('none', 'null'):
            return False
        if any(c in s for c in ' ;#/'):
            return False
        _sl = s.lower()
        return not any(b in _sl for b in (
            'communications error', 'timed out', 'connection refused', 'servfail',
            'nxdomain', 'no servers could be reached', '127.0.0.53'))
    def _bad_host(hn, ip):
        # unusable as a name: the device-<ip> fallback OR resolver noise that an
        # older scan may already have baked into the results file (e.g. .41's
        # ';; communications error ...'). Either should yield to the cache.
        return _is_fallback_name(hn, ip) or not _valid_host(hn)
    _idc = {}
    if ID_CACHE_PATH:
        try:
            _idc = json.load(open(ID_CACHE_PATH))
        except Exception:
            _idc = {}
        if not isinstance(_idc, dict):
            _idc = {}
        for h in hosts:
            ip = h.get("ip")
            if not ip:
                continue
            cached = _idc.get(ip) or {}
            if _bad_host(h.get("hostname"), ip):
                if cached.get("hostname") and _valid_host(cached["hostname"]):
                    h["hostname"] = cached["hostname"]
                    h["identity_source"] = "cache"
                elif not _is_fallback_name(h.get("hostname"), ip):
                    # invalid name, nothing cached -> scrub to the clean fallback
                    h["hostname"] = 'device-' + ip.replace('.', '-')
            for f in ("device_role", "manufacturer", "model", "serial"):
                if not (str(h.get(f) or "").strip()) and cached.get(f):
                    h[f] = cached[f]
            # Restore Hyper-V status + last VM list only when this run found none,
            # so a transient WinRM failure keeps the cluster and its VMs.
            if (not h.get("is_hyperv")) and cached.get("is_hyperv") \
                    and not (h.get("hyperv_vms")):
                h["is_hyperv"] = True
                if cached.get("hyperv_vms"):
                    h["hyperv_vms"] = cached["hyperv_vms"]
                h["identity_source"] = "cache"

    by_ip = {h["ip"]: h for h in hosts}
    ips = list(by_ip.keys())
    uf = UF(ips)
    reasons = {}   # (loser_ip) -> reason string

    # ---- Pass 1: SNMP ip_table ownership (folds secondary IPs like .2 -> .253)
    # Map every secondary IP -> the host that reports it in its ip_table.
    owner_of = {}
    for h in hosts:
        for e in ip_table_ips(h):
            ip = e["ip"]
            if ip != h["ip"]:
                owner_of.setdefault(ip, h["ip"])
    for ip in ips:
        owner = owner_of.get(ip)
        if owner and owner in by_ip and owner != ip:
            uf.union(ip, owner)
            reasons[ip] = f"secondary IP in {owner} SNMP ip_table"

    # ---- Pass 2: shared interface MAC
    mac_to_ip = {}
    for h in hosts:
        for m in host_macs(h):
            if m in mac_to_ip and mac_to_ip[m] != h["ip"]:
                uf.union(h["ip"], mac_to_ip[m])
                reasons.setdefault(h["ip"], f"shares MAC {m} with {mac_to_ip[m]}")
            else:
                mac_to_ip[m] = h["ip"]

    # ---- Pass 3: normalized short hostname (real names only)
    name_to_ip = {}
    for h in hosts:
        s = short_name(h.get("hostname"))
        if not s:
            continue
        if s in name_to_ip and name_to_ip[s] != h["ip"]:
            uf.union(h["ip"], name_to_ip[s])
            reasons.setdefault(h["ip"], f"same short-name '{s}' as {name_to_ip[s]}")
        else:
            name_to_ip[s] = h["ip"]

    # ---- Group, pick canonical deterministically, build merge output
    # Canonical selection (ascending sort, first wins):
    #   1. NOT an ip_table secondary -- a folded secondary (.2) can never win
    #      over its owner (.253), regardless of IP order.
    #   2. real name beats an auto-name (device-x-x-x-x) so the survivor keeps a
    #      meaningful hostname.
    #   3. lowest IP -- deterministic, stable across runs (user's choice).
    secondary_ips_set = set(owner_of.keys())

    def ipint(ip):
        try:
            return tuple(int(o) for o in ip.split("."))
        except ValueError:
            return (999, 999, 999, 999)

    def canon_key(h):
        return (h["ip"] in secondary_ips_set,
                is_auto_name(h.get("hostname")),
                ipint(h["ip"]))

    groups = {}
    for ip in ips:
        groups.setdefault(uf.find(ip), []).append(ip)

    for h in hosts:
        h["sync_as"] = "device"
        h["canonical"] = True
        h["merged_from"] = []
        h.setdefault("secondary_ips", [])

    # Role rank for enrichment: a stronger role on a merged-away interface wins
    # (a dual-homed Hyper-V host whose .243 NIC looks like a bare Windows box
    # must still end up Server, is_hyperv, with its VM inventory).
    _role_rank = {"Firewall": 6, "Router": 6, "Switch": 5, "Wireless AP": 5,
                  "Server": 4, "Printer": 4, "IP Camera": 4, "UPS": 4,
                  "Storage": 4, "Workstation": 2, "Endpoint": 1, "": 0}

    def enrich(winner, loser):
        # Hyper-V identity + VM inventory must survive onto the canonical record.
        winner["is_hyperv"] = bool(winner.get("is_hyperv") or loser.get("is_hyperv"))
        if not winner.get("hyperv_vms") and loser.get("hyperv_vms"):
            winner["hyperv_vms"] = loser["hyperv_vms"]
        if not winner.get("winrm_nics") and loser.get("winrm_nics"):
            winner["winrm_nics"] = loser["winrm_nics"]
        if not winner.get("hardware") and loser.get("hardware"):
            winner["hardware"] = loser["hardware"]
        # Strongest role wins.
        if _role_rank.get(loser.get("device_role"), 0) > \
                _role_rank.get(winner.get("device_role"), 0):
            winner["device_role"] = loser["device_role"]
        # Fill identity fields the winner is missing.
        for f in ("manufacturer", "model", "os", "serial", "vendor", "hostname"):
            wv = (winner.get(f) or "").strip()
            lv = (loser.get(f) or "").strip()
            if (not wv or wv in ("Unknown",) or
                    (f == "hostname" and is_auto_name(wv))) and lv:
                winner[f] = loser[f]
        if loser.get("snmp_details", {}).get("sys_oid") and \
                not winner.get("snmp_details", {}).get("sys_oid"):
            winner["snmp_details"] = loser["snmp_details"]
        # Best (lowest) scan tier, unioned interfaces + discovery methods.
        winner["scan_tier"] = min(winner.get("scan_tier", 4),
                                  loser.get("scan_tier", 4))
        seen_if = {(i.get("mac"), i.get("name")) for i in winner.get("interfaces", [])}
        for i in loser.get("interfaces", []) or []:
            k = (i.get("mac"), i.get("name"))
            if k not in seen_if:
                winner.setdefault("interfaces", []).append(i)
                seen_if.add(k)
        winner["discovery_methods"] = sorted(set(
            (winner.get("discovery_methods") or []) +
            (loser.get("discovery_methods") or [])))

    for _, members in groups.items():
        recs = sorted((by_ip[ip] for ip in members), key=canon_key)
        winner = recs[0]
        for loser in recs[1:]:
            enrich(winner, loser)
            winner["merged_from"].append(loser["ip"])
            # absorb loser's primary IP + its ip_table IPs as secondaries
            absorbed = [{"ip": loser["ip"], "mask": "255.255.255.0",
                         "if_index": None, "from": loser["ip"]}]
            for e in ip_table_ips(loser):
                if e["ip"] != winner["ip"]:
                    absorbed.append({"ip": e["ip"],
                                     "mask": e.get("mask", "255.255.255.0"),
                                     "if_index": e.get("if_index"),
                                     "from": loser["ip"]})
            winner["secondary_ips"].extend(absorbed)
            # union discovered ports onto the winner
            seen = {(p.get("port"), p.get("proto")) for p in winner.get("ports", [])}
            for p in loser.get("ports", []):
                key = (p.get("port"), p.get("proto"))
                if key not in seen:
                    winner.setdefault("ports", []).append(p)
                    seen.add(key)
            loser["sync_as"] = "skip"
            loser["canonical"] = False
            loser["merged_into"] = winner["ip"]
            loser["merge_reason"] = (reasons.get(loser["ip"])
                                     or reasons.get(winner["ip"])
                                     or "same device as %s" % winner["ip"])

    # ---- Neighbor/ARP MAC backfill -----------------------------------------
    # The scanner is frequently L2-blind (NAT'd container) and learns no MACs,
    # and nmap -Pn captures none either. Two L2-adjacent sources fill them in:
    #   * each Hyper-V host's Get-NetNeighbor table (it is on its VMs' vSwitch);
    #   * any SNMP L3 device's ARP table (a router/firewall/gateway holds the
    #     whole subnet's IP->MAC in one walk).
    # discovered-IP -> MAC (here) -> VM (inventory) then binds VMs whose guest IP
    # is not reported (e.g. CLI SysLog Server -> .235).
    ip2mac = {}
    for h in hosts:
        for n in h.get("neighbor_table", []) or []:
            ip = (n.get("IP") or "").strip()
            mac = (n.get("MAC") or "").strip().lower()
            if ip and len(mac) == 17 and ip not in ip2mac:
                ip2mac[ip] = mac
        for n in h.get("arp_table", []) or []:
            ip = (n.get("ip") or "").strip()
            mac = (n.get("mac") or "").strip().lower()
            if ip and len(mac) == 17 and ip not in ip2mac:
                ip2mac[ip] = mac
    # Persist IP<->MAC across runs. Router/firewall ARP is the source of truth
    # but volatile: an entry can be absent for one scan (aging, SNMP timeout),
    # which would strip a VM's IP and turn it into a phantom device. Fill gaps
    # from history (this scan always wins), then save the union back.
    if CACHE_PATH:
        try:
            _hist = json.load(open(CACHE_PATH))
        except Exception:
            _hist = {}
        if isinstance(_hist, dict):
            for _ip, _mac in _hist.items():
                if _ip not in ip2mac and isinstance(_mac, str) and len(_mac) == 17:
                    ip2mac[_ip] = _mac.lower()
        try:
            json.dump(ip2mac, open(CACHE_PATH, "w"))
        except Exception:
            pass
    # Inverse map (MAC -> IP) to recover the guest IP of a VM that reports none
    # via Get-VMNetworkAdapter: its vNIC MAC is in the gateway/host ARP tables.
    mac2ip = {}
    for ip, mac in ip2mac.items():
        mac2ip.setdefault(mac, ip)
    for h in hosts:
        if not host_macs(h):
            m = ip2mac.get(h["ip"])
            if m:
                h["mac"] = m
                h.setdefault("mac_source", "arp/neighbor")

    # Manufacturer for hosts whose TYPE we couldn't identify: at scan time there
    # was no MAC (L3 scanner), so the only vendor signal was a substring keyword
    # guess that defaulted to 'HP'. Now that the MAC is resolved from ARP, use the
    # real NIC vendor via an OUI lookup instead. Identified hosts (Server, Switch,
    # Printer, WinRM/OID, ...) carry a real role and are left untouched.
    for h in hosts:
        if h.get("device_role") in ("Endpoint", "Unknown", "", None):
            macs = host_macs(h)
            mac = next(iter(macs), None) if macs else None
            mac = mac or ip2mac.get(h.get("ip"))
            ov = oui_vendor(mac)
            if ov:
                h["manufacturer"] = ov
                h["manufacturer_source"] = "oui"

    # ---- VM resolution from Hyper-V inventory -------------------------------
    # Every VM instance is its OWN VM (Hyper-V Replica copies are NOT collapsed):
    # a primary and its replica become two separate NetBox VMs on their two
    # hosts. The only subtlety is binding: a primary and its Off replica can
    # share a MAC, so when a live discovered IP matches more than one instance we
    # bind it to the RUNNING one (the replica is Off and isn't serving that IP);
    # the replica still appears as its own VM record.
    vm_inv = []
    for h in hosts:
        if h.get("sync_as") == "skip":
            continue
        for vm in h.get("hyperv_vms", []) or []:
            macs, ips = set(), set()
            for a in vm.get("NetworkAdapters", []) or []:
                m = (a.get("MacAddress") or "").strip().lower()
                if m and len(m) == 17 and m != "00:00:00:00:00:00":
                    macs.add(m)
                for ip in a.get("IPAddresses", []) or []:
                    ip = (ip or "").strip()
                    if ip and ":" not in ip and not ip.startswith("169.254") \
                            and not ip.startswith("127."):
                        ips.add(ip)
            vm_inv.append({
                "name": vm.get("Name", ""), "host_ip": h["ip"],
                "host_name": h.get("hostname", ""), "macs": macs, "ips": ips,
                "cpu": vm.get("ProcessorCount"), "mem": vm.get("MemoryStartupBytes"),
                "state": (vm.get("State") or ""), "vmid": vm.get("VMId"),
            })

    def inst_key(vm):
        return vm.get("vmid") or (vm["host_ip"], vm["name"])

    def is_running(vm):
        return vm["state"].lower() == "running"

    def hardware_oid(h):
        oid = (h.get("snmp_details", {}).get("sys_oid") or "").strip()
        return bool(oid) and not oid.startswith("1.3.6.1.4.1.8072")

    def pick(cands):
        # Prefer the Running instance when a discovered IP matches several
        # instances that share a MAC/name (primary vs Off replica).
        run = [c for c in cands if is_running(c)]
        return (run or cands)[0]

    def vm_match(h):
        hm = host_macs(h)
        hips = {h["ip"]} | {e["ip"] for e in ip_table_ips(h)}
        hn = short_name(h.get("hostname"))
        cands = [vm for vm in vm_inv if hm & vm["macs"]]
        if cands:
            return pick(cands), "MAC"
        if hardware_oid(h):
            return None, None
        cands = [vm for vm in vm_inv if hips & vm["ips"]]
        if cands:
            return pick(cands), "IP"
        if hn:
            cands = [vm for vm in vm_inv if short_name(vm["name"]) == hn]
            if cands:
                return pick(cands), "name"
        return None, None

    matched_keys = set()
    for h in hosts:
        if h.get("sync_as") == "skip" or h.get("is_hyperv"):
            continue
        vm, how = vm_match(h)
        if vm:
            h["sync_as"] = "vm"
            h["vm_name"] = vm["name"]
            h["vm_host"] = vm["host_ip"]
            h["vm_cluster"] = vm["host_name"] or vm["host_ip"]
            h["vm_state"] = vm["state"]
            h["vm_reason"] = "Hyper-V VM '%s' on %s (%s, by %s)" % (
                vm["name"], vm["host_name"] or vm["host_ip"], vm["state"], how)
            matched_keys.add(inst_key(vm))
        else:
            vmac = next((m for m in host_macs(h) if m.startswith(HYPERV_OUI)), None)
            if vmac:
                h["sync_as"] = "vm"
                h["vm_reason"] = "Hyper-V MAC %s (host not WinRM-scanned)" % vmac

    # Synthesize a record for every VM instance not bound to a discovered host.
    # Replicas land here as their own VMs. Synthetic keys are made unique so two
    # same-named VMs on different hosts (a VM and its replica) don't collide.
    discovered_ips = {h["ip"] for h in hosts}
    used_keys = set()
    for vm in vm_inv:
        if inst_key(vm) in matched_keys:
            continue
        vm_ip = sorted(vm["ips"])[0] if vm["ips"] else None
        ip_source = "guest-report" if vm_ip else None
        # Recover the IP from the vNIC MAC via the gateway/host ARP map when the
        # guest did not report one (no Hyper-V integration services).
        if not vm_ip:
            for mac in sorted(vm["macs"]):
                if mac in mac2ip and mac2ip[mac] not in discovered_ips:
                    vm_ip = mac2ip[mac]
                    ip_source = "arp-recovered (mac %s)" % mac
                    break
        if vm_ip and vm_ip in discovered_ips:
            continue
        running = vm["state"].lower() == "running"
        no_ip_flag = running and not vm_ip   # active VM with no resolvable IP
        key = vm_ip or ("vm:" + (vm["name"] or str(vm.get("vmid", "unknown"))))
        if key in used_keys:
            key = "vm:%s@%s" % (vm["name"], vm["host_name"] or vm["host_ip"])
        used_keys.add(key)
        rec = {
            "ip": key, "hostname": vm["name"], "device_role": "Server",
            "manufacturer": "", "model": "", "os": "",
            "sync_as": "vm", "canonical": True, "merged_from": [],
            "secondary_ips": [], "source": "hyperv-inventory",
            "vm_name": vm["name"], "vm_host": vm["host_ip"],
            "vm_cluster": vm["host_name"] or vm["host_ip"],
            "vm_reason": "Hyper-V VM '%s' on %s (%s; inventory)" % (
                vm["name"], vm["host_name"] or vm["host_ip"], vm["state"]),
            "vm_cpu": vm["cpu"], "vm_mem_bytes": vm["mem"], "vm_state": vm["state"],
            "vm_ip_source": ip_source, "vm_no_ip_flag": no_ip_flag,
            "ports": [], "interfaces": [], "discovery_methods": ["hyperv-inventory"],
        }
        if vm_ip:
            discovered_ips.add(vm_ip)
        hosts.append(rec)

    data["hosts"] = hosts

    # ---- Persistent host-identity cache (save) ------------------------------
    # Refresh the cache with this run's known-good values. Never overwrite a good
    # cached value with a fallback/empty one, so a single bad scan can't poison
    # the cache -- only improve it.
    if ID_CACHE_PATH:
        for h in hosts:
            ip = h.get("ip")
            if not ip:
                continue
            ent = _idc.get(ip, {})
            hn = h.get("hostname")
            if not _bad_host(hn, ip):
                ent["hostname"] = hn
            for f in ("device_role", "manufacturer", "model", "serial"):
                v = str(h.get(f) or "").strip()
                if v and v.lower() not in ("unknown", "none"):
                    ent[f] = v
            if h.get("is_hyperv"):
                ent["is_hyperv"] = True
                if h.get("hyperv_vms"):
                    ent["hyperv_vms"] = h["hyperv_vms"]
            if ent:
                _idc[ip] = ent
        try:
            json.dump(_idc, open(ID_CACHE_PATH, "w"))
        except Exception:
            pass

    return data


def preview(data):
    hosts = data["hosts"]
    devices = [h for h in hosts if h.get("sync_as") == "device"]
    vms = [h for h in hosts if h.get("sync_as") == "vm"]
    skips = [h for h in hosts if h.get("sync_as") == "skip"]
    synth = [h for h in vms if h.get("source") == "hyperv-inventory"]
    lines = []

    def ipkey(h):
        ip = h["ip"]
        try:
            return (0, [int(o) for o in ip.split(".")])
        except ValueError:
            return (1, [0, 0, 0, 0])

    for h in sorted([x for x in hosts if x.get("sync_as") != "skip"], key=ipkey):
        if h["sync_as"] == "vm":
            tag = "VM    "
        else:
            tag = "KEEP  "
        extra = ""
        if h.get("merged_from"):
            extra = "  <- merges " + ", ".join(h["merged_from"])
        if h["sync_as"] == "vm" and h.get("vm_host"):
            extra += "  [on %s]" % (h.get("vm_cluster") or h.get("vm_host"))
        elif h["sync_as"] == "vm":
            extra += "  [%s]" % h.get("vm_reason", "")
        if (h.get("vm_ip_source") or "").startswith("arp-recovered"):
            extra += "  (IP via ARP)"
        if h.get("vm_no_ip_flag"):
            extra += "  !! ACTIVE VM, NO IP"
        lines.append("%s%-15s %-11s %-30s%s" % (
            tag, h["ip"], h.get("device_role", ""),
            (h.get("hostname", "") or "")[:30], extra))
    for h in sorted(skips, key=ipkey):
        lines.append("MERGE %-15s -> %-15s (%s)" % (
            h["ip"], h.get("merged_into", "?"), h.get("merge_reason", "")))
    noip = [h for h in vms if h.get("vm_no_ip_flag")]
    lines.append("\n%d records -> %d devices, %d VMs (%d synthesized from "
                 "inventory), %d merges" % (
                     len(hosts), len(devices), len(vms), len(synth), len(skips)))
    if noip:
        lines.append("%d ACTIVE VM(s) with no resolvable IP: %s" % (
            len(noip), ", ".join(h.get("vm_name", h["ip"]) for h in noip)))
    return "\n".join(lines)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "reconcile"
    path = sys.argv[2]
    CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(path)), "ip_mac_cache.json")
    ID_CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(path)), "host_identity_cache.json")
    data = json.load(open(path))
    data = reconcile(data)
    if mode == "preview":
        print(preview(data))
    else:
        out = sys.argv[3] if len(sys.argv) > 3 else path.replace(".json", ".reconciled.json")
        json.dump(data, open(out, "w"), indent=2)
        print(out)
PYEOF
    if [[ "${2:-}" == "--preview" ]]; then
        python3 "$pyf" preview "$results_file"; rm -f "$pyf"; return 0
    fi
    local out="${results_file%.json}.reconciled.json"
    python3 "$pyf" reconcile "$results_file" "$out" >/dev/null \
        && log_ok "Reconciled model: $out"
    python3 "$pyf" preview "$results_file" >&2
    rm -f "$pyf"
    echo "$out"
}

# -----------------------------------------------------------------------------
# SYNC TO NETBOX
# -----------------------------------------------------------------------------
sync_to_netbox() {
    local results_file="${1:-}"
    [[ -z "$results_file" ]] \
        && results_file=$(latest_scan_file)
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

            # Assign every SNMP ip_table IP bound to this interface index, not
            # just the first -- an interface can hold multiple IPs (e.g. UCG
            # if_index 44 carries both 192.168.0.253 and the secondary
            # 192.168.0.2). Skip unroutable addresses.
            local _iprow iface_ip iface_mask iface_prefix
            while IFS= read -r _iprow; do
                [[ -z "$_iprow" || "$_iprow" == "null" ]] && continue
                iface_ip=$(echo "$_iprow"   | jq -r '.ip   // empty')
                iface_mask=$(echo "$_iprow" | jq -r '.mask // "255.255.255.0"')
                # 169.254 retained on purpose: FortiLink uses it as a managed,
                # routable block. Only loopback / unspecified are dropped.
                [[ -z "$iface_ip" || "$iface_ip" == "0.0.0.0" \
                   || "$iface_ip" == 127.* ]] && continue
                iface_prefix=$(python3 -c \
                    "import ipaddress; \
print(ipaddress.IPv4Network('$iface_ip/$iface_mask',strict=False).prefixlen)" \
                    2>/dev/null || echo "24")
                nb_add_ip "${iface_ip}/${iface_prefix}" "" "$if_id" \
                    >/dev/null 2>&1 || true
            done < <(echo "$ip_table_json" | jq -c \
                "[.[] | select(.if_index==\"$if_idx\")][]" 2>/dev/null || true)

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

        # Guarantee the management IP is assigned SOMEWHERE on this device so
        # IP-first dedup (bash + Hyper-V PS1) can find it on later runs. WinRM
        # NIC data sometimes lacks per-NIC IPs (ips:[null]), which previously
        # left the mgmt IP unassigned -- the root cause of the SERVER01 /
        # server01.fqdn duplicate. If the IP is not already linked to this
        # device, attach it to the first real interface (or a mgmt0 fallback).
        local _mre _mat _mai
        _mre=$(nb_get "ipam/ip-addresses/?address=$(nb_urlencode "${ip}/32")&limit=1")
        [[ $(echo "$_mre" | jq '.count // 0' 2>/dev/null) == "0" ]] && \
            _mre=$(nb_get "ipam/ip-addresses/?address=$(nb_urlencode "$ip")&limit=1")
        _mat=$(echo "$_mre" | jq -r '.results[0].assigned_object_type // empty' 2>/dev/null)
        _mai=$(echo "$_mre" | jq -r '.results[0].assigned_object_id  // empty' 2>/dev/null)
        local _owner=""
        if [[ "$_mat" == "dcim.interface" && "$_mai" =~ ^[0-9]+$ ]]; then
            _owner=$(nb_get "dcim/interfaces/${_mai}/" | jq -r '.device.id // empty' 2>/dev/null)
        fi
        if [[ "$_owner" != "$dev_id" ]]; then
            # find an existing interface on this device, else create mgmt0
            local _tgt_if
            _tgt_if=$(nb_get "dcim/interfaces/?device_id=${dev_id}&limit=1" \
                | jq -r '.results[0].id // empty' 2>/dev/null)
            if [[ -z "$_tgt_if" || ! "$_tgt_if" =~ ^[0-9]+$ ]]; then
                _tgt_if=$(nb_add_interface "$dev_id" "mgmt0" "other" "" \
                    "Management (auto)" 2>/dev/null)
            fi
            if [[ -n "$_tgt_if" && "$_tgt_if" =~ ^[0-9]+$ ]]; then
                nb_add_ip "$ip" "$dev_id" "$_tgt_if" >/dev/null 2>&1 || true
            fi
        fi

        local nbr
        while IFS= read -r nbr; do
            local nbr_name nbr_remote_port
            nbr_name=$(echo "$nbr" | jq -r '.sys_name // .device_id // empty')
            # The port advertised by an LLDP/CDP neighbor (port_id/port_desc) is
            # the NEIGHBOR's (remote) port -- NOT ours. It must terminate on the
            # remote device. The container does not give us our own local port,
            # so the local side is named descriptively rather than mislabeled
            # with the remote port (which previously put e.g. laundry-sw's "g4"
            # onto mancave-sw).
            nbr_remote_port=$(echo "$nbr" | jq -r '.port_id // .port_desc // .remote_port // empty')
            [[ -z "$nbr_name" ]] && continue
            local nbr_enc nbr_dev_id
            nbr_enc=$(nb_urlencode "$nbr_name")
            nbr_dev_id=$(nb_get "dcim/devices/?name=${nbr_enc}" \
                | jq -r '.results[0].id // empty' 2>/dev/null || echo "")
            [[ -z "$nbr_dev_id" || ! "$nbr_dev_id" =~ ^[0-9]+$ ]] && continue
            [[ "$nbr_dev_id" == "$dev_id" ]] && continue
            local local_if_id nbr_if_id
            # LOCAL side on THIS device: descriptive uplink (local port unknown).
            local_if_id=$(nb_add_interface "$dev_id" \
                "uplink-${nbr_name}" "other" "" \
                "Topology link to $nbr_name" 2>/dev/null) || true
            # REMOTE side on the neighbor: the advertised port is theirs.
            nbr_if_id=$(nb_add_interface "$nbr_dev_id" \
                "${nbr_remote_port:-to-$hn}" "other" "" \
                "Topology link to $hn" 2>/dev/null) || true
            [[ -z "$local_if_id" || ! "$local_if_id" =~ ^[0-9]+$ ]] && continue
            [[ -z "$nbr_if_id"   || ! "$nbr_if_id"   =~ ^[0-9]+$ ]] && continue
            nb_create_cable "$local_if_id" "$nbr_if_id" \
                "$hn <-> $nbr_name" >/dev/null 2>&1 || true
            log_info "Cable: $hn <-> $nbr_name[${nbr_remote_port:-?}]"
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
        && results_file=$(latest_scan_file)
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

function Find-DeviceByShortName {{
    # Normalized-name dedup: match by short hostname, case-insensitive, so the
    # Hyper-V FQDN (server01.certifiedgeeks.net) merges with a discovered
    # NetBIOS name (SERVER01) instead of creating a duplicate device.
    param([string]$Name)
    if (-not $Name) {{ return $null }}
    $short = ($Name -split '\.')[0].ToLower()
    if (-not $short) {{ return $null }}
    try {{
        $enc = [uri]::EscapeDataString($short)
        $r = ((Invoke-NB -Uri "$uri/dcim/devices/?name__ic=$enc&limit=50").Content | ConvertFrom-Json).results
        foreach ($d in $r) {{
            if ((($d.name -split '\.')[0].ToLower()) -eq $short) {{ return $d }}
        }}
    }} catch {{}}
    return $null
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
    # IP-first dedup using the SAME management IP the bash discovery used
    # ($hyperVHost). Get-NetIPAddress | Select -First 1 was unreliable on a
    # Hyper-V host (it could return an internal vSwitch / mshome.net address),
    # which made this fail to find the already-created discovered device and
    # produced a duplicate (e.g. SERVER01 vs server01.fqdn). Prefer $hyperVHost,
    # fall back to the first non-virtual local IPv4.
    $localIP = $hyperVHost
    if (-not $localIP) {{
        $localIP = (Get-NetIPAddress -AddressFamily IPv4 |
                    Where-Object {{ $_.IPAddress -notlike "169.254*" -and
                                    $_.IPAddress -notlike "172.2*" -and
                                    $_.IPAddress -ne "127.0.0.1" -and
                                    $_.IPAddress -ne "0.0.0.0" }} |
                    Select-Object -First 1).IPAddress
    }}
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
    # Fall back to name lookup (exact, then normalized short-name)
    $dev = Get-NetboxDevice -Name $Name
    if (-not $dev) {{ $dev = Find-DeviceByShortName -Name $Name }}
    if ($dev) {{
        # Reuse the existing device (e.g. discovered "SERVER01") instead of
        # creating a duplicate "server01.fqdn". Keep whichever name is richer:
        # a non-auto-generated existing name is preserved over the FQDN so the
        # discovered device (with its ports/interfaces) remains the canonical one.
        $keepName = $dev.name
        if ($dev.name -match "^device-\d+-\d+-\d+-\d+$" -and $Name -notmatch "^device-\d+-\d+-\d+-\d+$") {{
            $keepName = $Name
        }}
        $patch = @{{
            name=$keepName; cluster=$ClusterId; site=$SiteId
            device_type=$DeviceTypeId; role=$DeviceRoleId; status="active"
        }} | ConvertTo-Json
        try {{ Invoke-NB -Uri "$uri/dcim/devices/$($dev.id)/" -Method PATCH -Body $patch | Out-Null }}
        catch {{ Write-Host "  [WARN] Failed to update device $keepName : $($_.Exception.Message)" }}
        return [int]$dev.id
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
    # Fetch the current IP object so we can no-op when it is already correct and
    # preserve its address in the reassign payload (NetBox 4.x validates it).
    $cur = $null
    try {{ $cur = (Invoke-NB -Uri "$uri/ipam/ip-addresses/$IpId/").Content | ConvertFrom-Json }}
    catch {{ Write-Host "  [WARN] IP $IpId fetch failed: $($_.Exception.Message)"; return $false }}
    if ($cur -and $cur.assigned_object_type -eq "virtualization.vminterface" `
            -and [int]$cur.assigned_object_id -eq $NicId) {{
        return $true   # already assigned to this VM NIC
    }}
    $addr = $cur.address   # keep the existing CIDR (e.g. 192.168.0.14/32)

    # Step 1: clear any existing assignment. NetBox 400s on a direct cross-type
    # reassignment (dcim.interface -> vminterface), so clear first and VERIFY.
    if ($cur.assigned_object_id) {{
        $clearBody=(@{{assigned_object_type=$null;assigned_object_id=$null}}|ConvertTo-Json)
        try {{ Invoke-NB -Uri "$uri/ipam/ip-addresses/$IpId/" -Method PATCH -Body $clearBody|Out-Null }}
        catch {{
            $eb = Get-NBErrorBody $_.Exception
            Write-Host "  [WARN] IP $IpId clear failed: $($_.Exception.Message) $eb"
        }}
        # verify the clear actually committed before reassigning
        try {{
            $chk = (Invoke-NB -Uri "$uri/ipam/ip-addresses/$IpId/").Content | ConvertFrom-Json
            if ($chk.assigned_object_id) {{
                Write-Host "  [WARN] IP $IpId still assigned after clear (object $($chk.assigned_object_type)/$($chk.assigned_object_id)); skipping reassign to avoid 400"
                return $false
            }}
        }} catch {{}}
    }}

    # Step 2: assign to the VM NIC, re-sending the address so validation passes.
    $body=@{{assigned_object_type="virtualization.vminterface"
            assigned_object_id=$NicId}}
    if ($addr) {{ $body.address=$addr }}
    $b=$body|ConvertTo-Json
    try {{
        Invoke-NB -Uri "$uri/ipam/ip-addresses/$IpId/" -Method PATCH -Body $b|Out-Null
        return $true
    }} catch {{
        $eb = Get-NBErrorBody $_.Exception
        Write-Host "  [WARN] IP $IpId assign to NIC $NicId failed: $($_.Exception.Message) -- $eb"
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
import_collector_json() {
    # Ingest a hand-collected (or auto-captured) netbox-collector.ps1 JSON and
    # MERGE it into a scan results file: matched to an existing scan-created
    # host by IP -> NIC MAC -> hostname (enriched in place, never duplicated),
    # else added as a new host. Hyper-V VMs + the neighbor table ride along so
    # the reconciler folds nmap-discovered IPs that are really VMs into
    # sync_as="vm" (no device+VM duplication). Accepts a single .json or a
    # directory of them.
    local src="$1" results_file="${2:-}"
    [[ -z "$results_file" ]] && results_file=$(latest_scan_file)
    if [[ -z "$src" ]]; then log_err "No collector JSON path given"; return 1; fi
    if [[ -z "$results_file" || ! -f "$results_file" ]]; then
        log_err "No scan results to merge into -- run a scan first (or pass a results file)."
        return 1
    fi
    local files=()
    if [[ -d "$src" ]]; then
        while IFS= read -r f; do files+=("$f"); done \
            < <(find "$src" -maxdepth 1 -type f -name "*.json" | sort)
    elif [[ -f "$src" ]]; then files=("$src")
    else log_err "Not found: $src"; return 1; fi
    [[ ${#files[@]} -eq 0 ]] && { log_err "No .json files in $src"; return 1; }
    log_info "Merging ${#files[@]} collector file(s) into $(basename "$results_file")"
    local f rc=0
    for f in "${files[@]}"; do
        python3 /dev/stdin "$f" "$results_file" <<'IMPORTEOF'
import json, sys, re

# IPs that are never the management identity of a host.
SKIP_PREFIXES = ('127.', '169.254.', '172.27.')  # 172.27 = Hyper-V Default Switch NAT


def load_json(path):
    with open(path, encoding='utf-8-sig') as f:
        return json.load(f)


def norm_mac(m):
    m = (m or '').strip().lower().replace('-', ':')
    return m if re.match(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$', m) else ''


def short(h):
    h = (h or '').strip().lower()
    return h.split('.')[0] if h else ''


def real_ips(ips):
    return [ip for ip in ips
            if ip and ':' not in ip and not any(ip.startswith(p) for p in SKIP_PREFIXES)]


def collector_to_host(c):
    H = c.get('Host', {}) or {}
    ipv4 = real_ips(H.get('IPv4Addresses') or [])
    nics, nic_macs = [], []
    for n in (H.get('NetworkAdapters') or []):
        mac = norm_mac(n.get('MacAddress'))
        if mac:
            nic_macs.append(mac)
        nics.append({'name': n.get('Name', 'eth'),
                     'description': n.get('Description', ''),
                     'mac': mac,
                     'ips': [i for i in (n.get('IPAddresses') or []) if i]})
    disks = [{'size_gb': d.get('SizeGB'), 'media': d.get('Media'),
              'interface': d.get('Interface')}
             for d in (H.get('PhysicalDisks') or [])]
    neigh = c.get('NeighborTable') or []
    arp = [{'ip': e.get('IP'), 'mac': norm_mac(e.get('MAC'))}
           for e in neigh if norm_mac(e.get('MAC'))]
    return {
        'hostname': H.get('Hostname', ''),
        'manufacturer': H.get('Manufacturer', ''),
        'model': H.get('Model', ''),
        'serial': H.get('SerialNumber', ''),
        'os': H.get('OS', ''),
        'is_hyperv': bool(H.get('IsHyperV')),
        'is_server': bool(H.get('IsServer')),
        'winrm_nics': nics,
        'interfaces': [{'name': n['name'], 'mac': n['mac'], 'type': 'other'}
                       for n in nics if n['mac']],
        'hardware': {'cpu_model': H.get('CPUName', ''), 'cpu_cores': H.get('CPUCores'),
                     'logical_procs': H.get('LogicalProcessors'),
                     'memory_gb': H.get('MemoryGB'), 'physical_disks': disks},
        'hyperv_vms': c.get('HyperVVMs') or [],
        'neighbor_table': neigh,
        'arp_table': arp,
        'ipv4_addresses': ipv4,
        'nic_macs': nic_macs,
    }


def host_macs(h):
    macs = set()
    m = norm_mac(h.get('mac'))
    if m:
        macs.add(m)
    for i in (h.get('interfaces') or []):
        mm = norm_mac(i.get('mac'))
        if mm:
            macs.add(mm)
    for n in (h.get('winrm_nics') or []):
        mm = norm_mac(n.get('mac'))
        if mm:
            macs.add(mm)
    return macs


def find_match(rec, hosts):
    rec_ips = set(rec['ipv4_addresses'])
    for h in hosts:                                   # 1) same IP (strongest)
        if h.get('ip') in rec_ips:
            return h, 'ip'
    rec_macs = set(rec['nic_macs'])
    for h in hosts:                                   # 2) shared NIC MAC
        if rec_macs & host_macs(h):
            return h, 'mac'
    sn = short(rec['hostname'])                        # 3) hostname
    if sn:
        for h in hosts:
            if short(h.get('hostname')) == sn:
                return h, 'hostname'
    return None, None


def apply_identity(h, rec):
    if rec['hostname']:
        h['hostname'] = rec['hostname']
    for k in ('manufacturer', 'model', 'serial', 'os'):
        if rec.get(k) and str(rec[k]).strip():
            h[k] = rec[k]
    h['is_hyperv'] = rec['is_hyperv']
    h['winrm_nics'] = rec['winrm_nics']
    h['hardware'] = rec['hardware']
    h['hyperv_vms'] = rec['hyperv_vms']
    h['neighbor_table'] = rec['neighbor_table']
    # union arp_table
    arp = {e['ip']: e['mac'] for e in (h.get('arp_table') or []) if e.get('ip')}
    for e in rec['arp_table']:
        arp.setdefault(e['ip'], e['mac'])
    h['arp_table'] = [{'ip': k, 'mac': v} for k, v in arp.items()]
    # union interfaces by mac
    seen = {norm_mac(i.get('mac')) for i in (h.get('interfaces') or [])}
    for i in rec['interfaces']:
        if i['mac'] and i['mac'] not in seen:
            h.setdefault('interfaces', []).append(i)
            seen.add(i['mac'])
    if not norm_mac(h.get('mac')) and rec['nic_macs']:
        h['mac'] = rec['nic_macs'][0]
    if h.get('device_role') in (None, '', 'Unknown'):
        h['device_role'] = 'Server' if rec['is_server'] else 'Workstation'
    dm = h.setdefault('discovery_methods', [])
    if 'import' not in dm:
        dm.append('import')
    h['imported'] = True
    h['os_accuracy'] = 'import'


def new_host(rec):
    ip = rec['ipv4_addresses'][0] if rec['ipv4_addresses'] else None
    h = {'ip': ip, 'hostname': rec['hostname'] or None,
         'mac': rec['nic_macs'][0] if rec['nic_macs'] else None,
         'vendor': '', 'os': rec['os'], 'os_accuracy': 'import',
         'device_role': 'Server' if rec['is_server'] else 'Workstation',
         'manufacturer': rec['manufacturer'], 'model': rec['model'],
         'serial': rec['serial'], 'is_hyperv': rec['is_hyperv'],
         'winrm_nics': rec['winrm_nics'], 'interfaces': rec['interfaces'],
         'hardware': rec['hardware'], 'hyperv_vms': rec['hyperv_vms'],
         'neighbor_table': rec['neighbor_table'], 'arp_table': rec['arp_table'],
         'ports': [], 'discovery_methods': ['import'], 'imported': True}
    return h


def main():
    coll_file, results_file = sys.argv[1], sys.argv[2]
    rec = collector_to_host(load_json(coll_file))
    if not rec['ipv4_addresses'] and not rec['nic_macs'] and not short(rec['hostname']):
        print('ERROR: collector JSON has no IP, MAC, or hostname to key on', file=sys.stderr)
        sys.exit(2)
    results = load_json(results_file)
    hosts = results.setdefault('hosts', [])
    h, how = find_match(rec, hosts)
    if h:
        apply_identity(h, rec)
        action = 'merged into existing %s (matched by %s)' % (h.get('ip'), how)
    else:
        nh = new_host(rec)
        hosts.append(nh)
        action = 'added as new host %s' % nh.get('ip')
    with open(results_file, 'w') as f:
        json.dump(results, f, indent=2)
    print('%s: %s; %d VM(s) attached, %d neighbor entries' %
          (rec['hostname'], action, len(rec['hyperv_vms']), len(rec['neighbor_table'])))


main()
IMPORTEOF
        [[ $? -ne 0 ]] && rc=1
    done
    if [[ $rc -eq 0 ]]; then
        log_ok "Import complete. Preview with reconcile (menu) or run sync to apply."
    else log_err "One or more imports failed."; fi
    return $rc
}

nb_add_vm_ip() {
    # Assign an IP to a VM interface (virtualization.vminterface) and set it as
    # the VM's primary_ip4. nb_add_ip only targets dcim.interface, which is what
    # broke VM IP assignment before.
    local ip="$1" vm_id="$2" vif_id="$3"
    [[ "$ip" != */* ]] && ip="${ip}/32"
    local ip_bare="${ip%/*}"
    # Match the existing IP by HOST address (any mask). A stale device-held
    # .160/32 from an earlier run would otherwise block a POST of .160/24 via
    # NetBox enforce_unique, leaving the VM with no IP. Found objects are PATCHed
    # below: moved onto the VM interface and re-masked to the desired prefix.
    local enc; enc=$(nb_urlencode "$ip_bare")
    local existing; existing=$(nb_get "ipam/ip-addresses/?address=${enc}")
    local ip_id; ip_id=$(echo "$existing" | jq -r '.results[0].id // empty' 2>/dev/null)
    local payload
    payload=$(jq -n --arg a "$ip" --argjson vif "$vif_id" \
        '{address:$a,status:"active",
          assigned_object_type:"virtualization.vminterface",
          assigned_object_id:$vif}')
    if [[ -z "$ip_id" ]]; then
        ip_id=$(nb_post "ipam/ip-addresses/" "$payload" | jq -r '.id // empty' 2>/dev/null)
    else
        nb_patch "ipam/ip-addresses/${ip_id}/" "$payload" >/dev/null 2>&1 || true
    fi
    if [[ -n "$vm_id" && "$vm_id" =~ ^[0-9]+$ && -n "$ip_id" && "$ip_id" =~ ^[0-9]+$ ]]; then
        nb_patch "virtualization/virtual-machines/${vm_id}/" \
            "{\"primary_ip4\":$ip_id}" >/dev/null 2>&1 || true
    fi
    echo "$ip_id"
}

sync_reconciled_to_netbox() {
    # SINGLE COORDINATED WRITER. Reconciles the scan results, then writes the
    # reconciled model to NetBox: devices (sync_as=device) with primary +
    # secondary IPs and interfaces; clusters per Hyper-V host; VMs (sync_as=vm)
    # with vCPU/memory/disk resolved from inventory and their IP on a
    # vminterface. sync_as=skip records are dropped. Pass --dry-run to print the
    # plan without touching NetBox.
    local results_file="${1:-}" mode="${2:-}"
    [[ -z "$results_file" ]] && results_file=$(latest_scan_file)
    if [[ -z "$results_file" || ! -f "$results_file" ]]; then
        log_error "No results file to sync -- run a scan first."; return 1
    fi
    reconcile_results "$results_file" >/dev/null 2>&1 || true
    local recon="${results_file%.json}.reconciled.json"
    [[ -f "$recon" ]] || { log_error "Reconcile produced no $recon"; return 1; }

    local pyf; pyf=$(mktemp --suffix=.py)
    cat > "$pyf" <<'PLANEOF'
import json, sys, re

# Resolve the writer's view of the reconciled model into a normalized plan:
#   devices[] (sync_as==device), vms[] (sync_as==vm), clusters[].
# VM hardware is resolved from each host's hyperv_vms inventory by (cluster,name)
# because discovered-VM records don't carry cpu/mem themselves.

DEF_MASK = 24


def norm_mac(m):
    m = (m or '').strip().lower().replace('-', ':')
    return m if re.match(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$', m) else ''


def mask_to_prefix(mask):
    if not mask:
        return DEF_MASK
    if isinstance(mask, int):
        return mask
    m = str(mask).strip()
    if m.isdigit() and 0 <= int(m) <= 32:
        return int(m)
    try:
        return sum(bin(int(o)).count('1') for o in m.split('.'))
    except Exception:
        return DEF_MASK


def host_prefix(h, ip):
    for e in (h.get('ip_table') or []):
        if e.get('ip') == ip and e.get('mask'):
            return mask_to_prefix(e.get('mask'))
    return DEF_MASK


def vm_status(state):
    s = (state or '').strip().lower()
    if s == 'running':
        return 'active'
    if s in ('off', 'offcritical'):
        return 'offline'
    if s in ('paused', 'saved'):
        return 'staged'
    return 'active'


ROLE_KEYWORDS = [
    (('opnsense', 'pfsense', 'fortigate', 'fgt', 'firewall', 'fortinet'), 'Firewall'),
    (('pihole', 'pi-hole', 'adguard', 'unbound', 'bind9'), 'DNS'),
    (('plex', 'jellyfin', 'emby', 'kodi'), 'Media'),
    (('veeam', 'goodsync', 'backup', 'bacula', 'restic', 'duplicati'), 'Backup'),
    (('prometheus', 'grafana', 'prtg', 'zabbix', 'nagios', 'librenms', 'netdata'), 'Monitoring'),
    (('syslog', 'graylog', 'fortianalyzer', 'faz', 'loki'), 'Logging'),
    (('tailscale', 'zerotier', 'wireguard', 'openvpn'), 'VPN'),
    (('docker', 'raspidocker', 'kubernetes', 'k8s', 'portainer', 'container'), 'Container Host'),
    (('kali', 'sophos', 'suricata', 'snort', 'pentest'), 'Security'),
    (('fortiauthenticator', 'radius', 'freeradius', 'authentik', 'keycloak'), 'Authentication'),
    (('iventoy', 'pxe', 'tftp', 'foreman', 'provision'), 'Provisioning'),
    (('fortimanager', 'fmg', 'vcenter'), 'Management'),
]
PORT_ROLES = {53: 'DNS', 32400: 'Media', 514: 'Logging', 9090: 'Monitoring'}


def vm_role(name, ports, fallback):
    n = (name or '').lower()
    for kws, role in ROLE_KEYWORDS:
        if any(k in n for k in kws):
            return role
    for p in (ports or []):
        try:
            pn = int(str(p.get('port') if isinstance(p, dict) else p).split('/')[0])
        except Exception:
            continue
        if pn in PORT_ROLES:
            return PORT_ROLES[pn]
    fb = (fallback or '').strip()
    if fb and fb not in ('Unknown', 'Workstation', 'Endpoint'):
        return fb
    return 'Server'


def device_custom_fields(hw, os_str):
    """Full host hardware custom-field set, matching the PS1 (integer types).
    Skips RAID/Storage-Spaces virtual disks (media 'Unspecified'). Returns
    (custom_fields_dict, kept_disk_count)."""
    cf = {}
    if os_str:
        cf['os_version'] = os_str
    if not hw:
        return cf, 0
    if hw.get('cpu_model'):
        cf['cpu_model'] = hw['cpu_model']
    if hw.get('cpu_cores') is not None:
        cf['cpu_cores'] = int(hw['cpu_cores'])
    lp = hw.get('logical_procs')
    if lp is not None:
        cf['vcpus'] = int(lp)
    mg = hw.get('memory_gb')
    if mg is not None:
        try:
            # memory_gb is a DECIMAL field; send a number. memory_mb stays int.
            cf['memory_gb'] = round(float(mg), 2)
            cf['memory_mb'] = int(round(float(mg) * 1024))
        except (TypeError, ValueError):
            pass
    # Include every physical disk with a real size (matches 2.5.9/PS1, which
    # filtered only size>0). RAID/Storage-Spaces volumes are real capacity and
    # are kept -- do not second-guess the host's reported disks.
    disks = [d for d in (hw.get('physical_disks') or []) if d.get('size_gb')]
    if disks:
        cf['disk_count'] = len(disks)
        cf['disk_total_gb'] = sum(int(d['size_gb']) for d in disks)
        for i, d in enumerate(disks[:8]):
            cf['disk_%d_size_gb' % i] = int(d['size_gb'])
            cf['disk_%d_media' % i] = str(d.get('media') or 'Unknown')
            cf['disk_%d_interface' % i] = str(d.get('interface') or 'Unknown')
    return cf, len(disks)


def build(reconciled):
    hosts = reconciled['hosts']

    # Global IP->MAC map from every host's ARP/neighbor tables (the router and
    # firewall ARP tables resolve almost every host) plus any interface-bound
    # MACs. Used to stamp the MAC onto each IP-bearing interface, since NetBox
    # 4.x keeps MACs on interfaces, not on IPs.
    ip2mac = {}
    for h in hosts:
        for key in ('arp_table', 'neighbor_table'):
            for e in (h.get(key) or []):
                i, m = e.get('ip'), e.get('mac')
                if i and m:
                    ip2mac.setdefault(i, m)

    # Inventory index: (cluster-or-host-key, vm_name) -> hardware detail.
    inv = {}
    for h in hosts:
        if h.get('sync_as') == 'skip':
            continue
        keys = [h.get('hostname'), h.get('ip')]
        for vm in (h.get('hyperv_vms') or []):
            nm = vm.get('Name', '')
            macs = [norm_mac(a.get('MacAddress'))
                    for a in (vm.get('NetworkAdapters') or []) if norm_mac(a.get('MacAddress'))]
            detail = {
                'vcpus': vm.get('ProcessorCount'),
                'mem_b': vm.get('MemoryStartupBytes'),
                'disk_b': vm.get('DiskBytes'),
                'disks': vm.get('Disks') or [],
                'macs': macs,
            }
            for k in keys:
                if k:
                    inv[(k, nm)] = detail

    site = reconciled.get('site') or 'Home Lab'
    clusters = set()
    devices, vms = [], []
    max_disks = 0

    for h in hosts:
        sa = h.get('sync_as')
        if sa == 'skip':
            continue

        if sa == 'device':
            ip = h.get('ip')
            ifaces = []
            seen = set()
            for n in (h.get('winrm_nics') or []):
                mac = norm_mac(n.get('mac') or n.get('MacAddress'))
                nm = n.get('name') or n.get('Name') or 'eth'
                if (nm, mac) not in seen:
                    ifaces.append({'name': nm, 'mac': mac})
                    seen.add((nm, mac))
            for n in (h.get('interfaces') or []):
                mac = norm_mac(n.get('mac'))
                nm = n.get('name') or 'if'
                if (nm, mac) not in seen:
                    ifaces.append({'name': nm, 'mac': mac})
                    seen.add((nm, mac))
            hw = h.get('hardware') or None
            is_hv = bool(h.get('is_hyperv'))
            cluster = h.get('hostname') if is_hv else None
            if cluster:
                clusters.add(cluster)
            sec = []
            for s in (h.get('secondary_ips') or []):
                sip = s.get('ip')
                if sip:
                    sec.append('%s/%d' % (sip, mask_to_prefix(s.get('mask'))))
            # Per-interface IP assignments from the SNMP ip_table: resolve each
            # if_index to a real interface name (named directly, or numeric ->
            # ifTable name) and attach the IP there. 169.254/FortiLink included;
            # only loopback/0.0.0.0 skipped.
            ifname_by_index = {}
            for n in (h.get('interfaces') or []):
                idx = '' if n.get('index') is None else str(n.get('index'))
                if idx:
                    ifname_by_index[idx] = n.get('name') or idx
            ip_assignments = []
            for e in (h.get('ip_table') or []):
                eip = e.get('ip')
                if not eip or eip.startswith('127.') or eip == '0.0.0.0':
                    continue
                idx = '' if e.get('if_index') is None else str(e.get('if_index'))
                nm = ifname_by_index.get(idx)
                if not nm:
                    nm = idx if (idx and not idx.isdigit()) else ('if' + idx if idx else 'mgmt0')
                ip_assignments.append({
                    'ifname': nm,
                    'ip': '%s/%d' % (eip, mask_to_prefix(e.get('mask'))),
                    'is_primary': (eip == ip),
                    'mac': ip2mac.get(eip) or ''})
            # Direct IP<->NIC binding from WinRM: the host itself reports which IP
            # sits on which adapter (including the Hyper-V mgmt vEthernet), so no
            # guessing is needed. Authoritative -- runs before the ARP fallback.
            for n in (h.get('winrm_nics') or []):
                nm2 = n.get('name') or 'eth'
                nmac2 = norm_mac(n.get('mac') or '')
                plens = n.get('prefix_lens') or []
                for _i, nip in enumerate(n.get('ips') or []):
                    if not nip or nip.startswith('127.') or nip.startswith('169.254'):
                        continue
                    if any((a.get('ip') or '').split('/')[0] == nip for a in ip_assignments):
                        continue
                    try:
                        pfx = int(plens[_i])
                    except Exception:
                        pfx = host_prefix(h, nip)
                    ip_assignments.append({
                        'ifname': nm2, 'ip': '%s/%d' % (nip, pfx),
                        'is_primary': (nip == ip), 'mac': nmac2 or (ip2mac.get(nip) or '')})
            # WinRM hosts report their NICs (name + MAC) but usually not the NIC's
            # IP, and have no SNMP ip_table -- so the primary IP had nowhere to
            # land and fell back to a synthetic mgmt0. Bind it to the real NIC
            # whose MAC matches the primary IP's ARP entry (or the sole NIC).
            if ip and not any(a.get('is_primary') for a in ip_assignments):
                _pmac = norm_mac(ip2mac.get(ip) or h.get('mac') or '')
                _target = None
                if _pmac:
                    for f in ifaces:
                        if f.get('mac') and norm_mac(f.get('mac')) == _pmac:
                            _target = f['name']; break
                if not _target and len(ifaces) == 1:
                    _target = ifaces[0]['name']
                if _target:
                    ip_assignments.append({
                        'ifname': _target,
                        'ip': '%s/%d' % (ip, host_prefix(h, ip)),
                        'is_primary': True,
                        'mac': _pmac or (ifaces[0].get('mac') if len(ifaces) == 1 else '')})
            dcf, ndisks = device_custom_fields(hw, (h.get('os') or '').strip())
            if ndisks > max_disks:
                max_disks = ndisks
            # discovered_ports + discovery_methods (parity with the legacy sync):
            # text fields, same formatting as before.
            _ports = h.get('ports') or []
            if _ports:
                dcf['discovered_ports'] = ', '.join(
                    '%s/%s' % (p.get('port'), p.get('service') or p.get('proto') or 'tcp')
                    for p in _ports if p.get('port'))
            _dm = h.get('discovery_methods') or []
            if _dm:
                dcf['discovery_methods'] = ', '.join(str(m) for m in _dm)
            # LLDP cabling links for this device. Each needs our local port and a
            # named neighbor; self-referential entries (a stack/aggregate that
            # reports this switch's own hostname/serial) are dropped -- not cables.
            _own = {(h.get('hostname') or '').strip().lower(),
                    (h.get('serial') or '').strip().lower()}
            _own.discard('')
            lldp_links = []
            for _n in (h.get('lldp_neighbors') or []):
                _nb = (_n.get('sys_name') or '').strip()
                _lp = (_n.get('local_port') or '').strip()
                _rp = (_n.get('port_id') or '').strip()
                if not _nb or not _lp:
                    continue
                if _nb.lower() in _own:
                    continue
                lldp_links.append({'local_port': _lp, 'neighbor': _nb, 'remote_port': _rp})
            devices.append({
                'name': h.get('hostname') or ('device-' + (ip or '').replace('.', '-')),
                'role': h.get('device_role') or 'Unknown',
                'manufacturer': (h.get('manufacturer') or '').strip(),
                'model': (h.get('model') or '').strip(),
                'serial': (h.get('serial') or '').strip(),
                'os': (h.get('os') or '').strip(),
                'primary_ip': ('%s/%d' % (ip, host_prefix(h, ip))) if ip else None,
                'secondary_ips': sec,
                'interfaces': ifaces,
                'is_hyperv': is_hv,
                'cluster': cluster,
                'hardware': hw,
                'custom_fields': dcf,
                'ip_assignments': ip_assignments,
                'lldp_links': lldp_links,
            })

        elif sa == 'vm':
            name = h.get('vm_name') or h.get('hostname')
            # A malformed Hyper-V host record (null ip AND null hostname) leaves a
            # VM with no cluster; fall back to a named bucket so it still syncs and
            # sorted(clusters) never has to compare None to a str.
            cluster = h.get('vm_cluster') or h.get('vm_host') or 'Unclustered'
            clusters.add(cluster)
            det = inv.get((cluster, name)) or inv.get((h.get('vm_host'), name)) or {}
            vcpus = det.get('vcpus')
            if vcpus is None:
                vcpus = h.get('vm_cpu')
            mem_b = det.get('mem_b')
            if mem_b is None:
                mem_b = h.get('vm_mem_bytes') or h.get('vm_mem')
            disk_b = det.get('disk_b')
            disks_gb = [ (int(b) + 1073741823) // 1073741824
                         for b in (det.get('disks') or []) if b ]
            macs = det.get('macs') or []
            ip = h.get('ip')
            ip = ip if (ip and re.match(r'^\d+\.\d+\.\d+\.\d+$', ip)) else None
            vms.append({
                'name': name,
                'cluster': cluster,
                'role': vm_role(name, h.get('ports'), h.get('device_role')),
                'status': vm_status(h.get('vm_state')),
                'vcpus': int(vcpus) if vcpus else None,
                'memory_mb': int(round(mem_b / 1048576)) if mem_b else None,
                'disk_gb': int(round(disk_b / 1073741824)) if disk_b else None,
                'disks_gb': disks_gb,
                'primary_ip': ('%s/%d' % (ip, DEF_MASK)) if ip else None,
                'mac': macs[0] if macs else None,
                'no_ip_flag': bool(h.get('vm_no_ip_flag')),
                'discovered_ports': (', '.join(
                    '%s/%s' % (p.get('port'), p.get('service') or p.get('proto') or 'tcp')
                    for p in (h.get('ports') or []) if p.get('port')) or None),
            })

    # ---- Canonical cable list (dedupe reciprocal links) --------------------
    # Each physical link is advertised from BOTH ends, and each end names the
    # other's port differently (S224EP calls office-sw's port "1"; office-sw
    # calls its own port "Port  1"). Building cables per-device therefore tried
    # to create two cables to one termination -- the second failed and left the
    # neighbor-abbreviated interface behind. Here we pair the two halves and emit
    # ONE cable per link, each end under its OWN local port name.
    def _n(s): return (s or '').strip().lower()
    name_idx = {}
    for d in devices:
        nm = d['name']; sr = d.get('serial')
        if nm:
            name_idx[_n(nm)] = nm
            name_idx[_n(nm).split('.')[0]] = nm
        if sr:
            name_idx[_n(sr)] = nm
    def _resolve(neigh):
        k = _n(neigh)
        return name_idx.get(k) or name_idx.get(k.split('.')[0])

    def _phys(p):
        # A real physical port (port23, g8, Port  1, internal7, 1) vs a serial-
        # derived FortiLink trunk name (4FNTF23000240-0, GT61E4Q16002812): the
        # latter carry a long run of digits from the embedded serial.
        p = (p or '').strip()
        return bool(p) and re.search(r'\d{5,}', p) is None

    pair = {}
    for d in devices:
        a = d['name']
        for l in d.get('lldp_links', []):
            b = _resolve(l['neighbor'])
            if not b or b == a:
                continue
            pair.setdefault(frozenset((a, b)), {}).setdefault(a, []).append(
                (l['local_port'], l.get('remote_port') or ''))

    cables = []
    seen = set()
    for key, sides in pair.items():
        devs = list(key)
        if len(devs) != 2:
            continue
        A, B = devs
        la, lb = sides.get(A, []), sides.get(B, [])
        if len(la) == 1 and len(lb) == 1:
            # Both ends reported once. Prefer each side's own local port when it
            # is a real physical port. A FortiLink trunk interface is named after
            # the PEER's serial (4FNTF23000240-0) rather than a physical port, so
            # in that case use the physical port the peer reports for this end
            # (each FortiSwitch reports the trunk lands on the other's port23).
            a_loc, a_rem = la[0]
            b_loc, b_rem = lb[0]
            ap = a_loc if _phys(a_loc) else (b_rem if _phys(b_rem) else a_loc)
            bp = b_loc if _phys(b_loc) else (a_rem if _phys(a_rem) else b_loc)
            ck = frozenset(((A, ap), (B, bp)))
            if ck not in seen:
                seen.add(ck)
                cables.append({'a_dev': A, 'a_port': ap, 'b_dev': B, 'b_port': bp})
        else:
            # only one end reported, or a multi-link bundle: best effort using
            # the reporter's local port and its view of the remote port
            for sd, links in sides.items():
                od = B if sd == A else A
                for lp, rp in links:
                    bp = rp or ('to-' + sd)
                    ck = frozenset(((sd, lp), (od, bp)))
                    if ck not in seen:
                        seen.add(ck)
                        cables.append({'a_dev': sd, 'a_port': lp, 'b_dev': od, 'b_port': bp})

    return {'site': site, 'clusters': sorted(c for c in clusters if c), 'devices': devices,
            'vms': vms, 'max_disks': max_disks, 'cables': cables}


def dry_run(plan):
    out = []
    out.append('SITE: %s' % plan['site'])
    out.append('CLUSTERS (%d): %s' % (len(plan['clusters']), ', '.join(plan['clusters'])))
    out.append('')
    out.append('DEVICES (%d):' % len(plan['devices']))
    for d in plan['devices']:
        hw = d.get('hardware')
        hws = ''
        if hw:
            _cf = d.get('custom_fields') or {}
            hws = ' hw[cpu=%s cores=%s mem=%sGB disks=%d]' % (
                (hw.get('cpu_model') or '')[:14], hw.get('cpu_cores'),
                _cf.get('memory_gb', hw.get('memory_gb')), _cf.get('disk_count', 0))
        cl = (' cluster=%s' % d['cluster']) if d['cluster'] else ''
        sec = (' +sec%s' % d['secondary_ips']) if d['secondary_ips'] else ''
        nip = len(d.get('ip_assignments') or [])
        ipinfo = ('%d-ips-on-ifaces' % nip) if nip else ('ip=%s%s' % (d['primary_ip'], sec))
        out.append('  %-22s %-11s %-16s %s ifaces=%d%s%s' % (
            d['name'][:22], d['role'][:11], (d['manufacturer'] + '/' + d['model'])[:16],
            ipinfo, len(d['interfaces']), cl, hws))
    out.append('')
    out.append('VMs (%d):' % len(plan['vms']))
    for v in plan['vms']:
        ipf = v['primary_ip'] or ('NO-IP' + ('!' if v['no_ip_flag'] else ''))
        out.append('  %-26s @%-12s %-10s %-8s vcpu=%s mem=%sMB disk=%sGB ip=%s' % (
            v['name'][:26], (v['cluster'] or '')[:12], (v.get('role') or '')[:10],
            v['status'], v['vcpus'], v['memory_mb'], v['disk_gb'], ipf))
    out.append('')
    _cables = plan.get('cables', [])
    out.append('LLDP CABLES (%d, marker lldp-auto -- created/replaced/pruned on sync):' % len(_cables))
    for c in _cables:
        out.append('  %-22s %-14s <-> %-22s %s' % (
            c['a_dev'][:22], c['a_port'][:14], c['b_dev'][:22], c['b_port']))
    out.append('')
    out.append('TOT:  %d devices, %d VMs, %d clusters, %d cables' % (
        len(plan['devices']), len(plan['vms']), len(plan['clusters']), len(_cables)))
    return '\n'.join(out)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'dryrun'
    path = sys.argv[2]
    plan = build(json.load(open(path)))
    if mode == 'plan':
        out = sys.argv[3] if len(sys.argv) > 3 else path.replace('.json', '.plan.json')
        json.dump(plan, open(out, 'w'), indent=2)
        print(out)
    else:
        print(dry_run(plan))


main()
PLANEOF
    if [[ "$mode" == "--dry-run" ]]; then
        python3 "$pyf" dryrun "$recon"; rm -f "$pyf"; return 0
    fi
    local plan="${results_file%.json}.plan.json"
    python3 "$pyf" plan "$recon" "$plan" >/dev/null 2>&1; rm -f "$pyf"
    [[ -s "$plan" ]] || { log_error "Plan generation failed"; return 1; }

    # Full HTTP trace of this sync (every request + response) for debugging, e.g.
    # the 'Invalid manufacturer ID' 409s. Disabled with SYNC_HTTP_LOG=0.
    if [[ "${SYNC_HTTP_LOG:-1}" == "1" ]]; then
        export NB_HTTP_LOG=1
        export NB_HTTP_LOG_FILE="${results_file%.json}.sync_http.log"
        : > "$NB_HTTP_LOG_FILE" 2>/dev/null || NB_HTTP_LOG_FILE="$(dirname "$results_file")/sync_http.log"
        printf '# NetBox sync HTTP trace %s\n# %s\n' "$(date '+%F %T')" "$(basename "$plan")" >> "$NB_HTTP_LOG_FILE"
    fi

    log_info "Single-writer sync from $(basename "$plan")"
    local site_id ctype_id
    site_id=$(nb_get_or_create_site "$(jq -r '.site' "$plan")")
    ctype_id=$(nb_get_or_create_cluster_type "Hyper-V")
    declare -A CLU=()
    local cl
    while IFS= read -r cl; do
        [[ -z "$cl" || "$cl" == "null" ]] && continue
        CLU["$cl"]=$(nb_get_or_create_cluster "$cl" "$ctype_id" "$site_id")
    done < <(jq -r '.clusters[]' "$plan")

    # Host hardware custom fields -- full PS1 parity, integer types (a float in
    # an integer field 400s the whole PATCH, which silently dropped ALL fields).
    nb_ensure_custom_field "cpu_model"     "CPU Model"       "text"    "dcim.device" >/dev/null 2>&1 || true
    nb_ensure_custom_field "cpu_cores"     "CPU Cores"       "integer" "dcim.device" >/dev/null 2>&1 || true
    nb_ensure_custom_field "vcpus"         "vCPUs"           "integer" "dcim.device" >/dev/null 2>&1 || true
    nb_ensure_custom_field "memory_mb"     "Memory (MB)"     "integer" "dcim.device" >/dev/null 2>&1 || true
    nb_ensure_custom_field "memory_gb"     "Memory (GB)"     "decimal" "dcim.device" >/dev/null 2>&1 || true
    nb_ensure_custom_field "disk_total_gb" "Disk Total (GB)" "integer" "dcim.device" >/dev/null 2>&1 || true
    nb_ensure_custom_field "disk_count"    "Disk Count"      "integer" "dcim.device" >/dev/null 2>&1 || true
    nb_ensure_custom_field "os_version"    "OS Version"      "text"    "dcim.device" >/dev/null 2>&1 || true
    nb_ensure_custom_field "discovered_ports" "Discovered Ports" "text" "dcim.device,virtualization.virtualmachine" >/dev/null 2>&1 || true
    nb_ensure_custom_field "discovery_methods" "Discovery Methods" "text" "dcim.device" >/dev/null 2>&1 || true
    local _maxd _di; _maxd=$(jq -r '.max_disks // 0' "$plan" 2>/dev/null || echo 0)
    for (( _di=0; _di<_maxd; _di++ )); do
        nb_ensure_custom_field "disk_${_di}_size_gb"   "Disk ${_di} Size (GB)" "integer" "dcim.device" >/dev/null 2>&1 || true
        nb_ensure_custom_field "disk_${_di}_media"     "Disk ${_di} Media"     "text"    "dcim.device" >/dev/null 2>&1 || true
        nb_ensure_custom_field "disk_${_di}_interface" "Disk ${_di} Interface" "text"    "dcim.device" >/dev/null 2>&1 || true
    done

    local dcount=0 vcount=0 d v
    while IFS= read -r d; do
        local name role mfr model serial pip pip_bare dev_id mgmt
        name=$(jq -r '.name' <<<"$d");      role=$(jq -r '.role' <<<"$d")
        mfr=$(jq -r '.manufacturer // ""' <<<"$d"); model=$(jq -r '.model // ""' <<<"$d")
        serial=$(jq -r '.serial // ""' <<<"$d");    pip=$(jq -r '.primary_ip // ""' <<<"$d")
        [[ -z "$mfr"   ]] && mfr="Unknown"
        [[ -z "$model" ]] && model="Unknown"
        pip_bare="${pip%/*}"
        dev_id=$(nb_upsert_device "$name" "$role" "$mfr" "$model" "$site_id" \
            "$serial" "" "$pip_bare" 2>>"$LOG_FILE")
        if [[ -z "$dev_id" || ! "$dev_id" =~ ^[0-9]+$ ]]; then
            log_warn "device upsert failed: $name"; continue
        fi
        # Link the host Device to its Cluster -- nb_upsert_device doesn't set the
        # device.cluster FK, so a Hyper-V host otherwise shows no cluster. The
        # cluster name (== the host's own hostname) was created in CLU above.
        local dcluster dcid
        dcluster=$(jq -r '.cluster // ""' <<<"$d")
        if [[ -n "$dcluster" && "$dcluster" != "null" ]]; then
            dcid="${CLU[$dcluster]:-}"
            [[ "$dcid" =~ ^[0-9]+$ ]] && \
                nb_patch "dcim/devices/$dev_id/" "{\"cluster\":$dcid}" >/dev/null 2>&1 || true
        fi
        # Named interfaces (with MACs) from the SNMP ifTable / WinRM NICs.
        local ifc ifn ifm
        while IFS= read -r ifc; do
            ifn=$(jq -r '.name' <<<"$ifc"); ifm=$(jq -r '.mac // ""' <<<"$ifc")
            [[ -z "$ifn" ]] && continue
            nb_add_interface "$dev_id" "$ifn" "other" "$ifm" "" >/dev/null 2>&1 || true
        done < <(jq -c '.interfaces[]?' <<<"$d")
        # IP assignment: per-interface from the ip_table when present (each IP on
        # its real interface, e.g. fortilink/169.254.1.1); else fall back to a
        # mgmt0 interface holding the primary + folded secondary IPs.
        local nass; nass=$(jq '.ip_assignments | length' <<<"$d" 2>/dev/null || echo 0)
        if [[ "$nass" =~ ^[0-9]+$ && "$nass" -gt 0 ]]; then
            local asg aif aip aprim aifid amac primset=0
            while IFS= read -r asg; do
                aif=$(jq -r '.ifname' <<<"$asg"); aip=$(jq -r '.ip' <<<"$asg")
                aprim=$(jq -r '.is_primary' <<<"$asg"); amac=$(jq -r '.mac // ""' <<<"$asg")
                aifid=$(nb_add_interface "$dev_id" "$aif" "other" "$amac" "" 2>>"$LOG_FILE")
                [[ ! "$aifid" =~ ^[0-9]+$ ]] && continue
                if [[ "$aprim" == "true" ]]; then
                    nb_add_ip "$aip" "$dev_id" "$aifid" >/dev/null 2>&1 || true
                    primset=1
                else
                    nb_add_ip "$aip" "" "$aifid" >/dev/null 2>&1 || true
                fi
            done < <(jq -c '.ip_assignments[]' <<<"$d")
            if [[ "$primset" -eq 0 && -n "$pip" ]]; then
                local m2; m2=$(nb_add_interface "$dev_id" "mgmt0" "other" "" "Management" 2>>"$LOG_FILE")
                [[ "$m2" =~ ^[0-9]+$ ]] && nb_add_ip "$pip" "$dev_id" "$m2" >/dev/null 2>&1 || true
            fi
        else
            local mgmt
            mgmt=$(nb_add_interface "$dev_id" "mgmt0" "other" "" "Management" 2>>"$LOG_FILE")
            if [[ -n "$pip" && "$mgmt" =~ ^[0-9]+$ ]]; then
                nb_add_ip "$pip" "$dev_id" "$mgmt" >/dev/null 2>&1 || true
            fi
            local sip
            while IFS= read -r sip; do
                [[ -z "$sip" || ! "$mgmt" =~ ^[0-9]+$ ]] && continue
                nb_add_ip "$sip" "" "$mgmt" >/dev/null 2>&1 || true
            done < <(jq -r '.secondary_ips[]?' <<<"$d")
        fi
        # Host hardware custom fields, precomputed in the plan (full set, correct
        # integer types, RAID/virtual disks filtered).
        local cf
        cf=$(jq -c '.custom_fields // {}' <<<"$d")
        if [[ -n "$cf" && "$cf" != "{}" && "$cf" != "null" ]]; then
            local _cfresp
            _cfresp=$(nb_patch "dcim/devices/$dev_id/" "{\"custom_fields\":$cf}")
            if ! echo "$_cfresp" | jq -e '.id' >/dev/null 2>&1; then
                # The bundled PATCH was rejected (one bad field 400s the whole
                # request). Apply each field on its own so the rest still land,
                # and surface exactly which field NetBox refused.
                local _k _v _one
                while IFS= read -r _k; do
                    _v=$(jq -c --arg k "$_k" '.[$k]' <<<"$cf")
                    _one=$(jq -nc --arg k "$_k" --argjson v "$_v" '{custom_fields:{($k):$v}}')
                    local _r; _r=$(nb_patch "dcim/devices/$dev_id/" "$_one")
                    if ! echo "$_r" | jq -e '.id' >/dev/null 2>&1; then
                        log_warn "Custom field '\''$_k'\'' rejected for device ID $dev_id: $(echo "$_r" | jq -c '.custom_fields // .' 2>/dev/null | head -c 160)"
                    fi
                done < <(jq -r 'keys[]' <<<"$cf")
            fi
        fi
        dcount=$((dcount+1))
    done < <(jq -c '.devices[]' "$plan")

    # ---- LLDP cabling (tagged-reconcile) ------------------------------------
    # Runs AFTER all devices exist so both endpoints resolve. Consumes the
    # plan's canonical (deduplicated) cable list: one entry per physical link,
    # each end already under its OWN local port name -- so no reciprocal
    # conflict. Only lldp-auto-marked cables are created/replaced/pruned; manual
    # cables are untouched.
    nb_ensure_tag "lldp-auto" "lldp-auto"
    local ccreated=0
    declare -A CABLE_KEEP=()
    local c a_dev b_dev a_port b_port adev_id bdev_id aif bif
    while IFS= read -r c; do
        a_dev=$(jq -r '.a_dev'  <<<"$c"); b_dev=$(jq -r '.b_dev'  <<<"$c")
        a_port=$(jq -r '.a_port' <<<"$c"); b_port=$(jq -r '.b_port' <<<"$c")
        [[ -z "$a_dev" || -z "$b_dev" || -z "$a_port" || -z "$b_port" ]] && continue
        # resolve both devices: exact name -> domain-stripped -> serial
        adev_id=$(nb_dev_id_by_name "$a_dev"); [[ ! "$adev_id" =~ ^[0-9]+$ ]] && adev_id=$(nb_dev_id_by_name "${a_dev%%.*}")
        [[ ! "$adev_id" =~ ^[0-9]+$ ]] && adev_id=$(nb_dev_id_by_serial "$a_dev")
        bdev_id=$(nb_dev_id_by_name "$b_dev"); [[ ! "$bdev_id" =~ ^[0-9]+$ ]] && bdev_id=$(nb_dev_id_by_name "${b_dev%%.*}")
        [[ ! "$bdev_id" =~ ^[0-9]+$ ]] && bdev_id=$(nb_dev_id_by_serial "$b_dev")
        if [[ ! "$adev_id" =~ ^[0-9]+$ || ! "$bdev_id" =~ ^[0-9]+$ ]]; then
            log_info "  cable skip: $a_dev <-> $b_dev (device not in NetBox)"; continue
        fi
        aif=$(nb_add_interface "$adev_id" "$a_port" "other" "" "")
        bif=$(nb_add_interface "$bdev_id" "$b_port" "other" "" "")
        [[ ! "$aif" =~ ^[0-9]+$ || ! "$bif" =~ ^[0-9]+$ ]] && continue
        CABLE_KEEP[$adev_id]="${CABLE_KEEP[$adev_id]:-} $aif"
        CABLE_KEEP[$bdev_id]="${CABLE_KEEP[$bdev_id]:-} $bif"
        nb_reconcile_cable "$aif" "$bif" "lldp-auto: $a_dev:$a_port <-> $b_dev:$b_port" \
            && { ccreated=$((ccreated+1)); log_info "  cable: $a_dev:$a_port <-> $b_dev:$b_port"; }
    done < <(jq -c '.cables[]?' "$plan")
    # prune stale lldp-auto cables on every device we touched
    local kdev
    if [[ ${#CABLE_KEEP[@]} -gt 0 ]]; then
        for kdev in "${!CABLE_KEEP[@]}"; do
            nb_prune_lldp_cables "$kdev" "${CABLE_KEEP[$kdev]}"
        done
    fi
    [[ "$ccreated" -gt 0 ]] && log_ok "LLDP cables created/replaced: $ccreated"

    while IFS= read -r v; do
        local vname vcl vrole status vcpus vmem vdisk vip vmac cid vm_id vif role_id vports
        local _nd _i _dsz _dname
        vname=$(jq -r '.name' <<<"$v");   vcl=$(jq -r '.cluster' <<<"$v")
        vrole=$(jq -r '.role // "Server"' <<<"$v")
        status=$(jq -r '.status' <<<"$v")
        vcpus=$(jq -r '.vcpus // ""' <<<"$v");  vmem=$(jq -r '.memory_mb // ""' <<<"$v")
        vdisk=$(jq -r '.disk_gb // ""' <<<"$v"); vip=$(jq -r '.primary_ip // ""' <<<"$v")
        vmac=$(jq -r '.mac // ""' <<<"$v")
        cid="${CLU[$vcl]:-}"
        if [[ -z "$cid" || ! "$cid" =~ ^[0-9]+$ ]]; then
            log_warn "no cluster for VM $vname ($vcl)"; continue
        fi
        vm_id=$(nb_upsert_vm "$vname" "$cid" "$status" "$vcpus" "$vmem" "$site_id" 2>>"$LOG_FILE")
        if [[ -z "$vm_id" || ! "$vm_id" =~ ^[0-9]+$ ]]; then
            log_warn "VM upsert failed: $vname"; continue
        fi
        if [[ -n "$vrole" && "$vrole" != "null" ]]; then
            role_id=$(nb_get_or_create_role "$vrole" 2>>"$LOG_FILE")
            [[ "$role_id" =~ ^[0-9]+$ ]] && nb_patch \
                "virtualization/virtual-machines/$vm_id/" \
                "{\"role\":$role_id}" >/dev/null 2>&1 || true
        fi
        # Discovered ports/protocols on the VM (parity with devices' custom field).
        vports=$(jq -r '.discovered_ports // ""' <<<"$v")
        if [[ -n "$vports" && "$vports" != "null" ]]; then
            nb_patch "virtualization/virtual-machines/$vm_id/" \
                "$(jq -nc --arg p "$vports" '{custom_fields:{discovered_ports:$p}}')" \
                >/dev/null 2>&1 || true
        fi
        # Per-VM virtual disks (NetBox 4.x aggregates VM.disk from these). Fall
        # back to the single aggregate disk field only when no per-disk data.
        _nd=$(jq '.disks_gb | length' <<<"$v" 2>/dev/null || echo 0)
        if [[ "$_nd" =~ ^[0-9]+$ && "$_nd" -gt 0 ]]; then
            _i=0
            while IFS= read -r _dsz; do
                _dname=$(printf '%s-disk%d' "$vname" "$_i" | tr -c 'A-Za-z0-9-' '-')
                nb_sync_vm_disk "$vm_id" "$_dname" "$_dsz"
                _i=$((_i+1))
            done < <(jq -r '.disks_gb[]' <<<"$v")
        elif [[ -n "$vdisk" && "$vdisk" =~ ^[0-9]+$ ]]; then
            # VM.disk is MB in NetBox 4.x -- convert the GB aggregate.
            nb_patch "virtualization/virtual-machines/$vm_id/" \
                "{\"disk\":$(( vdisk * 1024 ))}" >/dev/null 2>&1 || true
        fi
        vif=$(nb_add_vm_interface "$vm_id" "eth0" "$vmac" "" 2>>"$LOG_FILE")
        if [[ -n "$vip" && "$vif" =~ ^[0-9]+$ ]]; then
            nb_add_vm_ip "$vip" "$vm_id" "$vif" >/dev/null 2>&1 || true
        fi
        vcount=$((vcount+1))
    done < <(jq -c '.vms[]' "$plan")

    log_ok "Single-writer sync complete: $dcount device(s), $vcount VM(s) -> NetBox."
    if [[ "${NB_HTTP_LOG:-0}" == "1" && -n "${NB_HTTP_LOG_FILE:-}" ]]; then
        local nreq nerr_all nerr
        nreq=$(grep -c '^\[' "$NB_HTTP_LOG_FILE" 2>/dev/null || echo 0)
        nerr_all=$(grep -cE '< (4[0-9]{2}|5[0-9]{2}):' "$NB_HTTP_LOG_FILE" 2>/dev/null || echo 0)
        # "already exists" 4xx are expected: the get-or-create helpers POST
        # optimistically and recover by slug/name on collision. Only count the
        # unexpected ones as real errors.
        nerr=$(grep -E '< (4[0-9]{2}|5[0-9]{2}):' "$NB_HTTP_LOG_FILE" 2>/dev/null \
                | grep -vc 'already exists' || echo 0)
        local recovered=$(( nerr_all - nerr ))
        log_info "HTTP trace: $nreq request(s), $nerr error(s)$([[ $recovered -gt 0 ]] && echo ", $recovered recovered collision(s)") -> $NB_HTTP_LOG_FILE"
        [[ "$nerr" -gt 0 ]] && log_warn "Sync had $nerr unexpected HTTP error(s); see the trace for details."
    fi
    unset NB_HTTP_LOG NB_HTTP_LOG_FILE
}

# Interactive wrapper around the single writer: dry-run preview, confirm, sync.
# Used everywhere a sync is offered so every path runs the reconciled writer
# (never the legacy sync_to_netbox, which invents uplink-* interfaces).
run_reconciled_sync() {
    local results="$1"
    if [[ -z "$results" || ! -f "$results" ]]; then
        printf "${Y}  No results to sync -- run a scan first${NC}\n"; return 1
    fi
    printf "\n${C}Single-writer plan for $(basename "$results"):${NC}\n\n"
    sync_reconciled_to_netbox "$results" --dry-run
    echo ""
    if confirm "  Write this reconciled model to NetBox now?"; then
        sync_reconciled_to_netbox "$results"
    else
        printf "${D}  Skipped -- nothing written.${NC}\n"
    fi
}

generate_collector_script() {
    # Emit a standalone, read-only collector that runs on ANY Windows machine
    # (workstation or Hyper-V host) WITHOUT WinRM or NetBox access. It writes a
    # single JSON file that this tool ingests via the reconciler. Same
    # collection logic as the WinRM PS_BASE/PS_HYPERV probes, so output is
    # identical whether gathered over WinRM or run by hand on a closed host.
    local dest="${1:-$DISCOVERY_DIR/netbox-collector.ps1}"
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    cat > "$dest" <<'COLLECTEOF'
<#
  netbox-collector.ps1  --  standalone, read-only inventory collector.
  Runs on ANY Windows machine (workstation or Hyper-V host). Requires NO WinRM
  and NO NetBox connectivity. Emits one JSON file that netbox-discovery.sh
  ingests via its reconciler. Collect-only: it writes nothing to the system
  and makes no network calls.

  Usage (local, no admin needed for most fields):
    powershell -ExecutionPolicy Bypass -File .\netbox-collector.ps1
    powershell -ExecutionPolicy Bypass -File .\netbox-collector.ps1 -OutFile C:\temp\out.json
#>
param([string]$OutFile = "")
$ErrorActionPreference = "SilentlyContinue"

function _trim($s) { if ($null -ne $s) { ([string]$s).Trim() } else { "" } }
function _firstNonEmpty { foreach ($a in $args) { $t = _trim $a; if ($t) { return $t } }; return "" }

# ---- Host hardware + physical NICs (identical to the WinRM PS_BASE probe) ----
$cs   = Get-CimInstance Win32_ComputerSystem  2>$null
$os   = Get-CimInstance Win32_OperatingSystem 2>$null
$bios = Get-CimInstance Win32_BIOS            2>$null
$bb   = Get-CimInstance Win32_BaseBoard       2>$null
$cpu  = Get-CimInstance Win32_Processor 2>$null | Select-Object -First 1
$nics = Get-NetAdapter -Physical 2>$null | Where-Object { $_.Status -eq "Up" } |
        ForEach-Object {
            $if = $_
            $v4 = Get-NetIPAddress -InterfaceIndex $if.ifIndex 2>$null |
                  Where-Object { $_.AddressFamily -eq "IPv4" -and $_.IPAddress -ne "127.0.0.1" }
            [ordered]@{ Name=$if.Name; Description=$if.InterfaceDescription;
                        MacAddress=($if.MacAddress -replace "-",":").ToUpper();
                        IPAddresses=@(@($v4.IPAddress) | Where-Object { $_ });
                        PrefixLens=@(@($v4.PrefixLength) | Where-Object { $null -ne $_ }) }
        }
# Host-level IPv4s across ALL adapters (incl. Hyper-V vEthernet, where the
# management IP usually lives) -- the physical NIC alone often has none.
$hostIPs = @(Get-NetIPAddress -AddressFamily IPv4 2>$null |
    Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.IPAddress -notlike "169.254.*" } |
    Select-Object -ExpandProperty IPAddress -Unique)
$isHyperV = $false
try { $isHyperV = ($null -ne (Get-Command Get-VM -ErrorAction SilentlyContinue)) } catch {}
$pdisks = @()
try {
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $pd = Get-PhysicalDisk 2>$null
    } else { $pd = Get-CimInstance Win32_DiskDrive 2>$null }
    foreach ($d in $pd) {
        $sz = [int64]0; $md = "Unknown"; $ifc = "Unknown"
        if ($d.Size) { $sz = [int64]$d.Size }
        if ($d.MediaType)        { $md  = [string]$d.MediaType }
        if ($d.BusType)          { $ifc = [string]$d.BusType }
        elseif ($d.InterfaceType){ $ifc = [string]$d.InterfaceType }
        if ($sz -gt 0) {
            $pdisks += [ordered]@{ SizeGB=[int][Math]::Ceiling($sz/1GB);
                                   Media=$md; Interface=$ifc }
        }
    }
} catch {}
$hostObj = [ordered]@{ Hostname=$cs.Name; Domain=$cs.Domain;
            Manufacturer=(_firstNonEmpty $cs.Manufacturer $bb.Manufacturer);
            Model=(_firstNonEmpty $cs.Model $bb.Product);
            SerialNumber=(_firstNonEmpty $bios.SerialNumber $bb.SerialNumber);
            OS=$os.Caption;
            OSVersion=$os.Version; IsServer=($os.ProductType -ne 1);
            IsHyperV=$isHyperV;
            CPUName=(_trim $cpu.Name); CPUCores=[int]$cpu.NumberOfCores;
            LogicalProcessors=[int]$cs.NumberOfLogicalProcessors;
            MemoryGB=[math]::Round($cs.TotalPhysicalMemory/1GB,2);
            IPv4Addresses=@($hostIPs);
            PhysicalDisks=@($pdisks);
            NetworkAdapters=@($nics) }

# ---- Hyper-V VMs + disks + neighbors (identical to the WinRM PS_HYPERV probe) ----
$hvVMs = @()
$neighbors = @()
if ($isHyperV) {
    $adByVm = @{}
    Get-VMNetworkAdapter -VMName * 2>$null | ForEach-Object {
        $k = "$($_.VMName)"
        $m = ($_.MacAddress -replace "(..)(?=.)",'$1:').ToUpper()
        if (-not $adByVm.ContainsKey($k)) { $adByVm[$k] = @() }
        $adByVm[$k] += [ordered]@{ Name=$_.Name; MacAddress=$m;
                                   SwitchName=$_.SwitchName;
                                   IPAddresses=@(@($_.IPAddresses) | Where-Object { $_ }) }
    }
    $hvVMs = Get-VM 2>$null | ForEach-Object {
        $vm = $_
        $dbytes = [int64]0
        $dlist = @()
        foreach ($dd in (Get-VMHardDiskDrive -VMName $vm.Name 2>$null)) {
            try {
                if ($dd.Path -and (Test-Path $dd.Path)) {
                    $vh = Get-VHD -Path $dd.Path -ErrorAction Stop
                    if ($vh -and $vh.Size) { $dbytes += [int64]$vh.Size; $dlist += [int64]$vh.Size }
                }
            } catch {}
        }
        if ($vm.DynamicMemoryEnabled) { $memB = [int64]$vm.MemoryMaximum }
        else                          { $memB = [int64]$vm.MemoryStartup }
        [ordered]@{ Name=$vm.Name; State="$($vm.State)";
                    Generation=$vm.Generation;
                    ProcessorCount=[int]$vm.ProcessorCount;
                    MemoryStartupBytes=$memB;
                    DiskBytes=$dbytes;
                    Disks=@($dlist);
                    VMId="$($vm.VMId)";
                    NetworkAdapters=@($adByVm["$($vm.Name)"]) }
    }
    # Neighbor (ARP) table -- unicast only. Drop broadcast/multicast so the
    # reconciler gets clean IP<->MAC pairs for resolving VM/host IPs.
    $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.State -in 'Reachable','Stale','Permanent' -and
            $_.LinkLayerAddress -match '^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$' -and
            $_.LinkLayerAddress -ne 'FF-FF-FF-FF-FF-FF' -and
            $_.LinkLayerAddress -notmatch '^01-00-5E' -and
            $_.LinkLayerAddress -notmatch '^33-33' -and
            $_.IPAddress -notmatch '^(22[4-9]|23[0-9])\.' -and
            $_.IPAddress -notlike '*.255' -and
            $_.IPAddress -ne '255.255.255.255'
        } |
        ForEach-Object {
            [ordered]@{ IP="$($_.IPAddress)";
                        MAC=($_.LinkLayerAddress -replace '-',':').ToLower() }
        }
}

# ---- Merge + emit (single JSON; no NetBox, no WinRM) ----
$payload = [ordered]@{
    CollectorVersion = "1.2"
    CollectedAt      = (Get-Date).ToString("o")
    Host             = $hostObj
    HyperVVMs        = @($hvVMs)
    NeighborTable    = @($neighbors)
}
$json = $payload | ConvertTo-Json -Depth 8
if (-not $OutFile) {
    $base = "netbox-collect-$($cs.Name).json"
    $desk = [Environment]::GetFolderPath("Desktop")
    if ($desk -and (Test-Path $desk)) { $OutFile = Join-Path $desk $base }
    else { $OutFile = Join-Path $env:TEMP $base }
}
# Write UTF-8 WITHOUT BOM (Out-File -Encoding UTF8 emits a BOM that breaks
# strict JSON parsers).
[System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "NetBox collector JSON written to:"
Write-Host "  $OutFile"
Write-Host ""
Write-Host "Copy this file back to the netbox-discovery host and import it."

COLLECTEOF
    chmod 0644 "$dest" 2>/dev/null
    log_ok "Standalone collector written: $dest"
    printf "\n  ${W}Copy it to any Windows machine and run (no WinRM needed):${NC}\n"
    printf "    powershell -ExecutionPolicy Bypass -File .\\netbox-collector.ps1\n\n"
    printf "  ${D}It writes netbox-collect-<HOST>.json to the Desktop (or %%TEMP%%).${NC}\n"
    printf "  ${D}Bring that JSON back here to import (single coordinated writer).${NC}\n"
}

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
        echo "   8) Generate standalone collector script (JSON, runs anywhere)"
        echo "   9) Import collector JSON (merge into latest scan results)"
        echo "   0) Back"
        read -rp $'\nChoice: ' c
        local tip
        case "$c" in
        1) run_agent_local ;;
        2) read -rp "  Host IP: " tip
           valid_ip "$tip" && deploy_agent_remote "$tip" \
               || { printf "${R}  Invalid IP${NC}\n"; pause; } ;;
        3) local latest
           latest=$(latest_scan_file)
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
        8) read -rp "  Output path [$DISCOVERY_DIR/netbox-collector.ps1]: " dest
           generate_collector_script "${dest:-$DISCOVERY_DIR/netbox-collector.ps1}"
           pause ;;
        9) read -rp "  Collector JSON file or directory: " src
           import_collector_json "$src"
           pause ;;
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

    # 1. Clone / update Device-Type-Library-Import tool
    # Note: DTLI clones the device type library itself into ./repo/
    log_info "Installing Device-Type-Library-Import..."
    if [[ ! -d "$dtli_dir/.git" ]]; then
        git clone -q \
            https://github.com/netbox-community/Device-Type-Library-Import.git \
            "$dtli_dir" >> "$LOG_FILE" 2>&1 || { log_error "DTLI clone failed"; pause; return 1; }
        log_ok "DTLI cloned"
    else
        git -C "$dtli_dir" pull -q >> "$LOG_FILE" 2>&1 \
            && log_ok "DTLI updated" || log_warn "DTLI update skipped (using existing)"
    fi
    # Install requirements into a venv to avoid system package conflicts
    if [[ ! -d "$dtli_dir/venv" ]]; then
        python3 -m venv "$dtli_dir/venv" >> "$LOG_FILE" 2>&1 || true
    fi
    "$dtli_dir/venv/bin/pip" install --quiet \
        -r "$dtli_dir/requirements.txt" >> "$LOG_FILE" 2>&1 || true

    # 2. Write .env config (DTLI reads NETBOX_URL + NETBOX_TOKEN from .env)
    cat > "$dtli_dir/.env" <<ENVEOF
NETBOX_URL=${NETBOX_API_URL}
NETBOX_TOKEN=${NETBOX_API_TOKEN}
ENVEOF

    # 3. Optional vendor filter
    printf "\n  Import all vendors or specific ones?\n"
    printf "  Examples: cisco juniper fortinet hp dell ubiquiti\n"
    printf "  (blank = import all ~2000 device types)\n"
    read -rp "  Vendors (comma or space-separated, blank=all): " _vendors
    # normalise to comma-separated for --vendors arg
    local _vendor_arg=""
    if [[ -n "${_vendors:-}" ]]; then
        _vendor_arg=$(echo "$_vendors" | tr " " ",")
    fi

    # 4. Run import -- script is nb-dt-import.py
    log_info "Running Device-Type-Library-Import..."
    local _script="$dtli_dir/nb-dt-import.py"
    if [[ ! -f "$_script" ]]; then
        # Try common alternate names
        _script=$(find "$dtli_dir" -maxdepth 1 -name "*.py" \
            ! -name "setup.py" | head -1)
    fi
    if [[ -z "$_script" ]]; then
        log_error "Cannot find DTLI Python script in $dtli_dir"
        pause; return 1
    fi
    local _cmd=("$dtli_dir/venv/bin/python3" "$_script")
    [[ -n "$_vendor_arg" ]] && _cmd+=("--vendors" "$_vendor_arg")
    cd "$dtli_dir" && "${_cmd[@]}" 2>&1 | tee -a "$LOG_FILE" | tail -50
    log_ok "Device Type Library import complete"
    pause
}

# -----------------------------------------------------------------------------
# CREDENTIAL MANAGEMENT MENU
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# CREDENTIAL TESTING (validate a credential against a live IP before relying on it)
# -----------------------------------------------------------------------------
# cred_test <winrm|ssh|snmp> <ip> [args...]; rc 0 = success. Output -> stdout.
cred_test() {
    local typ="$1" ip="$2"; shift 2
    case "$typ" in
    winrm)
        local u="$1" p="$2" d="${3:-}"
        python3 - "$ip" "$u" "$p" "$d" <<'PYEOF'
import sys
ip,u,p,d = (list(sys.argv)+["","","",""])[1:5]
try:
    import winrm
except Exception as e:
    print("pywinrm not installed: %s" % e); sys.exit(2)
au = (d+"\\"+u) if (d and "\\" not in u and "@" not in u) else u
last="no response"
for proto,port in (("http",5985),("https",5986)):
    try:
        s=winrm.Session("%s://%s:%d/wsman"%(proto,ip,port),auth=(au,p),
            transport="ntlm",server_cert_validation="ignore",
            operation_timeout_sec=20,read_timeout_sec=30)
        r=s.run_ps("hostname")
        if r.status_code==0:
            print("%s -> %s"%(proto,r.std_out.decode("utf-8","replace").strip())); sys.exit(0)
        last="%s status=%d %s"%(proto,r.status_code,r.std_err.decode("utf-8","replace")[:160].strip())
    except Exception as e:
        last="%s %s"%(proto,str(e)[:160])
print(last); sys.exit(1)
PYEOF
        ;;
    ssh)
        local u="$1" p="$2" k="${3:-}"
        local opts=(-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o NumberOfPasswordPrompts=1)
        if [[ -n "$k" && -f "$k" ]]; then
            ssh -i "$k" "${opts[@]}" -o PreferredAuthentications=publickey "$u@$ip" 'echo SSH-OK $(hostname)' 2>&1
        elif [[ -n "$p" ]]; then
            sshpass -p "$p" ssh "${opts[@]}" -o PreferredAuthentications=password "$u@$ip" 'echo SSH-OK $(hostname)' 2>&1
        else
            ssh "${opts[@]}" "$u@$ip" 'echo SSH-OK $(hostname)' 2>&1
        fi
        ;;
    snmp)
        local comm="$1"
        snmpget -v2c -c "$comm" -t 2 -r 1 "$ip" 1.3.6.1.2.1.1.1.0 2>&1
        ;;
    snmpv3)
        local u="$1" ap="$2" ap2="$3" pp="$4" pp2="$5"
        snmpget -v3 -u "$u" -l authPriv -a "$ap" -A "$ap2" -x "$pp" -X "$pp2" \
            -t 2 -r 1 "$ip" 1.3.6.1.2.1.1.1.0 2>&1
        ;;
    esac
}

# Print a coloured PASS/FAIL line for a single test.
cred_test_report() {
    local label="$1"; shift
    local out rc
    out=$(cred_test "$@" 2>&1); rc=$?
    if [[ $rc -eq 0 && "$out" == *OK* ]] || [[ $rc -eq 0 && -n "$out" ]]; then
        printf "    ${G}PASS${NC} %-26s %s\n" "$label" "$out"
        return 0
    fi
    printf "    ${R}FAIL${NC} %-26s %s\n" "$label" "${out:-no response}"
    return 1
}

# Test every stored credential of each type against one IP.
test_credentials_against_ip() {
    local ip="$1" creds; creds=$(read_creds)
    local stop="${CRED_TEST_STOP_ON_PASS:-1}" stopped=0 passes=0 fails=0 any
    printf "\n  ${C}Testing stored credentials against %s${NC}\n" "$ip"
    printf "  ${D}(order: SNMP v2c -> v3 -> SSH -> WinRM; %s)${NC}\n" \
        "$([[ "$stop" == "1" ]] && echo 'stops at first pass' || echo 'tests all, highlights failures')"

    if [[ $stopped -ne 1 ]]; then
        printf "\n  ${W}SNMP v2c:${NC}\n"; any=0
        while IFS= read -r comm; do
            [[ -z "$comm" ]] && continue; [[ $stopped -eq 1 ]] && break; any=1
            if cred_test_report "$comm" snmp "$ip" "$comm"; then
                passes=$((passes+1)); [[ "$stop" == "1" ]] && stopped=1
            else fails=$((fails+1)); fi
        done < <(echo "$creds" | jq -r '.snmp_communities[]?')
        [[ $any -eq 0 ]] && echo "    (none stored)"
    fi
    if [[ $stopped -ne 1 ]]; then
        printf "\n  ${W}SNMP v3:${NC}\n"; any=0
        while IFS=$'\t' read -r u ap ap2 pp pp2; do
            [[ -z "$u" ]] && continue; [[ $stopped -eq 1 ]] && break; any=1
            if cred_test_report "$u" snmpv3 "$ip" "$u" "$ap" "$ap2" "$pp" "$pp2"; then
                passes=$((passes+1)); [[ "$stop" == "1" ]] && stopped=1
            else fails=$((fails+1)); fi
        done < <(echo "$creds" | jq -r '.snmp_v3[]? | [.username,(.auth_proto//"SHA"),(.auth_pass//""),(.priv_proto//"AES"),(.priv_pass//"")] | @tsv')
        [[ $any -eq 0 ]] && echo "    (none stored)"
    fi
    if [[ $stopped -ne 1 ]]; then
        printf "\n  ${W}SSH:${NC}\n"; any=0
        while IFS=$'\t' read -r u p k; do
            [[ -z "$u" ]] && continue; [[ $stopped -eq 1 ]] && break; any=1
            if cred_test_report "$u" ssh "$ip" "$u" "$p" "$k"; then
                passes=$((passes+1)); [[ "$stop" == "1" ]] && stopped=1
            else fails=$((fails+1)); fi
        done < <(echo "$creds" | jq -r '.ssh_credentials[]? | [.username,(.password//""),(.key_file//"")] | @tsv')
        [[ $any -eq 0 ]] && echo "    (none stored)"
    fi
    if [[ $stopped -ne 1 ]]; then
        printf "\n  ${W}WinRM:${NC}\n"; any=0
        while IFS=$'\t' read -r u p d; do
            [[ -z "$u" ]] && continue; [[ $stopped -eq 1 ]] && break; any=1
            if cred_test_report "${d:+$d\\}$u" winrm "$ip" "$u" "$p" "$d"; then
                passes=$((passes+1)); [[ "$stop" == "1" ]] && stopped=1
            else fails=$((fails+1)); fi
        done < <(echo "$creds" | jq -r '.windows_credentials[]? | [.username,.password,(.domain//"")] | @tsv')
        [[ $any -eq 0 ]] && echo "    (none stored)"
    fi

    echo ""
    if [[ $passes -gt 0 ]]; then
        if [[ "$stop" == "1" ]]; then
            log_ok "A credential passed against $ip (stopped at first pass)."
        else
            log_ok "$passes credential(s) passed, $fails failed against $ip."
        fi
        return 0
    fi
    log_error "No stored credential passed against $ip ($fails failed)."
    return 1
}

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
        echo "  12) Test credentials against an IP"
        echo "   0) Back"
        read -rp $'\nChoice: ' c
        local v3e sshe deve
        case "$c" in
        1)  read -rp "  Community: " x
            write_creds "$(echo "$creds" | jq ".snmp_communities += [\"$x\"]")"
            log_info "Added: $x"
            local s1ip
            read -rp "  Test against IP (blank to skip): " s1ip
            [[ -n "$s1ip" ]] && cred_test_report "$x" snmp "$s1ip" "$x" ;;
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
            write_creds "$(echo "$creds" | jq ".snmp_v3 += [$v3e]")"
            local s3ip
            read -rp "  Test against IP (blank to skip): " s3ip
            [[ -n "$s3ip" ]] && cred_test_report "$u" snmpv3 "$s3ip" "$u" "$ap" "$ap2" "$pp" "$pp2" ;;
        4)  read -rp "  Username: " u
            read -rsp "  Password (blank=key): " p; echo
            read -rp "  Key file (blank=password): " k
            read -rsp "  Enable pass (opt): " e; echo
            sshe=$(jq -n --arg u "$u" --arg p "$p" --arg k "$k" --arg e "$e" \
                '{username:$u,password:(if $p!="" then $p else null end),
                  key_file:(if $k!="" then $k else null end),
                  enable_pass:(if $e!="" then $e else null end)}')
            write_creds "$(echo "$creds" | jq ".ssh_credentials += [$sshe]")"
            local stip
            read -rp "  Test against IP (blank to skip): " stip
            if [[ -n "$stip" ]]; then
                cred_test_report "$u" ssh "$stip" "$u" "$p" "$k"
            fi ;;
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
            log_info "Added Windows: ${wdomain:+$wdomain\\}$wuser"
            local wtip
            read -rp "  Test against IP (blank to skip): " wtip
            if [[ -n "$wtip" ]]; then
                cred_test_report "${wdomain:+$wdomain\\}$wuser" winrm "$wtip" "$wuser" "$wpass" "$wdomain"
            fi ;;
        11) read -rp "  Remove username (exact): " wuser
            write_creds "$(echo "$creds" \
                | jq "del(.windows_credentials[] | select(.username==\"$wuser\"))")"
            log_info "Removed Windows credential: $wuser" ;;
        12) local tip
            read -rp "  Test against IP: " tip
            if [[ -n "$tip" ]]; then test_credentials_against_ip "$tip"
            else printf "${R}  No IP entered${NC}\n"; fi ;;
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
        printf "  8) Cred Test Stop-on-Pass  ${W}%s${NC}\n" \
            "$([ "${CRED_TEST_STOP_ON_PASS:-1}" -eq 1 ] && echo ON || echo OFF)"
        echo "  9) Schedule Recurring Scan (cron)"
        echo " 10) View Scheduled Scans"
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
        8) (( CRED_TEST_STOP_ON_PASS ^= 1 ));                   save_config ;;
        9) read -rp "  Networks (CIDRs or file): " snet
           read -rp "  Cron (e.g. 0 2 * * *): " scron
           (crontab -l 2>/dev/null
            echo "$scron root $SCRIPT_PATH --auto-scan '$snet' \
>> $LOG_DIR/cron.log 2>&1") | crontab -
           log_info "Scheduled: [$scron] $snet" ;;
        10) crontab -l 2>/dev/null | grep "auto-scan" || echo "  (none)" ;;
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
        echo "  11) Enable Auto-Start on Boot (systemd)"
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
        11) detect_docker_compose; setup_netbox_autostart ;;
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
        5) latest=$(latest_scan_file)
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
        echo "  8) Preview Reconciliation (dry-run, no NetBox writes)"
        echo "  9) Sync RECONCILED model to NetBox (single writer)"
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
                run_reconciled_sync "$DISC_RESULTS"
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
            run_reconciled_sync "$DISC_RESULTS" ;;
        4)  read -rp "  Switch IP: " swip
            valid_ip "$swip" && map_switchports "$swip" \
                || printf "${R}  Invalid IP${NC}\n" ;;
        5)  latest=$(latest_scan_file)
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
        6)  latest=$(latest_scan_file); run_reconciled_sync "$latest" ;;
        8)  latest=$(latest_scan_file)
            if [[ -z "$latest" ]]; then
                printf "${Y}  No discovery results -- run a scan first${NC}\n"
            else
                printf "\n${C}Reconciliation plan for $(basename "$latest"):${NC}\n\n"
                reconcile_results "$latest" --preview
                printf "\n${D}  (dry-run only -- nothing written to NetBox)${NC}\n"
            fi
            pause ;;
        9)  latest=$(latest_scan_file)
            if [[ -z "$latest" ]]; then
                printf "${Y}  No discovery results -- run a scan first${NC}\n"; pause; continue
            fi
            printf "\n${C}Single-writer plan for $(basename "$latest"):${NC}\n\n"
            sync_reconciled_to_netbox "$latest" --dry-run
            echo ""
            if confirm "  Write this reconciled model to NetBox now?"; then
                sync_reconciled_to_netbox "$latest"
            else
                printf "${D}  Skipped -- nothing written.${NC}\n"
            fi
            pause ;;
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
                sync_reconciled_to_netbox "$DISC_RESULTS"
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
                && scan_all_hosts && sync_reconciled_to_netbox "$DISC_RESULTS"
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
