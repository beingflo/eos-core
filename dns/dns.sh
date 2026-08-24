#!/usr/bin/env bash
#
# porkbun-ddns.sh — point Porkbun A records at this host's current public IP.
#
# Calls the edit API only when the IP has changed (cached in STATE_FILE), and
# detects the public IP via Porkbun's own /ping endpoint.
#
# Sends an updown.io heartbeat at most once per PULSE_INTERVAL, on successful
# runs only.
#
# Exit status: 0 = unchanged or all records updated; 1 = something failed
# (systemd marks the unit failed and the IP is NOT cached, forcing a retry).

set -euo pipefail

# --- config ---------------------------------------------------------------
# Secrets are injected by systemd via LoadCredential (never in the environment).
# $CREDENTIALS_DIRECTORY is set automatically by systemd when LoadCredential is used.
CRED_DIR="${CREDENTIALS_DIRECTORY:?CREDENTIALS_DIRECTORY not set (run via systemd)}"
APIKEY="$(<"${CRED_DIR}/apikey")"
SECRETAPIKEY="$(<"${CRED_DIR}/secretapikey")"
[[ -n "${APIKEY}" ]] || { echo "ERROR: apikey credential is empty" >&2; exit 1; }
[[ -n "${SECRETAPIKEY}" ]] || { echo "ERROR: secretapikey credential is empty" >&2; exit 1; }
TTL="${TTL:-600}"                             # Porkbun's minimum

# Heartbeat (updown.io). Missing/empty pulse_url credential disables it.
PULSE_URL="$([ -s "${CRED_DIR}/pulse_url" ] && cat "${CRED_DIR}/pulse_url" || true)"
PULSE_INTERVAL="${PULSE_INTERVAL:-82800}"    # seconds between pulses

STATE_FILE="/var/lib/porkbun-ddns/last_ip"     # last IP we successfully pushed
PULSE_STATE="/var/lib/porkbun-ddns/last_pulse" # timestamp of last successful pulse

# Records to keep pointed at this host, one per line as: "domain subdomain"
# Leave the subdomain empty ("") for the apex/root record of a domain.
RECORDS=(
  "marending.dev test"
  "rest.quest stage"
  "rest.quest stage.go"
  "rest.quest stage.jour"
)
# --------------------------------------------------------------------------

# api-ipv4 forces IPv4 so we always learn (and set) an A record.
API="https://api-ipv4.porkbun.com/api/json/v3"

# Build the JSON auth body; $1 is appended inside the object (e.g. ,"content":"...").
auth() { printf '{"apikey":"%s","secretapikey":"%s"%s}' "$APIKEY" "$SECRETAPIKEY" "$1"; }

# Send a heartbeat if enough time has passed since the last successful pulse.
# Call only on success paths; the timestamp advances only on a successful pulse.
maybe_pulse() {
  [[ -n "${PULSE_URL:-}" ]] || return 0
  local now last
  now="$(date +%s)"
  last=0
  [[ -f "$PULSE_STATE" ]] && last="$(cat "$PULSE_STATE" 2>/dev/null || echo 0)"
  if (( now - last >= PULSE_INTERVAL )); then
    if curl -fsS --max-time 15 "$PULSE_URL" >/dev/null; then
      printf '%s\n' "$now" > "$PULSE_STATE"
      echo "Heartbeat sent to updown."
    else
      echo "WARN: heartbeat to updown failed (will retry next eligible run)." >&2
    fi
  fi
}

# --- determine current public IP via Porkbun's ping endpoint --------------
current_ip="$(
  curl -fsS --max-time 20 -X POST "$API/ping" \
    -H 'Content-Type: application/json' \
    -d "$(auth '')" \
  | sed -n 's/.*"yourIp":"\([^"]*\)".*/\1/p'
)"

if [[ -z "${current_ip:-}" ]]; then
  echo "ERROR: could not determine current IP from Porkbun ping" >&2
  exit 1
fi

# --- compare against the last IP we pushed --------------------------------
last_ip=""
[[ -f "$STATE_FILE" ]] && last_ip="$(cat "$STATE_FILE")"

if [[ "$current_ip" == "$last_ip" ]]; then
  echo "IP unchanged ($current_ip); nothing to do."
  maybe_pulse
  exit 0
fi

echo "IP changed: ${last_ip:-<none>} -> $current_ip; updating ${#RECORDS[@]} record(s)."

# --- update each record ---------------------------------------------------
failed=0
for entry in "${RECORDS[@]}"; do
  domain="${entry%% *}"          # everything before the first space
  sub="${entry#* }"; sub="${sub# }"   # everything after; trim a leading space; may be empty
  label="${sub:+$sub.}$domain"   # pretty name for logging

  # Empty $sub hits the apex; the documented editByNameType behaviour.
  # NOTE: deliberately no -f/--fail-with-body here — on an HTTP 4xx we still
  # want Porkbun's JSON error body (it carries the machine-readable code +
  # message) so failures stay diagnosable. The status check below handles
  # non-SUCCESS responses; the || branch covers network/timeout failures.
  resp="$(
    curl -sS --max-time 20 -X POST "$API/dns/editByNameType/$domain/A/$sub" \
      -H 'Content-Type: application/json' \
      -d "$(auth ",\"content\":\"$current_ip\",\"ttl\":\"$TTL\"")"
  )" || { echo "  ERROR: request failed for $label: ${resp:-<no response body>}" >&2; failed=1; continue; }

  if [[ "$resp" == *'"status":"SUCCESS"'* ]]; then
    echo "  updated $label -> $current_ip"
  else
    echo "  ERROR updating $label: $resp" >&2
    failed=1
  fi
done

# --- persist the new IP only when every record succeeded ------------------
# On failure the old IP is kept, so the next run retries the whole set.
if [[ "$failed" -eq 0 ]]; then
  printf '%s\n' "$current_ip" > "$STATE_FILE"
  echo "All records updated; cached new IP."
  maybe_pulse
  exit 0
else
  echo "One or more records failed; not caching IP (will retry next run)." >&2
  exit 1
fi
