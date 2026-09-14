#!/usr/bin/env bash
# AL2 → AL2023 migration using aws-cli only (no auto-aws / npm).
#
# Usage:
#   ./aws-cli/migrate/migrate-al2-al2023.sh <profile> <ssh-host> [domain] [phase]
#
# If domain is omitted, runs discover-domains (Route53 + ssh-config + nginx/WP on host).
# Saves aws-cli/state/.migrate-<host>.domains — used for dns + ssl (up to 4 apex domains).
#
# Phases:
#   discover-domains — list/save apex domains for AL2 IP (Route53 A/AAAA, ssh-config, nginx/WP)
#   verify-domains — check A/AAAA for every domain in state/.migrate-<host>.domains
#   attach  — create AL2023 + snapshot AL2 + attach rescue disk (checks static IP on AL2)
#   nginx   — modules/1_nginx-php/playbook.yml
#   plugins — BBQ Firewall + SQLite Object Cache, auto-updates, lock BBQ (mu-plugin)
#   detach  — detach disk, move static IP AL2→AL2023, delete AL2
#   dns     — update Route53 A/AAAA to final static IP
#   ssl       — modules/3_ssl/playbook.yml (run after static IP + DNS)
#   fail2ban  — modules/5_security/playbook-fail2ban.yml
#   ssh-config — move Host block to AL2023 WordPress section + OS update cron tag
#   cleanup   — delete migration disk/instance snapshots (al2-rescue, AL2 instance snapshots)
#   backup    — modules/9_backup/playbook.yml (root cron site backup)
#   snapshot  — one Lightsail instance snapshot of AL2023 (after site HTTP 2xx)
#   all       — attach → nginx → (pause) → plugins → detach → dns → ssl → fail2ban → ssh-config → cleanup → backup → (pause) → snapshot
#
# Camden example:
#   ./aws-cli/migrate/migrate-al2-al2023.sh CamdenSurgery camden camdensurgery.com.au

set -euo pipefail

PROFILE="${1:?profile required}"
HOST="${2:?ssh Host alias required}"
ARG3="${3:-}"
ARG4="${4:-}"

KNOWN_PHASES='^(attach|nginx|plugins|detach|dns|verify-domains|ssl|fail2ban|ssh-config|cleanup|backup|snapshot|discover-domains|all)$'
if [[ "$ARG3" =~ $KNOWN_PHASES ]]; then
  DOMAIN=""
  PHASE="$ARG3"
elif [[ -n "$ARG3" ]]; then
  DOMAIN="$ARG3"
  PHASE="${ARG4:-all}"
else
  DOMAIN=""
  PHASE="${ARG4:-all}"
  [[ -z "$ARG4" ]] && PHASE="all"
fi

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"
MIGRATE_STATE="$AWS_CLI_STATE/.migrate-${HOST}.al2-ip"
MIGRATE_AL2_INSTANCE="$AWS_CLI_STATE/.migrate-${HOST}.al2-instance"
MIGRATE_DOMAINS="$AWS_CLI_STATE/.migrate-${HOST}.domains"
MIGRATE_FINAL_IP="$AWS_CLI_STATE/.migrate-${HOST}.final-ip"
DISK_SNAPSHOT_NAME="${DISK_SNAPSHOT_NAME:-al2-rescue}"
NEW_INSTANCE_NAME="${NEW_INSTANCE_NAME:-wp-web-23}"
INSTANCE_SNAPSHOT_NAME="${INSTANCE_SNAPSHOT_NAME:-${HOST}-al2023}"

resolve_ssh_config() {
  python3 -c "import os; print(os.path.realpath('${SSH_CONFIG}'))"
}

read_ssh() {
  local cfg
  cfg="$(resolve_ssh_config)"
  awk -v host="$HOST" -v k="$1" '
    $1 == "Host" && $2 == host { in_host = 1; next }
    in_host && $1 == "Host" { exit }
    in_host && $1 == k { print $2; exit }
  ' "$cfg"
}

