#!/usr/bin/env bash
# Keep HTTP/HTTPS (and SSH) reachable on AL2023 WordPress hosts.
#
# AL2023 dnf upgrades can install or re-enable firewalld with only ssh open.
# That blocks Nginx even when fail2ban/iptables would otherwise allow traffic.
#
# Always open ssh/http/https on firewalld first. Optionally disable firewalld
# on fail2ban hosts afterwards — opening ports must never depend on that.
#
# Usage:
#   fix-firewalld-after-boot.sh [--ports-only] [--delay SECONDS]
#
# Env overrides:
#   LOG_FILE=/var/log/firewalld-boot-fix.log
#   FIREWALLD_BOOT_DELAY=90   # ignored with --ports-only

set -euo pipefail

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

LOG_FILE="${LOG_FILE:-/var/log/firewalld-boot-fix.log}"
BOOT_DELAY="${FIREWALLD_BOOT_DELAY:-90}"
MARKER="fix-firewalld-after-boot.sh"
PORTS_ONLY=0
SERVICES=(ssh http https)

usage() {
  cat <<EOF
Usage: $0 [--ports-only] [--delay SECONDS]

  --ports-only  Open ssh/http/https on firewalld; do not start/stop services
  --delay       Sleep before running (default: \$FIREWALLD_BOOT_DELAY or 90)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ports-only) PORTS_ONLY=1; shift ;;
    --delay) BOOT_DELAY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")"
exec >>"$LOG_FILE" 2>&1

if [[ "$PORTS_ONLY" -eq 1 ]]; then
  BOOT_DELAY=0
fi

echo "========== ${MARKER} start: $(date -Is) (delay=${BOOT_DELAY}s ports_only=${PORTS_ONLY}) =========="

if [[ "$PORTS_ONLY" -eq 0 ]] && [[ "$BOOT_DELAY" =~ ^[0-9]+$ ]] && [[ "$BOOT_DELAY" -gt 0 ]]; then
  sleep "$BOOT_DELAY"
fi

firewalld_cmd_ready() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if firewall-cmd --state >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

open_firewalld_web_ports() {
  local svc

  if ! rpm -q firewalld >/dev/null 2>&1; then
    echo "firewalld not installed; nothing to open at host firewalld layer."
    return 0
  fi

  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewalld_cmd_ready || echo "WARN: firewalld active but firewall-cmd not ready"
    echo "firewalld is running; ensuring runtime + permanent ${SERVICES[*]}..."
    for svc in "${SERVICES[@]}"; do
      firewall-cmd --permanent --add-service="$svc" >/dev/null 2>&1 || true
      firewall-cmd --add-service="$svc" >/dev/null 2>&1 || true
    done
    echo "firewalld services: $(firewall-cmd --list-services 2>/dev/null || echo unknown)"
    return 0
  fi

  if command -v firewall-offline-cmd >/dev/null 2>&1; then
    echo "firewalld is not running; persisting ${SERVICES[*]} with firewall-offline-cmd..."
    for svc in "${SERVICES[@]}"; do
      firewall-offline-cmd --add-service="$svc" >/dev/null 2>&1 || true
    done
    return 0
  fi

  echo "WARN: firewalld installed but neither firewall-cmd nor firewall-offline-cmd could apply services."
}

open_firewalld_web_ports

if [[ "$PORTS_ONLY" -eq 1 ]]; then
  echo "========== ${MARKER} finished (ports-only): $(date -Is) =========="
  exit 0
fi

if systemctl is-enabled --quiet fail2ban 2>/dev/null || systemctl is-active --quiet fail2ban 2>/dev/null; then
  echo "fail2ban host; disabling firewalld after ports are open (iptables bans)..."
  # fail2ban is PartOf=firewalld on AL2023 — stopping firewalld also stops fail2ban.
  systemctl disable firewalld >/dev/null 2>&1 || true
  systemctl mask firewalld >/dev/null 2>&1 || true
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "Stopping active firewalld (will stop fail2ban via PartOf)..."
    systemctl stop firewalld >/dev/null 2>&1 || true
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "WARN: firewalld still active after disable/mask/stop; web ports were opened above."
  fi
  if ! systemctl is-active --quiet fail2ban; then
    echo "Starting fail2ban after firewalld disable..."
    systemctl unmask fail2ban >/dev/null 2>&1 || true
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl start fail2ban || echo "WARN: fail2ban failed to start"
  fi
  echo "========== ${MARKER} finished (fail2ban/iptables): $(date -Is) =========="
  exit 0
fi

if ! rpm -q firewalld >/dev/null 2>&1; then
  echo "========== ${MARKER} finished (no firewalld): $(date -Is) =========="
  exit 0
fi

echo "No fail2ban; leaving firewalld enabled with ssh/http/https."
systemctl unmask firewalld >/dev/null 2>&1 || true
systemctl enable --now firewalld >/dev/null 2>&1 || true
open_firewalld_web_ports

echo "========== ${MARKER} finished: $(date -Is) =========="
