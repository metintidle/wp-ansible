#!/usr/bin/env bash
# Ensure firewalld allows web traffic after boot (post-OS-upgrade reboot).
#
# AL2023 dnf upgrades can install/re-enable firewalld with only ssh open.
# Fail2ban hosts use iptables instead — disable firewalld when fail2ban is active.
#
# Env overrides:
#   LOG_FILE=/var/log/firewalld-boot-fix.log
#   FIREWALLD_BOOT_DELAY=90   # seconds to wait for network/firewalld after boot

set -euo pipefail

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

LOG_FILE="${LOG_FILE:-/var/log/firewalld-boot-fix.log}"
BOOT_DELAY="${FIREWALLD_BOOT_DELAY:-90}"
MARKER="fix-firewalld-after-boot.sh"

mkdir -p "$(dirname "$LOG_FILE")"
exec >>"$LOG_FILE" 2>&1

echo "========== ${MARKER} start: $(date -Is) (delay=${BOOT_DELAY}s) =========="

if [[ "$BOOT_DELAY" =~ ^[0-9]+$ ]] && [[ "$BOOT_DELAY" -gt 0 ]]; then
  sleep "$BOOT_DELAY"
fi

if systemctl is-active --quiet fail2ban; then
  echo "fail2ban active; stopping and disabling firewalld..."
  systemctl stop firewalld >/dev/null 2>&1 || true
  systemctl disable firewalld >/dev/null 2>&1 || true
  echo "========== ${MARKER} finished (fail2ban/iptables): $(date -Is) =========="
  exit 0
fi

if ! rpm -q firewalld >/dev/null 2>&1; then
  echo "firewalld not installed; nothing to fix."
  echo "========== ${MARKER} finished (no firewalld): $(date -Is) =========="
  exit 0
fi

echo "Ensuring firewalld allows ssh, http, and https..."
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
firewall-cmd --reload
firewall-cmd --list-services

echo "========== ${MARKER} finished: $(date -Is) =========="
