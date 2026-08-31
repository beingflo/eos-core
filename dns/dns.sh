#!/usr/bin/env bash
#
# porkbun-ddns.sh — point Porkbun A records at this host's current public IP.
#
# Self-healing: compares each record's live content against the current IP
# (/ping) and only edits mismatches. No cache gate; no-op edits are skipped
# (Porkbun 400s them). Missing records fail (likely a typo). Updown heartbeat
# at most once per PULSE_INTERVAL. Exit: 0 = all records verified, 1 = failed.

set -euo pipefail

# --- config ---------------------------------------------------------------
# Secrets injected by systemd via LoadCredential; $CREDENTIALS_DIRECTORY set by systemd.
CRED_DIR="${CREDENTIALS_DIRECTORY:?CREDENTIALS_DIRECTORY not set (run via systemd)}"
APIKEY="$(<"${CRED_DIR}/apikey")"
SECRETAPIKEY="$(<"${CRED_DIR}/secretapikey")"
[[ -n "${APIKEY}" ]] || { echo "ERROR: apikey credential is empty" >&2; exit 1; }
[[ -n "${SECRETAPIKEY}" ]] || { echo "ERROR: secretapikey credential is empty" >&2; exit 1; }
TTL="${TTL:-600}"                             # Porkbun's minimum

# Heartbeat (updown.io). Missing/empty pulse_url credential disables it.
PULSE_URL="$([ -s "${CRED_DIR}/pulse_url" ] && cat "${CRED_DIR}/pulse_url" || true)"
PULSE_INTERVAL="${PULSE_INTERVAL:-82800}"    # seconds between pulses

STATE_FILE="${STATE_FILE:-/var/lib/porkbun-ddns/last_ip}"     # last-known-good IP (informational)
PULSE_STATE="${PULSE_STATE:-/var/lib/porkbun-ddns/last_pulse}" # timestamp of last successful pulse

# Records to keep pointed at this host, one per line as: "domain subdomain"
# Leave the subdomain empty ("") for the apex/root record of a domain.
RECORDS=(
  "rest.quest "
  "rest.quest go"
  "rest.quest jour"
)
# --------------------------------------------------------------------------

# api-ipv4 host is retired. api.porkbun.com ping returns the connection's
# address; -4 forces IPv4 (validated below as a backstop).
API="https://api.porkbun.com/api/json/v3"

# Build the JSON auth body; $1 is appended inside the object (e.g. ,"content":"...").
auth() { printf '{"apikey":"%s","secretapikey":"%s"%s}' "$APIKEY" "$SECRETAPIKEY" "$1"; }

# Heartbeat, at most once per PULSE_INTERVAL, on success paths only.
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
current_ip=""
for attempt in 1 2 3; do
  if current_ip="$(
    curl -4 -fsS --max-time 15 -X POST "$API/ping" \
      -H 'Content-Type: application/json' \
      -d "$(auth '')" \
    | sed -n 's/.*"yourIp":"\([^"]*\)".*/\1/p'
  )" && [[ -n "${current_ip:-}" ]]; then
    break
  fi
  echo "WARN: ping attempt $attempt failed; retrying..." >&2
  current_ip=""
  sleep 2
done

if [[ -z "${current_ip:-}" ]]; then
  echo "ERROR: could not determine current IP from Porkbun ping" >&2
  exit 1
fi

