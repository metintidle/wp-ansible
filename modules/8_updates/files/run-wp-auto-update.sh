#!/usr/bin/env bash
# WordPress core + selective plugin auto-updates via WP-CLI (ec2-user, no --allow-root).
# Live runs dump the DB first (wp db export | gzip) to /home/ec2-user/backups/wp-auto-update/;
# a failed dump aborts the update. Dry-run skips the dump.
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
WP_AUTO_UPDATE_BACKUP="${WP_AUTO_UPDATE_BACKUP:-1}"
WP_AUTO_UPDATE_BACKUP_DIR="${WP_AUTO_UPDATE_BACKUP_DIR:-/home/ec2-user/backups/wp-auto-update}"
WP_AUTO_UPDATE_BACKUP_RETENTION="${WP_AUTO_UPDATE_BACKUP_RETENTION:-28}"

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

backup_outside_webroot() {
  local wp_root="$1"
  local backup="$2"
  local wp_real backup_real

  wp_real="$(realpath "$wp_root")"
  backup_real="$(realpath -m "$backup")"

  if [[ "$backup_real" == "$wp_real" ]] || [[ "$backup_real" == "$wp_real"/* ]]; then
    log "ERROR: backup dir inside webroot ($backup_real)"
    exit 3
  fi
  if [[ "$backup_real" == *"/wp-content"* ]]; then
    log "ERROR: backup dir must not be under wp-content ($backup_real)"
    exit 3
  fi
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

  backup_database() {
    local backup_dir="$WP_AUTO_UPDATE_BACKUP_DIR"
    local retention="$WP_AUTO_UPDATE_BACKUP_RETENTION"
    local db_name timestamp backup_file dump_rc size

    if [[ "$WP_AUTO_UPDATE_BACKUP" != "1" ]]; then
      log "Skip: database backup disabled"
      return 0
    fi

    backup_outside_webroot "$wp_root" "$backup_dir"
    mkdir -p "$backup_dir"
    chmod 750 "$backup_dir" 2>/dev/null || true

    set +e
    db_name="$("$WP_BIN" db name "${wp_args[@]}" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
    set -e
    if [[ -z "$db_name" ]]; then
      db_name="wordpress"
    fi

    timestamp="$(date +%Y%m%d_%H%M%S)"
    backup_file="${backup_dir}/${db_name}_pre-update_${timestamp}.sql.gz"

    if [[ "$WP_AUTO_UPDATE_DRY_RUN" == "1" ]]; then
      log "DRY-RUN: would backup database ${db_name} to ${backup_file}"
      return 0
    fi

    log "Backing up database ${db_name} to ${backup_file}"
    set +e
    "$WP_BIN" db export - "${wp_args[@]}" 2>>"$LOG_FILE" | gzip -c > "$backup_file"
    dump_rc=$?
    set -e

    if [[ "$dump_rc" -ne 0 ]] || [[ ! -s "$backup_file" ]]; then
      log "ERROR: database backup failed (rc=${dump_rc}); aborting updates"
      rm -f "$backup_file"
      exit 1
    fi
    if ! gzip -t "$backup_file" >/dev/null 2>&1; then
      log "ERROR: backup archive is corrupt; aborting updates"
      rm -f "$backup_file"
      exit 1
    fi

    size="$(du -h "$backup_file" | awk '{print $1}')"
    log "Database backup OK (${size})"

    find "$backup_dir" -type f -name '*_pre-update_*.sql.gz' -mtime "+${retention}" -delete 2>/dev/null || true
    log "Pruned backups older than ${retention} days"
  }

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

  backup_database

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
