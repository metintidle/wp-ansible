#!/usr/bin/env bash
# AL2 → AL2023 migration — phase 2: detach rescue disk, move static IP AL2→AL2023, delete AL2.
# Run AFTER ansible nginx-php has copied site files from the rescue disk.
#
# Required env:
#   SOURCE_PUBLIC_IP   — original AL2 IP (from ssh-config before migration)
#
# Optional env:
#   REGION             — default ap-southeast-2
#   NEW_INSTANCE_NAME  — default wp-web-23
#   INSTANCE_NAME_AL2  — override AL2 instance name
#   STATIC_IP_NAME     — override static IP resource name
#   RESCUE_DISK_NAME   — default al2-rescue-disk
#
# Correct order:
#   1. Stop AL2023, detach/delete rescue disk, start AL2023
#   2. Detach static IP from AL2 → attach to AL2023 (same IP as before migration)
#   3. Delete AL2
#
# Outputs:
#   STATIC_IP=…
#   STATIC_IP_NAME=…
#   NEW_PUBLIC_IPV6=…
#   INSTANCE_NAME_AL2=…

set -euo pipefail

REGION="${REGION:-ap-southeast-2}"
NEW_INSTANCE_NAME="${NEW_INSTANCE_NAME:-wp-web-23}"
SOURCE_PUBLIC_IP="${SOURCE_PUBLIC_IP:?SOURCE_PUBLIC_IP required}"
RESCUE_DISK_NAME="${RESCUE_DISK_NAME:-al2-rescue-disk}"
DEFAULT_STATIC_IP_NAME="${STATIC_IP_NAME:-StaticIp-1}"

wait_instance_state() {
  local name="$1"
  local want="$2"
  local attempt=0
  echo "Waiting for instance ${name} → ${want}…"
  while [ "$attempt" -lt 90 ]; do
    local state
    state=$(aws lightsail get-instance \
      --region "$REGION" \
      --instance-name "$name" \
      --query 'instance.state.name' \
      --output text 2>/dev/null || echo "missing")
    if [ "$state" = "$want" ]; then
      echo "Instance ${name} is ${want}"
      return 0
    fi
    sleep 10
    attempt=$((attempt + 1))
  done
  echo "TIMEOUT: instance ${name} did not reach state ${want} (last: ${state:-unknown})" >&2
  exit 1
}

find_static_ip_name() {
  local attached_to="$1"
  local ip="$2"
  local name=""

  if [ -n "${STATIC_IP_NAME:-}" ]; then
    echo "$STATIC_IP_NAME"
    return 0
  fi

  name=$(aws lightsail get-static-ips \
    --region "$REGION" \
    --query "staticIps[?attachedTo=='${attached_to}'].name | [0]" \
    --output text 2>/dev/null || true)

  if [ -n "$name" ] && [ "$name" != "None" ]; then
    echo "$name"
    return 0
  fi

  name=$(aws lightsail get-static-ips \
    --region "$REGION" \
    --query "staticIps[?ipAddress=='${ip}'].name | [0]" \
    --output text 2>/dev/null || true)

  if [ -n "$name" ] && [ "$name" != "None" ]; then
    echo "$name"
    return 0
  fi

  return 1
}

# --- Resolve AL2 instance (never guess wp-web-23 after static IP cutover) ---
if [ -z "${INSTANCE_NAME_AL2:-}" ] && [ -n "${MIGRATE_AL2_INSTANCE_FILE:-}" ] && [ -f "$MIGRATE_AL2_INSTANCE_FILE" ]; then
  INSTANCE_NAME_AL2="$(tr -d '[:space:]' < "$MIGRATE_AL2_INSTANCE_FILE")"
fi

if [ -z "${INSTANCE_NAME_AL2:-}" ]; then
  INSTANCE_NAME_AL2=$(aws lightsail get-instances \
    --region "$REGION" \
    --query "instances[?publicIpAddress=='${SOURCE_PUBLIC_IP}'].name | [0]" \
    --output text)
fi

if [ -z "$INSTANCE_NAME_AL2" ] || [ "$INSTANCE_NAME_AL2" = "None" ]; then
  INSTANCE_NAME_AL2=$(aws lightsail get-instances \
    --region "$REGION" \
    --query "instances[?name!='${NEW_INSTANCE_NAME}'] | [0].name" \
    --output text 2>/dev/null || true)
fi

if [ "$INSTANCE_NAME_AL2" = "$NEW_INSTANCE_NAME" ]; then
  echo "ERROR: AL2 instance name resolved to ${NEW_INSTANCE_NAME} — refusing to continue." >&2
  echo "Set INSTANCE_NAME_AL2 explicitly (e.g. from aws-cli/state/.migrate-<host>.al2-instance)." >&2
  exit 1
fi

echo "INSTANCE_NAME_AL2=${INSTANCE_NAME_AL2:-missing}"

