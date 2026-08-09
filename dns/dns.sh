#!/usr/bin/env bash
#
# porkbun-ddns.sh — point Porkbun A records at this host's current public IP.
#
# Only calls the edit API when the IP has actually changed (cached in STATE_FILE),
# so it's safe to run every few minutes without tripping Porkbun's rate limits.
# Detects the public IP via Porkbun's own /ping endpoint, so the value pushed is
# exactly the address Porkbun sees the request coming from (avoids NAT/proxy skew).
#
# Sends a heartbeat to updown.io at most once per PULSE_INTERVAL, and only on a
# successful run, so a stretch of failures stops the heartbeat and updown alerts.
#
# Exit status: 0 = unchanged or all records updated; 1 = something failed
# (so systemd marks the unit failed and the IP is NOT cached, forcing a retry).

set -euo pipefail

# --- config ---------------------------------------------------------------
CRED_FILE="/etc/porkbun-ddns/credentials"    # 0600 root:root; defines APIKEY + SECRETAPIKEY
STATE_FILE="/var/lib/porkbun-ddns/last_ip"   # cache of the last IP we successfully pushed
TTL="600"                                    # 600s is Porkbun's minimum

# Heartbeat (updown.io). Leave PULSE_URL empty to disable.
PULSE_URL="https://pulse.updown.io/xxxxxxxx"  # your updown pulse URL
PULSE_STATE="/var/lib/porkbun-ddns/last_pulse"
PULSE_INTERVAL=82800                          # seconds between pulses; 82800 = 23h
                                              # (first successful run past this pings)

# Records to keep pointed at this host, one per line as: "domain subdomain"
# Leave the subdomain empty ("") for the apex/root record of a domain.
RECORDS=(
  "example.com "          # example.com        (apex)
  "example.com www"       # www.example.com
  "otherdomain.net "      # otherdomain.net    (apex)
)
# --------------------------------------------------------------------------

# api-ipv4 forces the request over IPv4 so we always learn (and set) an A record.
API="https://api-ipv4.porkbun.com/api/json/v3"

# shellcheck source=/dev/null
. "$CRED_FILE"   # must set: APIKEY=pk1_...  and  SECRETAPIKEY=sk1_...

# Build the JSON auth body; $1 is appended inside the object (e.g. ,"content":"...").
auth() { printf '{"apikey":"%s","secretapikey":"%s"%s}' "$APIKEY" "$SECRETAPIKEY" "$1"; }

# Send a heartbeat if enough time has passed since the last successful pulse.
# Call this ONLY on success paths. The timestamp advances only when the pulse
# itself succeeds, so a failed pulse is retried on the next eligible run.
maybe_pulse() {
  [[ -n "${PULSE_URL:-}" ]] || return 0
  local now last
  now="$(date +%s)"
  last=0
  [[ -f "$PULSE_STATE" ]] && last="$(cat "$PULSE_STATE" 2>/dev/null || echo 0)"
  if (( now - last >= PULSE_INTERVAL )); then
    if curl -fsS --max-time 15 "$PULSE_URL" >/dev/null; then
      mkdir -p "$(dirname "$PULSE_STATE")"
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
  maybe_pulse            # healthy run: heartbeat eligible
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
  resp="$(
    curl -fsS --max-time 20 -X POST "$API/dns/editByNameType/$domain/A/$sub" \
      -H 'Content-Type: application/json' \
      -d "$(auth ",\"content\":\"$current_ip\",\"ttl\":\"$TTL\"")"
  )" || { echo "  ERROR: request failed for $label" >&2; failed=1; continue; }

  if [[ "$resp" == *'"status":"SUCCESS"'* ]]; then
    echo "  updated $label -> $current_ip"
  else
    echo "  ERROR updating $label: $resp" >&2
    failed=1
  fi
done

# --- persist new IP only on full success ----------------------------------
# If any record failed, we deliberately do NOT cache the new IP, so the next
# run sees a "change" again and retries the whole set rather than masking it.
if [[ "$failed" -eq 0 ]]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s\n' "$current_ip" > "$STATE_FILE"
  echo "All records updated; cached new IP."
  maybe_pulse            # healthy run: heartbeat eligible
  exit 0
else
  echo "One or more records failed; not caching IP (will retry next run)." >&2
  exit 1
fi
