#!/usr/bin/env bash
# AL2 → AL2023 phase 2 using local AWS CLI — after nginx-php Ansible has copied site files.
#
# Usage:
#   ./aws-cli/migrate/migrate-local-detach.sh <aws-profile> <ssh-host-alias> [original-al2-ip]
#
# If original AL2 IP is omitted, reads current HostName from ssh-config (must still be the
# pre-cutover AL2 IP, or pass it explicitly).
# Prefer ./aws-cli/migrate/migrate-al2-al2023.sh for the full flow.

set -euo pipefail

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

PROFILE="${1:?Usage: $0 <aws-profile> <ssh-host-alias> [original-al2-ip]}"
HOST_ALIAS="${2:?Usage: $0 <aws-profile> <ssh-host-alias> [original-al2-ip]}"

SOURCE_PUBLIC_IP="${3:-}"
if [[ -z "$SOURCE_PUBLIC_IP" ]]; then
  SOURCE_PUBLIC_IP="$(awk -v host="$HOST_ALIAS" '
    $1 == "Host" && $2 == host { in_host = 1; next }
    in_host && $1 == "Host" { exit }
    in_host && $1 == "HostName" { print $2; exit }
  ' "$SSH_CONFIG")"
fi

if [[ -z "$SOURCE_PUBLIC_IP" ]]; then
  echo "Could not determine SOURCE_PUBLIC_IP for Host $HOST_ALIAS" >&2
  exit 1
fi

echo "Profile:        $PROFILE"
echo "Host alias:     $HOST_ALIAS"
echo "Source AL2 IP:  $SOURCE_PUBLIC_IP"
echo

"$AWS_CLI_AUTH/aws-profile.sh" "$PROFILE" sts get-caller-identity

export AWS_PROFILE="$PROFILE"
export SOURCE_PUBLIC_IP
export REGION="${REGION:-ap-southeast-2}"
export NEW_INSTANCE_NAME="${NEW_INSTANCE_NAME:-wp-web-23}"

bash "$AWS_CLI_MIGRATE/migrate-detach.sh"

echo
echo "Phase 2 complete. Update ssh-config HostName to STATIC_IP from output, then run:"
echo "  ANSIBLE_SSH_ARGS=\"-F $SSH_CONFIG\" ansible-playbook -i '${HOST_ALIAS},' modules/5_security/playbook-fail2ban.yml"
echo "  ANSIBLE_SSH_ARGS=\"-F $SSH_CONFIG\" ansible-playbook -i '${HOST_ALIAS},' modules/3_ssl/playbook.yml -e domain_name=camdensurgery.com.au"
