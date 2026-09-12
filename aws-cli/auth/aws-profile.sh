#!/usr/bin/env bash
# Run any aws CLI command with a named login_session profile (auto-login if needed).
#
# Usage:
#   ./aws-cli/auth/aws-profile.sh <profile> <aws subcommand...>
#   ./aws-cli/auth/aws-profile.sh TongarraFamilyPractice lightsail get-instances
set -euo pipefail

usage() {
  echo "Usage: $0 <profile-or-account-query> <aws subcommand...>" >&2
  echo "Example: $0 TongarraFamilyPractice lightsail get-instances --region ap-southeast-2" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage

PROFILE="$1"
shift

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

if ! aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; then
  echo "No active session for profile '$PROFILE'; running aws login…" >&2
  "$AWS_CLI_AUTH/aws-login.sh" "$PROFILE"
fi

exec aws --profile "$PROFILE" "$@"
