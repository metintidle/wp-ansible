#!/usr/bin/env bash
# WordPress agent – nginx, fail2ban, payload, POST (run as root in cron).
# Reads plugin JSON from STATE_DIR/plugins/ written by wp-agent-wp.sh.
# Usage: ./wp-agent-root.sh [--site-id SITE_ID] [--site-name "Full Site Name"]
# Cron (root): 0 3,6,14,22 * * * /usr/local/bin/wp-agent-root.sh --site-id ID --site-name "Name"

set -e

MONITOR_URL="${MONITOR_URL:-https://monitoring.itt.com.au:4000/api/wordpress/maintenance}"
STATE_DIR="${STATE_DIR:-/var/lib/wp-agent}"
PLUGINS_DIR="${PLUGINS_DIR:-$STATE_DIR/plugins}"
NGINX_LOG="${NGINX_LOG:-/var/log/nginx/error.log}"
NGINX_LOG_DIR="${NGINX_LOG_DIR:-/var/log/nginx}"
FAIL2BAN_FILTER="${FAIL2BAN_FILTER:-nginx-unknown-script}"
PLUGINS_MAX_AGE_MIN=120
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"

SITE_ID=""
SITE_NAME=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --site-id)
      shift
      SITE_ID=""
      while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
        [[ -n "$SITE_ID" ]] && SITE_ID="$SITE_ID "
        SITE_ID="$SITE_ID$1"
        shift
      done
      ;;
    --site-name)
      shift
      SITE_NAME=""
      while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
        [[ -n "$SITE_NAME" ]] && SITE_NAME="$SITE_NAME "
        SITE_NAME="$SITE_NAME$1"
        shift
      done
      ;;
    *) shift ;;
  esac
done

mkdir -p "$STATE_DIR"
LAST_TS_FILE="${STATE_DIR}/last_nginx_ts"

# --- Plugins: read from file if recent ---
SAFE_SITE_ID="${SITE_ID//\//_}"
PLUGINS_FILE="${PLUGINS_DIR}/plugins-${SAFE_SITE_ID}.json"
PLUGINS_JSON="[]"
if [[ -f "$PLUGINS_FILE" ]]; then
  if [[ -z "$(find "$PLUGINS_FILE" -mmin -$PLUGINS_MAX_AGE_MIN 2>/dev/null)" ]]; then
    : # file too old, keep []
  else
    RAW=$(cat "$PLUGINS_FILE" 2>/dev/null) || true
    if echo "${RAW:-[]}" | jq -e . &>/dev/null; then
      PLUGINS_JSON=$(echo "$RAW" | jq -c . 2>/dev/null) || PLUGINS_JSON="[]"
    fi
  fi
fi

# --- Nginx error log (from last index, including rotated files) ---
LAST_TS=""
[[ -f "$LAST_TS_FILE" ]] && LAST_TS=$(cat "$LAST_TS_FILE")
if [[ -z "$LAST_TS" ]]; then
  LAST_TS=$(date -u "+%Y/%m/%d 00:00:00")
fi

# Collect all log files to read: rotated (uncompressed) + current.
# Rotated logs hold errors from before logrotate ran, which the previous
# run may not have seen yet (22:00 → ~03:40 gap).
NGINX_LOG_FILES=()
if [[ -d "$NGINX_LOG_DIR" ]]; then
  # Add any uncompressed rotated error logs newer than the last timestamp date
  LAST_DATE_COMPACT="${LAST_TS:0:4}${LAST_TS:5:2}${LAST_TS:8:2}"
  for rotated in "${NGINX_LOG_DIR}"/error.log-[0-9]*; do
    [[ -f "$rotated" ]] || continue
    # Skip compressed (.gz) files – reading them would need zcat
    [[ "$rotated" == *.gz ]] && continue
    # Extract YYYYMMDD from filename (e.g. error.log-20260209)
    FNAME=$(basename "$rotated")
    FILE_DATE="${FNAME##error.log-}"
    # Only include files from the same date or newer
    if [[ ! "$FILE_DATE" < "$LAST_DATE_COMPACT" ]]; then
      NGINX_LOG_FILES+=("$rotated")
    fi
  done
fi
# Always add the current log last (so timestamps increase)
[[ -r "$NGINX_LOG" ]] && NGINX_LOG_FILES+=("$NGINX_LOG")

