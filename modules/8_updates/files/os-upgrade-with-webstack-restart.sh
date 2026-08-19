#!/usr/bin/env bash
# Stop nginx/php-fpm, run Amazon Linux dnf upgrade, restart web stack.
# Intended for root cron on AL2023 hosts.
#
# Env overrides:
#   LOG_FILE=/var/log/os-upgrade.log
#   RELEASEVER=auto          # auto-detect latest AL2023 release (default)
#   RELEASEVER=2023.12.x     # pin a specific releasever

set -euo pipefail

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

LOG_FILE="${LOG_FILE:-/var/log/os-upgrade.log}"
LOCK_FILE="/var/run/os-upgrade.lock"
RELEASEVER="${RELEASEVER:-auto}"
MARKER="os-upgrade-with-webstack-restart.sh"

mkdir -p "$(dirname "$LOG_FILE")"
exec >>"$LOG_FILE" 2>&1

echo "========== ${MARKER} start: $(date -Is) =========="

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "Another upgrade run is in progress; exiting."
  exit 0
fi

web_stack_masked=0

unmask_and_start_web_stack() {
  echo "Unmasking and starting php-fpm and nginx..."
  systemctl unmask php-fpm nginx >/dev/null 2>&1 || true
  systemctl start php-fpm || echo "WARN: php-fpm failed to start"
  systemctl start nginx || echo "WARN: nginx failed to start"
}

mask_and_stop_web_stack() {
  echo "Masking and stopping nginx and php-fpm (blocks fpm.sh from restarting php-fpm)..."
  systemctl mask --now nginx php-fpm
  web_stack_masked=1
}

ensure_web_stack_running() {
  if [[ "$web_stack_masked" -eq 1 ]]; then
    unmask_and_start_web_stack
    web_stack_masked=0
  fi
}

resolve_releasever() {
  local override="${RELEASEVER:-auto}"
  local installed latest

  # Bare "2023" no longer works on current AL2023 repo mirrors (403).
  if [[ "$override" == "2023" ]]; then
    override="auto"
  fi

  if [[ -n "$override" && "$override" != "auto" ]]; then
    echo "$override"
    return
  fi

  installed="$(rpm -q --qf '%{VERSION}' system-release 2>/dev/null || true)"
  latest="$(dnf check-update 2>&1 | awk '/^  Version / {ver=$2} END {gsub(/:/, "", ver); print ver}')"

  if [[ -n "$latest" ]]; then
    echo "$latest"
    return
  fi

  if [[ -n "$installed" ]]; then
    echo "$installed"
    return
  fi

  echo "ERROR: could not resolve AL2023 releasever" >&2
  return 1
}

trap ensure_web_stack_running EXIT

TARGET_RELEASEVER="$(resolve_releasever)"
echo "Checking for package updates (releasever=${TARGET_RELEASEVER})..."
set +e
dnf check-update --releasever="${TARGET_RELEASEVER}" --refresh
check_rc=$?
set -e
# dnf: 0 = no updates, 100 = updates available, other = error
if [[ "$check_rc" -eq 0 ]]; then
  echo "No package updates; leaving nginx/php-fpm running."
  trap - EXIT
  echo "========== ${MARKER} finished (no-op): $(date -Is) =========="
  exit 0
fi
if [[ "$check_rc" -ne 100 ]]; then
  echo "ERROR: dnf check-update failed with exit ${check_rc}"
  trap - EXIT
  exit "$check_rc"
fi

mask_and_stop_web_stack

echo "Running: dnf upgrade --releasever=${TARGET_RELEASEVER} -y"
dnf upgrade --releasever="${TARGET_RELEASEVER}" -y

ensure_web_stack_running
trap - EXIT

echo "Service status:"
systemctl is-active php-fpm nginx || echo "WARN: one or more web services are not active"

echo "========== ${MARKER} finished: $(date -Is) =========="