# --- Stop AL2023, detach rescue disk, start AL2023 ---
aws lightsail stop-instance \
  --instance-name "$NEW_INSTANCE_NAME" \
  --region "$REGION"

wait_instance_state "$NEW_INSTANCE_NAME" "stopped"

if aws lightsail get-disk \
  --region "$REGION" \
  --disk-name "$RESCUE_DISK_NAME" \
  --query 'disk.name' \
  --output text >/dev/null 2>&1; then
  aws lightsail detach-disk \
    --region "$REGION" \
    --disk-name "$RESCUE_DISK_NAME"
  aws lightsail delete-disk \
    --region "$REGION" \
    --disk-name "$RESCUE_DISK_NAME"
  echo "Rescue disk ${RESCUE_DISK_NAME} detached and deleted"
fi

aws lightsail start-instance \
  --instance-name "$NEW_INSTANCE_NAME" \
  --region "$REGION"

wait_instance_state "$NEW_INSTANCE_NAME" "running"

# --- Move static IP from AL2 to AL2023 (required before deleting AL2) ---
STATIC_IP_NAME=""
PUBLIC_IP=""

CURRENT_STATIC_ATTACH=$(aws lightsail get-static-ips \
  --region "$REGION" \
  --query "staticIps[?attachedTo=='${NEW_INSTANCE_NAME}'].{name:name,ip:ipAddress} | [0]" \
  --output json 2>/dev/null || echo "null")

if [ "$CURRENT_STATIC_ATTACH" != "null" ] && [ -n "$CURRENT_STATIC_ATTACH" ]; then
  STATIC_IP_NAME=$(echo "$CURRENT_STATIC_ATTACH" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))")
  PUBLIC_IP=$(echo "$CURRENT_STATIC_ATTACH" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ip',''))")
  echo "Static IP already on ${NEW_INSTANCE_NAME}: ${STATIC_IP_NAME} (${PUBLIC_IP})"
elif STATIC_IP_NAME="$(find_static_ip_name "${INSTANCE_NAME_AL2:-}" "$SOURCE_PUBLIC_IP")"; then
  echo "Moving static IP ${STATIC_IP_NAME} from ${INSTANCE_NAME_AL2} to ${NEW_INSTANCE_NAME}…"
  aws lightsail detach-static-ip \
    --region "$REGION" \
    --static-ip-name "$STATIC_IP_NAME"

  aws lightsail attach-static-ip \
    --region "$REGION" \
    --static-ip-name "$STATIC_IP_NAME" \
    --instance-name "$NEW_INSTANCE_NAME"

  PUBLIC_IP=$(aws lightsail get-static-ip \
    --region "$REGION" \
    --static-ip-name "$STATIC_IP_NAME" \
    --query 'staticIp.ipAddress' \
    --output text)

  echo "STATIC_IP_NAME=${STATIC_IP_NAME}"
  echo "STATIC_IP=${PUBLIC_IP}"
else
  echo "ERROR: No Lightsail static IP found for AL2 (${INSTANCE_NAME_AL2:-unknown}) or IP ${SOURCE_PUBLIC_IP}." >&2
  echo "Before migration, the AL2 instance must have a static IP attached (same IP as ssh-config)." >&2
  echo "In Lightsail console: Networking → Create static IP → attach to AL2, then re-run detach." >&2
  exit 1
fi

# --- Delete old AL2 instance (only after static IP moved) ---
if [ -n "${INSTANCE_NAME_AL2:-}" ] && [ "$INSTANCE_NAME_AL2" != "None" ] && [ "$INSTANCE_NAME_AL2" != "missing" ]; then
  if [ "$INSTANCE_NAME_AL2" = "$NEW_INSTANCE_NAME" ]; then
    echo "ERROR: Refusing to delete AL2 — name equals ${NEW_INSTANCE_NAME}" >&2
    exit 1
  fi
  if aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "$INSTANCE_NAME_AL2" \
    --query 'instance.name' \
    --output text >/dev/null 2>&1; then
    aws lightsail stop-instance \
      --region "$REGION" \
      --instance-name "$INSTANCE_NAME_AL2" 2>/dev/null || true
    wait_instance_state "$INSTANCE_NAME_AL2" "stopped" || sleep 30
    aws lightsail delete-instance \
      --region "$REGION" \
      --instance-name "$INSTANCE_NAME_AL2" \
      --force-delete-add-ons
    echo "Deleted AL2 instance: ${INSTANCE_NAME_AL2}"
  else
    echo "AL2 instance ${INSTANCE_NAME_AL2} not found (already deleted)"
  fi
fi

NEW_PUBLIC_IPV6=$(aws lightsail get-instance \
  --region "$REGION" \
  --instance-name "$NEW_INSTANCE_NAME" \
  --query 'instance.ipv6Addresses[0]' \
  --output text)

echo "NEW_PUBLIC_IPV6=${NEW_PUBLIC_IPV6}"
echo "MIGRATE_DETACH_DONE=1"
