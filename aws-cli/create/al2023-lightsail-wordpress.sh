#!/usr/bin/env bash
# Create a new AL2023 Lightsail WordPress site (AWS CLI + Ansible).
#
# Usage:
#   ./aws-cli/create/al2023-lightsail-wordpress.sh <profile> <ssh-host> [domain] [phase]
#
# Phases:
#   create    — Lightsail AL2023 instance (amazon_linux_2023 / nano_3_2)
#   ports     — TCP 22 limited to SSH_ALLOW_CIDRS; 80/443 open; static IP
#   ssh-config — add Host block + wait until SSH answers
#   dns       — Route53 hosted zone(s) + apex/www A (and AAAA) records
#   nginx     — modules/1_nginx-php/playbook.yml (fresh stack, skip rescue disk)
#   wordpress — modules/2_wordpress/playbook.yml (prompts for db_name + table_prefix)
#   all       — create → ports → ssh-config → dns → nginx → wordpress
#
# WordPress prompts (or env, to skip):
#   DB_NAME / DATA_NAME     MySQL database name → ansible -e db_name
#   DB_PREFIX / TABLE_PREFIX  table prefix (default wp_) → ansible -e db_prefix
#
# Environment:
#   REGION, AVAILABILITY_ZONE, NEW_INSTANCE_NAME, BUNDLE_ID, STATIC_IP_NAME
#   SSH_KEY_PAIR_NAME, SSH_ALLOW_CIDRS, IDENTITY_FILE
#   EXTRA_DOMAINS           extra apex domains (comma-separated) for extra hosted zones
#   DB_HOST, DB_ADMIN_USER, DB_ADMIN_PASS  (or modules/2_wordpress/.db-admin.env)
#
# Example:
#   ./aws-cli/create/al2023-lightsail-wordpress.sh ExampleProfile newsite example.com.au

set -euo pipefail

# shellcheck source=../lib/paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/paths.sh"

REGION="${REGION:-ap-southeast-2}"
AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-ap-southeast-2a}"
NEW_INSTANCE_NAME="${NEW_INSTANCE_NAME:-wp-web-23}"
BUNDLE_ID="${BUNDLE_ID:-nano_3_2}"
STATIC_IP_NAME="${STATIC_IP_NAME:-StaticIp-1}"
SSH_ALLOW_CIDRS="${SSH_ALLOW_CIDRS:-111.220.137.221/32,43.245.170.89/32,158.180.7.100/32}"
SSH_KEY_PAIR_NAME="${SSH_KEY_PAIR_NAME:-LightsailDefaultKeyPair}"
DRY_RUN="${DRY_RUN:-0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <profile> <ssh-host> [domain] [phase]

Create a new Amazon Linux 2023 Lightsail WordPress host.

Phases (default: all):
  create      Create Lightsail instance ${NEW_INSTANCE_NAME}
  ports       SSH allow-list + HTTP/HTTPS + allocate/attach static IP
  ssh-config  Add Host alias to ssh-config and wait for SSH
  dns         Create Route53 hosted zone(s) and upsert apex + www A/AAAA
  nginx       modules/1_nginx-php/playbook.yml
  wordpress   modules/2_wordpress/playbook.yml (prompt db_name + table_prefix)
  all         create → ports → ssh-config → dns → nginx → wordpress

Options:
  --dry-run   Print actions without AWS/Ansible changes
  -h, --help  Show this help

Examples:
  ./aws-cli/create/al2023-lightsail-wordpress.sh MyProfile newsite
  ./aws-cli/create/al2023-lightsail-wordpress.sh MyProfile newsite example.com.au
  EXTRA_DOMAINS=other.com.au ./aws-cli/create/al2023-lightsail-wordpress.sh MyProfile newsite example.com.au dns
  DB_NAME=newsite DB_PREFIX=ns_ ./aws-cli/create/al2023-lightsail-wordpress.sh MyProfile newsite wordpress
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) break ;;
  esac
done

PROFILE="${1:?profile required}"
HOST="${2:?ssh Host alias required}"
ARG3="${3:-}"
ARG4="${4:-}"

KNOWN_PHASES='^(create|ports|ssh-config|dns|nginx|wordpress|all)$'
if [[ "$ARG3" =~ $KNOWN_PHASES ]]; then
  DOMAIN=""
  PHASE="$ARG3"
elif [[ -n "$ARG3" ]]; then
  DOMAIN="$ARG3"
  PHASE="${ARG4:-all}"
else
  DOMAIN=""
  PHASE="all"
fi

