#!/usr/bin/env bash
# DreamScape Reseller API — list customer domains and DNS (migration planning).
#
# Usage:
#   ./aws-cli/dns/dreamscape-fetch.sh list-customers [query]
#   ./aws-cli/dns/dreamscape-fetch.sh fetch [--write-domains <file>]
#
# Credentials (gitignored aws-cli/dreamscape.env):
#   DREAMSCAPE_API_KEY=...
#   DREAMSCAPE_RESELLER_ID=...   # optional; logged for reference only
#   DREAMSCAPE_API_BASE=https://reseller-api.ds.network
#
# Customer selection:
#   DREAMSCAPE_CUSTOMER_ID=12345
#   DREAMSCAPE_CUSTOMER_QUERY=corrimal   # username/email/business name substring
#
# Docs: https://doc-reseller-api.ds.network/swagger

set -euo pipefail

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

load_dreamscape_env() {
  local envf="$AWS_CLI_ROOT/dreamscape.env"
  if [[ -f "$envf" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$envf"
    set +a
  fi
  if [[ -z "${DREAMSCAPE_API_KEY:-}" ]]; then
    echo "ERROR: DREAMSCAPE_API_KEY not set. Copy aws-cli/dreamscape.env.example → aws-cli/dreamscape.env" >&2
    exit 1
  fi
}

usage() {
  sed -n '1,22p' "$0"
}

CMD="${1:-}"
shift || true

load_dreamscape_env

case "$CMD" in
  list-customers)
    exec python3 "$AWS_CLI_LIB/dreamscape-api.py" list-customers "${1:-}"
    ;;
  fetch)
    WRITE_DOMAINS=""
    JSON_OUT="${DREAMSCAPE_JSON_OUT:-}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --write-domains)
          WRITE_DOMAINS="${2:?}"
          shift 2
          ;;
        --json-out)
          JSON_OUT="${2:?}"
          shift 2
          ;;
        *)
          echo "Unknown option: $1" >&2
          usage >&2
          exit 1
          ;;
      esac
    done
    args=(fetch)
    if [[ -n "${DREAMSCAPE_CUSTOMER_ID:-}" ]]; then
      args+=(--customer-id "$DREAMSCAPE_CUSTOMER_ID")
    fi
    if [[ -n "${DREAMSCAPE_CUSTOMER_QUERY:-}" ]]; then
      args+=(--customer-query "$DREAMSCAPE_CUSTOMER_QUERY")
    fi
    [[ -n "$JSON_OUT" ]] && args+=(--json-out "$JSON_OUT")
    [[ -n "$WRITE_DOMAINS" ]] && args+=(--domains-out "$WRITE_DOMAINS")
    exec python3 "$AWS_CLI_LIB/dreamscape-api.py" "${args[@]}"
    ;;
  -h|--help|help|"")
    usage
    [[ -n "$CMD" ]] || exit 0
    exit 1
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac
