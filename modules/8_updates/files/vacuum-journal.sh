#!/usr/bin/env bash
# Remove old systemd journal entries and enforce the configured size cap.
#
# Usage:
#   sudo vacuum-journal.sh
#   sudo vacuum-journal.sh --size 200M
#   sudo vacuum-journal.sh --time 7d
#
# Defaults:
#   --size from SystemMaxUse in /etc/systemd/journald.conf, else 200M

set -euo pipefail

JOURNALD_CONF="${JOURNALD_CONF:-/etc/systemd/journald.conf}"
DEFAULT_SIZE="${JOURNAL_MAX_USE:-200M}"
VACUUM_SIZE=""
VACUUM_TIME=""

usage() {
  cat <<EOF
Usage: $0 [--size SIZE] [--time DURATION]

  --size SIZE       journalctl --vacuum-size (default: SystemMaxUse from ${JOURNALD_CONF}, else ${DEFAULT_SIZE})
  --time DURATION   journalctl --vacuum-time (e.g. 7d, 2weeks); overrides --size when set

Examples:
  sudo $0
  sudo $0 --size 200M
  sudo $0 --time 7d
EOF
}

read_system_max_use() {
  local line value
  if [[ ! -f "$JOURNALD_CONF" ]]; then
    printf '%s' "$DEFAULT_SIZE"
    return 0
  fi
  line="$(grep -E '^[[:space:]]*SystemMaxUse=' "$JOURNALD_CONF" | tail -1 || true)"
  value="${line#SystemMaxUse=}"
  value="${value// /}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$DEFAULT_SIZE"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) VACUUM_SIZE="$2"; shift 2 ;;
    --time) VACUUM_TIME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

if ! command -v journalctl >/dev/null 2>&1; then
  echo "journalctl not found" >&2
  exit 1
fi

if [[ -z "$VACUUM_SIZE" && -z "$VACUUM_TIME" ]]; then
  VACUUM_SIZE="$(read_system_max_use)"
fi

echo "Journal disk usage before:"
journalctl --disk-usage

if [[ -n "$VACUUM_TIME" ]]; then
  echo "Vacuuming journals older than ${VACUUM_TIME}..."
  journalctl --vacuum-time="$VACUUM_TIME"
elif [[ -n "$VACUUM_SIZE" ]]; then
  echo "Vacuuming journals to max size ${VACUUM_SIZE}..."
  journalctl --vacuum-size="$VACUUM_SIZE"
fi

echo "Journal disk usage after:"
journalctl --disk-usage
