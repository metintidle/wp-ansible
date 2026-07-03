#!/usr/bin/env bash
# Backup and delete unused WordPress media library attachments.
#
# Usage:
#   ./run-unused-media-cleanup.sh                 # backup + delete
#   WP_CLEAN_DRY_RUN=1 ./run-unused-media-cleanup.sh   # audit only (JSON)
#   ./run-unused-media-cleanup.sh north             # remote via SSH (ohara config)
#
# Optional env file (not committed): /home/ec2-user/.wp-clean.env

set -euo pipefail

WP_BIN="${WP_BIN:-/usr/local/bin/wp}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHP_SCRIPT="${WP_CLEAN_PHP_SCRIPT:-$SCRIPT_DIR/unused-media-cleanup.php}"
LOCK_FILE="/tmp/wp-unused-media-cleanup.lock"
LOG_DIR="${WP_CLEAN_LOG_DIR:-/home/ec2-user/logs}"
LOG_FILE="$LOG_DIR/wp-unused-media-cleanup.log"
BACKUP_DIR="${WP_CLEAN_BACKUP_DIR:-/home/ec2-user/backups/unused-media}"
ENV_FILE="${WP_CLEAN_ENV_FILE:-/home/ec2-user/.wp-clean.env}"

export WP_CLEAN_DRY_RUN="${WP_CLEAN_DRY_RUN:-0}"
export WP_CLEAN_BACKUP_DIR="$BACKUP_DIR"
export WP_CLEAN_BACKUP_RETENTION="${WP_CLEAN_BACKUP_RETENTION:-1}"
export WP_CLEAN_MIN_AGE_DAYS="${WP_CLEAN_MIN_AGE_DAYS:-7}"
export WP_CLEAN_MAX_PAGES="${WP_CLEAN_MAX_PAGES:-10}"
export WP_CLEAN_MAX_POSTS="${WP_CLEAN_MAX_POSTS:-50}"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  mkdir -p "$LOG_DIR"
  echo "$msg" >> "$LOG_FILE"
}

detect_wp_root() {
  local root
  for root in /home/ec2-user/html /var/www/html /usr/share/nginx/html; do
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

run_cleanup() {
  [[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

  local wp_root
  wp_root="$(detect_wp_root)"
  backup_outside_webroot "$wp_root" "$WP_CLEAN_BACKUP_DIR"

  mkdir -p "$LOG_DIR" "$WP_CLEAN_BACKUP_DIR"
  chmod 750 "$LOG_DIR" "$WP_CLEAN_BACKUP_DIR" 2>/dev/null || true

  if [[ ! -f "$PHP_SCRIPT" ]]; then
    log "ERROR: PHP script not found: $PHP_SCRIPT"
    exit 1
  fi

  log "Start unused-media cleanup (dry_run=$WP_CLEAN_DRY_RUN) wp_root=$wp_root"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Skip: another cleanup run in progress"
    exit 0
  fi

  set +e
  local out rc
  out="$("$WP_BIN" --path="$wp_root" eval-file "$PHP_SCRIPT" 2>&1)"
  rc=$?
  set -e

  echo "$out"
  echo "$out" >> "$LOG_FILE"

  if [[ $rc -eq 0 ]]; then
    log "Done (exit 0)"
  else
    log "Finished with exit $rc"
  fi
  exit "$rc"
}

apply_remote() {
  local host="$1"
  local ssh_config="${SSH_CONFIG:-$HOME/.ssh/ohara/config}"
  case "$host" in
    cccls|bateys|lifeimaging|chippingnortonmedical|centrehealth|traffic|lwhydraulics)
      ssh_config="${SSH_CONFIG:-$HOME/.ssh/config}"
      ;;
  esac

  echo "========== $host =========="
  ssh -F "$ssh_config" "$host" \
    "WP_CLEAN_DRY_RUN=${WP_CLEAN_DRY_RUN:-0} ${WRAPPER_REMOTE:-/home/ec2-user/bin/run-unused-media-cleanup.sh}"
}

if [[ $# -ge 1 && "$1" != "--help" && "$1" != "-h" ]]; then
  for h in "$@"; do
    apply_remote "$h"
  done
else
  run_cleanup
fi
