#!/usr/bin/env bash
# Disable WordPress pseudo-cron on page load; run due events via system cron (WP-CLI).
# Usage:
#   ./bash/disable-wp-cron.sh              # local (wp at /home/ec2-user/html)
#   ./bash/disable-wp-cron.sh lake cccls   # remote via SSH
#   SSH_CONFIG=~/.ssh/config ./bash/disable-wp-cron.sh cccls

set -euo pipefail

WP_BIN="${WP_BIN:-/usr/local/bin/wp}"
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"

apply_local() {
  local wp_root="${1:-/home/ec2-user/html}"
  [[ -f "$wp_root/wp-config.php" ]] || wp_root="/var/www/html"
  local config="$wp_root/wp-config.php"

  if ! grep -q "DISABLE_WP_CRON" "$config" 2>/dev/null; then
    sudo cp -a "$config" "${config}.bak-disable-wp-cron-$(date +%Y%m%d%H%M%S)"
    sudo sed -i "/That's all, stop editing/i define('DISABLE_WP_CRON', true);" "$config"
    echo "  wp-config: added DISABLE_WP_CRON"
  else
    echo "  wp-config: DISABLE_WP_CRON already set"
  fi

  local cron_line="${CRON_SCHEDULE} cd ${wp_root} && ${WP_BIN} cron event run --due-now --path=${wp_root} >> /home/ec2-user/wp-cron.log 2>&1"
  if crontab -l 2>/dev/null | grep -qF "wp cron event run"; then
    echo "  crontab: wp cron job already present"
  else
    { crontab -l 2>/dev/null || true; echo "$cron_line"; } | crontab -
    echo "  crontab: added (${CRON_SCHEDULE})"
  fi

  grep DISABLE_WP_CRON "$config" || true
  crontab -l | grep -F "wp cron event run" || true
}

apply_remote() {
  local host="$1"
  local ssh_config="${SSH_CONFIG:-$HOME/.ssh/ohara/config}"
  [[ "$host" == "cccls" || "$host" == "bateys" ]] && ssh_config="${SSH_CONFIG:-$HOME/.ssh/config}"

  echo "========== $host =========="
  ssh -F "$ssh_config" "$host" 'bash -s' <<'REMOTE'
set -eu
WP_BIN=/usr/local/bin/wp
CRON_SCHEDULE='*/5 * * * *'
WP=/home/ec2-user/html
[[ -f "$WP/wp-config.php" ]] || WP=/var/www/html
CONFIG="$WP/wp-config.php"

if ! grep -q "DISABLE_WP_CRON" "$CONFIG" 2>/dev/null; then
  sudo cp -a "$CONFIG" "${CONFIG}.bak-disable-wp-cron-$(date +%Y%m%d%H%M%S)"
  sudo sed -i "/That's all, stop editing/i define('DISABLE_WP_CRON', true);" "$CONFIG"
  echo "  wp-config: added DISABLE_WP_CRON"
else
  echo "  wp-config: DISABLE_WP_CRON already set"
fi

CRON_LINE="${CRON_SCHEDULE} cd ${WP} && ${WP_BIN} cron event run --due-now --path=${WP} >> /home/ec2-user/wp-cron.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "wp cron event run"; then
  echo "  crontab: wp cron job already present"
else
  { crontab -l 2>/dev/null || true; echo "$CRON_LINE"; } | crontab -
  echo "  crontab: added every 5 minutes"
fi

grep DISABLE_WP_CRON "$CONFIG" || true
crontab -l | grep -F "wp cron event run" || true
REMOTE
}

if [[ $# -eq 0 ]]; then
  apply_local
else
  for h in "$@"; do
    apply_remote "$h"
  done
fi

echo "Done."
