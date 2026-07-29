#!/usr/bin/env bash
# List fail2ban blocked IPs across AL2023 WordPress hosts (ssh-config ~lines 250-443).
#
# Usage:
#   ./bash/list-fail2ban-blocked-ips.sh              # all hosts in section
#   ./bash/list-fail2ban-blocked-ips.sh cccls bateys # subset
#   ./bash/list-fail2ban-blocked-ips.sh --json       # JSON lines per host/jail
#   ./bash/list-fail2ban-blocked-ips.sh --summary    # unique IPs + host count
#   ./bash/list-fail2ban-blocked-ips.sh --hosts-only # host + IP from ssh-config only
#
# Env:
#   SSH_CONFIG   path to ssh config (default: repo ssh-config symlink)
#   START_LINE   first line of host section (default: 250)
#   END_LINE     last line of host section (default: 443)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_CONFIG="${SSH_CONFIG:-$REPO_ROOT/ssh-config}"
START_LINE="${START_LINE:-250}"
END_LINE="${END_LINE:-443}"

JSON=0
SUMMARY=0
HOSTS_ONLY=0
HOSTS=()

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --json) JSON=1; shift ;;
    --summary) SUMMARY=1; shift ;;
    --hosts-only) HOSTS_ONLY=1; shift ;;
    --) shift; HOSTS+=("$@"); break ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done

if [[ ! -f "$SSH_CONFIG" ]]; then
  echo "ERROR: SSH config not found: $SSH_CONFIG" >&2
  exit 1
fi

parse_section_hosts() {
  sed -n "${START_LINE},${END_LINE}p" "$SSH_CONFIG" | awk '
    /^Host / && $2 !~ /^[*?]$/ { print $2 }
  '
}

parse_hostname() {
  local host="$1"
  awk -v h="$host" '
    $1 == "Host" && $2 == h { found=1; next }
    found && $1 == "Host" { exit }
    found && $1 == "HostName" { print $2; exit }
  ' "$SSH_CONFIG"
}

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  while IFS= read -r h; do
    [[ -n "$h" ]] && HOSTS+=("$h")
  done < <(parse_section_hosts)
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "ERROR: no hosts found in $SSH_CONFIG lines $START_LINE-$END_LINE" >&2
  exit 1
fi

remote_banned_ips() {
  ssh -F "$SSH_CONFIG" -o ConnectTimeout=15 -o BatchMode=yes "$1" 'bash -s' <<'REMOTE'
set -uo pipefail

if ! command -v fail2ban-client &>/dev/null; then
  echo "__STATUS__ NO_FAIL2BAN"
  exit 0
fi

if ! sudo fail2ban-client ping &>/dev/null; then
  echo "__STATUS__ FAIL2BAN_DOWN"
  exit 0
fi

jails=$(sudo fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)
if [[ -z "${jails:-}" ]]; then
  echo "__STATUS__ NO_JAILS"
  exit 0
fi

echo "__STATUS__ OK"
while IFS= read -r jail; do
  [[ -z "$jail" ]] && continue
  line=$(sudo fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p' || true)
  if [[ -n "${line:-}" ]]; then
    for ip in $line; do
      printf '%s\t%s\n' "$jail" "$ip"
    done
  fi
done <<< "$jails"
REMOTE
}

# bash 3.x (macOS): no associative arrays — summary uses temp files
SUMMARY_TMP="$(mktemp)"
trap 'rm -f "$SUMMARY_TMP"' EXIT

print_hosts_only() {
  printf "%-28s %s\n" "HOST" "IP"
  printf "%-28s %s\n" "----" "--"
  for host in "${HOSTS[@]}"; do
    ip="$(parse_hostname "$host" || true)"
    printf "%-28s %s\n" "$host" "${ip:-?}"
  done
}

if [[ "$HOSTS_ONLY" -eq 1 ]]; then
  print_hosts_only
  exit 0
fi

for host in "${HOSTS[@]}"; do
  host_ip="$(parse_hostname "$host" || true)"
  output=""
  if ! output="$(remote_banned_ips "$host" 2>&1)"; then
    if [[ "$JSON" -eq 1 ]]; then
      jq -nc --arg host "$host" --arg ip "${host_ip:-}" --arg err "$output" \
        '{host:$host, server_ip:$ip, status:"ssh_error", error:$err, jails:[]}'
    else
      echo "========== $host (${host_ip:-?}) =========="
      echo "  SSH ERROR: $output"
    fi
    continue
  fi

  status="$(printf '%s\n' "$output" | sed -n 's/^__STATUS__ //p' | head -1)"
  body="$(printf '%s\n' "$output" | grep -v '^__STATUS__ ' || true)"

  if [[ "$JSON" -eq 1 ]]; then
    if [[ -z "$body" ]]; then
      jq -nc --arg host "$host" --arg ip "${host_ip:-}" --arg status "${status:-OK}" \
        '{host:$host, server_ip:$ip, status:$status, jails:[]}'
    else
      printf '%s\n' "$body" | jq -Rs --arg host "$host" --arg ip "${host_ip:-}" --arg status "${status:-OK}" '
        split("\n") | map(select(length > 0)) |
        group_by(split("\t")[0]) |
        map({
          jail: (.[0] | split("\t")[0]),
          ips: map(split("\t")[1])
        }) as $jails |
        {host:$host, server_ip:$ip, status:$status, jails:$jails}
      '
    fi
  else
    echo "========== $host (${host_ip:-?}) =========="
    case "${status:-OK}" in
      NO_FAIL2BAN) echo "  fail2ban: not installed"; continue ;;
      FAIL2BAN_DOWN) echo "  fail2ban: not running"; continue ;;
      NO_JAILS) echo "  fail2ban: no jails"; continue ;;
      OK)
        if [[ -z "$body" ]]; then
          echo "  (no banned IPs)"
        else
          current_jail=""
          while IFS=$'\t' read -r jail ip; do
            [[ -z "${jail:-}" || -z "${ip:-}" ]] && continue
            if [[ "$jail" != "$current_jail" ]]; then
              current_jail="$jail"
              echo "  [$jail]"
            fi
            echo "    $ip"
            printf '%s %s\n' "$ip" "$host" >> "$SUMMARY_TMP"
          done <<< "$body"
        fi
        ;;
      *) echo "  status: ${status:-unknown}" ;;
    esac
  fi
done

if [[ "$SUMMARY" -eq 1 && "$JSON" -eq 0 ]]; then
  echo ""
  echo "========== Summary (unique banned IPs) =========="
  if [[ ! -s "$SUMMARY_TMP" ]]; then
    echo "  (none)"
  else
    sort -t. -k1,1n -k2,2n -k3,3n -k4,4n "$SUMMARY_TMP" | awk '
      { ip=$1; $1=""; sub(/^ /,""); hosts[ip]=hosts[ip] $0 " " }
      END {
        for (ip in hosts) {
          n=split(hosts[ip], a, " ")
          list=""
          for (i=1; i<n; i++) list=list (list=="" ? "" : " ") a[i]
          printf "  %-15s  (%d host(s): %s)\n", ip, n-1, list
        }
      }
    ' | sort
  fi
fi
