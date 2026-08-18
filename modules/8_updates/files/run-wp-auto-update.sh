#!/usr/bin/env bash
# WordPress core + selective plugin auto-updates via WP-CLI (ec2-user, no --allow-root).
#
# Plugin policy (when WP_AUTO_UPDATE_PLUGINS=1):
#   - All plugins except Elementor Pro and Elementor (bulk pass)
#   - Elementor free: minor updates only (e.g. 4.2.x -> 4.3.x, not 5.x)
#
# Usage:
#   ./run-wp-auto-update.sh
#   WP_AUTO_UPDATE_DRY_RUN=1 ./run-wp-auto-update.sh   # check only, no changes
#   ./run-wp-auto-update.sh north                      # remote via SSH (ohara config)
#
# Optional env file: /home/ec2-user/.wp-auto-update.env

set -euo pipefail

WP_BIN="${WP_BIN:-/usr/local/bin/wp}"
LOCK_FILE="/tmp/wp-auto-update.lock"
LOG_DIR="${WP_AUTO_UPDATE_LOG_DIR:-/home/ec2-user/logs}"
LOG_FILE="$LOG_DIR/wp-auto-update.log"
ENV_FILE="${WP_AUTO_UPDATE_ENV_FILE:-/home/ec2-user/.wp-auto-update.env}"

WP_AUTO_UPDATE_DRY_RUN="${WP_AUTO_UPDATE_DRY_RUN:-0}"
WP_AUTO_UPDATE_PLUGINS="${WP_AUTO_UPDATE_PLUGINS:-1}"
WP_AUTO_UPDATE_THEMES="${WP_AUTO_UPDATE_THEMES:-0}"
WP_AUTO_UPDATE_CORE_MINOR_ONLY="${WP_AUTO_UPDATE_CORE_MINOR_ONLY:-0}"
WP_AUTO_UPDATE_PLUGIN_EXCLUDE="${WP_AUTO_UPDATE_PLUGIN_EXCLUDE:-elementor-pro,elementor}"
WP_AUTO_UPDATE_ELEMENTOR_MINOR="${WP_AUTO_UPDATE_ELEMENTOR_MINOR:-1}"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  mkdir -p "$LOG_DIR"
  echo "$msg" >> "$LOG_FILE"
}

detect_wp_root() {
  local root
  for root in /home/ec2-user/html /usr/share/nginx/html /var/www/html; do
    if [[ -f "$root/wp-config.php" ]]; then
      echo "$root"
      return 0
    fi
  done
  echo "ERROR: WordPress root not found" >&2
  return 1
}

run_updates() {
  [[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

  local wp_root
  wp_root="$(detect_wp_root)"

  mkdir -p "$LOG_DIR"
  chmod 750 "$LOG_DIR" 2>/dev/null || true

  log "Start wp auto-update (dry_run=$WP_AUTO_UPDATE_DRY_RUN) wp_root=$wp_root"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Skip: another update run in progress"
    exit 0
  fi

  local wp_args=(--path="$wp_root")
  local out rc

  run_wp() {
    if [[ "$WP_AUTO_UPDATE_DRY_RUN" == "1" ]]; then
      log "DRY-RUN: $*"
      return 0
    fi
    set +e
    out="$("$WP_BIN" "$@" 2>&1)"
    rc=$?
    set -e
    echo "$out"
    echo "$out" >> "$LOG_FILE"
    return "$rc"
  }

  run_wp_or_dry() {
    if [[ "$WP_AUTO_UPDATE_DRY_RUN" == "1" ]]; then
      log "DRY-RUN: $* --dry-run"
      set +e
      out="$("$WP_BIN" "$@" --dry-run --format=summary 2>&1)"
      rc=$?
      set -e
      echo "$out"
      echo "$out" >> "$LOG_FILE"
      return "$rc"
    fi
    run_wp "$@"
  }

  update_plugins() {
    local exclude="$WP_AUTO_UPDATE_PLUGIN_EXCLUDE"

    log "Checking plugin updates..."
    run_wp plugin list --update=available --fields=name,version,update_version "${wp_args[@]}" || true

    log "Bulk plugin update (exclude: $exclude)"
    run_wp_or_dry plugin update --all --exclude="$exclude" "${wp_args[@]}" \
      || log "WARN: bulk plugin update had failures"

    if [[ "$WP_AUTO_UPDATE_ELEMENTOR_MINOR" == "1" ]]; then
      if "$WP_BIN" plugin is-installed elementor "${wp_args[@]}" >/dev/null 2>&1; then
        log "Elementor: minor updates only (same major, e.g. 4.x.x)"
        run_wp_or_dry plugin update elementor --minor "${wp_args[@]}" \
          || log "WARN: elementor minor update failed or not needed"
      else
        log "Skip: elementor not installed"
      fi
    fi

    log "Skip: elementor-pro (never auto-updated)"
  }

  # Clear stale core updater lock if present.
  run_wp option delete core_updater.lock "${wp_args[@]}" || true

  log "Core version before: $($WP_BIN core version "${wp_args[@]}")"

  if [[ "$WP_AUTO_UPDATE_CORE_MINOR_ONLY" == "1" ]]; then
    log "Checking core minor updates..."
    run_wp core check-update --minor "${wp_args[@]}" || true
    if [[ "$WP_AUTO_UPDATE_DRY_RUN" != "1" ]]; then
      run_wp core update --minor "${wp_args[@]}" || log "WARN: core minor update failed or not needed"
    fi
  else
    log "Checking core updates..."
    run_wp core check-update "${wp_args[@]}" || true
    if [[ "$WP_AUTO_UPDATE_DRY_RUN" != "1" ]]; then
      run_wp core update "${wp_args[@]}" || log "WARN: core update failed or not needed"
      run_wp core update-db "${wp_args[@]}" || log "WARN: core update-db failed or not needed"
    fi
  fi

  if [[ "$WP_AUTO_UPDATE_PLUGINS" == "1" ]]; then
    update_plugins
  fi

  if [[ "$WP_AUTO_UPDATE_THEMES" == "1" ]]; then
    log "Checking theme updates..."
    run_wp theme list --update=available --fields=name,version,update_version "${wp_args[@]}" || true
    if [[ "$WP_AUTO_UPDATE_DRY_RUN" != "1" ]]; then
      run_wp theme update --all "${wp_args[@]}" || log "WARN: theme update had failures"
    fi
  fi

  log "Core version after: $($WP_BIN core version "${wp_args[@]}")"
  log "Done"
}

apply_remote() {
  local host="$1"
  local ssh_config="${SSH_CONFIG:-$HOME/.ssh/ohara/config}"

  echo "========== $host =========="
  ssh -F "$ssh_config" "$host" \
    "WP_AUTO_UPDATE_DRY_RUN=${WP_AUTO_UPDATE_DRY_RUN:-0} ${WRAPPER_REMOTE:-/home/ec2-user/bin/run-wp-auto-update.sh}"
}

if [[ $# -ge 1 && "$1" != "--help" && "$1" != "-h" ]]; then
  for h in "$@"; do
    apply_remote "$h"
  done
else
  run_updates
fi