CREATE_STATE_INSTANCE="$AWS_CLI_STATE/.create-${HOST}.instance"
CREATE_STATE_IP="$AWS_CLI_STATE/.create-${HOST}.ip"
CREATE_STATE_DOMAINS="$AWS_CLI_STATE/.create-${HOST}.domains"
if [[ -f "$CREATE_STATE_INSTANCE" ]]; then
  NEW_INSTANCE_NAME="$(cat "$CREATE_STATE_INSTANCE")"
fi

export AWS_PROFILE="$PROFILE"
export REGION

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

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

IDENTITY="${IDENTITY_FILE:-$(read_ssh IdentityFile)}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="${HOME}/.ssh/${HOST}.pem"
fi
IDENTITY_PATH="${IDENTITY/#\~/$HOME}"

wait_instance_state() {
  local name="$1"
  local want="$2"
  local attempt=0
  local state="missing"
  log "Waiting for instance ${name} → ${want}"
  while [[ "$attempt" -lt 90 ]]; do
    state=$(aws lightsail get-instance \
      --region "$REGION" \
      --instance-name "$name" \
      --query 'instance.state.name' \
      --output text 2>/dev/null || echo "missing")
    if [[ "$state" == "$want" ]]; then
      log "Instance ${name} is ${want}"
      return 0
    fi
    sleep 10
    attempt=$((attempt + 1))
  done
  echo "TIMEOUT: instance ${name} did not reach ${want} (last: ${state})" >&2
  exit 1
}

instance_public_ip() {
  aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "$NEW_INSTANCE_NAME" \
    --query 'instance.publicIpAddress' \
    --output text
}

save_ip() {
  local ip="$1"
  echo "$ip" > "$CREATE_STATE_IP"
}

current_ip() {
  if [[ -f "$CREATE_STATE_IP" ]]; then
    cat "$CREATE_STATE_IP"
    return 0
  fi
  local ip
  ip="$(read_ssh HostName)"
  if [[ -n "$ip" ]]; then
    printf '%s' "$ip"
    return 0
  fi
  instance_public_ip
}

decode_b64() {
  python3 -c "import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))"
}

ensure_aws_login() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: aws-login ${PROFILE}"
    return 0
  fi
  "$AWS_CLI_AUTH/aws-login.sh" "$PROFILE"
}

ensure_key_pair() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: key pair ${SSH_KEY_PAIR_NAME}"
    return 0
  fi

  if [[ "$SSH_KEY_PAIR_NAME" == "LightsailDefaultKeyPair" ]]; then
    log "Using existing LightsailDefaultKeyPair"
    if [[ ! -f "$IDENTITY_PATH" ]]; then
      mkdir -p "$(dirname "$IDENTITY_PATH")"
      if ! aws lightsail download-default-key-pair \
        --region "$REGION" \
        --query 'privateKeyBase64' \
        --output text | decode_b64 > "$IDENTITY_PATH"; then
        rm -f "$IDENTITY_PATH"
        echo "ERROR: cannot download LightsailDefaultKeyPair (often only once per region)." >&2
        echo "Copy the existing default PEM to ${IDENTITY_PATH} and re-run." >&2
        exit 1
      fi
      chmod 600 "$IDENTITY_PATH"
      log "Wrote default key to ${IDENTITY_PATH}"
    fi
    return 0
  fi

  if aws lightsail get-key-pair \
    --region "$REGION" \
    --key-pair-name "$SSH_KEY_PAIR_NAME" \
    --query 'keyPair.name' \
    --output text >/dev/null 2>&1; then
    log "Key pair ${SSH_KEY_PAIR_NAME} already exists"
    return 0
  fi

  if [[ ! -f "$IDENTITY_PATH" ]]; then
    echo "ERROR: IDENTITY_FILE ${IDENTITY_PATH} not found for key pair ${SSH_KEY_PAIR_NAME}" >&2
    exit 1
  fi

  local pub_b64
  pub_b64="$("$AWS_CLI_SSH/encode-ssh-pubkey-b64.sh" "$IDENTITY_PATH")"
  aws lightsail import-key-pair \
    --region "$REGION" \
    --key-pair-name "$SSH_KEY_PAIR_NAME" \
    --public-key-base64 "$pub_b64"
  log "Imported key pair ${SSH_KEY_PAIR_NAME}"
}

