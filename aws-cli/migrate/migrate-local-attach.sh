#!/usr/bin/env bash
# AL2 → AL2023 phase 1 using local AWS CLI (aws login profile), not CloudShell.
#
# Usage:
#   ./aws-cli/migrate/migrate-local-attach.sh <aws-profile> <ssh-host-alias> [ssh-config-path]
#
# Example:
#   ./aws-cli/migrate/migrate-local-attach.sh CamdenSurgery camden
#
# Reads HostName + IdentityFile from ssh-config, ensures aws login, runs migrate-attach.sh.
# Prefer ./aws-cli/migrate/migrate-al2-al2023.sh for the full flow.

set -euo pipefail

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

PROFILE="${1:?Usage: $0 <aws-profile> <ssh-host-alias> [ssh-config-path]}"
HOST_ALIAS="${2:?Usage: $0 <aws-profile> <ssh-host-alias> [ssh-config-path]}"
[[ $# -ge 3 ]] && SSH_CONFIG="$3"

if [[ ! -f "$SSH_CONFIG" ]]; then
  echo "ssh-config not found: $SSH_CONFIG" >&2
  exit 1
fi

read_ssh_value() {
  local key="$1"
  awk -v host="$HOST_ALIAS" -v k="$key" '
    $1 == "Host" && $2 == host { in_host = 1; next }
    in_host && $1 == "Host" { exit }
    in_host && $1 == k { print $2; exit }
  ' "$SSH_CONFIG"
}

SOURCE_PUBLIC_IP="$(read_ssh_value HostName)"
IDENTITY_FILE="$(read_ssh_value IdentityFile)"

if [[ -z "$SOURCE_PUBLIC_IP" || -z "$IDENTITY_FILE" ]]; then
  echo "Could not read HostName/IdentityFile for Host $HOST_ALIAS in $SSH_CONFIG" >&2
  exit 1
fi

IDENTITY_PATH="${IDENTITY_FILE/#\~/$HOME}"
if [[ ! -f "$IDENTITY_PATH" ]]; then
  echo "SSH key not found: $IDENTITY_PATH" >&2
  exit 1
fi

echo "Profile:        $PROFILE"
echo "Host alias:     $HOST_ALIAS"
echo "Source AL2 IP:   $SOURCE_PUBLIC_IP"
echo "Identity file:  $IDENTITY_PATH"
echo

"$AWS_CLI_AUTH/aws-profile.sh" "$PROFILE" sts get-caller-identity

SSH_KEY_PAIR_NAME="${HOST_ALIAS}-migrate"
SSH_PUBLIC_KEY_B64="$(ssh-keygen -y -f "$IDENTITY_PATH" | base64 | tr -d '\n')"

export AWS_PROFILE="$PROFILE"
export SOURCE_PUBLIC_IP
export SSH_KEY_PAIR_NAME
export SSH_PUBLIC_KEY_B64
export REGION="${REGION:-ap-southeast-2}"
export NEW_INSTANCE_NAME="${NEW_INSTANCE_NAME:-wp-web-23}"
export SSH_ALLOW_CIDRS="${SSH_ALLOW_CIDRS:-111.220.137.221/32,43.245.170.89/32,158.180.7.100/32}"

bash "$AWS_CLI_MIGRATE/migrate-attach.sh"

echo
echo "Phase 1 complete. Next steps:"
echo "  1. Update ssh-config Host $HOST_ALIAS to NEW_PUBLIC_IP from output above"
echo "  2. Move host block to AL2023 WordPress section"
echo "  3. ANSIBLE_SSH_ARGS=\"-F $SSH_CONFIG\" ansible-playbook -i '${HOST_ALIAS},' modules/1_nginx-php/playbook.yml"
echo "  4. Verify wp-config.php, then: ./aws-cli/migrate/migrate-local-detach.sh $PROFILE $HOST_ALIAS"
