#!/usr/bin/env bash
# Wrapper: deploy OS upgrade cron via Ansible module 8_updates.
# Canonical scripts: modules/8_updates/files/
#
# Usage:
#   SSH_CONFIG=d:/wp-ansible/config ./bash/install-os-upgrade-cron.sh cccls
#   ./bash/install-os-upgrade-cron.sh --remove cccls

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYBOOK="${REPO_ROOT}/modules/8_updates/playbook.yml"
SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
INVENTORY="${INVENTORY:-}"

usage() {
  cat <<EOF
Usage: $0 [--remove] [--schedule "CRON_EXPR"] [--tz TIMEZONE] HOST [HOST ...]

Deploys modules/8_updates OS upgrade scripts + root cron via Ansible.

  --remove     Remove OS upgrade cron (os_upgrade_remove_cron=true)
  --schedule   Cron expression (default: 0 0 */3 * *)
  --tz         CRON_TZ (default: Australia/Sydney)
  HOST         Limit target (repeatable; passed as --limit a,b)

Set INVENTORY to an ini file, or pass ansible -i yourself by editing this script.
Example:
  INVENTORY=inventory/al2023-fail2ban.ini SSH_CONFIG=d:/wp-ansible/config $0 cccls
EOF
}

REMOVE=0
CRON_TZ="${CRON_TZ:-Australia/Sydney}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 0 */3 * *}"
HOSTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) REMOVE=1; shift ;;
    --schedule) CRON_SCHEDULE="$2"; shift 2 ;;
    --tz) CRON_TZ="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "At least one HOST is required." >&2
  usage
  exit 1
fi

if [[ -z "$INVENTORY" ]]; then
  echo "Set INVENTORY (e.g. inventory/al2023-fail2ban.ini) or use ansible-playbook directly." >&2
  exit 1
fi

LIMIT="$(IFS=,; echo "${HOSTS[*]}")"
EXTRA=(-e "os_upgrade_cron_tz=${CRON_TZ}" -e "os_upgrade_cron_schedule=${CRON_SCHEDULE}")

if [[ "$REMOVE" -eq 1 ]]; then
  EXTRA+=(-e os_upgrade_remove_cron=true)
else
  EXTRA+=(-e os_upgrade_enable_cron=true)
fi

export ANSIBLE_SSH_ARGS="${ANSIBLE_SSH_ARGS:-}"
if [[ -n "$SSH_CONFIG" ]]; then
  export ANSIBLE_ssh_common_args="-F ${SSH_CONFIG}"
fi

exec ansible-playbook -i "$INVENTORY" "$PLAYBOOK" --tags os_upgrade --limit "$LIMIT" "${EXTRA[@]}"
