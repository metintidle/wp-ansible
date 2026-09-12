#!/usr/bin/env bash
# AL2 → AL2023 phase 1: create AL2023 instance, snapshot AL2, attach rescue disk.
# Requires: AWS_PROFILE or aws login session. Called by migrate-al2-al2023.sh.
#
# Optional env:
#   REGION=ap-southeast-2
#   NEW_INSTANCE_NAME=wp-web-23
#   SOURCE_PUBLIC_IP=52.63.103.53   (AL2 IP from ssh-config; auto-detect if unset)
#   SSH_KEY_PAIR_NAME=camden-migrate
#   SSH_PUBLIC_KEY_B64=...          (base64 of ssh-keygen -y output)
#   SSH_ALLOW_CIDRS=111.220.137.221/32,...

set -euo pipefail

REGION="${REGION:-ap-southeast-2}"
NEW_INSTANCE_NAME="${NEW_INSTANCE_NAME:-wp-web-23}"
DISK_SNAPSHOT_NAME="${DISK_SNAPSHOT_NAME:-al2-rescue}"
RESCUE_DISK_NAME="${RESCUE_DISK_NAME:-al2-rescue-disk}"
SSH_ALLOW_CIDRS="${SSH_ALLOW_CIDRS:-111.220.137.221/32,43.245.170.89/32,158.180.7.100/32}"

wait_instance_state() {
  local name="$1"
  local want="$2"
  local attempt=0
  echo "Waiting for instance ${name} to reach state ${want}…"
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

if [[ -n "${SOURCE_PUBLIC_IP:-}" ]]; then
  INSTANCE_NAME_AL2=$(aws lightsail get-instances \
    --region "$REGION" \
    --query "instances[?publicIpAddress=='${SOURCE_PUBLIC_IP}'].name | [0]" \
    --output text)
else
  INSTANCE_NAME_AL2=$(aws lightsail get-instances \
    --region "$REGION" \
    --query "instances[?name!='${NEW_INSTANCE_NAME}'] | [0].name" \
    --output text)
fi

if [[ -z "$INSTANCE_NAME_AL2" || "$INSTANCE_NAME_AL2" == "None" ]]; then
  echo "ERROR: AL2 source instance not found" >&2
  exit 1
fi

AVAILABILITY_ZONE=$(aws lightsail get-instance \
  --region "$REGION" \
  --instance-name "$INSTANCE_NAME_AL2" \
  --query 'instance.location.availabilityZone' \
  --output text)

echo "INSTANCE_NAME_AL2=${INSTANCE_NAME_AL2}"
echo "AVAILABILITY_ZONE=${AVAILABILITY_ZONE}"

KEY_PAIR_NAME="${SSH_KEY_PAIR_NAME:-LightsailDefaultKeyPair}"
KEY_OPT=(--key-pair-name "$KEY_PAIR_NAME")

# Only import custom keys — LightsailDefaultKeyPair already exists in every account.
if [[ "$KEY_PAIR_NAME" != "LightsailDefaultKeyPair" ]]; then
  if [[ -z "${SSH_PUBLIC_KEY_B64:-}" ]]; then
    echo "ERROR: SSH_PUBLIC_KEY_B64 required for custom key pair ${KEY_PAIR_NAME}" >&2
    exit 1
  fi
  if ! aws lightsail get-key-pair \
    --region "$REGION" \
    --key-pair-name "$KEY_PAIR_NAME" \
    --query 'keyPair.name' \
    --output text >/dev/null 2>&1; then
    aws lightsail import-key-pair \
      --region "$REGION" \
      --key-pair-name "$KEY_PAIR_NAME" \
      --public-key-base64 "$SSH_PUBLIC_KEY_B64"
    echo "Imported key pair ${KEY_PAIR_NAME}"
  else
    echo "Key pair ${KEY_PAIR_NAME} already exists"
  fi
else
  echo "Using existing LightsailDefaultKeyPair (no import)"
fi

if ! aws lightsail get-instance \
  --region "$REGION" \
  --instance-name "$NEW_INSTANCE_NAME" \
  --query 'instance.name' \
  --output text >/dev/null 2>&1; then
  aws lightsail create-instances \
    --instance-names "$NEW_INSTANCE_NAME" \
    --availability-zone "$AVAILABILITY_ZONE" \
    --blueprint-id amazon_linux_2023 \
    --bundle-id nano_3_2 \
    --ip-address-type dualstack \
    "${KEY_OPT[@]}" \
    --region "$REGION"
else
  echo "Instance ${NEW_INSTANCE_NAME} already exists"
fi

wait_instance_state "$NEW_INSTANCE_NAME" "running"

aws lightsail put-instance-public-ports \
  --region "$REGION" \
  --instance-name "$NEW_INSTANCE_NAME" \
  --port-infos \
    "fromPort=22,toPort=22,protocol=tcp,cidrs=${SSH_ALLOW_CIDRS}" \
    "fromPort=80,toPort=80,protocol=tcp,cidrs=0.0.0.0/0" \
    "fromPort=443,toPort=443,protocol=tcp,cidrs=0.0.0.0/0"

aws lightsail create-disk-snapshot \
  --region "$REGION" \
  --instance-name "$INSTANCE_NAME_AL2" \
  --disk-snapshot-name "$DISK_SNAPSHOT_NAME"

echo "Waiting for snapshot ${DISK_SNAPSHOT_NAME}…"
for _ in $(seq 1 120); do
  STATE=$(aws lightsail get-disk-snapshot \
    --region "$REGION" \
    --disk-snapshot-name "$DISK_SNAPSHOT_NAME" \
    --query 'diskSnapshot.state' \
    --output text 2>/dev/null || echo missing)
  [[ "$STATE" == "completed" ]] && break
  sleep 15
done

DISK_SNAPSHOT_SIZE=$(aws lightsail get-disk-snapshot \
  --region "$REGION" \
  --disk-snapshot-name "$DISK_SNAPSHOT_NAME" \
  --query 'diskSnapshot.sizeInGb' \
  --output text)
echo "DISK_SNAPSHOT_SIZE=${DISK_SNAPSHOT_SIZE} GB"

aws lightsail create-disk-from-snapshot \
  --region "$REGION" \
  --disk-name "$RESCUE_DISK_NAME" \
  --disk-snapshot-name "$DISK_SNAPSHOT_NAME" \
  --availability-zone "$AVAILABILITY_ZONE" \
  --size-in-gb "$DISK_SNAPSHOT_SIZE"

echo "Waiting for rescue disk ${RESCUE_DISK_NAME}…"
for _ in $(seq 1 60); do
  STATE=$(aws lightsail get-disk \
    --region "$REGION" \
    --disk-name "$RESCUE_DISK_NAME" \
    --query 'disk.state' \
    --output text 2>/dev/null || echo missing)
  [[ "$STATE" == "available" ]] && break
  sleep 10
done

wait_instance_state "$NEW_INSTANCE_NAME" "running"

aws lightsail attach-disk \
  --region "$REGION" \
  --disk-name "$RESCUE_DISK_NAME" \
  --instance-name "$NEW_INSTANCE_NAME" \
  --disk-path /dev/xvdf

NEW_PUBLIC_IP=$(aws lightsail get-instance \
  --region "$REGION" \
  --instance-name "$NEW_INSTANCE_NAME" \
  --query 'instance.publicIpAddress' \
  --output text)

echo "NEW_PUBLIC_IP=${NEW_PUBLIC_IP}"
echo "MIGRATE_ATTACH_DONE=1"
