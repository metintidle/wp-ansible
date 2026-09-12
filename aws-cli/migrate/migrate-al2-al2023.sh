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
#   discover-domains — list/save apex domains for AL2 IP (Route53, ssh-config, nginx/WP)
#   attach  — create AL2023 + snapshot AL2 + attach rescue disk (checks static IP on AL2)
#   nginx   — modules/1_nginx-php/playbook.yml
#   plugins — BBQ Firewall + SQLite Object Cache, auto-updates, lock BBQ (mu-plugin)
#   detach  — detach disk, move static IP AL2→AL2023, delete AL2
#   dns     — update Route53 A/AAAA to final static IP
#   ssl       — modules/3_ssl/playbook.yml (run after static IP + DNS)
#   fail2ban  — modules/5_security/playbook-fail2ban.yml
#   ssh-config — move Host block to AL2023 WordPress section + OS update cron tag
#   cleanup   — delete migration disk/instance snapshots (al2-rescue, AL2 instance snapshots)
#   all       — attach → nginx → (pause) → plugins → detach → dns → ssl → fail2ban → ssh-config → cleanup
#
# Camden example:
#   ./aws-cli/migrate/migrate-al2-al2023.sh CamdenSurgery camden camdensurgery.com.au

set -euo pipefail

PROFILE="${1:?profile required}"
HOST="${2:?ssh Host alias required}"
ARG3="${3:-}"
ARG4="${4:-}"

KNOWN_PHASES='^(attach|nginx|plugins|detach|dns|ssl|fail2ban|ssh-config|cleanup|discover-domains|all)$'
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
  "$AWS_CLI_MIGRATE/discover-domains.sh" "$PROFILE" "$HOST" --write
  DOMAIN="$(head -1 "$MIGRATE_DOMAINS")"
  echo "Primary domain: ${DOMAIN}"
  echo "All domains:"
  cat "$MIGRATE_DOMAINS"
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
    --instance-name "${NEW_INSTANCE_NAME:-wp-web-23}" \
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
  ensure_domains
  local ip="${1:-}"
  if [[ -z "$ip" && -f "$MIGRATE_FINAL_IP" ]]; then
    ip="$(cat "$MIGRATE_FINAL_IP")"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(read_ssh HostName)"
  fi
  IPV6=$(aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "${NEW_INSTANCE_NAME:-wp-web-23}" \
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
}

do_ssl() {
  ensure_domains
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

case "$PHASE" in
  discover-domains) do_discover_domains ;;
  attach) do_attach ;;
  nginx)  do_nginx ;;
  plugins) do_plugins ;;
  detach) do_detach ;;
  dns)    do_dns ;;
  ssl)      do_ssl ;;
  fail2ban) do_fail2ban ;;
  ssh-config) do_ssh_config_section ;;
  cleanup)  do_cleanup ;;
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
    ;;
  *)
    echo "Unknown phase: $PHASE (use discover-domains|attach|nginx|plugins|detach|dns|ssl|fail2ban|ssh-config|cleanup|all)" >&2
    exit 1
    ;;
esac