set_ssh_ip() {
  local ip="$1"
  local cfg
  cfg="$(resolve_ssh_config)"
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "/^Host ${HOST}$/,/^Host / s/^[[:space:]]*HostName .*/    HostName ${ip}/" "$cfg"
  else
    sed -i "/^Host ${HOST}$/,/^Host / s/^[[:space:]]*HostName .*/    HostName ${ip}/" "$cfg"
  fi
  echo "ssh-config Host ${HOST} → ${ip} (${cfg})"
}

SOURCE_IP="$(read_ssh HostName)"
IDENTITY="$(read_ssh IdentityFile)"
IDENTITY_PATH="${IDENTITY/#\~/$HOME}"

if [[ -z "$SOURCE_IP" || -z "$IDENTITY_PATH" ]]; then
  echo "Host $HOST not found in $SSH_CONFIG" >&2
  exit 1
fi

export AWS_PROFILE="$PROFILE"
export REGION="${REGION:-ap-southeast-2}"
export SOURCE_PUBLIC_IP="$SOURCE_IP"
# Camden (and most Lightsail hosts) use ~/.ssh/<site>.pem which is LightsailDefaultKeyPair.
export SSH_KEY_PAIR_NAME="${SSH_KEY_PAIR_NAME:-LightsailDefaultKeyPair}"

load_domains() {
  if [[ -n "${DOMAIN:-}" ]]; then
    printf '%s\n' "$DOMAIN"
    return 0
  fi
  if [[ -f "$MIGRATE_DOMAINS" ]]; then
    cat "$MIGRATE_DOMAINS"
    return 0
  fi
  do_discover_domains >/dev/null
  cat "$MIGRATE_DOMAINS"
}

ensure_domains() {
  if [[ -n "${DOMAIN:-}" ]]; then
    printf '%s\n' "$DOMAIN" >"$MIGRATE_DOMAINS"
    return 0
  fi
  if [[ ! -f "$MIGRATE_DOMAINS" ]]; then
    do_discover_domains
  fi
  DOMAIN="$(head -1 "$MIGRATE_DOMAINS")"
  if [[ -z "$DOMAIN" ]]; then
    echo "No domains found. Run: ./aws-cli/migrate/discover-domains.sh ${PROFILE} ${HOST} --write" >&2
    exit 1
  fi
}

do_discover_domains() {
  export IPV4="${SOURCE_PUBLIC_IP:-$(read_ssh HostName)}"
  "$AWS_CLI_AUTH/aws-login.sh" "$PROFILE"
  USE_SSH="${USE_SSH:-1}" "$AWS_CLI_MIGRATE/discover-domains.sh" "$PROFILE" "$HOST" --write
  DOMAIN="$(head -1 "$MIGRATE_DOMAINS")"
  echo "Primary domain: ${DOMAIN}"
  echo "All domains:"
  cat "$MIGRATE_DOMAINS"
}

