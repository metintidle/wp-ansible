#!/usr/bin/env bash
# Verify AL2 has a Lightsail static IP before starting migration.
# Usage: SOURCE_PUBLIC_IP=52.63.103.53 ./aws-cli/migrate/check-static-ip.sh

set -euo pipefail

REGION="${REGION:-ap-southeast-2}"
SOURCE_PUBLIC_IP="${SOURCE_PUBLIC_IP:?SOURCE_PUBLIC_IP required}"

STATIC=$(aws lightsail get-static-ips \
  --region "$REGION" \
  --query "staticIps[?ipAddress=='${SOURCE_PUBLIC_IP}'] | [0].{name:name,attached:attachedTo,ip:ipAddress}" \
  --output json)

if [ "$STATIC" = "null" ] || [ -z "$STATIC" ]; then
  echo "FAIL: No Lightsail static IP resource for ${SOURCE_PUBLIC_IP}" >&2
  echo "Create one in Lightsail → Networking → Create static IP → attach to AL2 instance." >&2
  echo "Then re-run migration attach phase." >&2
  exit 1
fi

echo "$STATIC"
echo "OK: static IP exists for ${SOURCE_PUBLIC_IP}"
