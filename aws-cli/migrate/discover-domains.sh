#!/usr/bin/env bash
# Discover apex domains pointing at a migration host (AL2 static IP).
#
# Sources (merged, deduped):
#   1. Route53 A records in AWS_PROFILE account → IP
#   2. ssh-config comment above Host (# https://example.com/)
#   3. Optional SSH (USE_SSH=1): nginx server_name + WP siteurl/home
#
# Usage:
#   ./aws-cli/migrate/discover-domains.sh <profile> <ssh-host>
#   IPV4=3.104.213.239 ./aws-cli/migrate/discover-domains.sh <profile> <ssh-host>
#   ./aws-cli/migrate/discover-domains.sh <profile> <ssh-host> --write
#
# Output:
#   Prints one apex domain per line (first = primary).
#   With --write: also saves aws-cli/state/.migrate-<host>.domains

set -euo pipefail

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"
WRITE=false

PROFILE=""
HOST=""
for arg in "$@"; do
  case "$arg" in
    --write) WRITE=true ;;
    -h|--help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
    *)
      if [[ -z "$PROFILE" ]]; then PROFILE="$arg"
      elif [[ -z "$HOST" ]]; then HOST="$arg"
      fi
      ;;
  esac
done

PROFILE="${PROFILE:?profile required}"
HOST="${HOST:?ssh-host required}"

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

read_ssh_comment_domains() {
  local cfg
  cfg="$(resolve_ssh_config)"
  awk -v host="$HOST" '
    /^#/ {
      pending = $0
      next
    }
    /^Host / {
      if ($2 == host) {
        if (pending ~ /^# https?:\/\//) {
          gsub(/^# https?:\/\//, "", pending)
          gsub(/\/.*$/, "", pending)
          if (pending != "") print pending
        }
        exit
      }
      pending = ""
    }
  ' "$cfg"
}

normalize_domain() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E \
    's#^https?://##; s#/.*##; s/\.$//; s/^www\.//'
}

IPV4="${IPV4:-${SOURCE_PUBLIC_IP:-}}"
if [[ -z "$IPV4" ]]; then
  IPV4="$(read_ssh HostName)"
fi
if [[ -z "$IPV4" ]]; then
  echo "Could not resolve IPv4 for Host ${HOST}" >&2
  exit 1
fi

export AWS_PROFILE="$PROFILE"
REGION="${REGION:-ap-southeast-2}"

discover_route53() {
  local ip="$1"
  aws route53 list-hosted-zones \
    --query 'HostedZones[*].Id' \
    --output text 2>/dev/null | tr '\t' '\n' | while read -r zone_id; do
      [[ -z "$zone_id" || "$zone_id" == "None" ]] && continue
      zone_id="${zone_id##*/}"
      aws route53 list-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --query "ResourceRecordSets[?Type=='A' && ResourceRecords[0].Value=='${ip}'].Name" \
        --output text 2>/dev/null | tr '\t' '\n' | while IFS= read -r name; do
          [[ -z "$name" || "$name" == "None" ]] && continue
          normalize_domain "$name"
          echo
        done
    done
}

discover_ssh() {
  ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" 'bash -s' <<'EOF' 2>/dev/null || true
set -euo pipefail
domains=()
add() {
  local d="${1,,}"
  d="${d%.}"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  d="${d#www.}"
  [[ -z "$d" || "$d" == "_" || "$d" == *" "* ]] && return
  domains+=("$d")
}

if [[ -f /etc/nginx/nginx.conf ]]; then
  while read -r token; do
    [[ "$token" == _ ]] && continue
    add "$token"
  done < <(grep -oE 'server_name[[:space:]]+[^;]+' /etc/nginx/nginx.conf 2>/dev/null | sed 's/server_name[[:space:]]\+//' | tr ' ' '\n')
fi

for root in /home/ec2-user/html /usr/share/nginx/html; do
  if [[ -x /usr/local/bin/wp && -f "$root/wp-config.php" ]]; then
    add "$(/usr/local/bin/wp option get siteurl --path="$root" 2>/dev/null || true)"
    add "$(/usr/local/bin/wp option get home --path="$root" 2>/dev/null || true)"
  fi
done

printf '%s\n' "${domains[@]}" | sort -u
EOF
}

merge_domains() {
  local tmp primary line
  tmp="$(mktemp)"
  {
    read_ssh_comment_domains || true
    discover_route53 "$IPV4" || true
    if [[ "${USE_SSH:-0}" == "1" ]]; then
      discover_ssh || true
    fi
  } | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    normalize_domain "$line"
    echo
  done | sort -u >"$tmp"

  primary="$(read_ssh_comment_domains | head -1 | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    normalize_domain "$line"
  done)"
  if [[ -n "$primary" ]] && grep -qx "$primary" "$tmp" 2>/dev/null; then
    echo "$primary"
    grep -vx "$primary" "$tmp" 2>/dev/null || true
  else
    cat "$tmp"
  fi
  rm -f "$tmp"
}

DOMAINS="$(merge_domains | awk 'NF')"
if [[ -z "$DOMAINS" ]]; then
  echo "No domains found for ${HOST} @ ${IPV4}" >&2
  echo "Hint: pass primary domain as 3rd arg to ./aws-cli/migrate/migrate-al2-al2023.sh" >&2
  exit 1
fi

echo "# Host ${HOST} @ ${IPV4}" >&2
echo "$DOMAINS" | nl -w1 -s'. ' >&2

echo "$DOMAINS"

if $WRITE; then
  out="$AWS_CLI_STATE/.migrate-${HOST}.domains"
  printf '%s\n' "$DOMAINS" >"$out"
  echo "Wrote ${out}" >&2
fi
