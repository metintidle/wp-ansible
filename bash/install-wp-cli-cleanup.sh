#!/usr/bin/env bash
# Install WP-CLI if missing (modules/2_wordpress/playbook.yml) and run one-time DB cleanup.
# Usage: ./bash/install-wp-cli-cleanup.sh [host ...]

set -euo pipefail

SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/ohara/config}"
WP_BIN=/usr/local/bin/wp
WP_URL=https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar

HOSTS=("${@:-bligh station warrilahotel town lake}")

if [[ ! -f "$SSH_CONFIG" ]]; then
  echo "SSH config not found: $SSH_CONFIG" >&2
  exit 1
fi

remote() {
  local host="$1"
  echo "========== $host =========="
  ssh -F "$SSH_CONFIG" "$host" "bash -s" <<REMOTE
set -eu
WP_BIN=$WP_BIN
WP_ROOT=/home/ec2-user/html
[[ -f "\$WP_ROOT/wp-config.php" ]] || WP_ROOT=/var/www/html
WP_ARGS=(--path="\$WP_ROOT")

if [[ -x "\$WP_BIN" ]]; then
  echo "  wp-cli: already installed"
else
  echo "  wp-cli: installing..."
  sudo curl -fsSL -o /usr/local/bin/wp-cli.phar "$WP_URL"
  sudo chmod 0755 /usr/local/bin/wp-cli.phar
  sudo mv /usr/local/bin/wp-cli.phar "\$WP_BIN"
  "\$WP_BIN" --info >/dev/null
  echo "  wp-cli: installed (\$("\$WP_BIN" --version 2>/dev/null || true))"
fi

REVS=\$("\$WP_BIN" "\${WP_ARGS[@]}" post list --post_type=revision --format=count 2>/dev/null || echo 0)
echo "  revisions before: \$REVS"

deleted=0
while true; do
  batch=\$("\$WP_BIN" "\${WP_ARGS[@]}" post list --post_type=revision --format=ids --posts_per_page=100 2>/dev/null || true)
  [[ -n "\${batch// }" ]] || break
  "\$WP_BIN" "\${WP_ARGS[@]}" post delete \$batch --force
  deleted=\$((deleted + 1))
done
if [[ "\$deleted" -gt 0 ]]; then
  echo "  revisions: deleted in \$deleted batch(es)"
else
  echo "  revisions: none to delete"
fi

REVS_AFTER=\$("\$WP_BIN" "\${WP_ARGS[@]}" post list --post_type=revision --format=count 2>/dev/null || echo 0)
echo "  revisions after: \$REVS_AFTER"

"\$WP_BIN" "\${WP_ARGS[@]}" transient delete --expired 2>/dev/null || true
echo "  transients: expired deleted"

"\$WP_BIN" "\${WP_ARGS[@]}" db optimize 2>/dev/null || true
echo "  db: optimize done"
REMOTE
}

for h in "${HOSTS[@]}"; do
  remote "$h" || echo "FAILED: $h" >&2
done

echo "Done."
