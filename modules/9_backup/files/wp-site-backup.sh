#!/usr/bin/env bash
# Root WordPress site backup: database dump + wp-config.php / wp-content archive.
# Destination: /var/backups/wordpress (root:root 0700, outside webroot).
# Coordinates with module 8 auto-update via /run/wp-site-backup-db.stamp and flock locks.
#
# Usage:
#   sudo /usr/local/bin/wp-site-backup.sh
#   WP_ROOT=/home/ec2-user/html sudo /usr/local/bin/wp-site-backup.sh

set -euo pipefail
IFS=$'\n\t'

WP_BIN="${WP_BIN:-/usr/local/bin/wp}"
BACKUP_DIR="${WP_SITE_BACKUP_DIR:-/var/backups/wordpress}"
LOCK_FILE="${BACKUP_DIR}/.lock"
AUTO_UPDATE_LOCK="/tmp/wp-auto-update.lock"
STAMP_FILE="/run/wp-site-backup-db.stamp"
LOG_FILE="/var/log/wp-site-backup.log"

DB_RETENTION="${WP_SITE_BACKUP_DB_RETENTION:-5}"
FILES_RETENTION="${WP_SITE_BACKUP_FILES_RETENTION:-4}"
DB_MAX_AGE_DAYS="${WP_SITE_BACKUP_DB_MAX_AGE_DAYS:-7}"
FILES_MAX_AGE_DAYS="${WP_SITE_BACKUP_FILES_MAX_AGE_DAYS:-14}"

OTHER_LOCK_WAIT_SECS="${WP_SITE_BACKUP_OTHER_LOCK_WAIT:-300}"

[[ -f "${WP_SITE_BACKUP_ENV_FILE:-/etc/wp-site-backup.env}" ]] \
  && set -a && source "${WP_SITE_BACKUP_ENV_FILE:-/etc/wp-site-backup.env}" && set +a

SKIP_HOSTS="${WP_SITE_BACKUP_SKIP_HOSTS:-capitalformwork lwhydraulics figtreesports}"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$msg" >> "$LOG_FILE"
}

detect_wp_root() {
  if [[ -n "${WP_ROOT:-}" ]] && [[ -f "${WP_ROOT}/wp-config.php" ]]; then
    echo "$WP_ROOT"
    return 0
  fi
  local root
  for root in /home/ec2-user/html /usr/share/nginx/html /var/www/html; do
    if [[ -f "$root/wp-config.php" ]]; then
      echo "$root"
      return 0
    fi
  done
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

host_skipped() {
  local h short
  h="$(hostname 2>/dev/null || echo unknown)"
  short="${h%%.*}"
  local skip
  for skip in $SKIP_HOSTS; do
    if [[ "$h" == "$skip" ]] || [[ "$short" == "$skip" ]]; then
      return 0
    fi
  done
  return 1
}

sydney_weekday() {
  TZ=Australia/Sydney date +%w
}

wait_for_other_lock() {
  local lock="$1"
  local waited=0
  [[ -e "$lock" ]] || return 0

  while (( waited < OTHER_LOCK_WAIT_SECS )); do
    exec 8>>"$lock"
    if flock -n 8; then
      flock -u 8
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
  done
  log "Skip: lock held on $lock after ${OTHER_LOCK_WAIT_SECS}s"
  exit 0
}

newest_file() {
  local pattern="$1"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n1 | awk '{print $2}'
}

file_age_days() {
  local f="$1"
  [[ -n "$f" && -f "$f" ]] || return 1
  local now mtime
  now="$(date +%s)"
  mtime="$(stat -c %Y "$f")"
  echo $(( (now - mtime) / 86400 ))
}

free_space_kb() {
  df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}'
}

