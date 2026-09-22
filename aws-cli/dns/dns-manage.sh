#!/usr/bin/env bash
# Route 53 — create hosted zone and A/AAAA records (apex + www).
# Run in AWS CloudShell or locally with AWS CLI credentials.
#
# Usage:
#   ./aws-cli/dns/dns-manage.sh setup
#   ./aws-cli/dns/dns-manage.sh create-zone
#   ./aws-cli/dns/dns-manage.sh upsert-records
#   ./aws-cli/dns/dns-manage.sh show
#   ./aws-cli/dns/dns-manage.sh upsert-batch aws-cli/dns/records/ucdrs.com.au.json
#
# Environment:
#   CUSTOMER — preset key (see below); sets AWS_PROFILE + DOMAIN when unset
#   AWS_PROFILE — IAM login profile from ~/.aws/config (sync-config)
#   DOMAIN   — default tongarrafamilypractice.com
#   IPV4     — required for every domain except the download default; no implicit fallback
#   IPV6     — optional; when empty, AAAA records are skipped (never defaulted for other domains)
#   TTL      — default 300
#   ZONE_ID  — optional; resolved from DOMAIN when unset
#
# Customer presets (login: cd auto-aws && npm run cli-login -- --account <Profile>):
#   ucdrs / UnanderraCommunityHealth — account 055537175907, domain ucdrs.com.au

set -euo pipefail

resolve_customer() {
  local customer="$1"
  case "$customer" in
    ucdrs|UnanderraCommunityHealth)
      echo "UnanderraCommunityHealth|ucdrs.com.au"
      ;;
    *)
      echo "${customer}|"
      ;;
  esac
}

CUSTOMER="${CUSTOMER:-}"
AWS_PROFILE="${AWS_PROFILE:-}"

if [[ -n "$CUSTOMER" ]]; then
  IFS='|' read -r customer_profile customer_domain <<<"$(resolve_customer "$CUSTOMER")"
  AWS_PROFILE="${AWS_PROFILE:-$customer_profile}"
  if [[ -n "$customer_domain" ]]; then
    DOMAIN="${DOMAIN:-$customer_domain}"
  fi
fi

# The implicit IP defaults belong to the tongarrafamilypractice.com zone ONLY.
# They must never leak into another domain: that is how gerringonggp.com.au got AAAA
# records pointing at the Tongarra server, so IPv6 visitors were served
# tongarrafamilypractice.com (wrong site, wrong TLS certificate) while IPv4 was fine.
# An empty IPV4/IPV6 — a failed Lightsail lookup, for example — is therefore an error
# for every domain other than the default one.
DEFAULTS_DOMAIN="tongarrafamilypractice.com"
DEFAULTS_IPV4="13.211.239.203"
DEFAULTS_IPV6="2406:da1c:f1e:dc00:371d:f5a3:741:8281"

DOMAIN="${DOMAIN:-$DEFAULTS_DOMAIN}"
TTL="${TTL:-300}"
ZONE_ID="${ZONE_ID:-}"

if [[ "$DOMAIN" == "$DEFAULTS_DOMAIN" ]]; then
  IPV4="${IPV4:-$DEFAULTS_IPV4}"
  IPV6="${IPV6:-$DEFAULTS_IPV6}"
else
  if [[ -z "${IPV4:-}" || "${IPV4:-}" == "None" ]]; then
    echo "ERROR: IPV4 must be set explicitly for ${DOMAIN} — refusing to fall back to ${DEFAULTS_IPV4}" >&2
    exit 1
  fi
  if [[ -n "${IPV6:-}" && "${IPV6:-}" == "$DEFAULTS_IPV6" ]]; then
    echo "ERROR: refusing to publish ${DEFAULTS_DOMAIN}'s IPv6 (${DEFAULTS_IPV6}) in ${DOMAIN}" >&2
    exit 1
  fi
  IPV6="${IPV6:-}"
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  setup           Create hosted zone (if missing) and upsert A/AAAA records
  create-zone     Create Route 53 hosted zone for DOMAIN
  upsert-records  Upsert apex + www A/AAAA records into the zone
  upsert-batch    Upsert records from a Route 53 change-batch JSON file
  show            Print zone ID, nameservers, and A/AAAA records

Environment:
  CUSTOMER=${CUSTOMER:-<unset>}
  AWS_PROFILE=${AWS_PROFILE:-<unset>}
  DOMAIN=${DOMAIN}
  IPV4=${IPV4}
  IPV6=${IPV6}
  TTL=${TTL}
  ZONE_ID=${ZONE_ID:-<auto>}
EOF
}

require_aws() {
  command -v aws >/dev/null 2>&1 || {
    echo "aws CLI not found in PATH" >&2
    exit 1
  }
}

aws_cmd() {
  if [[ -n "$AWS_PROFILE" ]]; then
    aws --profile "$AWS_PROFILE" "$@"
  else
    aws "$@"
  fi
}

normalize_zone_id() {
  sed 's|/hostedzone/||'
}

