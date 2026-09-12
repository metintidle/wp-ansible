#!/usr/bin/env bash
# Ensure an aws login session exists for a profile (browser opens once).
#
# Usage:
#   ./aws-cli/auth/aws-login.sh CamdenSurgery

set -euo pipefail

PROFILE="${1:?Usage: $0 <profile-name>}"

if aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; then
  echo "Profile ${PROFILE} already has an active session."
  aws sts get-caller-identity --profile "$PROFILE"
  exit 0
fi

echo "Opening browser for: aws login --profile ${PROFILE}"
aws login --profile "$PROFILE"
aws sts get-caller-identity --profile "$PROFILE"