refresh_domains() {
  local ip old merged
  old="$(mktemp)"
  merged="$(mktemp)"
  if [[ -f "$MIGRATE_DOMAINS" ]]; then
    cat "$MIGRATE_DOMAINS" >"$old"
  fi
  if [[ -f "$MIGRATE_FINAL_IP" ]]; then
    ip="$(cat "$MIGRATE_FINAL_IP")"
  else
    ip="$(read_ssh HostName)"
  fi
  export IPV4="$ip"
  "$AWS_CLI_AUTH/aws-login.sh" "$PROFILE"
  USE_SSH=1 "$AWS_CLI_MIGRATE/discover-domains.sh" "$PROFILE" "$HOST" --write
  cat "$MIGRATE_DOMAINS" >"$merged"
  if [[ -s "$old" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      grep -qx "$d" "$merged" 2>/dev/null || echo "$d" >>"$merged"
    done <"$old"
    sort -u "$merged" -o "$MIGRATE_DOMAINS"
  fi
  rm -f "$old" "$merged"
  DOMAIN="$(head -1 "$MIGRATE_DOMAINS")"
  echo "Refreshed domains ($(wc -l <"$MIGRATE_DOMAINS" | tr -d ' ') apex — see ${MIGRATE_DOMAINS}):"
  cat "$MIGRATE_DOMAINS"
}

do_verify_domains() {
  local ip="${1:-}"
  if [[ -z "$ip" && -f "$MIGRATE_FINAL_IP" ]]; then
    ip="$(cat "$MIGRATE_FINAL_IP")"
  fi
  ip="${ip:-$(read_ssh HostName)}"
  IPV4="$ip" "$AWS_CLI_MIGRATE/verify-domains.sh" "$PROFILE" "$HOST"
}

ansible_run() {
  local playbook="$1"
  shift
  local cfg
  cfg="$(resolve_ssh_config)"
  ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_SSH_ARGS="-F $cfg" \
    ansible-playbook -i "${HOST}," "$playbook" "$@" \
    -e "ansible_ssh_private_key_file=${IDENTITY_PATH}"
}

do_attach() {
  ensure_domains
  echo "$SOURCE_IP" > "$MIGRATE_STATE"
  "$AWS_CLI_AUTH/aws-login.sh" "$PROFILE"
  export SOURCE_PUBLIC_IP="$SOURCE_IP"
  bash "$AWS_CLI_MIGRATE/check-static-ip.sh"
  ATTACH_OUT="$(bash "$AWS_CLI_MIGRATE/attach-disk-new.sh" 2>&1 | tee /dev/stderr)"
  AL2_NAME="$(echo "$ATTACH_OUT" | sed -n 's/^INSTANCE_NAME_AL2=//p' | tail -1)"
  if [[ -n "$AL2_NAME" ]]; then
    echo "$AL2_NAME" > "$MIGRATE_AL2_INSTANCE"
  fi
  NEW_IP=$(aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "$NEW_INSTANCE_NAME" \
    --query 'instance.publicIpAddress' \
    --output text)
  set_ssh_ip "$NEW_IP"
  echo "Attach done. NEW_PUBLIC_IP=${NEW_IP}"
}

do_nginx() {
  ansible_run "$REPO_ROOT/modules/1_nginx-php/playbook.yml"
}

do_plugins() {
  ansible_run "$REPO_ROOT/modules/2_wordpress/playbook-core-plugins.yml"
}

do_detach() {
  if [[ -f "$MIGRATE_STATE" ]]; then
    export SOURCE_PUBLIC_IP="$(cat "$MIGRATE_STATE")"
    echo "Using original AL2 IP from ${MIGRATE_STATE}: ${SOURCE_PUBLIC_IP}"
  fi
  if [[ -f "$MIGRATE_AL2_INSTANCE" ]]; then
    export INSTANCE_NAME_AL2="$(cat "$MIGRATE_AL2_INSTANCE")"
    export MIGRATE_AL2_INSTANCE_FILE="$MIGRATE_AL2_INSTANCE"
    echo "Using AL2 instance name from ${MIGRATE_AL2_INSTANCE}: ${INSTANCE_NAME_AL2}"
  fi
  "$AWS_CLI_AUTH/aws-login.sh" "$PROFILE"
  DETACH_OUT="$(bash "$AWS_CLI_MIGRATE/migrate-detach.sh" 2>&1 | tee /dev/stderr)"
  AL2_NAME="$(echo "$DETACH_OUT" | sed -n 's/^INSTANCE_NAME_AL2=//p' | tail -1)"
  if [[ -n "$AL2_NAME" && "$AL2_NAME" != "missing" ]]; then
    echo "$AL2_NAME" > "$MIGRATE_AL2_INSTANCE"
  fi
  STATIC_IP="$(echo "$DETACH_OUT" | sed -n 's/^STATIC_IP=//p' | tail -1)"
  if [[ -z "$STATIC_IP" ]]; then
    echo "ERROR: migrate-detach did not output STATIC_IP" >&2
    exit 1
  fi
  set_ssh_ip "$STATIC_IP"
  echo "$STATIC_IP" > "$MIGRATE_FINAL_IP"
  echo "Detach done. Static IP: ${STATIC_IP}"
}

do_dns() {
  refresh_domains
  local ip="${1:-}"
  if [[ -z "$ip" && -f "$MIGRATE_FINAL_IP" ]]; then
    ip="$(cat "$MIGRATE_FINAL_IP")"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(read_ssh HostName)"
  fi
  IPV6=$(aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "$NEW_INSTANCE_NAME" \
    --query 'instance.ipv6Addresses[0]' \
    --output text 2>/dev/null || true)
  export AWS_PROFILE="$PROFILE"
  export IPV4="$ip"
  export IPV6="${IPV6:-}"
  local d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    export DOMAIN="$d"
    "$AWS_CLI_DNS/dns-manage.sh" upsert-records
    echo "DNS updated: ${d} → ${ip}"
  done < <(load_domains)
  do_verify_domains "$ip"
}

do_ssl() {
  refresh_domains
  local -a domains=()
  local -a extra=()
  local i d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    domains+=("$d")
  done < <(load_domains)
  if [[ ${#domains[@]} -eq 0 ]]; then
    echo "No domains for SSL" >&2
    exit 1
  fi
  if [[ ${#domains[@]} -gt 4 ]]; then
    echo "WARN: SSL playbook supports 4 apex domains; using first 4 of ${#domains[@]}" >&2
  fi
  extra=(-e "domain_name=${domains[0]}")
  for i in 1 2 3; do
    [[ ${#domains[@]} -gt $i ]] && extra+=(-e "domain_name${i}=${domains[$i]}")
  done
  ansible_run "$REPO_ROOT/modules/3_ssl/playbook.yml" \
    "${extra[@]}" \
    -e "install_wp_agent=false"
}

do_fail2ban() {
  ansible_run "$REPO_ROOT/modules/5_security/playbook-fail2ban.yml"
}

do_ssh_config_section() {
  local ip=""
  if [[ -f "$MIGRATE_FINAL_IP" ]]; then
    ip="$(cat "$MIGRATE_FINAL_IP")"
  else
    ip="$(read_ssh HostName)"
  fi
  python3 "$AWS_CLI_SSH/move-ssh-host-al2023.py" "$(resolve_ssh_config)" "$HOST" "$ip"
}

do_backup() {
  ansible_run "$REPO_ROOT/modules/9_backup/playbook.yml"
}

do_cleanup() {
  "$AWS_CLI_AUTH/aws-login.sh" "$PROFILE"

  if aws lightsail get-disk-snapshot \
    --region "$REGION" \
    --disk-snapshot-name "$DISK_SNAPSHOT_NAME" \
    --query 'diskSnapshot.name' \
    --output text >/dev/null 2>&1; then
    echo "Deleting disk snapshot ${DISK_SNAPSHOT_NAME}…"
    aws lightsail delete-disk-snapshot \
      --region "$REGION" \
      --disk-snapshot-name "$DISK_SNAPSHOT_NAME"
  else
    echo "Disk snapshot ${DISK_SNAPSHOT_NAME} not found (skip)"
  fi

  local al2_name=""
  if [[ -f "$MIGRATE_AL2_INSTANCE" ]]; then
    al2_name="$(cat "$MIGRATE_AL2_INSTANCE")"
  fi

  if [[ -n "$al2_name" ]]; then
    instance_snaps=$(aws lightsail get-instance-snapshots \
      --region "$REGION" \
      --query "instanceSnapshots[?fromInstanceName=='${al2_name}'].name" \
      --output text)

    if [[ -n "$instance_snaps" && "$instance_snaps" != "None" ]]; then
      for snap in $instance_snaps; do
        echo "Deleting instance snapshot ${snap} (from ${al2_name})…"
        aws lightsail delete-instance-snapshot \
          --region "$REGION" \
          --instance-snapshot-name "$snap"
      done
    else
      echo "No instance snapshots for ${al2_name} (skip)"
    fi
  else
    echo "AL2 instance name unknown — skip instance snapshot cleanup"
    echo "Run: aws lightsail get-instance-snapshots --region ${REGION} --output table"
  fi

  echo "Snapshot cleanup done."
}

wait_instance_snapshot_state() {
  local name="$1"
  local want="$2"
  local attempt=0
  local state="missing"
  echo "Waiting for instance snapshot ${name} to reach state ${want}…"
  while [ "$attempt" -lt 120 ]; do
    state=$(aws lightsail get-instance-snapshot \
      --region "$REGION" \
      --instance-snapshot-name "$name" \
      --query 'instanceSnapshot.state' \
      --output text 2>/dev/null || echo "missing")
    if [ "$state" = "$want" ]; then
      echo "Instance snapshot ${name} is ${want}"
      return 0
    fi
    if [ "$state" = "error" ]; then
      echo "ERROR: instance snapshot ${name} entered error state" >&2
      exit 1
    fi
    sleep 15
    attempt=$((attempt + 1))
  done
  echo "TIMEOUT: instance snapshot ${name} did not reach state ${want} (last: ${state})" >&2
  exit 1
}

check_website_loading() {
  ensure_domains
  local d host code fail=0
  echo "Checking website HTTP response…"
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    for host in "$d" "www.${d}"; do
      code=$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 30 "https://${host}/" || true)
      [[ -z "$code" ]] && code="000"
      echo "  https://${host}/ → HTTP ${code}"
      case "$code" in
        2*) ;;
        *) fail=1 ;;
      esac
    done
  done < <(load_domains)
  if [[ "$fail" -ne 0 ]]; then
    echo "ERROR: website is not loading correctly (expected HTTP 2xx). Fix the site, then re-run snapshot." >&2
    exit 1
  fi
}

do_snapshot() {
  local snap="$INSTANCE_SNAPSHOT_NAME"
  local existing=""
  local instance_state=""

  check_website_loading
  "$AWS_CLI_AUTH/aws-login.sh" "$PROFILE"

  instance_state=$(aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "$NEW_INSTANCE_NAME" \
    --query 'instance.state.name' \
    --output text 2>/dev/null || echo "missing")
  if [[ "$instance_state" != "running" ]]; then
    echo "ERROR: ${NEW_INSTANCE_NAME} is ${instance_state}, expected running" >&2
    exit 1
  fi

  existing=$(aws lightsail get-instance-snapshots \
    --region "$REGION" \
    --query "instanceSnapshots[?fromInstanceName=='${NEW_INSTANCE_NAME}' && !starts_with(name, 'AutomaticSnapshot-')].name" \
    --output text 2>/dev/null || true)

  if [[ -n "$existing" && "$existing" != "None" ]]; then
    echo "New instance ${NEW_INSTANCE_NAME} already has a snapshot (${existing}) — keeping this one only"
    for snap_name in $existing; do
      wait_instance_snapshot_state "$snap_name" "available"
    done
    return 0
  fi

  echo "Creating one instance snapshot ${snap} from ${NEW_INSTANCE_NAME}…"
  aws lightsail create-instance-snapshot \
    --region "$REGION" \
    --instance-name "$NEW_INSTANCE_NAME" \
    --instance-snapshot-name "$snap"
  wait_instance_snapshot_state "$snap" "available"
  echo "Snapshot done: ${snap} (from ${NEW_INSTANCE_NAME})"
}

case "$PHASE" in
  discover-domains) do_discover_domains ;;
  attach) do_attach ;;
  nginx)  do_nginx ;;
  plugins) do_plugins ;;
  detach) do_detach ;;
  dns)    do_dns ;;
  verify-domains) do_verify_domains ;;
  ssl)      do_ssl ;;
  fail2ban) do_fail2ban ;;
  ssh-config) do_ssh_config_section ;;
  cleanup)  do_cleanup ;;
  backup)   do_backup ;;
  snapshot) do_snapshot ;;
  all)
    do_discover_domains
    do_attach
    do_nginx
    read -r -p "Verify wp-config.php on ${HOST}, then press Enter to install plugins and cut over static IP…"
    do_plugins
    do_detach
    do_dns
    do_ssl
    do_fail2ban
    do_ssh_config_section
    do_cleanup
    do_backup
    echo "All migration tasks finished. Confirm the site loads in a browser:"
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      echo "  https://${d}/"
    done < <(load_domains)
    read -r -p "When the website is loading correctly, press Enter to create one Lightsail snapshot of ${NEW_INSTANCE_NAME}…"
    do_snapshot
    ;;
  *)
    echo "Unknown phase: $PHASE (use discover-domains|attach|nginx|plugins|detach|dns|verify-domains|ssl|fail2ban|ssh-config|cleanup|backup|snapshot|all)" >&2
    exit 1
    ;;
esac
