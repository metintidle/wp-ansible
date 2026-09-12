#!/usr/bin/env bash
# Add or update an aws login profile in ~/.aws/config (no npm, no vault file).
#
# Usage:
#   ./aws-cli/auth/setup-profile.sh <profile-name> <account-id> <iam-username> [region]
#
# Example (Camden Surgery):
#   ./aws-cli/auth/setup-profile.sh CamdenSurgery 122610501814 CamdenSurgery

set -euo pipefail

PROFILE="${1:?profile-name required}"
ACCOUNT_ID="${2:?account-id required}"
IAM_USER="${3:?iam-username required}"
REGION="${4:-ap-southeast-2}"

AWS_CONFIG="${HOME}/.aws/config"
mkdir -p "${HOME}/.aws"

if [[ -f "$AWS_CONFIG" ]]; then
  cp "$AWS_CONFIG" "${AWS_CONFIG}.bak.$(date +%Y%m%dT%H%M%S)"
fi

BLOCK="[profile ${PROFILE}]
region = ${REGION}
output = json
login_session = arn:aws:iam::${ACCOUNT_ID}:user/${IAM_USER}
"

if [[ -f "$AWS_CONFIG" ]] && grep -q "^\[profile ${PROFILE}\]" "$AWS_CONFIG"; then
  echo "Profile ${PROFILE} already exists in ${AWS_CONFIG}"
else
  printf '\n%s\n' "$BLOCK" >> "$AWS_CONFIG"
  echo "Added profile ${PROFILE} to ${AWS_CONFIG}"
fi

echo
echo "Next:"
echo "  aws login --profile ${PROFILE}"
echo "  export AWS_PROFILE=${PROFILE}"
echo "  aws sts get-caller-identity"