do_create() {
  ensure_aws_login
  ensure_key_pair

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: create-instances ${NEW_INSTANCE_NAME} (${AVAILABILITY_ZONE}, ${BUNDLE_ID})"
    echo "$NEW_INSTANCE_NAME" > "$CREATE_STATE_INSTANCE"
    return 0
  fi

  if aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "$NEW_INSTANCE_NAME" \
    --query 'instance.name' \
    --output text >/dev/null 2>&1; then
    log "Instance ${NEW_INSTANCE_NAME} already exists"
  else
    log "Creating ${NEW_INSTANCE_NAME} (amazon_linux_2023 / ${BUNDLE_ID} / ${AVAILABILITY_ZONE})"
    aws lightsail create-instances \
      --instance-names "$NEW_INSTANCE_NAME" \
      --availability-zone "$AVAILABILITY_ZONE" \
      --blueprint-id amazon_linux_2023 \
      --bundle-id "$BUNDLE_ID" \
      --ip-address-type dualstack \
      --key-pair-name "$SSH_KEY_PAIR_NAME" \
      --region "$REGION"
  fi

  wait_instance_state "$NEW_INSTANCE_NAME" "running"
  echo "$NEW_INSTANCE_NAME" > "$CREATE_STATE_INSTANCE"
  local ip
  ip="$(instance_public_ip)"
  save_ip "$ip"
  log "CREATE_DONE instance=${NEW_INSTANCE_NAME} ip=${ip}"
}

do_ports() {
  ensure_aws_login

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: put-instance-public-ports ${NEW_INSTANCE_NAME} SSH=${SSH_ALLOW_CIDRS}"
    log "DRY-RUN: allocate/attach static IP ${STATIC_IP_NAME}"
    return 0
  fi

  log "Setting public ports on ${NEW_INSTANCE_NAME}"
  aws lightsail put-instance-public-ports \
    --region "$REGION" \
    --instance-name "$NEW_INSTANCE_NAME" \
    --port-infos \
      "fromPort=22,toPort=22,protocol=tcp,cidrs=${SSH_ALLOW_CIDRS}" \
      "fromPort=80,toPort=80,protocol=tcp,cidrs=0.0.0.0/0" \
      "fromPort=443,toPort=443,protocol=tcp,cidrs=0.0.0.0/0"

  local attached
  attached=$(aws lightsail get-static-ip \
    --region "$REGION" \
    --static-ip-name "$STATIC_IP_NAME" \
    --query 'staticIp.attachedTo' \
    --output text 2>/dev/null || echo "missing")

  if [[ "$attached" == "missing" ]]; then
    log "Allocating static IP ${STATIC_IP_NAME}"
    aws lightsail allocate-static-ip \
      --static-ip-name "$STATIC_IP_NAME" \
      --region "$REGION"
    attached="None"
  fi

  if [[ "$attached" == "$NEW_INSTANCE_NAME" ]]; then
    log "Static IP ${STATIC_IP_NAME} already attached to ${NEW_INSTANCE_NAME}"
  elif [[ "$attached" == "None" || -z "$attached" ]]; then
    log "Attaching static IP ${STATIC_IP_NAME} to ${NEW_INSTANCE_NAME}"
    aws lightsail attach-static-ip \
      --static-ip-name "$STATIC_IP_NAME" \
      --instance-name "$NEW_INSTANCE_NAME" \
      --region "$REGION"
  else
    echo "ERROR: static IP ${STATIC_IP_NAME} is attached to ${attached}, not ${NEW_INSTANCE_NAME}" >&2
    exit 1
  fi

  local ip
  ip=$(aws lightsail get-static-ip \
    --region "$REGION" \
    --static-ip-name "$STATIC_IP_NAME" \
    --query 'staticIp.ipAddress' \
    --output text)
  save_ip "$ip"
  log "PORTS_DONE SSH=${SSH_ALLOW_CIDRS} static_ip=${ip}"
}

wait_ssh() {
  local ip="$1"
  local attempt=0
  log "Waiting for SSH on ${ip}"
  while [[ "$attempt" -lt 60 ]]; do
    if ssh -i "$IDENTITY_PATH" \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      "ec2-user@${ip}" true 2>/dev/null; then
      log "SSH is up on ${ip}"
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
  echo "TIMEOUT: SSH did not answer on ${ip}" >&2
  exit 1
}

do_ssh_config() {
  local ip
  ip="$(current_ip)"
  if [[ -z "$ip" || "$ip" == "None" ]]; then
    echo "ERROR: no public IP — run create/ports first" >&2
    exit 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: ssh-config Host ${HOST} → ${ip} IdentityFile ${IDENTITY}"
    return 0
  fi

  if [[ ! -f "$IDENTITY_PATH" ]]; then
    echo "ERROR: SSH identity not found: ${IDENTITY_PATH}" >&2
    exit 1
  fi

  python3 "$AWS_CLI_SSH/move-ssh-host-al2023.py" --add \
    "$(resolve_ssh_config)" "$HOST" "$ip" "$IDENTITY_PATH" "$(primary_domain)" "$PROFILE"
  wait_ssh "$ip"
}

