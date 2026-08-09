#!/usr/bin/env bash
#
# Deploy the Porkbun DDNS updater to the server (run from inside the dns/ folder):
#   dns.sh          -> /usr/local/bin/dns.sh
#   dns.service     -> /etc/systemd/system/dns.service
#   dns.timer       -> /etc/systemd/system/dns.timer   (enabled + started)
#   credential files -> /etc/porkbun-ddns/{apikey,secretapikey,pulse_url}  (0600 root:root)
#
# Secrets: .env.enc is decrypted with sops (age key from 1Password),
# sourced into local shell memory, then each value is piped individually
# to the server — no plaintext touches disk on either side.
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

# --- 1. code + systemd units ----------------------------------------------
scp "${SRC_SCRIPT}" "${SRC_UNITS[@]}" "${REMOTE}:/tmp/"
ssh "${REMOTE}" "
  sudo install -m0755 /tmp/dns.sh /usr/local/bin/dns.sh &&
  sudo install -m0644 /tmp/dns.service /tmp/dns.timer /etc/systemd/system/ &&
  rm -f /tmp/dns.sh /tmp/dns.service /tmp/dns.timer &&
  sudo mkdir -p ${REMOTE_DIR} &&
  sudo systemctl daemon-reload
"

# --- 2. credentials --------------------------------------------------------
ENV_SRC=".env.enc"
[[ -f "${ENV_SRC}" ]] || die "${ENV_SRC} not found"

echo "Decrypting ${ENV_SRC} ..."
export SOPS_AGE_KEY="$(op item get "SOPS age key - eos-core" --reveal --fields "private key")"

# Source decrypted dotenv into local shell (never touches disk).
SOPS_OUT="$(sops -d --input-type dotenv --output-type dotenv "${ENV_SRC}")" || die "sops decryption failed (check SOPS_AGE_KEY vs .env.enc recipient)"
# NOTE: source <(...) silently sources nothing on macOS bash 3.2 (returns 0,
# defines no variables) - use eval to execute the dotenv in this shell.
eval "${SOPS_OUT}"

echo "Deploying credentials to ${REMOTE} ..."
ssh "${REMOTE}" "sudo mkdir -p ${REMOTE_DIR}"
printf '%s' "$APIKEY"       | ssh "${REMOTE}" "sudo install -m0600 /dev/stdin ${REMOTE_DIR}/apikey"
printf '%s' "$SECRETAPIKEY" | ssh "${REMOTE}" "sudo install -m0600 /dev/stdin ${REMOTE_DIR}/secretapikey"
printf '%s' "$PULSE_URL"    | ssh "${REMOTE}" "sudo install -m0600 /dev/stdin ${REMOTE_DIR}/pulse_url"
echo "Credentials deployed (0600 root:root)."

# Start the timer only now: units AND credentials are in place, so the
# service can never fire with missing LoadCredential files (which fails
# every tick until the next successful deploy).
ssh "${REMOTE}" "sudo systemctl enable --now dns.timer"

echo "Done. Timer status:"
ssh "${REMOTE}" "systemctl status dns.timer --no-pager -n 0 | head -6"