# Shared awk script: parse nginx error lines, extract fields, emit JSON.
# Captures multiple error patterns for broader security monitoring.
read -r -d '' AWK_PARSE << 'AWKEOF' || true
BEGIN { first = 1 }
{
  # Filter by timestamp (string comparison works for YYYY/MM/DD HH:MM:SS)
  if ($0 < from) next

  d = $1; gsub(/\//, "-", d); created = d "T" $2 "Z"

  # Extract client IP
  match($0, /client: ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/, ip_arr)
  ip = ip_arr[1]

  # Extract request URI
  match($0, /request: "([A-Z]+) ([^ ]+)/, req_arr)
  req = req_arr[2]

  # Classify the error – broadened from the original 2 patterns
  detail = ""
  if ($0 ~ /Primary script unknown/)           { detail = "Primary script unknown" }
  else if ($0 ~ /access forbidden by rule/)     { detail = "access forbidden by rule" }
  else if ($0 ~ /access forbidden/)             { detail = "access forbidden" }
  else if ($0 ~ /directory index .* is forbidden/) { detail = "directory index forbidden" }
  else if ($0 ~ /Connection reset by peer/)     { detail = "connection reset by peer" }
  else if ($0 ~ /upstream timed out/)           { detail = "upstream timed out" }
  else if ($0 ~ /No such file or directory/)    { detail = "no such file or directory" }
  else if ($0 ~ /connect\(\) failed/)           { detail = "upstream connect failed" }
  else if ($0 ~ /SSL_do_handshake\(\) failed/)  { detail = "SSL handshake failed" }
  else if ($0 ~ /limit_req/)                    { detail = "rate limit exceeded" }

  # Emit JSON only when all key fields are present
  if (created != "" && ip != "" && req != "" && detail != "") {
    if (!first) printf ","
    printf "{\"created\":\"%s\",\"IP\":\"%s\",\"request\":\"%s\",\"detail\":\"%s\"}\n", created, ip, req, detail
    first = 0
  }
}
AWKEOF

NGINX_JSON="["
if [[ ${#NGINX_LOG_FILES[@]} -gt 0 ]]; then
  ENTRIES=$(cat "${NGINX_LOG_FILES[@]}" 2>/dev/null \
    | awk -v from="$LAST_TS" "$AWK_PARSE" 2>/dev/null) || ENTRIES=""
  NGINX_JSON="${NGINX_JSON}${ENTRIES}"
fi
NGINX_JSON="${NGINX_JSON}]"

# Update last-seen timestamp from the LAST file in the list (current log).
if [[ -r "$NGINX_LOG" ]] && [[ -s "$NGINX_LOG" ]]; then
  NEW_LAST=$(tail -1 "$NGINX_LOG" | awk '{ print $1 " " $2 }')
  [[ -n "$NEW_LAST" ]] && echo "$NEW_LAST" > "$LAST_TS_FILE"
elif [[ ${#NGINX_LOG_FILES[@]} -gt 0 ]]; then
  # Fallback: use last line from the newest rotated file
  LAST_ROTATED="${NGINX_LOG_FILES[-1]}"
  if [[ -s "$LAST_ROTATED" ]]; then
    NEW_LAST=$(tail -1 "$LAST_ROTATED" | awk '{ print $1 " " $2 }')
    [[ -n "$NEW_LAST" ]] && echo "$NEW_LAST" > "$LAST_TS_FILE"
  fi
fi

# --- Fail2ban status ---
FAIL2BAN_JSON="{}"
if command -v fail2ban-client &>/dev/null; then
  FAIL2BAN_JSON=$(fail2ban-client status "$FAIL2BAN_FILTER" 2>/dev/null | awk '
    /Total failed:/     { tf=$NF }
    /Total banned:/     { tb=$NF }
    /Currently banned:/ { cb=$NF }
    /Banned IP list:/ {
      printf "{\"total_failed\":%s,\"total_banned\":%s,\"currently_banned\":%s,\"banned_ips\":[", tf, tb, cb
      for (i=5; i<=NF; i++) printf "\"%s\"%s", $i, (i<NF?",":"")
      print "]}"
    }
  ' 2>/dev/null) || FAIL2BAN_JSON="{}"
fi

# --- Build payload and POST ---
COLLECTED_AT=$(date -u -Iseconds)
NGINX_JSON=$(echo "$NGINX_JSON" | jq -c . 2>/dev/null) || NGINX_JSON="[]"
FAIL2BAN_JSON=$(echo "$FAIL2BAN_JSON" | jq -c . 2>/dev/null) || FAIL2BAN_JSON="{}"
PAYLOAD=$(jq -n \
  --arg siteId "$SITE_ID" \
  --arg siteName "$SITE_NAME" \
  --arg collectedAt "$COLLECTED_AT" \
  --argjson plugins "$PLUGINS_JSON" \
  --argjson nginxErrors "$NGINX_JSON" \
  --argjson fail2ban "$FAIL2BAN_JSON" \
  '{ site_id: $siteId, site_name: $siteName, collected_at: $collectedAt, plugins: $plugins, nginx_errors: $nginxErrors, fail2ban: $fail2ban }')

if command -v curl &>/dev/null; then
  curl -s -S -X POST "$MONITOR_URL" \
    --max-time "$CURL_MAX_TIME" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    -w "\nHTTP %{http_code}\n" || true
elif command -v wget &>/dev/null; then
  wget -q -O- --timeout="$CURL_MAX_TIME" \
    --post-data="$PAYLOAD" \
    --header="Content-Type: application/json" \
    "$MONITOR_URL" || true
fi