check_disk_space() {
  local free_kb last_archive last_size_kb min_free_kb
  free_kb="$(free_space_kb)"
  min_free_kb=$((500 * 1024))

  if [[ -z "$free_kb" ]] || (( free_kb < min_free_kb )); then
    log "Abort: free space under 500MB (${free_kb:-0}KB available)"
    exit 4
  fi

  last_archive="$(newest_file '*_db_*.sql.gz')"
  if [[ -z "$last_archive" ]]; then
    last_archive="$(newest_file '*_files_*.tar.gz')"
  fi
  if [[ -n "$last_archive" && -f "$last_archive" ]]; then
    last_size_kb="$(du -k "$last_archive" | awk '{print $1}')"
    min_free_kb=$((last_size_kb + last_size_kb / 2))
    if (( free_kb < min_free_kb )); then
      log "Abort: free space under 1.5x last archive (${free_kb}KB < ${min_free_kb}KB)"
      exit 4
    fi
  fi
}

compute_fingerprint() {
  local wp_root="$1"
  local base="$wp_root/wp-content"
  local dir

  for dir in uploads plugins themes mu-plugins; do
    if [[ -d "$base/$dir" ]]; then
      find "$base/$dir" \
        \( -path '*/cache/*' -o -path '*/upgrade/*' -o -path '*/tmp/*' \
           -o -path '*/updraft/*' -o -path '*/wpvividbackups/*' \) -prune -o \
        -type f -printf '%p %s %T@\n' 2>/dev/null || true
    fi
  done | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

fingerprint_for_latest_files() {
  local latest fp
  latest="$(newest_file '*_files_*.tar.gz')"
  [[ -n "$latest" ]] || return 1
  fp="${latest%.tar.gz}.fingerprint"
  [[ -f "$fp" ]] && cat "$fp" || return 1
}

db_backup_due() {
  local latest age
  latest="$(newest_file '*_db_*.sql.gz')"
  if [[ -z "$latest" ]]; then
    return 0
  fi
  age="$(file_age_days "$latest")"
  (( age > DB_MAX_AGE_DAYS ))
}

files_backup_due() {
  local wp_root="$1"
  local latest age current_fp stored_fp

  if [[ "$(sydney_weekday)" == "0" ]]; then
    return 1
  fi

  latest="$(newest_file '*_files_*.tar.gz')"
  if [[ -z "$latest" ]]; then
    return 0
  fi

  age="$(file_age_days "$latest")"
  if (( age > FILES_MAX_AGE_DAYS )); then
    return 0
  fi

  current_fp="$(compute_fingerprint "$wp_root")"
  stored_fp="$(fingerprint_for_latest_files || true)"
  [[ "$current_fp" != "$stored_fp" ]]
}

secure_archive() {
  local f="$1"
  chmod 600 "$f"
  if command -v chattr >/dev/null 2>&1; then
    chattr +i "$f" 2>/dev/null || true
  fi
}

remove_archive() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if command -v chattr >/dev/null 2>&1; then
    chattr -i "$f" 2>/dev/null || true
  fi
  rm -f "$f"
}

prune_retention() {
  local pattern="$1"
  local keep="$2"
  local -a files
  mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' \
    | sort -rn | awk '{print $2}')
  local i
  for i in "${!files[@]}"; do
    if (( i >= keep )); then
      remove_archive "${files[$i]}"
      local sidecar
      sidecar="${files[$i]%.tar.gz}.fingerprint"
      [[ -f "$sidecar" ]] && remove_archive "$sidecar"
      sidecar="${files[$i]%.tar.gz}.version"
      [[ -f "$sidecar" ]] && remove_archive "$sidecar"
      log "Pruned old archive ${files[$i]}"
    fi
  done
}

