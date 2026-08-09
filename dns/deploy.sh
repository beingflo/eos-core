#!/usr/bin/env bash
set -euo pipefail
die() { echo "$*" 1>&2; exit 1; }

REMOTE=arm
ENC=.env.enc
REMOTE_ENV=/etc/dyndns/env
REMOTE_MARKER=/etc/dyndns/env.blob

[ -z "$(git status --porcelain)" ] || die "Uncommitted changes"

# code + units — no secrets, always sync
scp dyndns.sh dyndns.service dyndns.timer "${REMOTE}:/tmp/"
ssh "${REMOTE}" '
  sudo install -m0755 /tmp/dyndns.sh /usr/local/bin/dyndns.sh &&
  sudo install -m0644 /tmp/dyndns.service /tmp/dyndns.timer /etc/systemd/system/ &&
  sudo mkdir -p /etc/dyndns &&
  rm -f /tmp/dyndns.{sh,service,timer} &&
  sudo systemctl daemon-reload &&
  sudo systemctl enable --now dyndns.timer'

# env — decrypt + push only when the ciphertext actually changed
local_blob=$(git rev-parse "HEAD:${ENC}")
remote_blob=$(ssh "${REMOTE}" "sudo cat ${REMOTE_MARKER} 2>/dev/null" || true)

if [ "${local_blob}" != "${remote_blob}" ]; then
  echo "Secret changed — decrypting"
  trap 'rm -f .env.plain' EXIT
  export SOPS_AGE_KEY=$(op item get "SOPS age key - dyndns" --reveal --fields "private key")
  sops -d --input-type dotenv --output-type dotenv "${ENC}" > .env.plain
  # create 0600 root file first, then fill it — no world-readable window, no /tmp residue
  ssh "${REMOTE}" "sudo install -m0600 /dev/null ${REMOTE_ENV} && sudo tee ${REMOTE_ENV} >/dev/null" < .env.plain
  echo "${local_blob}" | ssh "${REMOTE}" "sudo tee ${REMOTE_MARKER} >/dev/null"
else
  echo "Secret unchanged — skipping decrypt"
fi