normalize_domain() {
  local d="$1"
  d="${d#http://}"
  d="${d#https://}"
  d="${d#www.}"
  d="${d%/}"
  printf '%s' "$d"
}

write_domains_file() {
  local d
  : > "$CREATE_STATE_DOMAINS"
  for d in "$@"; do
    d="$(normalize_domain "$d")"
    [[ -z "$d" ]] && continue
    grep -qx "$d" "$CREATE_STATE_DOMAINS" 2>/dev/null && continue
    printf '%s\n' "$d" >> "$CREATE_STATE_DOMAINS"
  done
}

load_domains() {
  if [[ -f "$CREATE_STATE_DOMAINS" ]]; then
    cat "$CREATE_STATE_DOMAINS"
    return 0
  fi
  if [[ -n "${DOMAIN:-}" ]]; then
    printf '%s\n' "$(normalize_domain "$DOMAIN")"
  fi
}

primary_domain() {
  if [[ -n "${DOMAIN:-}" ]]; then
    printf '%s' "$(normalize_domain "$DOMAIN")"
    return 0
  fi
  if [[ -f "$CREATE_STATE_DOMAINS" ]]; then
    head -1 "$CREATE_STATE_DOMAINS"
  fi
}

ensure_domains() {
  local extra="${EXTRA_DOMAINS:-}"
  local d
  local -a extras=()

  if [[ -z "$DOMAIN" && -f "$CREATE_STATE_DOMAINS" ]]; then
    DOMAIN="$(head -1 "$CREATE_STATE_DOMAINS")"
  fi

  if [[ -z "$DOMAIN" ]]; then
    if [[ ! -t 0 ]]; then
      echo "ERROR: domain required for dns (3rd argument, or DOMAIN= / EXTRA_DOMAINS=)" >&2
      exit 1
    fi
    read -r -p "Primary domain (Route53 hosted zone): " DOMAIN
  fi
  DOMAIN="$(normalize_domain "$DOMAIN")"
  if [[ -z "$DOMAIN" ]]; then
    echo "ERROR: domain is required to create a hosted zone" >&2
    exit 1
  fi

  if [[ -z "$extra" && -t 0 && ! -f "$CREATE_STATE_DOMAINS" ]]; then
    read -r -p "Additional apex domains (comma-separated, empty to skip): " extra
  fi
  extra="${extra//,/ }"
  for d in $extra; do
    d="$(normalize_domain "$d")"
    [[ -n "$d" && "$d" != "$DOMAIN" ]] && extras+=("$d")
  done

  if [[ -f "$CREATE_STATE_DOMAINS" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" || "$d" == "$DOMAIN" ]] && continue
      extras+=("$d")
    done < "$CREATE_STATE_DOMAINS"
  fi

  if [[ ${#extras[@]} -gt 0 ]]; then
    write_domains_file "$DOMAIN" "${extras[@]}"
  else
    write_domains_file "$DOMAIN"
  fi
  log "Domains for Route53: $(tr '\n' ' ' < "$CREATE_STATE_DOMAINS")"
}

instance_ipv6() {
  aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "$NEW_INSTANCE_NAME" \
    --query 'instance.ipv6Addresses[0]' \
    --output text 2>/dev/null || true
}

do_dns() {
  ensure_aws_login
  ensure_domains

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: Route53 hosted zone + apex/www A/AAAA for:"
    load_domains | sed 's/^/  /'
    return 0
  fi

  local ip ipv6 d
  ip="$(current_ip)"
  if [[ -z "$ip" || "$ip" == "None" ]]; then
    echo "ERROR: no public IP — run create/ports first" >&2
    exit 1
  fi

  ipv6="$(instance_ipv6)"
  if [[ "$ipv6" == "None" ]]; then
    ipv6=""
  fi

  export AWS_PROFILE="$PROFILE"
  export IPV4="$ip"
  export IPV6="${ipv6:-}"

  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    log "Route53 hosted zone + records for ${d} → ${ip}"
    DOMAIN="$d" "$AWS_CLI_DNS/dns-manage.sh" setup
  done < <(load_domains)

  DOMAIN="$(primary_domain)"
  log "DNS_DONE primary=${DOMAIN} ip=${ip}"
  echo "At the domain registrar, set nameservers to the Route53 NS values printed above."
}

ansible_run() {
  local playbook="$1"
  shift
  local cfg ip site_domain
  local -a extra=()
  cfg="$(resolve_ssh_config)"
  ip="$(current_ip)"
  IDENTITY="$(read_ssh IdentityFile)"
  IDENTITY_PATH="${IDENTITY/#\~/$HOME}"
  if [[ -z "$IDENTITY_PATH" || ! -f "$IDENTITY_PATH" ]]; then
    echo "ERROR: IdentityFile not found for Host ${HOST} in ${SSH_CONFIG}" >&2
    exit 1
  fi
  extra+=(-e "ansible_ssh_private_key_file=${IDENTITY_PATH}" -e "ansible_host=${ip}")
  site_domain="$(primary_domain)"
  if [[ -n "$site_domain" ]]; then
    extra+=(-e "domain_name=${site_domain}")
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: ansible-playbook -i ${HOST}, ${playbook} $* ${extra[*]}"
    return 0
  fi
  ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_SSH_ARGS="-F ${cfg}" \
    ansible-playbook -i "${HOST}," "$playbook" "$@" "${extra[@]}"
}

do_nginx() {
  if [[ -z "$(read_ssh HostName)" ]]; then
    do_ssh_config
  fi
  log "Running nginx-php playbook on ${HOST}"
  ansible_run "$REPO_ROOT/modules/1_nginx-php/playbook.yml" --skip-tags rescue
}

source_db_admin() {
  local envf="$REPO_ROOT/modules/2_wordpress/.db-admin.env"
  if [[ -f "$envf" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$envf"
    set +a
  fi
  if [[ -z "${DB_HOST:-}" || -z "${DB_ADMIN_USER:-}" || -z "${DB_ADMIN_PASS:-}" ]]; then
    echo "ERROR: set DB_HOST, DB_ADMIN_USER, DB_ADMIN_PASS (export or ${envf})" >&2
    exit 1
  fi
}

prompt_wp_vars() {
  local name prefix
  name="${DB_NAME:-${DATA_NAME:-}}"
  prefix="${DB_PREFIX:-${TABLE_PREFIX:-}}"

  if [[ -z "$name" ]]; then
    if [[ ! -t 0 ]]; then
      echo "ERROR: DB_NAME / DATA_NAME required when stdin is not a terminal" >&2
      exit 1
    fi
    read -r -p "Database name (db_name): " name
  fi
  if [[ -z "$name" ]]; then
    echo "ERROR: database name is required" >&2
    exit 1
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "ERROR: db_name must be letters, digits, or underscore: ${name}" >&2
    exit 1
  fi

  if [[ -z "$prefix" ]]; then
    if [[ ! -t 0 ]]; then
      prefix="wp_"
    else
      read -r -p "Table prefix (table_prefix) [wp_]: " prefix
      prefix="${prefix:-wp_}"
    fi
  fi
  if [[ "$prefix" != *_ ]]; then
    prefix="${prefix}_"
  fi
  if [[ ! "$prefix" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "ERROR: table_prefix must be letters, digits, or underscore: ${prefix}" >&2
    exit 1
  fi

  WP_DB_NAME="$name"
  WP_DB_PREFIX="$prefix"
}

do_wordpress() {
  if [[ -z "$(read_ssh HostName)" ]]; then
    do_ssh_config
  fi
  source_db_admin
  prompt_wp_vars
  log "Running WordPress playbook on ${HOST} (db_name=${WP_DB_NAME} db_prefix=${WP_DB_PREFIX})"
  ansible_run "$REPO_ROOT/modules/2_wordpress/playbook.yml" \
    -e "db_name=${WP_DB_NAME}" \
    -e "db_prefix=${WP_DB_PREFIX}"
}

case "$PHASE" in
  create) do_create ;;
  ports) do_ports ;;
  ssh-config) do_ssh_config ;;
  dns) do_dns ;;
  nginx) do_nginx ;;
  wordpress) do_wordpress ;;
  all)
    do_create
    do_ports
    ensure_domains
    do_ssh_config
    do_dns
    do_nginx
    do_wordpress
    log "New WordPress host ${HOST} is provisioned."
    if [[ -n "$(primary_domain)" ]]; then
      echo "Registrar: point the domain at the Route53 nameservers from the dns step."
      echo "Then SSL: ansible modules/3_ssl/playbook.yml  (https://$(primary_domain)/)"
    else
      echo "Next: browse http://$(current_ip)/ then SSL via modules/3_ssl/playbook.yml"
    fi
    ;;
  *)
    echo "Unknown phase: $PHASE (use create|ports|ssh-config|dns|nginx|wordpress|all)" >&2
    usage >&2
    exit 1
    ;;
esac
