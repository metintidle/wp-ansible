#!/usr/bin/env bash
# Apply docs/elementor-low-ram-optimization.md to Ohara hotel hosts.
# Usage: ./bash/apply-elementor-low-ram.sh [host ...]
# Default hosts: berkeley bligh station warrilahotel centralhotel

set -euo pipefail

SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/ohara/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MU_PLUGIN="$REPO_ROOT/snippets/files/heartbeat-throttle.php"
NGINX_MARKER='elementor-preview|action=elementor'
NGINX_LINE='if ($request_uri ~* "elementor-preview|action=elementor") { set $skip_cache 1; }'

DEFAULT_HOSTS=(berkeley bligh station warrilahotel centralhotel town salamander lake)
HOSTS=("${@:-${DEFAULT_HOSTS[@]}}")

if [[ ! -f "$SSH_CONFIG" ]]; then
  echo "SSH config not found: $SSH_CONFIG" >&2
  exit 1
fi

if [[ ! -f "$MU_PLUGIN" ]]; then
  echo "Missing mu-plugin: $MU_PLUGIN" >&2
  exit 1
fi

remote_apply() {
  local host="$1"
  echo "========== $host =========="
  scp -F "$SSH_CONFIG" -q "$MU_PLUGIN" "${host}:/tmp/heartbeat-throttle.php"
  ssh -F "$SSH_CONFIG" "$host" "bash -s" <<'REMOTE'
set -euo pipefail
WP=/home/ec2-user/html
[[ -f "$WP/wp-config.php" ]] || WP=/var/www/html
MU_DIR="$WP/wp-content/mu-plugins"
CONFIG="$WP/wp-config.php"

sudo install -d -m 0755 -o ec2-user -g ec2-user "$MU_DIR"
sudo install -m 0644 -o ec2-user -g ec2-user /tmp/heartbeat-throttle.php "$MU_DIR/heartbeat-throttle.php"
rm -f /tmp/heartbeat-throttle.php

insert_define() {
  local name="$1" value="$2"
  if grep -qE "define\s*\(\s*['\"]${name}['\"]" "$CONFIG" 2>/dev/null; then
    echo "  wp-config: $name already set"
    return 0
  fi
  sudo cp -a "$CONFIG" "${CONFIG}.bak-elementor-low-ram-$(date +%Y%m%d%H%M%S)"
  sudo sed -i "/That's all, stop editing/i\\
// Elementor low-RAM optimization (wp-ansible)\\
define('${name}', ${value});\\
" "$CONFIG"
  echo "  wp-config: added $name"
}

# Only add missing constants; do not override station's WP_POST_REVISIONS=false
if ! grep -qE "define\s*\(\s*['\"]WP_POST_REVISIONS['\"]" "$CONFIG" 2>/dev/null; then
  insert_define 'WP_POST_REVISIONS' '3'
fi
if ! grep -qE "define\s*\(\s*['\"]AUTOSAVE_INTERVAL['\"]" "$CONFIG" 2>/dev/null; then
  insert_define 'AUTOSAVE_INTERVAL' '86400'
  sudo sed -i "s|define('AUTOSAVE_INTERVAL', 86400);|define('AUTOSAVE_INTERVAL', 86400); // 24 hours = effectively off|" "$CONFIG"
fi
if ! grep -qE "define\s*\(\s*['\"]EMPTY_TRASH_DAYS['\"]" "$CONFIG" 2>/dev/null; then
  insert_define 'EMPTY_TRASH_DAYS' '7'
fi
if ! grep -qE "define\s*\(\s*['\"]DISALLOW_FILE_EDIT['\"]" "$CONFIG" 2>/dev/null; then
  insert_define 'DISALLOW_FILE_EDIT' 'true'
fi

WP_BIN=/usr/local/bin/wp
cd "$WP"
if [[ -x "$WP_BIN" ]]; then
  REV_IDS=$("$WP_BIN" post list --post_type=revision --format=ids 2>/dev/null || true)
  if [[ -n "${REV_IDS// }" ]]; then
    "$WP_BIN" post delete $REV_IDS --force 2>/dev/null || true
    echo "  wp-cli: deleted revisions"
  else
    echo "  wp-cli: no revisions to delete"
  fi
  "$WP_BIN" transient delete --expired 2>/dev/null || true
  "$WP_BIN" db optimize 2>/dev/null || true
  echo "  wp-cli: transients + db optimize done"

  if "$WP_BIN" plugin is-active elementor 2>/dev/null; then
    for exp in e_font_icon_svg e_optimized_assets_loading e_optimized_image_loading; do
      "$WP_BIN" elementor experiments activate "$exp" 2>/dev/null || true
    done
    echo "  elementor: experiments activate attempted"
  fi
else
  echo "  wp-cli: not installed (run bash/install-wp-cli-cleanup.sh $host)"
fi

# Nginx: add elementor preview bypass if fastcgi cache config exists
NGINX_FILE=""
for f in /etc/nginx/default.d/fastcgi_cache_block.conf \
         /etc/nginx/conf.d/cache_block.conf \
         /etc/nginx/default.d/cache_block.conf; do
  if [[ -f "$f" ]] && grep -q 'skip_cache' "$f" 2>/dev/null; then
    NGINX_FILE="$f"
    break
  fi
done

if [[ -n "$NGINX_FILE" ]]; then
  if grep -q 'elementor-preview' "$NGINX_FILE" 2>/dev/null; then
    echo "  nginx: elementor bypass already in $NGINX_FILE"
  else
    sudo cp -a "$NGINX_FILE" "${NGINX_FILE}.bak-elementor-low-ram-$(date +%Y%m%d%H%M%S)"
    sudo sed -i '/set \$skip_cache 0;/a\
if ($request_uri ~* "elementor-preview|action=elementor") { set $skip_cache 1; }' "$NGINX_FILE"
    sudo nginx -t && sudo systemctl reload nginx
    echo "  nginx: updated $NGINX_FILE"
  fi
else
  echo "  nginx: no fastcgi cache config found (skipped)"
fi

echo "  done: $WP"
REMOTE
}

for h in "${HOSTS[@]}"; do
  remote_apply "$h" || echo "FAILED: $h" >&2
done

echo "All hosts processed."
