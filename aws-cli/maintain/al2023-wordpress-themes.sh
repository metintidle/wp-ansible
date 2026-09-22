#!/usr/bin/env bash
# Audit installed and active WordPress themes on every AL2023 WordPress host.
#
# The default host list is kept here as a server variable, matching the other
# maintenance scripts. Pass host names on the command line to run a subset.
#
# Usage (from repo root):
#   ./aws-cli/maintain/al2023-wordpress-themes.sh
#   ./aws-cli/maintain/al2023-wordpress-themes.sh --dry-run
#   ./aws-cli/maintain/al2023-wordpress-themes.sh cccls vcawol
#   ./aws-cli/maintain/al2023-wordpress-themes.sh --output /tmp/themes.txt
#
# With no host arguments, the DEFAULT_HOSTS list below is used. Supplying one
# or more host names overrides that list for the current run.
#
# Options:
#   --dry-run   Show the selected hosts without connecting
#   --output    Save the displayed audit result to this file
#   -h, --help  Show help
#
# The remote check runs as the SSH user and probes for wp-load.php rather than
# assuming a single WordPress document root.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SSH_CONFIG="${SSH_CONFIG:-${REPO_ROOT}/ssh-config}"
DRY_RUN=0
HOSTS=()
FAILURES=()
RESULT_FILE=""

# Default AL2023 WordPress fleet. Edit this list when the maintenance scope
# changes, or pass explicit hosts to override it for one run.
DEFAULT_HOSTS=(
  healthworth
  gerringong
  albionpark
  camden
  skinandvien
  lifeimaging
  annettebeaufils
  tongarrafamilypractice
  ucdrs
  ecmc
  diagnosticradiologists
  moorebankfamilypractice
  bettercaremedicalcentre
  chippingnortonmedical
  cccls
  centrehealth
  centrehealth2
  CityMedicalWollongong
  dmfp
  drbeshoyfarah
  greenfarm
  gpubg.com
  krmp
  newfresh
  rvmap
  theoaksgp
  vcawol
  venkatesanfamilyoffice
  wmeds
  wpni
)

usage() {
  sed -n '2,20p' "$0"
}

log() {
  local line
  line="[$(date '+%H:%M:%S')] $*"
  printf '%s\n' "$line"
  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$line" >> "$RESULT_FILE"
}

result() {
  printf '%s\n' "$*"
  [[ -n "$RESULT_FILE" ]] && printf '%s\n' "$*" >> "$RESULT_FILE"
}

record_failure() {
  FAILURES+=("$1")
  log "FAIL: $1"
}

remote_theme_audit() {
  ssh \
    -F "$SSH_CONFIG" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o LogLevel=ERROR \
    -o StrictHostKeyChecking=accept-new \
    "$1" 'bash -s' <<'REMOTE'
set -u

wp_bin="$(command -v wp || true)"
if [[ -z "$wp_bin" ]]; then
  echo "ERROR|wp-cli-not-found"
  exit 1
fi

# Discover every WordPress root below the normal fleet locations. The realpath
# de-duplication also avoids reporting /home/ec2-user/html and its target twice.
roots=()
while IFS= read -r root; do
  [[ -n "$root" ]] && roots+=("$root")
done < <(
  find /usr/share/nginx /home/ec2-user /var/www \
    -type f -name wp-load.php -print 2>/dev/null \
    | while IFS= read -r file; do dirname "$file"; done \
    | while IFS= read -r root; do cd "$root" 2>/dev/null && pwd -P; done \
    | LC_ALL=C sort -u
)

if [[ ${#roots[@]} -eq 0 ]]; then
  echo "ERROR|wordpress-root-not-found"
  exit 1
fi

for root in "${roots[@]}"; do
  result="$($wp_bin --path="$root" theme list \
    --fields=name,status \
    --format=csv \
    --skip-update-check \
    --skip-plugins 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "ERROR|${root}|${result//$'\n'/ }"
    continue
  fi

  count=0
  active="none"
  while IFS=, read -r name status rest; do
    [[ "$name" == "name" ]] && continue
    [[ -z "$name" ]] && continue
    count=$((count + 1))
    [[ "$status" == "active" ]] && active="$name"
  done <<< "$result"

  printf 'THEMES|%s|%s|%s\n' "$root" "$count" "$active"
done
REMOTE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --output)
      [[ $# -ge 2 ]] || { echo "ERROR: --output requires a file path" >&2; exit 1; }
      RESULT_FILE="$2"
      shift 2
      ;;
    --output=*) RESULT_FILE="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  HOSTS=("${DEFAULT_HOSTS[@]}")
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "ERROR: no AL2023 WordPress hosts found in $SSH_CONFIG" >&2
  exit 1
fi

if [[ -z "$RESULT_FILE" ]]; then
  RESULT_FILE="${REPO_ROOT}/logs/al2023-wordpress-themes-$(date '+%Y-%m-%d-%H%M%S').log"
fi
mkdir -p "$(dirname "$RESULT_FILE")"
: > "$RESULT_FILE"

log "SSH config: $SSH_CONFIG"
log "Hosts (${#HOSTS[@]}): ${HOSTS[*]}"
log "Result file: $RESULT_FILE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Dry run only: no SSH connections or WordPress theme queries were executed."
  exit 0
fi

for host in "${HOSTS[@]}"; do
  log "======== ${host} ========"
  output="$(remote_theme_audit "$host" 2>&1)"
  rc=$?
  if [[ -n "$output" ]]; then
    while IFS= read -r line; do
      case "$line" in
        THEMES\|*)
          IFS='|' read -r _ root count active <<< "$line"
          result "${host}: ${count} themes; active=${active} (${root})"
          ;;
        ERROR\|*)
          IFS='|' read -r _ root details <<< "$line"
          if [[ -n "$details" ]]; then
            record_failure "${host}: ${root}: ${details}"
          else
            record_failure "${host}: ${root}"
          fi
          ;;
        *)
          result "${host}: ${line}"
          ;;
      esac
    done <<< "$output"
  fi
  [[ $rc -eq 0 ]] || record_failure "${host}: SSH or remote audit failed"
done

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  log "Completed with ${#FAILURES[@]} failure(s):"
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi

log "All hosts completed successfully."
