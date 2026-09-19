#!/usr/bin/env bash
# Start stopped Lightsail instances by repo ssh-config host alias.
#
# Usage:
#   ./aws-cli/maintain/start-lightsail-ssh-host.sh healthworth onix skinandvien traffic
#   ./aws-cli/maintain/start-lightsail-ssh-host.sh --dry-run healthworth
#   ./aws-cli/maintain/start-lightsail-ssh-host.sh healthworth:MyAwsProfile
#
# Env:
#   SSH_CONFIG  default: repo ssh-config symlink
#   REGION      default: ap-southeast-2

set -euo pipefail

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

REGION="${REGION:-ap-southeast-2}"
DRY_RUN=0
HOSTS=()
PROFILE_OVERRIDES=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] HOST | HOST:PROFILE ...

Start a stopped Lightsail instance whose public IP matches the ssh-config HostName.

Built-in profile mapping:
  healthworth  -> HealthworthSpecialistCentre
  onix         -> OnixConstruction
  skinandvien  -> SCSVC
  traffic      -> TrafficProfessionals

Options:
  --dry-run   Print actions only
  -h, --help  Show this help
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

lookup_host_profile() {
  local host="$1"
  local line key val
  while IFS=$'\t' read -r key val; do
    [[ "$key" == "$host" && -n "$val" ]] && printf '%s' "$val" && return 0
  done <<<"$PROFILE_OVERRIDES"
  case "$host" in
    healthworth) printf '%s' HealthworthSpecialistCentre ;;
    onix) printf '%s' OnixConstruction ;;
    skinandvien) printf '%s' SCSVC ;;
    traffic) printf '%s' TrafficProfessionals ;;
    *) return 1 ;;
  esac
}

read_ssh() {
  local host="$1"
  local key="$2"
  awk -v host="$host" -v k="$key" '
    $1 == "Host" && $2 == host { in_host = 1; next }
    in_host && $1 == "Host" { exit }
    in_host && $1 == k { print $2; exit }
  ' "$SSH_CONFIG"
}

parse_host_arg() {
  local arg="$1"
  if [[ "$arg" == *:* ]]; then
    PROFILE_OVERRIDES+="${arg%%:*}"$'\t'"${arg#*:}"$'\n'
    printf '%s' "${arg%%:*}"
    return 0
  fi
  printf '%s' "$arg"
}

find_lightsail_instance_by_ip() {
  local profile="$1"
  local ip="$2"
  aws lightsail get-instances \
    --region "$REGION" \
    --profile "$profile" \
    --query "instances[?publicIpAddress=='${ip}'].{name:name,state:state.name,ip:publicIpAddress} | [0]" \
    --output json
}

wait_instance_running() {
  local profile="$1"
  local instance="$2"
  local attempt=0
  local state=""
  while [[ "$attempt" -lt 60 ]]; do
    state="$(aws lightsail get-instance \
      --region "$REGION" \
      --profile "$profile" \
      --instance-name "$instance" \
      --query 'instance.state.name' \
      --output text)"
    [[ "$state" == "running" ]] && return 0
    sleep 5
    attempt=$((attempt + 1))
  done
  echo "Timed out waiting for ${instance} to reach running (last state: ${state})" >&2
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) HOSTS+=("$(parse_host_arg "$1")"); shift ;;
  esac
done

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "At least one HOST is required." >&2
  usage
  exit 1
fi

if [[ ! -f "$SSH_CONFIG" ]]; then
  echo "ERROR: SSH config not found: $SSH_CONFIG" >&2
  exit 1
fi

FAILURES=0
for host in "${HOSTS[@]}"; do
  ip="$(read_ssh "$host" HostName || true)"
  if [[ -z "$ip" ]]; then
    log "SKIP ${host}: no HostName in ${SSH_CONFIG}"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  if ! profile="$(lookup_host_profile "$host")"; then
    log "SKIP ${host}: no AWS profile mapping (use ${host}:ProfileName)"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  log "${host} (${ip}) → profile ${profile}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: aws-login ${profile}; find Lightsail instance by IP ${ip}; start if stopped"
    continue
  fi

  if ! "$AWS_CLI_AUTH/aws-login.sh" "$profile" >/dev/null; then
    log "FAIL ${host}: aws login failed for profile ${profile}"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  info="$(find_lightsail_instance_by_ip "$profile" "$ip")"
  if [[ "$info" == "null" || -z "$info" ]]; then
    log "FAIL ${host}: no Lightsail instance with public IP ${ip} in ${profile}"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  instance="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))" <<<"$info")"
  state="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('state',''))" <<<"$info")"

  if [[ -z "$instance" ]]; then
    log "FAIL ${host}: Lightsail lookup returned empty instance name"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  case "$state" in
    running)
      log "OK ${host}: ${instance} already running"
      ;;
    stopped)
      log "START ${host}: ${instance} (was stopped)"
      aws lightsail start-instance \
        --region "$REGION" \
        --profile "$profile" \
        --instance-name "$instance" >/dev/null
      wait_instance_running "$profile" "$instance"
      log "OK ${host}: ${instance} is running"
      ;;
    *)
      log "FAIL ${host}: ${instance} state is ${state} (not startable from script)"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
done

exit "$([[ "$FAILURES" -eq 0 ]] && echo 0 || echo 1)"
