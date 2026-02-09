#!/usr/bin/env bash
# WordPress agent – WP-CLI only (run as unprivileged user in cron).
# Writes plugin list JSON to STATE_DIR/plugins/ for wp-agent-root.sh to read.
# Usage: ./wp-agent-wp.sh [--site-id SITE_ID] [--site-name "Full Site Name"]
# Cron (user, e.g. ec2-user): 0 6,14,22 * * * STATE_DIR=/var/lib/wp-agent /usr/local/bin/wp-agent-wp.sh --site-id ID --site-name "Name"

set -e

export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

STATE_DIR="${STATE_DIR:-/var/lib/wp-agent}"
WP_PATH="${WP_PATH:-/usr/share/nginx/html}"
PLUGINS_DIR="${PLUGINS_DIR:-$STATE_DIR/plugins}"

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

# Sanitize SITE_ID for filename (replace / with _)
SAFE_SITE_ID="${SITE_ID//\//_}"
PLUGINS_FILE="${PLUGINS_DIR}/plugins-${SAFE_SITE_ID}.json"

mkdir -p "$PLUGINS_DIR"
PLUGINS_JSON="[]"

WP_CMD=""
for candidate in wp /usr/local/bin/wp /usr/bin/wp; do
  if command -v "$candidate" &>/dev/null; then
    WP_CMD="$candidate"
    break
  fi
done

if [[ -n "$WP_CMD" ]] && [[ -d "$WP_PATH" ]]; then
  PLUGINS_JSON=$("$WP_CMD" plugin list --skip-plugins --path="$WP_PATH" --format=json 2>&1) || PLUGINS_JSON="[]"
  if ! echo "$PLUGINS_JSON" | jq -e . &>/dev/null; then
    PLUGINS_JSON="[]"
  fi
fi

echo "$PLUGINS_JSON" | jq -c . > "$PLUGINS_FILE"
