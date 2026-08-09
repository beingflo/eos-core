#!/usr/bin/env bash
#
# Deploy the Porkbun DDNS updater to the server (run from inside the dns/ folder):
#   dns.sh          -> /usr/local/bin/dns.sh
#   dns.service     -> /etc/systemd/system/dns.service
#   dns.timer       -> /etc/systemd/system/dns.timer   (enabled + started)
#   env file        -> /etc/porkbun-ddns/env           (0600 root:root)
#
# Secrets: .env.enc is decrypted with sops (age key from 1Password) and
# streamed to the server.
#
# Usage:
#   ./deploy.sh              # default remote (REMOTE=arm)
#   REMOTE=myserver ./deploy.sh

set -euo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }

REMOTE="${REMOTE:-eos}"                    # ssh host alias

SRC_SCRIPT="dns.sh"
SRC_UNITS=( "dns.service" "dns.timer" )

REMOTE_DIR="/etc/porkbun-ddns"
REMOTE_ENV="${REMOTE_DIR}/env"             # EnvironmentFile

# --- 1. code + systemd units ----------------------------------------------
scp "${SRC_SCRIPT}" "${SRC_UNITS[@]}" "${REMOTE}:/tmp/"
ssh "${REMOTE}" "
  sudo install -m0755 /tmp/dns.sh /usr/local/bin/dns.sh &&
  sudo install -m0644 /tmp/dns.service /tmp/dns.timer /etc/systemd/system/ &&
  rm -f /tmp/dns.sh /tmp/dns.service /tmp/dns.timer &&
  sudo mkdir -p ${REMOTE_DIR} &&
  sudo systemctl daemon-reload &&
  sudo systemctl enable --now dns.timer &&
  sudo systemctl restart dns.timer
"

# --- 2. env file -----------------------------------------------------------
ENV_SRC=".env.enc"
[[ -f "${ENV_SRC}" ]] || die "${ENV_SRC} not found"

echo "Decrypting ${ENV_SRC} and deploying."
export SOPS_AGE_KEY="$(op item get "SOPS age key - dyndns" --reveal --fields "private key")"
sops -d --input-type dotenv --output-type dotenv "${ENV_SRC}" |
  ssh "${REMOTE}" "sudo install -m0600 /dev/null ${REMOTE_ENV}.tmp && sudo tee ${REMOTE_ENV}.tmp >/dev/null && sudo mv ${REMOTE_ENV}.tmp ${REMOTE_ENV}"
echo "Env deployed (0600 root:root → ${REMOTE_ENV})."

echo "Done. Timer status:"
ssh "${REMOTE}" "systemctl status dns.timer --no-pager -n 0 | head -6"
