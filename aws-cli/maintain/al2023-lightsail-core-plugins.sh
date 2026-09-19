#!/usr/bin/env bash
# Install BBQ Firewall + SQLite Object Cache on the AL2023 Lightsail WordPress fleet.
#
# Per host: ansible-playbook modules/2_wordpress/playbook-core-plugins.yml
#   - BBQ Firewall (block-bad-queries): install, activate, auto-updates
#   - SQLite Object Cache: install, activate, auto-updates
#   - mu-plugin protect-bbq-firewall.php (prevents BBQ uninstall/deactivate;
#     hides BBQ and SQLite Object Cache on Plugins except for user itt-admin)
#   - mu-plugin protect-itt-admin.php (locks WordPress user itt-admin)
#
# Same default host list as al2023-lightsail-maintain.sh.
#
# Usage (from repo root):
#   ./aws-cli/maintain/al2023-lightsail-core-plugins.sh
#   ./aws-cli/maintain/al2023-lightsail-core-plugins.sh camden vcawol
#   ./aws-cli/maintain/al2023-lightsail-core-plugins.sh --dry-run
#
# Environment:
#   SSH_CONFIG   default: repo ssh-config symlink

set -euo pipefail

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

DRY_RUN=0
HOSTS=()
FAILURES=()

# Default fleet: keep in sync with al2023-lightsail-maintain.sh DEFAULT_HOSTS.
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
  cat <<EOF
Usage: $(basename "$0") [options] [HOST ...]

Install BBQ Firewall + SQLite Object Cache and deploy the BBQ + itt-admin lock mu-plugins
on AL2023 Lightsail WordPress hosts (same fleet as al2023-lightsail-maintain.sh).

Runs: modules/2_wordpress/playbook-core-plugins.yml

Options:
  --dry-run   Print actions without running Ansible
  -h, --help  Show this help

Examples:
  ./aws-cli/maintain/al2023-lightsail-core-plugins.sh
  ./aws-cli/maintain/al2023-lightsail-core-plugins.sh --dry-run camden
  ./aws-cli/maintain/al2023-lightsail-core-plugins.sh vcawol venkatesanfamilyoffice
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

record_failure() {
  FAILURES+=("$1")
  log "FAIL: $1"
}

resolve_ssh_config() {
  python3 -c "import os; print(os.path.realpath('${SSH_CONFIG}'))"
}

read_ssh() {
  local host="$1"
  local key="$2"
  local cfg
  cfg="$(resolve_ssh_config)"
  awk -v host="$host" -v k="$key" '
    { sub(/\r$/, "") }
    $1 == "Host" && $2 == host { in_host = 1; next }
    in_host && $1 == "Host" { exit }
    in_host && $1 == k { print $2; exit }
  ' "$cfg"
}

ansible_run() {
  local host="$1"
  local playbook="$2"
  local cfg identity identity_path
  cfg="$(resolve_ssh_config)"
  identity="$(read_ssh "$host" IdentityFile)"
  identity_path="${identity/#\~/$HOME}"
  if [[ -z "$identity_path" ]]; then
    log "${host}: IdentityFile not found in ${SSH_CONFIG}"
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: ansible-playbook -i ${host}, ${playbook}"
    return 0
  fi
  ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_SSH_ARGS="-F ${cfg}" \
    ansible-playbook -i "${host}," "$playbook" \
      -e "ansible_ssh_private_key_file=${identity_path}"
}

process_host() {
  local host="$1"
  local ip

  log "======== ${host} ========"
  ip="$(read_ssh "$host" HostName)"
  if [[ -z "$ip" ]]; then
    record_failure "${host}: Host not found in ${SSH_CONFIG}"
    return 1
  fi
  log "${host}: ${ip}"

  ansible_run "$host" "$REPO_ROOT/modules/2_wordpress/playbook-core-plugins.yml" \
    || record_failure "${host}: core-plugins playbook failed"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  HOSTS=("${DEFAULT_HOSTS[@]}")
fi

log "Hosts: ${HOSTS[*]}"
log "Playbook: modules/2_wordpress/playbook-core-plugins.yml; dry-run=${DRY_RUN}"

for host in "${HOSTS[@]}"; do
  process_host "$host" || true
done

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  log "Completed with ${#FAILURES[@]} failure(s):"
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi

log "All hosts completed successfully."
