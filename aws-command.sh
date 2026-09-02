#   --ip-address-type dualstack \

aws lightsail create-instances \
  --instance-names wp-web-23 \
  --availability-zone ap-southeast-2a \
  --blueprint-id amazon_linux_2023 \
  --bundle-id nano_3_2 \
  --ip-address-type ipv4 \
  --region ap-southeast-2

aws lightsail put-instance-public-ports \
  --region ap-southeast-2 \
  --instance-name wp-web-23 \
  --port-infos \
    fromPort=22,toPort=22,protocol=tcp,cidrs=111.220.137.221/32,43.245.170.89/32,158.180.7.100/32 \
    fromPort=80,toPort=80,protocol=tcp,cidrs=0.0.0.0/0 \
    fromPort=443,toPort=443,protocol=tcp,cidrs=0.0.0.0/0
# Step 1: Create the static IP (like naming it "StaticIp-1" in the dialog)
aws lightsail allocate-static-ip \
  --static-ip-name StaticIp-1 \
  --region ap-southeast-2
# Step 2: Attach to the instance (like clicking "Create and attach")
aws lightsail attach-static-ip \
  --static-ip-name StaticIp-1 \
  --instance-name wp-web-23 \
  --region ap-southeast-2

