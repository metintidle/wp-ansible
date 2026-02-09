#!/usr/bin/env bash
# WordPress agent – nginx, fail2ban, payload, POST (run as root in cron).
# Reads plugin JSON from STATE_DIR/plugins/ written by wp-agent-wp.sh.
# Usage: ./wp-agent-root.sh [--site-id SITE_ID] [--site-name "Full Site Name"]
# Cron (root): 0 6,14,22 * * * /usr/local/bin/wp-agent-root.sh --site-id ID --site-name "Name"

set -e

MONITOR_URL="${MONITOR_URL:-https://monitoring.itt.com.au:4000/api/wordpress/maintenance}"
STATE_DIR="${STATE_DIR:-/var/lib/wp-agent}"
PLUGINS_DIR="${PLUGINS_DIR:-$STATE_DIR/plugins}"
NGINX_LOG="${NGINX_LOG:-/var/log/nginx/error.log}"
FAIL2BAN_FILTER="${FAIL2BAN_FILTER:-nginx-unknown-script}"
PLUGINS_MAX_AGE_MIN=60

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

# --- Nginx error log (from last index) ---
LAST_TS=""
[[ -f "$LAST_TS_FILE" ]] && LAST_TS=$(cat "$LAST_TS_FILE")
if [[ -z "$LAST_TS" ]]; then
  LAST_TS=$(date -u "+%Y/%m/%d 00:00:00")
fi

NGINX_JSON="[]"
if [[ -r "$NGINX_LOG" ]]; then
  NGINX_JSON=$(awk -v from="$LAST_TS" '$0 >= from' "$NGINX_LOG" | awk '
    BEGIN { print "[" }
    {
      d = $1; gsub(/\//, "-", d); created = d "T" $2 "Z"
      match($0, /client: ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/, ip_arr)
      ip = ip_arr[1]
      match($0, /request: "([A-Z]+) ([^ ]+)/, req_arr)
      req = req_arr[2]
      detail = ""
      if ($0 ~ /Primary script unknown/) { detail = "Primary script unknown" }
      else if ($0 ~ /access forbidden by rule/) { detail = "access forbidden by rule" }
      if (created != "" && ip != "" && req != "" && detail != "") {
        if (NR>1) printf ",\n"
        printf "{\"created\":\"%s\",\"IP\":\"%s\",\"request\":\"%s\",\"detail\":\"%s\"}", created, ip, req, detail
      }
    }
    END { print "\n]" }
  ' 2>/dev/null || true)
  if [[ -s "$NGINX_LOG" ]]; then
    NEW_LAST=$(tail -1 "$NGINX_LOG" | awk '{ print $1 " " $2 }')
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
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    -w "\nHTTP %{http_code}\n" || true
elif command -v wget &>/dev/null; then
  echo "$PAYLOAD" | wget -q -O- --post-data="$PAYLOAD" --header="Content-Type: application/json" "$MONITOR_URL" || true
fi
