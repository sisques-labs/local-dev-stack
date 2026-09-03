#!/bin/sh
# Imports every docker/keycloak/realms/*.json into the running Keycloak via
# the Admin REST API, instead of Keycloak's own `--import-realm` startup
# flag. `--import-realm` is unusable on Keycloak 26.0: it reliably crashes
# the server on boot with "ERROR: Session not bound to a realm" right after
# logging "Realm '<name>' imported" (reproduced repeatedly while adding this
# service — see upstream keycloak/keycloak#33637 and #34673, unresolved as
# of 26.0.8). The REST API path below hits the same import endpoint Keycloak
# uses internally, without that startup-time race.
set -eu

KEYCLOAK_URL="http://keycloak:8080"
ADMIN_USERNAME="${KEYCLOAK_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

echo "Waiting for Keycloak to be ready..."
until curl -sf "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration" -o /dev/null; do
  sleep 2
done

echo "Keycloak is up. Importing realms from /realms..."

TOKEN=$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=${ADMIN_USERNAME}" \
  -d "password=${ADMIN_PASSWORD}" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

if [ -z "$TOKEN" ]; then
  echo "Failed to obtain an admin token" >&2
  exit 1
fi

for realm_file in /realms/*.json; do
  [ -e "$realm_file" ] || continue
  echo "Importing ${realm_file}..."
  http_code=$(curl -s -o /tmp/import-response.txt -w "%{http_code}" \
    -X POST "${KEYCLOAK_URL}/admin/realms" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@${realm_file}")
  case "$http_code" in
    201) echo "  created" ;;
    409) echo "  already exists, skipping" ;;
    *)
      echo "  unexpected HTTP ${http_code}:"
      cat /tmp/import-response.txt
      exit 1
      ;;
  esac
done

echo "Realm import complete."
