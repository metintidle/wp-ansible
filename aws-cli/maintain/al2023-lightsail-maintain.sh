#!/usr/bin/env bash
# AL2023 Lightsail fleet maintenance (SSH firewall, snapshot, backup, OS upgrade deploy).
#
# Per host (in order):
#   1. Verify Lightsail port 22 is limited to SSH_ALLOW_CIDRS; fix when --fix-ssh (default)
#   2. ansible-playbook modules/9_backup/playbook.yml
#   3. ansible-playbook modules/8_updates/playbook-os.yml
#   4. Ensure one non-automatic Lightsail instance snapshot exists; create if missing
#
# Usage (from repo root):
#   ./aws-cli/maintain/al2023-lightsail-maintain.sh
#   ./aws-cli/maintain/al2023-lightsail-maintain.sh iwm
#   ./aws-cli/maintain/al2023-lightsail-maintain.sh --step ssh iwm
#   ./aws-cli/maintain/al2023-lightsail-maintain.sh --dry-run
#   ./aws-cli/maintain/al2023-lightsail-maintain.sh iwm:MyAwsProfile
#
# Environment:
#   SSH_CONFIG          default: repo ssh-config symlink
#   REGION              default: ap-southeast-2
#   SSH_ALLOW_CIDRS     default: 111.220.137.221/32,43.245.170.89/32,158.180.7.100/32
#   INSTANCE_SNAPSHOT_PREFIX  default: <ssh-host>-al2023

set -euo pipefail

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

REGION="${REGION:-ap-southeast-2}"
SSH_ALLOW_CIDRS="${SSH_ALLOW_CIDRS:-111.220.137.221/32,43.245.170.89/32,158.180.7.100/32}"
REQUIRED_SSH_CIDR="20.193.75.72/32"
INSTANCE_SNAPSHOT_PREFIX="${INSTANCE_SNAPSHOT_PREFIX:-}"
DRY_RUN=0
FIX_SSH=1
STEP="all"
HOSTS=()
FAILURES=()

# Default fleet: ssh-config AL2023 WordPress host iwm (innovativerealty.com.au).
DEFAULT_HOSTS=(
  iwm
)

# Optional CLI overrides: host:profile (stored as host<TAB>profile lines)
PROFILE_OVERRIDES=""

lookup_host_profile() {
  local host="$1"
  local line key val
  while IFS=$'\t' read -r key val; do
    [[ "$key" == "$host" && -n "$val" ]] && printf '%s' "$val" && return 0
  done <<<"$PROFILE_OVERRIDES"
  case "$host" in
    iwm) printf '%s' InnovativeWealthManagement ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [HOST | HOST:PROFILE ...]

AL2023 Lightsail maintenance for WordPress hosts in ssh-config.

Steps (default: all, in order):
  ssh       Verify/fix Lightsail TCP/22 firewall to SSH_ALLOW_CIDRS
  backup    modules/9_backup/playbook.yml
  os        modules/8_updates/playbook-os.yml
  snapshot  Keep one manual instance snapshot (skip if any non-auto snapshot exists)

Options:
  --dry-run       Print actions without AWS/Ansible changes
  --no-fix-ssh    Check SSH port only; do not call put-instance-public-ports
  --step STEP     Run one step: ssh|snapshot|backup|os|all
  -h, --help      Show this help

Examples:
  ./aws-cli/maintain/al2023-lightsail-maintain.sh --dry-run iwm
  ./aws-cli/maintain/al2023-lightsail-maintain.sh --step backup iwm
  ./aws-cli/maintain/al2023-lightsail-maintain.sh --step os iwm
  ./aws-cli/maintain/al2023-lightsail-maintain.sh iwm:MyProfileName

Hosts without a built-in profile mapping must use HOST:PROFILE or will be skipped for AWS steps.
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
  ssh -G -F "$cfg" "$host" 2>/dev/null |
    awk -v k="$key" 'tolower($1) == tolower(k) { print $2; exit }'
}

host_profile() {
  lookup_host_profile "$1"
}

parse_host_arg() {
  local arg="$1"
  if [[ "$arg" == *:* ]]; then
    PARSED_HOST="${arg%%:*}"
    PROFILE_OVERRIDES+="${PARSED_HOST}"$'\t'"${arg#*:}"$'\n'
  else
    PARSED_HOST="$arg"
  fi
}

step_enabled() {
  local want="$1"
  [[ "$STEP" == "all" || "$STEP" == "$want" ]]
}

