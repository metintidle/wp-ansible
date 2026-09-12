# CloudShell command log for rescue-disk detach + static IP move (not the live path).
# Live orchestrator: ../migrate-al2-al2023.sh → ../migrate-detach.sh
# See ../../README.md
#
# Step 5: SSH into wp-web-23, then mount and copy:
# This disk-attach approach is AWS's documented method for recovering data from the root volume of a botched instance.
# aws cli to stop lightsail instance wp-web-23 

aws lightsail stop-instance \
  --instance-name wp-web-23 \
  --region ap-southeast-2

# Wait until state is "stopped"
INSTANCE_STATE=$(aws lightsail get-instance \
  --region ap-southeast-2 \
  --instance-name wp-web-23 \
  --query 'instance.state.name' \
  --output text)
echo  $INSTANCE_STATE
# 3. Detach the disk
aws lightsail detach-disk \
  --region ap-southeast-2 \
  --disk-name al2-rescue-disk


# 4. Delete the disk
aws lightsail delete-disk \
  --region ap-southeast-2 \
  --disk-name al2-rescue-disk

# 5. Start the instance
aws lightsail start-instance \
  --instance-name wp-web-23 \
  --region ap-southeast-2


INSTANCE_NAME_AL2=$(aws lightsail get-instances \
  --region ap-southeast-2 \
  --query 'instances[?name!=`wp-web-23`] | [0].name' \
  --output text)
echo "Old instance: $INSTANCE_NAME_AL2"

STATIC_IP_NAME=$(aws lightsail get-static-ips \
  --region ap-southeast-2 \
  --query "staticIps[?attachedTo=='${INSTANCE_NAME_AL2}'].name | [0]" \
  --output text)
echo "Static IP to move: $STATIC_IP_NAME"

# 6. Detach static IP from old instance
aws lightsail detach-static-ip \
  --region ap-southeast-2 \
  --static-ip-name "$STATIC_IP_NAME"

# 7. Attach static IP to wp-web-23
aws lightsail attach-static-ip \
  --region ap-southeast-2 \
  --static-ip-name "$STATIC_IP_NAME" \
  --instance-name wp-web-23

INSTANCE_STATE=$(aws lightsail get-instance \
  --region ap-southeast-2 \
  --instance-name wp-web-23 \
  --query 'instance.state.name' \
  --output text)
echo "Instance state: $INSTANCE_STATE"

PUBLIC_IP=$(aws lightsail get-static-ip \
  --region ap-southeast-2 \
  --static-ip-name "$STATIC_IP_NAME" \
  --query 'staticIp.ipAddress' \
  --output text)
echo "Static IP: $PUBLIC_IP"

aws lightsail stop-instance \
  --region ap-southeast-2 \
  --instance-name "$INSTANCE_NAME_AL2"
# 8. Delete old AL2 instance
aws lightsail delete-instance \
  --region ap-southeast-2 \
  --instance-name "$INSTANCE_NAME_AL2" \
  --force-delete-add-ons

echo "Deleted instance: $INSTANCE_NAME_AL2"

NEW_PUBLIC_IPV6=$(aws lightsail get-instance \
  --region ap-southeast-2 \
  --instance-name wp-web-23 \
  --query 'instance.ipv6Addresses[0]' \
  --output text)
echo "New IPv6: $NEW_PUBLIC_IPV6"

# Lightsail IPv6 is not static. Upsert AAAA on names whose A record is this
# instance's static IPv4 so only this site's zones are changed.
if [ -z "$NEW_PUBLIC_IPV6" ] || [ "$NEW_PUBLIC_IPV6" = "None" ]; then
  echo "No IPv6 on wp-web-23; skip Route53 AAAA update"
else
  aws route53 list-hosted-zones \
    --query 'HostedZones[*].[Id,Name]' \
    --output text | while IFS=$'\t' read -r ZONE_ID ZONE_NAME; do
      ZONE_ID="${ZONE_ID##*/}"
      echo "Checking zone: $ZONE_NAME ($ZONE_ID)"

      aws route53 list-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --query "ResourceRecordSets[?Type=='A'].[Name,TTL,ResourceRecords[0].Value]" \
        --output text | while IFS=$'\t' read -r RECORD_NAME RECORD_TTL RECORD_IP; do
          [ "$RECORD_IP" = "$PUBLIC_IP" ] || continue
          echo "UPSERT AAAA $RECORD_NAME -> $NEW_PUBLIC_IPV6"
          aws route53 change-resource-record-sets \
            --hosted-zone-id "$ZONE_ID" \
            --change-batch "$(cat <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$RECORD_NAME",
      "Type": "AAAA",
      "TTL": ${RECORD_TTL:-300},
      "ResourceRecords": [{"Value": "$NEW_PUBLIC_IPV6"}]
    }
  }]
}
EOF
)"
        done
    done
fi