# Backstop: A records need IPv4 even though ping already used -4.
if [[ ! "$current_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "ERROR: ping returned non-IPv4 address '$current_ip'; refusing to update A records" >&2
  exit 1
fi

# --- verify each record against the current IP ----------------------------
# No cache gate: records can drift or be added while the IP is unchanged, so
# compare live contents every run.
echo "Current IP: $current_ip; checking ${#RECORDS[@]} record(s)."

# --- verify/update each record --------------------------------------------
failed=0
for entry in "${RECORDS[@]}"; do
  domain="${entry%% *}"          # everything before the first space
  sub="${entry#* }"; sub="${sub# }"   # everything after; trim a leading space; may be empty
  label="${sub:+$sub.}$domain"   # pretty name for logging

  # Empty $sub hits the apex. No -f: we want Porkbun's error body on 4xx.
  resp="$(
    curl -sS --max-time 20 -X POST "$API/dns/retrieveByNameType/$domain/A/$sub" \
      -H 'Content-Type: application/json' \
      -d "$(auth '')"
  )" || { echo "  ERROR: retrieve failed for $label: ${resp:-<no response body>}" >&2; failed=1; continue; }

  if [[ "$resp" != *'"status":"SUCCESS"'* ]]; then
    echo "  ERROR retrieving $label: $resp" >&2
    failed=1
    continue
  fi

  # Extract record ids/contents in order, so ids[i] pairs with contents[i].
  ids=(); contents=()
  while IFS= read -r id; do ids+=("$id"); done < <(printf '%s' "$resp" | grep -o '"id":"[^"]*"' | sed 's/^"id":"//; s/"$//' || true)
  while IFS= read -r c; do contents+=("$c"); done < <(printf '%s' "$resp" | grep -o '"content":"[^"]*"' | sed 's/^"content":"//; s/"$//' || true)

  if (( ${#ids[@]} == 0 )); then
    # No record exists — fail rather than create (usually a typo).
    echo "  ERROR: no A record found for $label; refusing to create (check the name)" >&2
    failed=1
    continue
  fi

  # Edit by record ID; skip records already at the current IP.
  for (( i = 0; i < ${#contents[@]}; i++ )); do
    if [[ "${contents[i]}" == "$current_ip" ]]; then
      echo "  $label already $current_ip (record ${ids[i]}); nothing to do"
      continue
    fi
    # edit-by-ID wipes the name if omitted (moves the record to the apex);
    # always send the subdomain.
    edit_extra=",\"type\":\"A\",\"content\":\"$current_ip\",\"ttl\":\"$TTL\""
    if [[ -n "$sub" ]]; then
      edit_extra=",\"name\":\"$sub\"$edit_extra"
    fi
    resp2="$(
      curl -sS --max-time 20 -X POST "$API/dns/edit/$domain/${ids[i]}" \
        -H 'Content-Type: application/json' \
        -d "$(auth "$edit_extra")"
    )" || { echo "  ERROR: edit failed for $label (record ${ids[i]}): ${resp2:-<no response body>}" >&2; failed=1; continue; }
    if [[ "$resp2" != *'"status":"SUCCESS"'* ]]; then
      echo "  ERROR updating $label (record ${ids[i]}): $resp2" >&2
      failed=1
      continue
    fi
    echo "  updated $label -> $current_ip (record ${ids[i]})"
    # Re-retrieve and confirm the record still exists (catches silent renames).
    verify="$(
      curl -sS --max-time 20 -X POST "$API/dns/retrieveByNameType/$domain/A/$sub" \
        -H 'Content-Type: application/json' \
        -d "$(auth '')"
    )" || { echo "  ERROR: verify failed for $label: ${verify:-<no response body>}" >&2; failed=1; continue; }
    if [[ "$verify" == *"\"id\":\"${ids[i]}\""* && "$verify" == *"\"content\":\"$current_ip\""* ]]; then
      echo "  verified $label (record ${ids[i]})"
    else
      echo "  ERROR: $label (record ${ids[i]}) missing after edit — renamed? check Porkbun" >&2
      failed=1
    fi
  done
done

# --- cache last-known-good IP only when every record is correct -----------
if [[ "$failed" -eq 0 ]]; then
  printf '%s\n' "$current_ip" > "$STATE_FILE"
  echo "All records verified/updated; cached last-known-good IP."
  maybe_pulse
  exit 0
else
  echo "One or more records failed; not caching IP (will retry next run)." >&2
  exit 1
fi
