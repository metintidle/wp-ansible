#!/usr/bin/env bash
# WordPress Maintenance Cron Agent
# Runs WP-CLI plugin list, nginx error log parsing, and fail2ban status;
# sends payload to monitoring server. Run 3x/day (e.g. 6:00, 14:00, 22:00).
# Usage: ./wp-agent.sh [--site-id SITE_ID] [--site-name "My Site"]
# Env: MONITOR_URL, WP_PATH, STATE_DIR, NGINX_LOG, FAIL2BAN_FILTER, WP_USER, WP_GROUP, LOG_FILE (default: /home/ec2-user/wp-agent.log)

set -e

# --- Config (override with env) ---
MONITOR_URL="${MONITOR_URL:-https://48vlro2uil.execute-api.ap-southeast-2.amazonaws.com/dev/api/services/wordpress/maintenance}"
WP_PATH="${WP_PATH:-/usr/share/nginx/html}"
STATE_DIR="${STATE_DIR:-/var/lib/wp-agent}"
NGINX_LOG="${NGINX_LOG:-/var/log/nginx/error.log}"
FAIL2BAN_FILTER="${FAIL2BAN_FILTER:-nginx-unknown-script}"
LOG_FILE="${LOG_FILE:-/home/ec2-user/wp-agent.log}"
# Run WP-CLI as this user:group (e.g. ec2-user:nginx)
WP_USER="${WP_USER:-ec2-user}"
WP_GROUP="${WP_GROUP:-nginx}"

SITE_ID=""
SITE_NAME=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --site-id)   SITE_ID="$2";   shift 2 ;;
    --site-name) SITE_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$STATE_DIR"
LAST_TS_FILE="${STATE_DIR}/last_nginx_ts"

# --- Logging ---
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log "=== start (site-id=$SITE_ID site-name=$SITE_NAME) ==="

# --- 1. WP-CLI plugin list (as root: sudo -u WP_USER -i; else: current user) ---
PLUGINS_JSON="[]"
if command -v wp &>/dev/null && [[ -d "$WP_PATH" ]]; then
  if [[ $(id -u) -eq 0 ]]; then
    PLUGINS_JSON=$(sudo -u "$WP_USER" -i -- wp plugin list --skip-plugins --path="$WP_PATH" --format=json 2>/dev/null) || PLUGINS_JSON="[]"
  else
    PLUGINS_JSON=$(wp plugin list --skip-plugins --path="$WP_PATH" --format=json 2>/dev/null) || PLUGINS_JSON="[]"
  fi
  PLUGIN_COUNT=$(echo "$PLUGINS_JSON" | jq 'length' 2>/dev/null || echo "0")
  log "step 1 wp plugin list: ok (plugins=$PLUGIN_COUNT)"
else
  log "step 1 wp plugin list: skipped (wp missing or WP_PATH not found)"
fi

# --- 2. Nginx error log (from last index) ---
LAST_TS=""
[[ -f "$LAST_TS_FILE" ]] && LAST_TS=$(tr -d '\r\n' < "$LAST_TS_FILE")
# Default: from start of yesterday (YYYY/MM/DD 00:00:00) UTC
if [[ -z "$LAST_TS" ]]; then
  LAST_TS=$(date -u -d "yesterday" "+%Y/%m/%d 00:00:00")
fi
log "step 2 nginx error log: from_ts=$LAST_TS"

NGINX_JSON="[]"
if [[ -r "$NGINX_LOG" ]]; then
  NGINX_JSON=$(sudo awk -v from="$LAST_TS" '( $1 " " $2 ) >= from' "$NGINX_LOG" | awk '
    BEGIN { print "["; first = 1 }
    {
      created = $1 " " $2
      match($0, /client: ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/, ip_arr)
      ip = ip_arr[1]
      match($0, /request: "([A-Z]+) ([^ ]+)/, req_arr)
      req = req_arr[2]
      detail = ""
      if ($0 ~ /Primary script unknown/) { detail = "Primary script unknown" }
      else if ($0 ~ /access forbidden by rule/) { detail = "access forbidden by rule" }
      if (created != "" && ip != "" && req != "" && detail != "") {
        if (!first) printf ",\n"
        first = 0
        printf "{\"created\":\"%s\",\"IP\":\"%s\",\"request\":\"%s\",\"detail\":\"%s\"}", created, ip, req, detail
      }
    }
    END { print "\n]" }
  ' 2>/dev/null || true)
  # Update last index: last line timestamp from log (for next run)
  if [[ -s "$NGINX_LOG" ]]; then
    NEW_LAST=$(sudo tail -1 "$NGINX_LOG" | awk '{ print $1 " " $2 }')
    [[ -n "$NEW_LAST" ]] && echo "$NEW_LAST" > "$LAST_TS_FILE"
  fi
  NGINX_COUNT=$(echo "$NGINX_JSON" | jq 'length' 2>/dev/null || echo "0")
  log "step 2 nginx error log: ok (entries=$NGINX_COUNT)"
else
  log "step 2 nginx error log: skipped (log unreadable or missing)"
fi

# --- 3. Fail2ban status ---
FAIL2BAN_JSON="{}"
if command -v fail2ban-client &>/dev/null; then
  FAIL2BAN_JSON=$(sudo fail2ban-client status "$FAIL2BAN_FILTER" 2>/dev/null | awk '
    /Total failed:/     { tf=$NF }
    /Total banned:/     { tb=$NF }
    /Currently banned:/ { cb=$NF }
    /Banned IP list:/ {
      printf "{\"total_failed\":%s,\"total_banned\":%s,\"currently_banned\":%s,\"banned_ips\":[", tf, tb, cb
      for (i=5; i<=NF; i++) printf "\"%s\"%s", $i, (i<NF?",":"")
      print "]}"
    }
  ' 2>/dev/null) || FAIL2BAN_JSON="{}"
  log "step 3 fail2ban: ok (filter=$FAIL2BAN_FILTER)"
else
  log "step 3 fail2ban: skipped (fail2ban-client not found)"
fi

# --- 4. Build payload and POST ---
COLLECTED_AT=$(date -u -Iseconds)
# Compact JSON so shell variables are single-line (required for --argjson)
PLUGINS_JSON=$(echo "$PLUGINS_JSON" | jq -c . 2>/dev/null) || PLUGINS_JSON="[]"
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
log "step 4 payload: built (collected_at=$COLLECTED_AT)"

HTTP_CODE=""
if command -v curl &>/dev/null; then
  HTTP_CODE=$(curl -s -S -o /dev/null -w "%{http_code}" -X POST "$MONITOR_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null) || HTTP_CODE="000"
  log "step 5 POST: curl http_code=$HTTP_CODE"
elif command -v wget &>/dev/null; then
  if wget -q -O- --post-data="$PAYLOAD" --header="Content-Type: application/json" "$MONITOR_URL" &>/dev/null; then
    log "step 5 POST: wget ok"
  else
    log "step 5 POST: wget failed"
  fi
else
  log "step 5 POST: skipped (no curl or wget)"
fi
log "=== end ==="
