#!/usr/bin/env bash
#
# deploy.sh — deploy the Caddyfile to the eos server and reload Caddy.
#
# Usage: ./deploy.sh [path/to/Caddyfile]
#   Defaults to ./Caddyfile in this directory.

set -euo pipefail

HOST="eos"
CADDYFILE="${1:-./Caddyfile}"
REMOTE_TMP="/tmp/Caddyfile.new"
REMOTE_PATH="/etc/caddy/Caddyfile"

if [[ ! -f "$CADDYFILE" ]]; then
    echo "error: $CADDYFILE not found" >&2
    exit 1
fi

echo "==> Copying $CADDYFILE to $HOST"
scp "$CADDYFILE" "${HOST}:${REMOTE_TMP}"

# All sudo steps run in one SSH session, so sudo only prompts once
# (it caches the credential for the rest of the session).
echo "==> Validating, installing, and reloading on the server (one sudo prompt)"
ssh -t "$HOST" '
    set -euo pipefail
    sudo caddy validate --config /tmp/Caddyfile.new --adapter caddyfile
    sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
    sudo mv /tmp/Caddyfile.new /etc/caddy/Caddyfile
    sudo restorecon /etc/caddy/Caddyfile
    sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
'

echo "==> Done"
