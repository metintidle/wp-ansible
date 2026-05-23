#!/usr/bin/env bash
# Apply low-RAM PHP-FPM pool settings (lake profile) to Ohara hosts.
# Usage: ./bash/apply-php-fpm-ondemand.sh [host ...]

set -euo pipefail

SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/ohara/config}"
DEFAULT_HOSTS=(berkeley bligh station warrilahotel centralhotel town salamander lake)
HOSTS=("${@:-${DEFAULT_HOSTS[@]}}")

remote_apply() {
  local host="$1"
  echo "========== $host =========="
  ssh -F "$SSH_CONFIG" "$host" "bash -s" <<'REMOTE'
set -eu
CONF=/etc/php-fpm.d/www.conf

if [[ ! -f "$CONF" ]]; then
  echo "  ERROR: $CONF not found" >&2
  exit 1
fi

sudo cp -a "$CONF" "${CONF}.bak-ondemand-$(date +%Y%m%d%H%M%S)"

sudo sed -i 's/^pm = dynamic$/pm = ondemand/' "$CONF"
sudo sed -i 's/^pm = ondemand$/pm = ondemand/' "$CONF"
sudo sed -i 's/^pm.start_servers = /;pm.start_servers = /' "$CONF"
sudo sed -i 's/^pm.min_spare_servers = /;pm.min_spare_servers = /' "$CONF"
sudo sed -i 's/^pm.max_spare_servers = /;pm.max_spare_servers = /' "$CONF"
sudo sed -i 's/^pm.max_children = .*/pm.max_children = 2/' "$CONF"
sudo sed -i 's/^pm.max_requests = .*/pm.max_requests = 200/' "$CONF"
sudo sed -i 's/^;pm.process_idle_timeout = .*/pm.process_idle_timeout = 15s/' "$CONF"
sudo sed -i 's/^pm.process_idle_timeout = .*/pm.process_idle_timeout = 15s/' "$CONF"
sudo sed -i 's/^;rlimit_files = .*/rlimit_files = 1024/' "$CONF"
sudo sed -i 's/^rlimit_files = .*/rlimit_files = 1024/' "$CONF"
sudo sed -i 's/^;php_admin_value\[memory_limit\] = .*/php_admin_value[memory_limit] = 96M/' "$CONF"
sudo sed -i 's/^php_admin_value\[memory_limit\] = .*/php_admin_value[memory_limit] = 96M/' "$CONF"

if ! grep -q '^php_admin_value\[max_execution_time\]' "$CONF"; then
  sudo sed -i '/^php_admin_value\[memory_limit\] = 96M/a php_admin_value[max_execution_time] = 30' "$CONF"
else
  sudo sed -i 's/^;php_admin_value\[max_execution_time\] = .*/php_admin_value[max_execution_time] = 30/' "$CONF"
  sudo sed -i 's/^php_admin_value\[max_execution_time\] = .*/php_admin_value[max_execution_time] = 30/' "$CONF"
fi

echo "  Applied:"
grep -E '^pm =|^pm\.(max_children|process_idle|max_requests)|^rlimit_files|^php_admin_value\[(memory_limit|max_execution_time)\]' "$CONF" | sed 's/^/    /'

if sudo php-fpm -t 2>&1 | grep -q successful; then
  sudo systemctl reload php-fpm
  echo "  php-fpm: reloaded ($(systemctl is-active php-fpm))"
else
  echo "  ERROR: php-fpm config test failed" >&2
  sudo php-fpm -t 2>&1 || true
  exit 1
fi
REMOTE
}

for h in "${HOSTS[@]}"; do
  remote_apply "$h" || echo "FAILED: $h" >&2
done

echo "Done."