run_backup() {
  mkdir -p "$(dirname "$LOG_FILE")"
  log "Start wp-site-backup"

  if host_skipped; then
    log "Skip: hostname on skip list"
    exit 0
  fi

  local wp_root
  if ! wp_root="$(detect_wp_root)"; then
    log "Skip: WordPress root not found"
    exit 0
  fi

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  backup_outside_webroot "$wp_root" "$BACKUP_DIR"
  check_disk_space

  wait_for_other_lock "$AUTO_UPDATE_LOCK"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Skip: another backup run in progress"
    exit 0
  fi

  local do_db=0 do_files=0
  if db_backup_due; then
    do_db=1
  fi
  if files_backup_due "$wp_root"; then
    do_files=1
  fi

  if (( do_db == 0 && do_files == 0 )); then
    log "nothing due"
    exit 0
  fi

  local RUN=(nice -n 19)
  command -v ionice >/dev/null && RUN+=(ionice -c2 -n7)

  local wp_args=(--path="$wp_root")
  local db_name timestamp backup_file dump_rc size core_ver

  set +e
  db_name="$("$WP_BIN" db name "${wp_args[@]}" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  set -e
  [[ -n "$db_name" ]] || db_name="wordpress"

  timestamp="$(TZ=Australia/Sydney date +%Y%m%d_%H%M%S)"

  if (( do_db == 1 )); then
    backup_file="${BACKUP_DIR}/${db_name}_db_${timestamp}.sql.gz"
    log "Backing up database ${db_name} to ${backup_file}"
    set +e
    "${RUN[@]}" sudo -u ec2-user "$WP_BIN" db export - "${wp_args[@]}" 2>>"$LOG_FILE" | gzip -c > "${backup_file}.part"
    dump_rc=${PIPESTATUS[0]}
    set -e
    if [[ "$dump_rc" -ne 0 ]] || [[ ! -s "${backup_file}.part" ]]; then
      log "ERROR: database backup failed (rc=${dump_rc})"
      rm -f "${backup_file}.part"
      exit 1
    fi
    if ! gzip -t "${backup_file}.part" >/dev/null 2>&1; then
      log "ERROR: database backup archive corrupt"
      rm -f "${backup_file}.part"
      exit 1
    fi
    mv "${backup_file}.part" "$backup_file"
    secure_archive "$backup_file"
    size="$(du -h "$backup_file" | awk '{print $1}')"
    log "Database backup OK (${size})"
    {
      echo "timestamp=${timestamp}"
      echo "path=${backup_file}"
      echo "db_name=${db_name}"
    } > "$STAMP_FILE"
    chmod 0644 "$STAMP_FILE"
    prune_retention '*_db_*.sql.gz' "$DB_RETENTION"
  fi

  if (( do_files == 1 )); then
    local files_archive fp_file ver_file
    files_archive="${BACKUP_DIR}/${db_name}_files_${timestamp}.tar.gz"
    fp_file="${files_archive%.tar.gz}.fingerprint"
    ver_file="${files_archive%.tar.gz}.version"

    log "Archiving wp-config.php and wp-content to ${files_archive}"
    set +e
    "${RUN[@]}" tar -C "$wp_root" \
      --exclude='./wp-content/cache' \
      --exclude='./wp-content/upgrade' \
      --exclude='./wp-content/tmp' \
      --exclude='./wp-content/updraft' \
      --exclude='./wp-content/wpvividbackups' \
      --exclude='./wp-content/debug.log' \
      -czf "${files_archive}.part" wp-config.php wp-content
    dump_rc=$?
    set -e
    if [[ "$dump_rc" -ne 0 ]] || [[ ! -s "${files_archive}.part" ]]; then
      log "ERROR: files archive failed (rc=${dump_rc})"
      rm -f "${files_archive}.part"
      exit 1
    fi
    mv "${files_archive}.part" "$files_archive"
    secure_archive "$files_archive"

    compute_fingerprint "$wp_root" > "$fp_file"
    chmod 600 "$fp_file"
    command -v chattr >/dev/null && chattr +i "$fp_file" 2>/dev/null || true

    set +e
    core_ver="$("$WP_BIN" core version "${wp_args[@]}" 2>/dev/null | tail -n1 | tr -d '[:space:]')"
    set -e
    echo "${core_ver:-unknown}" > "$ver_file"
    chmod 600 "$ver_file"
    command -v chattr >/dev/null && chattr +i "$ver_file" 2>/dev/null || true

    size="$(du -h "$files_archive" | awk '{print $1}')"
    log "Files backup OK (${size}, core ${core_ver:-unknown})"
    prune_retention '*_files_*.tar.gz' "$FILES_RETENTION"
  fi

  log "Done"
}

run_backup
