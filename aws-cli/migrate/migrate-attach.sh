#!/usr/bin/env bash
# AL2 → AL2023 migration — phase 1 (CloudShell / env-driven). Prefer attach-disk-new.sh
# via ./aws-cli/migrate/migrate-al2-al2023.sh. This script is used by migrate-local-attach.sh.
#
# Required env:
#   SOURCE_PUBLIC_IP   — current HostName from ssh-config (AL2 static/ephemeral IP)
#   SSH_KEY_PAIR_NAME  — Lightsail key pair name (e.g. altus-migrate)
#   SSH_PUBLIC_KEY_B64 — base64-encoded OpenSSH public key (from ssh-keygen -y)
#
# Optional env:
#   REGION             — default ap-southeast-2
#   NEW_INSTANCE_NAME  — default wp-web-23
#   SSH_ALLOW_CIDRS    — comma-separated CIDRs for port 22
#
# Outputs parseable lines:
#   INSTANCE_NAME_AL2=…
#   AVAILABILITY_ZONE=…
#   NEW_PUBLIC_IP=…

set -euo pipefail

REGION="${REGION:-ap-southeast-2}"
NEW_INSTANCE_NAME="${NEW_INSTANCE_NAME:-wp-web-23}"
SOURCE_PUBLIC_IP="${SOURCE_PUBLIC_IP:?SOURCE_PUBLIC_IP required}"
SSH_KEY_PAIR_NAME="${SSH_KEY_PAIR_NAME:?SSH_KEY_PAIR_NAME required}"
SSH_PUBLIC_KEY_B64="${SSH_PUBLIC_KEY_B64:?SSH_PUBLIC_KEY_B64 required}"
SSH_ALLOW_CIDRS="${SSH_ALLOW_CIDRS:-111.220.137.221/32,43.245.170.89/32,158.180.7.100/32}"
DISK_SNAPSHOT_NAME="${DISK_SNAPSHOT_NAME:-al2-rescue}"
RESCUE_DISK_NAME="${RESCUE_DISK_NAME:-al2-rescue-disk}"

wait_instance_state() {
  local name="$1"
  local want="$2"
  local attempt=0
  while [ "$attempt" -lt 90 ]; do
    local state
    state=$(aws lightsail get-instance \
      --region "$REGION" \
      --instance-name "$name" \
      --query 'instance.state.name' \
      --output text 2>/dev/null || echo "missing")
    if [ "$state" = "$want" ]; then
      return 0
    fi
    sleep 10
    attempt=$((attempt + 1))
  done
  echo "TIMEOUT: instance $name did not reach state $want" >&2
  exit 1
}

wait_snapshot_state() {
  local name="$1"
  local want="$2"
  local attempt=0
  while [ "$attempt" -lt 120 ]; do
    local state
    state=$(aws lightsail get-disk-snapshot \
      --region "$REGION" \
      --disk-snapshot-name "$name" \
      --query 'diskSnapshot.state' \
      --output text 2>/dev/null || echo "missing")
    if [ "$state" = "$want" ]; then
      return 0
    fi
    sleep 15
    attempt=$((attempt + 1))
  done
  echo "TIMEOUT: snapshot $name did not reach state $want" >&2
  exit 1
}

wait_disk_state() {
  local name="$1"
  local want="$2"
  local attempt=0
  while [ "$attempt" -lt 60 ]; do
    local state
    state=$(aws lightsail get-disk \
      --region "$REGION" \
      --disk-name "$name" \
      --query 'disk.state' \
      --output text 2>/dev/null || echo "missing")
    if [ "$state" = "$want" ]; then
      return 0
    fi
    sleep 10
    attempt=$((attempt + 1))
  done
  echo "TIMEOUT: disk $name did not reach state $want" >&2
  exit 1
}

instance_exists() {
  aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "$1" \
    --query 'instance.name' \
    --output text >/dev/null 2>&1
}

# --- Find AL2 source instance by public IP ---
INSTANCE_NAME_AL2=$(aws lightsail get-instances \
  --region "$REGION" \
  --query "instances[?publicIpAddress=='${SOURCE_PUBLIC_IP}'].name | [0]" \
  --output text)

if [ -z "$INSTANCE_NAME_AL2" ] || [ "$INSTANCE_NAME_AL2" = "None" ]; then
  INSTANCE_NAME_AL2=$(aws lightsail get-instances \
    --region "$REGION" \
    --query "instances[?name!='${NEW_INSTANCE_NAME}'] | [0].name" \
    --output text)
fi

if [ -z "$INSTANCE_NAME_AL2" ] || [ "$INSTANCE_NAME_AL2" = "None" ]; then
  echo "ERROR: no AL2 source instance found for IP ${SOURCE_PUBLIC_IP}" >&2
  exit 1
fi

AVAILABILITY_ZONE=$(aws lightsail get-instance \
  --region "$REGION" \
  --instance-name "$INSTANCE_NAME_AL2" \
  --query 'instance.location.availabilityZone' \
  --output text)

echo "INSTANCE_NAME_AL2=${INSTANCE_NAME_AL2}"
echo "AVAILABILITY_ZONE=${AVAILABILITY_ZONE}"