normalize_cidr_list() {
  local raw="$1"
  local item
  local -a items=()
  raw="${raw//,/ }"
  for item in $raw; do
    [[ -z "$item" ]] && continue
    items+=("$item")
  done
  if [[ ${#items[@]} -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "${items[@]}" | LC_ALL=C sort -u | paste -sd, -
}

cidr_sets_match() {
  local a b
  a="$(normalize_cidr_list "$1")"
  b="$(normalize_cidr_list "$2")"
  [[ "$a" == "$b" ]]
}

ensure_required_ssh_cidr() {
  SSH_ALLOW_CIDRS="$(normalize_cidr_list "${SSH_ALLOW_CIDRS},${REQUIRED_SSH_CIDR}")"
}

find_lightsail_instance_by_ip() {
  local profile="$1"
  local ip="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'lightsail-%s' "$ip"
    return 0
  fi
  aws lightsail get-instances \
    --region "$REGION" \
    --profile "$profile" \
    --query "instances[?publicIpAddress=='${ip}'].name | [0]" \
    --output text 2>/dev/null || echo "None"
}

get_ssh_port_cidrs() {
  local profile="$1"
  local instance="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s' "$SSH_ALLOW_CIDRS"
    return 0
  fi
  aws lightsail get-instance-port-states \
    --region "$REGION" \
    --profile "$profile" \
    --instance-name "$instance" \
    --query "portStates[?fromPort==\`22\` && toPort==\`22\` && protocol=='tcp'].cidrs | [0]" \
    --output text 2>/dev/null || echo ""
}

ensure_aws_login() {
  local profile="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: aws-login ${profile}"
    return 0
  fi
  "$AWS_CLI_AUTH/aws-login.sh" "$profile" >/dev/null
}

apply_ssh_firewall() {
  local profile="$1"
  local instance="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: put-instance-public-ports ${instance} (SSH=${SSH_ALLOW_CIDRS})"
    return 0
  fi
  aws lightsail put-instance-public-ports \
    --region "$REGION" \
    --profile "$profile" \
    --instance-name "$instance" \
    --port-infos \
      "fromPort=22,toPort=22,protocol=tcp,cidrs=${SSH_ALLOW_CIDRS}" \
      "fromPort=80,toPort=80,protocol=tcp,cidrs=0.0.0.0/0" \
      "fromPort=443,toPort=443,protocol=tcp,cidrs=0.0.0.0/0"
}

wait_instance_snapshot_state() {
  local profile="$1"
  local name="$2"
  local want="$3"
  local attempt=0
  local state="missing"
  log "Waiting for snapshot ${name} → ${want}"
  while [[ "$attempt" -lt 120 ]]; do
    state=$(aws lightsail get-instance-snapshot \
      --region "$REGION" \
      --profile "$profile" \
      --instance-snapshot-name "$name" \
      --query 'instanceSnapshot.state' \
      --output text 2>/dev/null || echo "missing")
    if [[ "$state" == "$want" ]]; then
      log "Snapshot ${name} is ${want}"
      return 0
    fi
    if [[ "$state" == "error" ]]; then
      log "Snapshot ${name} entered error state"
      return 1
    fi
    sleep 15
    attempt=$((attempt + 1))
  done
  log "Timeout waiting for snapshot ${name} (last state: ${state})"
  return 1
}

ensure_instance_snapshot() {
  local host="$1"
  local profile="$2"
  local instance="$3"
  local snap_prefix="${INSTANCE_SNAPSHOT_PREFIX:-${host}-al2023}"
  local existing state

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: ensure instance snapshot for ${instance} (name ${snap_prefix} if none exists)"
    return 0
  fi

  existing=$(aws lightsail get-instance-snapshots \
    --region "$REGION" \
    --profile "$profile" \
    --query "instanceSnapshots[?fromInstanceName=='${instance}' && !starts_with(name, 'AutomaticSnapshot-')].name" \
    --output text 2>/dev/null || true)

  if [[ -n "$existing" && "$existing" != "None" ]]; then
    log "${host}: instance ${instance} already has snapshot(s): ${existing}"
    for snap_name in $existing; do
      if [[ "$DRY_RUN" -eq 0 ]]; then
        wait_instance_snapshot_state "$profile" "$snap_name" "available" || return 1
      fi
    done
    return 0
  fi

  state=$(aws lightsail get-instance \
    --region "$REGION" \
    --profile "$profile" \
    --instance-name "$instance" \
    --query 'instance.state.name' \
    --output text 2>/dev/null || echo "missing")
  if [[ "$state" != "running" ]]; then
    log "${host}: instance ${instance} is ${state}, expected running"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: create-instance-snapshot ${instance} → ${snap_prefix}"
    return 0
  fi

  log "${host}: creating instance snapshot ${snap_prefix} from ${instance}"
  aws lightsail create-instance-snapshot \
    --region "$REGION" \
    --profile "$profile" \
    --instance-name "$instance" \
    --instance-snapshot-name "$snap_prefix"
  wait_instance_snapshot_state "$profile" "$snap_prefix" "available"
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
  local profile ip instance current_cidrs

  log "======== ${host} ========"
  ip="$(read_ssh "$host" HostName)"
  if [[ -z "$ip" ]]; then
    record_failure "${host}: Host not found in ${SSH_CONFIG}"
    return 1
  fi

  if ! profile="$(host_profile "$host")"; then
    log "${host}: no AWS profile mapping — skipping ssh/snapshot (use HOST:PROFILE to override)"
    profile=""
  fi

  instance=""
  if [[ -n "$profile" ]]; then
    if ! ensure_aws_login "$profile"; then
      record_failure "${host}: AWS login failed for profile ${profile}"
      return 1
    fi
    instance="$(find_lightsail_instance_by_ip "$profile" "$ip")"
    if [[ -z "$instance" || "$instance" == "None" ]]; then
      record_failure "${host}: no Lightsail instance with public IP ${ip} (profile ${profile})"
      return 1
    fi
    log "${host}: Lightsail instance ${instance} @ ${ip} (profile ${profile})"
    ensure_required_ssh_cidr
    log "${host}: SSH allow-list includes ${REQUIRED_SSH_CIDR}"
  fi

  if step_enabled ssh; then
    if [[ -z "$profile" || -z "$instance" ]]; then
      record_failure "${host}: ssh step needs AWS profile and Lightsail instance"
    else
      current_cidrs="$(get_ssh_port_cidrs "$profile" "$instance")"
      current_cidrs="${current_cidrs//$'\t'/,}"
      if cidr_sets_match "$current_cidrs" "$SSH_ALLOW_CIDRS"; then
        log "${host}: SSH port 22 OK (${current_cidrs:-<none>})"
      elif [[ "$FIX_SSH" -eq 1 ]]; then
        log "${host}: SSH port 22 mismatch (have: ${current_cidrs:-<none>}; want: ${SSH_ALLOW_CIDRS}) — fixing"
        if apply_ssh_firewall "$profile" "$instance"; then
          log "${host}: SSH firewall updated"
        else
          record_failure "${host}: failed to update SSH firewall"
        fi
      else
        record_failure "${host}: SSH port 22 not limited to ${SSH_ALLOW_CIDRS} (have: ${current_cidrs:-<none>})"
      fi
    fi
  fi

  if step_enabled backup; then
    ansible_run "$host" "$REPO_ROOT/modules/9_backup/playbook.yml" \
      || record_failure "${host}: backup playbook failed"
  fi

  if step_enabled os; then
    ansible_run "$host" "$REPO_ROOT/modules/8_updates/playbook-os.yml" \
      || record_failure "${host}: OS upgrade playbook failed"
  fi

  if step_enabled snapshot; then
    if [[ -z "$profile" || -z "$instance" ]]; then
      record_failure "${host}: snapshot step needs AWS profile and Lightsail instance"
    else
      ensure_instance_snapshot "$host" "$profile" "$instance" || record_failure "${host}: snapshot step failed"
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-fix-ssh) FIX_SSH=0; shift ;;
    --step)
      STEP="${2:?--step requires ssh|snapshot|backup|os|all}"
      case "$STEP" in
        ssh|snapshot|backup|os|all) ;;
        *) echo "Unknown step: $STEP" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)
      parse_host_arg "$1"
      HOSTS+=("$PARSED_HOST")
      shift
      ;;
  esac
done

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  HOSTS=("${DEFAULT_HOSTS[@]}")
fi

log "Hosts: ${HOSTS[*]}"
log "Step: ${STEP}; dry-run=${DRY_RUN}; fix-ssh=${FIX_SSH}"
log "SSH allow list: ${SSH_ALLOW_CIDRS}"

for host in "${HOSTS[@]}"; do
  process_host "$host" || true
done

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  log "Completed with ${#FAILURES[@]} failure(s):"
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi

log "All hosts completed successfully."
