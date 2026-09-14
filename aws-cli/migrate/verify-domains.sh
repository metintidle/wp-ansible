#!/usr/bin/env bash
# Verify public DNS (A/AAAA) for every apex domain in state/.migrate-<host>.domains.
#
# Usage:
#   IPV4=1.2.3.4 IPV6=2406:... ./aws-cli/migrate/verify-domains.sh <profile> <ssh-host>
#   ./aws-cli/migrate/verify-domains.sh <profile> <ssh-host>   # reads IP from ssh-config / state
#
# Checks apex + www for each domain. Exits 1 if any record mismatches.

set -euo pipefail

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

PROFILE="${1:?profile required}"
HOST="${2:?ssh-host required}"
DOMAINS_FILE="$AWS_CLI_STATE/.migrate-${HOST}.domains"

resolve_ssh_config() {
  python3 -c "import os; print(os.path.realpath('${SSH_CONFIG}'))"
}

read_ssh() {
  local cfg k="$1"
  cfg="$(resolve_ssh_config)"
  awk -v host="$HOST" -v key="$1" '
    $1 == "Host" && $2 == host { in_host = 1; next }
    in_host && $1 == "Host" { exit }
    in_host && $1 == key { print $2; exit }
  ' "$cfg"
}

if [[ ! -f "$DOMAINS_FILE" ]]; then
  echo "Missing ${DOMAINS_FILE} — run discover-domains first" >&2
  exit 1
fi

IPV4="${IPV4:-}"
IPV6="${IPV6:-}"
if [[ -z "$IPV4" && -f "$AWS_CLI_STATE/.migrate-${HOST}.final-ip" ]]; then
  IPV4="$(cat "$AWS_CLI_STATE/.migrate-${HOST}.final-ip")"
fi
IPV4="${IPV4:-$(read_ssh HostName)}"

if [[ -z "$IPV6" ]]; then
  export AWS_PROFILE="$PROFILE"
  REGION="${REGION:-ap-southeast-2}"
  IPV6="$(aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "${NEW_INSTANCE_NAME:-wp-web-23}" \
    --query 'instance.ipv6Addresses[0]' \
    --output text 2>/dev/null || true)"
  [[ "$IPV6" == "None" ]] && IPV6=""
fi

if [[ -z "$IPV4" ]]; then
  echo "Could not resolve IPV4 for ${HOST}" >&2
  exit 1
fi

dig_val() {
  local name="$1" type="$2"
  dig +short "$name" "$type" 2>/dev/null | head -1 | tr -d '\r'
}

check_host() {
  local fqdn="$1" type="$2" want="$3"
  local got
  [[ -z "$want" ]] && return 0
  got="$(dig_val "$fqdn" "$type")"
  if [[ "$got" == "$want" ]]; then
    echo "  OK   ${fqdn} ${type} → ${got}"
    return 0
  fi
  echo "  FAIL ${fqdn} ${type} → ${got:-<missing>} (want ${want})" >&2
  return 1
}

echo "Verifying DNS for Host ${HOST} (expect IPv4=${IPV4}${IPV6:+, IPv6=${IPV6}})"
max_attempts="${VERIFY_DNS_ATTEMPTS:-6}"
attempt=1
while [[ "$attempt" -le "$max_attempts" ]]; do
  fail=0
  while IFS= read -r apex; do
    [[ -z "$apex" ]] && continue
    echo "${apex}:"
    check_host "$apex" A "$IPV4" || fail=1
    check_host "www.${apex}" A "$IPV4" || fail=1
    if [[ -n "$IPV6" ]]; then
      check_host "$apex" AAAA "$IPV6" || fail=1
      check_host "www.${apex}" AAAA "$IPV6" || fail=1
    fi
  done <"$DOMAINS_FILE"
  if [[ "$fail" -eq 0 ]]; then
    echo "All domains verified."
    exit 0
  fi
  if [[ "$attempt" -lt "$max_attempts" ]]; then
    echo "DNS not fully propagated (attempt ${attempt}/${max_attempts}); retrying in 30s…" >&2
    sleep 30
  fi
  attempt=$((attempt + 1))
done
echo "DNS verification failed for ${HOST}" >&2
exit 1
