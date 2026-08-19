#!/usr/bin/env bash
# Install root cron for OS upgrade (stop nginx/php-fpm, dnf upgrade, restart).
#
# Usage:
#   ./install-os-upgrade-cron.sh
#   ./install-os-upgrade-cron.sh --remove
#   ./install-os-upgrade-cron.sh --schedule "0 0 */3 * *" --tz Australia/Sydney

set -euo pipefail

CRON_TZ="${CRON_TZ:-Australia/Sydney}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 0 */3 * *}"
WRAPPER_PATH="${WRAPPER_PATH:-/usr/local/bin/os-upgrade-with-webstack-restart.sh}"
LOG_FILE="/var/log/os-upgrade.log"
RELEASEVER="${RELEASEVER:-auto}"
MARKER="os-upgrade-with-webstack-restart.sh"
COMMENT="# OS upgrade every 3 days at local midnight"

usage() {
  cat <<EOF
Usage: $0 [--remove] [--schedule "CRON_EXPR"] [--tz TIMEZONE] [--wrapper PATH] [--releasever VER]

  --remove     Remove OS upgrade cron job
  --schedule   Cron expression (default: 0 0 */3 * * = midnight every 3 days)
  --tz         CRON_TZ value (default: Australia/Sydney)
  --wrapper    Path to os-upgrade-with-webstack-restart.sh on server
  --releasever AL2023 releasever for dnf (default: auto = latest offered release)
EOF
}

REMOVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) REMOVE=1; shift ;;
    --schedule) CRON_SCHEDULE="$2"; shift 2 ;;
    --tz) CRON_TZ="$2"; shift 2 ;;
    --wrapper) WRAPPER_PATH="$2"; shift 2 ;;
    --releasever) RELEASEVER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$RELEASEVER" == "auto" || "$RELEASEVER" == "2023" || -z "$RELEASEVER" ]]; then
  CRON_LINE="${CRON_SCHEDULE} ${WRAPPER_PATH} >> ${LOG_FILE} 2>&1"
else
  CRON_LINE="${CRON_SCHEDULE} RELEASEVER=${RELEASEVER} ${WRAPPER_PATH} >> ${LOG_FILE} 2>&1"
fi

filter_crontab() {
  crontab -l 2>/dev/null \
    | grep -vF "$MARKER" \
    | grep -vF "$COMMENT" \
    || true
}

# Drop a trailing CRON_TZ= we appended on a previous install (keep earlier CRON_TZ lines).
strip_trailing_cron_tz() {
  local tz_line="CRON_TZ=${CRON_TZ}"
  local buf="" last=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$last" ]]; then
      buf+="${last}"$'\n'
    fi
    last="$line"
  done
  if [[ "$last" != "$tz_line" ]]; then
    buf+="${last}"
    [[ -n "$last" ]] && buf+=$'\n'
  fi
  printf '%s' "$buf"
}

if [[ "$REMOVE" -eq 1 ]]; then
  filter_crontab | strip_trailing_cron_tz | crontab - || true
  echo "Removed OS upgrade cron job."
  crontab -l 2>/dev/null || echo "(empty crontab)"
  exit 0
fi

{
  filter_crontab | strip_trailing_cron_tz
  echo "CRON_TZ=${CRON_TZ}"
  echo "${COMMENT} (${CRON_TZ})"
  echo "$CRON_LINE"
} | crontab -

echo "Installed OS upgrade cron:"
echo "  CRON_TZ=${CRON_TZ}"
echo "  ${CRON_LINE}"
echo ""
crontab -l | grep -E "CRON_TZ|${MARKER}" || true