# --- Import SSH key pair (reuse existing host PEM) ---
if ! aws lightsail get-key-pair \
  --region "$REGION" \
  --key-pair-name "$SSH_KEY_PAIR_NAME" \
  --query 'keyPair.name' \
  --output text >/dev/null 2>&1; then
  aws lightsail import-key-pair \
    --region "$REGION" \
    --key-pair-name "$SSH_KEY_PAIR_NAME" \
    --public-key-base64 "$SSH_PUBLIC_KEY_B64"
  echo "Imported key pair ${SSH_KEY_PAIR_NAME}"
else
  echo "Key pair ${SSH_KEY_PAIR_NAME} already exists"
fi

# --- Create AL2023 instance if missing ---
if ! instance_exists "$NEW_INSTANCE_NAME"; then
  aws lightsail create-instances \
    --instance-names "$NEW_INSTANCE_NAME" \
    --availability-zone "$AVAILABILITY_ZONE" \
    --blueprint-id amazon_linux_2023 \
    --bundle-id nano_3_2 \
    --ip-address-type dualstack \
    --key-pair-name "$SSH_KEY_PAIR_NAME" \
    --region "$REGION"
  wait_instance_state "$NEW_INSTANCE_NAME" "running"
else
  echo "Instance ${NEW_INSTANCE_NAME} already exists"
  wait_instance_state "$NEW_INSTANCE_NAME" "running"
fi

# Firewall (idempotent — overwrites port config)
aws lightsail put-instance-public-ports \
  --region "$REGION" \
  --instance-name "$NEW_INSTANCE_NAME" \
  --port-infos \
    "fromPort=22,toPort=22,protocol=tcp,cidrs=${SSH_ALLOW_CIDRS}" \
    "fromPort=80,toPort=80,protocol=tcp,cidrs=0.0.0.0/0" \
    "fromPort=443,toPort=443,protocol=tcp,cidrs=0.0.0.0/0"

# --- Snapshot AL2 root volume ---
_snapshot_state=$(aws lightsail get-disk-snapshot \
  --region "$REGION" \
  --disk-snapshot-name "$DISK_SNAPSHOT_NAME" \
  --query 'diskSnapshot.state' \
  --output text 2>/dev/null || echo "missing")

if [ "$_snapshot_state" = "completed" ]; then
  echo "Snapshot ${DISK_SNAPSHOT_NAME} already completed"
else
  if [ "$_snapshot_state" != "missing" ]; then
    aws lightsail delete-disk-snapshot \
      --region "$REGION" \
      --disk-snapshot-name "$DISK_SNAPSHOT_NAME" 2>/dev/null || true
  fi
  aws lightsail create-disk-snapshot \
    --region "$REGION" \
    --instance-name "$INSTANCE_NAME_AL2" \
    --disk-snapshot-name "$DISK_SNAPSHOT_NAME"
  wait_snapshot_state "$DISK_SNAPSHOT_NAME" "completed"
fi

DISK_SNAPSHOT_SIZE=$(aws lightsail get-disk-snapshot \
  --region "$REGION" \
  --disk-snapshot-name "$DISK_SNAPSHOT_NAME" \
  --query 'diskSnapshot.sizeInGb' \
  --output text)

# --- Rescue disk from snapshot ---
_disk_state=$(aws lightsail get-disk \
  --region "$REGION" \
  --disk-name "$RESCUE_DISK_NAME" \
  --query 'disk.state' \
  --output text 2>/dev/null || echo "missing")

if [ "$_disk_state" = "available" ] || [ "$_disk_state" = "in-use" ]; then
  echo "Rescue disk ${RESCUE_DISK_NAME} already exists (state=${_disk_state})"
else
  if [ "$_disk_state" != "missing" ]; then
    aws lightsail delete-disk \
      --region "$REGION" \
      --disk-name "$RESCUE_DISK_NAME" 2>/dev/null || true
  fi
  aws lightsail create-disk-from-snapshot \
    --region "$REGION" \
    --disk-name "$RESCUE_DISK_NAME" \
    --disk-snapshot-name "$DISK_SNAPSHOT_NAME" \
    --availability-zone "$AVAILABILITY_ZONE" \
    --size-in-gb "$DISK_SNAPSHOT_SIZE"
  wait_disk_state "$RESCUE_DISK_NAME" "available"
fi

# --- Attach rescue disk ---
_attached_to=$(aws lightsail get-disk \
  --region "$REGION" \
  --disk-name "$RESCUE_DISK_NAME" \
  --query 'disk.attachedTo' \
  --output text 2>/dev/null || echo "None")

if [ "$_attached_to" = "$NEW_INSTANCE_NAME" ]; then
  echo "Rescue disk already attached to ${NEW_INSTANCE_NAME}"
else
  aws lightsail attach-disk \
    --region "$REGION" \
    --disk-name "$RESCUE_DISK_NAME" \
    --instance-name "$NEW_INSTANCE_NAME" \
    --disk-path /dev/xvdf
  sleep 5
fi

NEW_PUBLIC_IP=$(aws lightsail get-instance \
  --region "$REGION" \
  --instance-name "$NEW_INSTANCE_NAME" \
  --query 'instance.publicIpAddress' \
  --output text)

echo "NEW_PUBLIC_IP=${NEW_PUBLIC_IP}"
echo "MIGRATE_ATTACH_DONE=1"
