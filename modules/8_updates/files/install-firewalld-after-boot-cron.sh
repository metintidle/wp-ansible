#!/usr/bin/env bash
# Install root @reboot cron plus systemd timer to keep HTTP/HTTPS open on firewalld.
#
# Usage:
#   ./install-firewalld-after-boot-cron.sh
#   ./install-firewalld-after-boot-cron.sh --remove
#   ./install-firewalld-after-boot-cron.sh --delay 120

set -euo pipefail

WRAPPER_PATH="${WRAPPER_PATH:-/usr/local/bin/fix-firewalld-after-boot.sh}"
LOG_FILE="/var/log/firewalld-boot-fix.log"
BOOT_DELAY="${BOOT_DELAY:-90}"
MARKER="fix-firewalld-after-boot.sh"
COMMENT="# Fix firewalld http/https after boot (post-OS-upgrade)"
TIMER_UNIT="ensure-web-ports.timer"
FIREWALLD_DROPIN_DIR="/etc/systemd/system/firewalld.service.d"
FIREWALLD_DROPIN="${FIREWALLD_DROPIN_DIR}/open-web-ports.conf"

usage() {
  cat <<EOF
Usage: $0 [--remove] [--delay SECONDS] [--wrapper PATH]

  --remove   Remove firewalld after-boot cron, timer, and firewalld drop-in
  --delay    Seconds to wait after boot before fixing firewalld (default: 90)
  --wrapper  Path to fix-firewalld-after-boot.sh on server
EOF
}

REMOVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) REMOVE=1; shift ;;
    --delay) BOOT_DELAY="$2"; shift 2 ;;
    --wrapper) WRAPPER_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

CRON_LINE="@reboot sleep ${BOOT_DELAY} && FIREWALLD_BOOT_DELAY=0 ${WRAPPER_PATH} >> ${LOG_FILE} 2>&1"

filter_crontab() {
  crontab -l 2>/dev/null \
    | grep -vF "$MARKER" \
    | grep -vF "$COMMENT" \
    || true
}

enable_systemd_guards() {
  if [[ -f /etc/systemd/system/ensure-web-ports.timer ]]; then
    systemctl daemon-reload
    systemctl enable --now "$TIMER_UNIT"
    echo "Enabled systemd timer: ${TIMER_UNIT}"
  fi
  if [[ -f "$FIREWALLD_DROPIN" ]]; then
    systemctl daemon-reload
    echo "firewalld ExecStartPost drop-in: ${FIREWALLD_DROPIN}"
  fi
}

disable_systemd_guards() {
  systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/ensure-web-ports.timer
  rm -f /etc/systemd/system/ensure-web-ports.service
  rm -f "$FIREWALLD_DROPIN"
  rmdir "$FIREWALLD_DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  echo "Removed ensure-web-ports timer/service and firewalld drop-in."
}

if [[ "$REMOVE" -eq 1 ]]; then
  filter_crontab | crontab - || true
  disable_systemd_guards
  echo "Removed firewalld after-boot cron job."
  crontab -l 2>/dev/null || echo "(empty crontab)"
  exit 0
fi

{
  filter_crontab
  echo "${COMMENT}"
  echo "$CRON_LINE"
} | crontab -

enable_systemd_guards

echo "Installed firewalld after-boot cron:"
echo "  ${CRON_LINE}"
echo ""
crontab -l | grep -E "@reboot|${MARKER}" || true
