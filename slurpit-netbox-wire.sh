#!/usr/bin/env bash
set -euo pipefail

NETBOX_CONTAINER="netbox-docker-netbox-1"
NETBOX_URL="http://localhost:8000"

SLURPIT_CONTAINERS=(
  slurpit-portal
  slurpit-warehouse
  slurpit-scraper
  slurpit-scanner
)

log() { echo "[INFO] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

###############################################################################
# Verify NetBox reachable (health endpoint only)
###############################################################################
log "Checking NetBox API reachability..."
curl -s "${NETBOX_URL}/api/status/" >/dev/null \
  || die "NetBox API not reachable"

###############################################################################
# Generate or reuse NetBox API token (NetBox 4.4+ correct)
###############################################################################
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

###############################################################################
# Restart Slurp’it services ONLY
###############################################################################
log "Restarting Slurp’it services..."
docker restart "${SLURPIT_CONTAINERS[@]}" >/dev/null

###############################################################################
# Verify Slurp’it plugin registered in NetBox
###############################################################################
log "Verifying Slurp’it plugin registration..."

docker exec -i "${NETBOX_CONTAINER}" \
  /opt/netbox/netbox/manage.py shell <<'PY'
from django.conf import settings
assert "slurpit_netbox" in settings.PLUGINS
print("Slurp’it plugin registered")
PY

###############################################################################
# REAL verification: Slurp’it → NetBox smoke test
###############################################################################
log "Verifying Slurp’it can reach NetBox..."

docker exec slurpit-warehouse sh -c "
  curl -s http://netbox-docker-netbox-1:8080/api/status/ >/dev/null
" || die "Slurp’it cannot reach NetBox API"


log "SUCCESS: Slurp’it ↔ NetBox integration verified"
