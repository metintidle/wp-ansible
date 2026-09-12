#!/usr/bin/env bash
# Install root cron for nightly WordPress site backup (01:00 Australia/Sydney + per-host stagger).
#
# Usage:
#   ./install-wp-site-backup-cron.sh
#   ./install-wp-site-backup-cron.sh --remove
#   ./install-wp-site-backup-cron.sh --schedule "15 1 * * *" --tz Australia/Sydney

set -euo pipefail

CRON_TZ="${CRON_TZ:-Australia/Sydney}"
WRAPPER_PATH="${WRAPPER_PATH:-/usr/local/bin/wp-site-backup.sh}"
LOG_FILE="/var/log/wp-site-backup.log"
MARKER="wp-site-backup.sh"
COMMENT="# WordPress site backup nightly (Australia/Sydney, staggered)"

usage() {
  cat <<EOF
Usage: $0 [--remove] [--schedule "CRON_EXPR"] [--tz TIMEZONE] [--wrapper PATH]

  --remove     Remove wp-site-backup cron job
  --schedule   Cron expression (default: computed from hostname stagger at 01:00)
  --tz         CRON_TZ value (default: Australia/Sydney)
  --wrapper    Path to wp-site-backup.sh on server
EOF
}

compute_stagger_schedule() {
  local host stagger minute
  host="$(hostname 2>/dev/null || echo localhost)"
  stagger="$(printf '%s' "$host" | cksum | awk '{print $1 % 45}')"
  minute="$stagger"
  echo "${minute} 1 * * *"
}

REMOVE=0
CRON_SCHEDULE=""
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

if [[ -z "$CRON_SCHEDULE" ]]; then
  CRON_SCHEDULE="$(compute_stagger_schedule)"
fi

CRON_LINE="${CRON_SCHEDULE} ${WRAPPER_PATH} >> ${LOG_FILE} 2>&1"

filter_crontab() {
  crontab -l 2>/dev/null \
    | grep -vF "$MARKER" \
    | grep -vF "$COMMENT" \
    || true
}

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
  echo "Removed wp-site-backup cron job."
  crontab -l 2>/dev/null || echo "(empty crontab)"
  exit 0
fi

{
  filter_crontab | strip_trailing_cron_tz
  echo "CRON_TZ=${CRON_TZ}"
  echo "${COMMENT} (${CRON_TZ})"
  echo "$CRON_LINE"
} | crontab -

echo "Installed wp-site-backup cron:"
echo "  CRON_TZ=${CRON_TZ}"
echo "  ${CRON_LINE}"
echo ""
crontab -l | grep -E "CRON_TZ|${MARKER}" || true
