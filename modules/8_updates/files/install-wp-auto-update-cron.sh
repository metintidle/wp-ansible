#!/usr/bin/env bash
# Install ec2-user cron for weekly WordPress updates (03:00 Sunday, Australia/Sydney).
#
# Usage:
#   ./install-wp-auto-update-cron.sh
#   ./install-wp-auto-update-cron.sh --remove
#   ./install-wp-auto-update-cron.sh --schedule "0 3 * * 0" --tz Australia/Sydney

set -euo pipefail

CRON_TZ="${CRON_TZ:-Australia/Sydney}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * 0}"
WRAPPER_PATH="${WRAPPER_PATH:-/home/ec2-user/bin/run-wp-auto-update.sh}"
LOG_FILE="/home/ec2-user/logs/wp-auto-update.log"
MARKER="run-wp-auto-update.sh"

usage() {
  cat <<EOF
Usage: $0 [--remove] [--schedule "CRON_EXPR"] [--tz TIMEZONE] [--wrapper PATH]

  --remove     Remove wp auto-update cron job
  --schedule   Cron expression (default: 0 3 * * 0 = 03:00 Sunday)
  --tz         CRON_TZ value (default: Australia/Sydney)
  --wrapper    Path to run-wp-auto-update.sh on server
EOF
}

REMOVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) REMOVE=1; shift ;;
    --schedule) CRON_SCHEDULE="$2"; shift 2 ;;
    --tz) CRON_TZ="$2"; shift 2 ;;
    --wrapper) WRAPPER_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

CRON_LINE="${CRON_SCHEDULE} ${WRAPPER_PATH} >> ${LOG_FILE} 2>&1"

filter_crontab() {
  crontab -l 2>/dev/null | grep -vF "$MARKER" || true
}

if [[ "$REMOVE" -eq 1 ]]; then
  filter_crontab | crontab - || true
  echo "Removed wp auto-update cron job."
  crontab -l 2>/dev/null || echo "(empty crontab)"
  exit 0
fi

existing="$(crontab -l 2>/dev/null || true)"
if echo "$existing" | grep -qF "$MARKER"; then
  filter_crontab | crontab -
fi

{
  filter_crontab
  if ! echo "$existing" | grep -qE '^CRON_TZ='; then
    echo "CRON_TZ=${CRON_TZ}"
  fi
  echo "$CRON_LINE"
} | crontab -

echo "Installed wp auto-update cron:"
echo "  CRON_TZ=${CRON_TZ}"
echo "  ${CRON_LINE}"
echo ""
crontab -l | grep -E "CRON_TZ|${MARKER}" || true
