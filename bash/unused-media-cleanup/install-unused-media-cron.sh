#!/usr/bin/env bash
# Install ec2-user cron for monthly unused media cleanup (01:00 Sydney, 1st of month).
#
# Usage:
#   ./install-unused-media-cron.sh
#   ./install-unused-media-cron.sh --remove
#   ./install-unused-media-cron.sh --schedule "0 1 1 * *" --tz Australia/Sydney
#
# Expects run-unused-media-cleanup.sh at /home/ec2-user/bin/ (or set WRAPPER_PATH).

set -euo pipefail

CRON_TZ="${CRON_TZ:-Australia/Sydney}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 1 1 * *}"
WRAPPER_PATH="${WRAPPER_PATH:-/home/ec2-user/bin/run-unused-media-cleanup.sh}"
LOG_FILE="/home/ec2-user/logs/wp-unused-media-cleanup.log"
MARKER="run-unused-media-cleanup.sh"

usage() {
  cat <<EOF
Usage: $0 [--remove] [--schedule "CRON_EXPR"] [--tz TIMEZONE] [--wrapper PATH]

  --remove     Remove unused-media cron job and CRON_TZ line
  --schedule   Cron expression (default: 0 1 1 * * = 01:00 on 1st of month)
  --tz         CRON_TZ value (default: Australia/Sydney)
  --wrapper    Path to run-unused-media-cleanup.sh on server
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
  crontab -l 2>/dev/null | grep -vF "$MARKER" | grep -vE '^CRON_TZ=' || true
}

if [[ "$REMOVE" -eq 1 ]]; then
  filter_crontab | crontab - || true
  echo "Removed unused-media cron job."
  crontab -l 2>/dev/null || echo "(empty crontab)"
  exit 0
fi

{
  filter_crontab
  echo "CRON_TZ=${CRON_TZ}"
  echo "$CRON_LINE"
} | crontab -

echo "Installed unused-media cron:"
echo "  CRON_TZ=${CRON_TZ}"
echo "  ${CRON_LINE}"
echo ""
crontab -l | grep -E "CRON_TZ|${MARKER}" || true