resolve_zone_id() {
  if [[ -n "$ZONE_ID" ]]; then
    echo "$ZONE_ID"
    return 0
  fi

  local zone_id
  zone_id=$(aws_cmd route53 list-hosted-zones-by-name \
    --dns-name "$DOMAIN" \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id | [0]" \
    --output text)

  if [[ -z "$zone_id" || "$zone_id" == "None" ]]; then
    echo "Hosted zone not found for ${DOMAIN}" >&2
    exit 1
  fi

  echo "$zone_id" | normalize_zone_id
}

create_zone() {
  local existing_id
  existing_id=$(aws_cmd route53 list-hosted-zones-by-name \
    --dns-name "$DOMAIN" \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id | [0]" \
    --output text 2>/dev/null || true)

  if [[ -n "$existing_id" && "$existing_id" != "None" ]]; then
    ZONE_ID=$(echo "$existing_id" | normalize_zone_id)
    echo "Hosted zone already exists: ${ZONE_ID}"
    return 0
  fi

  local caller_ref
  caller_ref="${DOMAIN}-$(date +%s)"

  ZONE_ID=$(aws_cmd route53 create-hosted-zone \
    --name "$DOMAIN" \
    --caller-reference "$caller_ref" \
    --query 'HostedZone.Id' \
    --output text | normalize_zone_id)

  echo "Created hosted zone: ${ZONE_ID}"
}

ipv6_usable() {
  [[ -n "${IPV6:-}" && "$IPV6" != "None" && "$IPV6" == *:* ]]
}

delete_www_cname_if_present() {
  local zone_id="$1"
  local existing
  existing=$(aws_cmd route53 list-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --query "ResourceRecordSets[?Name=='www.${DOMAIN}.' && Type=='CNAME'] | [0]" \
    --output json 2>/dev/null || echo "null")
  if [[ -z "$existing" || "$existing" == "null" || "$existing" == "{}" ]]; then
    return 0
  fi
  local ttl value
  ttl=$(python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('TTL',300))" <<<"$existing")
  value=$(python3 -c "import json,sys; r=json.load(sys.stdin); print(r['ResourceRecords'][0]['Value'])" <<<"$existing")
  local del_file
  del_file=$(mktemp)
  cat >"$del_file" <<EOF
{
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "www.${DOMAIN}",
        "Type": "CNAME",
        "TTL": ${ttl},
        "ResourceRecords": [{ "Value": "${value}" }]
      }
    }
  ]
}
EOF
  aws_cmd route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --change-batch "file://${del_file}"
  rm -f "$del_file"
  echo "Removed www CNAME (conflicts with www A) before upsert"
}

upsert_records() {
  ZONE_ID=$(resolve_zone_id)

  if [[ -z "${IPV4:-}" || "$IPV4" == "None" ]]; then
    echo "ERROR: IPV4 is required to upsert A records" >&2
    exit 1
  fi

  delete_www_cname_if_present "$ZONE_ID"

  local batch_file
  batch_file=$(mktemp)

  cat >"$batch_file" <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [{ "Value": "${IPV4}" }]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "www.${DOMAIN}",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [{ "Value": "${IPV4}" }]
      }
    }
EOF

  if ipv6_usable; then
    cat >>"$batch_file" <<EOF
    ,
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}",
        "Type": "AAAA",
        "TTL": ${TTL},
        "ResourceRecords": [{ "Value": "${IPV6}" }]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "www.${DOMAIN}",
        "Type": "AAAA",
        "TTL": ${TTL},
        "ResourceRecords": [{ "Value": "${IPV6}" }]
      }
    }
EOF
  else
    echo "Skipping AAAA (IPV6 unset or invalid)"
  fi

  cat >>"$batch_file" <<EOF
  ]
}
EOF

  aws_cmd route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://${batch_file}"
  rm -f "$batch_file"

  echo "Upserted A/AAAA records in zone ${ZONE_ID}"
}

upsert_batch() {
  local batch_file="${1:-}"
  if [[ -z "$batch_file" || ! -f "$batch_file" ]]; then
    echo "Usage: $(basename "$0") upsert-batch <change-batch.json>" >&2
    exit 1
  fi

  ZONE_ID=$(resolve_zone_id)

  aws_cmd route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://${batch_file}"

  echo "Upserted records from ${batch_file} in zone ${ZONE_ID}"
}

show_zone() {
  ZONE_ID=$(resolve_zone_id)

  echo "DOMAIN=${DOMAIN}"
  echo "ZONE_ID=${ZONE_ID}"
  echo
  echo "Nameservers:"
  aws_cmd route53 get-hosted-zone \
    --id "$ZONE_ID" \
    --query 'DelegationSet.NameServers' \
    --output table

  echo
  echo "A / AAAA records:"
  aws_cmd route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Type=='A' || Type=='AAAA']" \
    --output table
}

main() {
  require_aws

  local cmd="${1:-}"
  case "$cmd" in
    setup)
      create_zone
      upsert_records
      show_zone
      ;;
    create-zone)
      create_zone
      show_zone
      ;;
    upsert-records)
      upsert_records
      show_zone
      ;;
    upsert-batch)
      upsert_batch "${2:-}"
      ;;
    show)
      show_zone
      ;;
    -h|--help|help|"")
      usage
      [[ -n "$cmd" ]] || exit 0
      exit 1
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
