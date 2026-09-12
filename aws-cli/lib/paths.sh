#!/usr/bin/env bash
# Shared paths for every script under aws-cli/. Source this file; do not execute it.
#
# From a script in aws-cli/<subdir>/:
#   # shellcheck source=../lib/paths.sh
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "source aws-cli/lib/paths.sh — do not execute it" >&2
  exit 1
fi

if [[ -n "${AWS_CLI_PATHS_LOADED:-}" ]]; then
  return 0
fi
AWS_CLI_PATHS_LOADED=1

_AWS_CLI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_CLI_ROOT="$(cd "${_AWS_CLI_LIB_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${AWS_CLI_ROOT}/.." && pwd)"

AWS_CLI_AUTH="${AWS_CLI_ROOT}/auth"
AWS_CLI_MIGRATE="${AWS_CLI_ROOT}/migrate"
AWS_CLI_DNS="${AWS_CLI_ROOT}/dns"
AWS_CLI_SSH="${AWS_CLI_ROOT}/ssh"
AWS_CLI_DOCS="${AWS_CLI_ROOT}/docs"
AWS_CLI_STATE="${AWS_CLI_STATE:-${AWS_CLI_ROOT}/state}"
AWS_CLI_DNS_RECORDS="${AWS_CLI_DNS}/records"

SSH_CONFIG="${SSH_CONFIG:-${REPO_ROOT}/ssh-config}"

mkdir -p "${AWS_CLI_STATE}" "${AWS_CLI_DNS_RECORDS}"
