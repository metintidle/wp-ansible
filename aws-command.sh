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
# Part 1 — Pull your files off the dead disk
# Prerequisite: create wp-web-23 first (lines 3-9 above; same AZ ap-southeast-2a)

# Step 1: Snapshot the broken instance root volume
aws lightsail create-disk-snapshot \
  --region ap-southeast-2 \
  --instance-name Amazon_Linux_2023-1 \
  --disk-snapshot-name al2-rescue

# Step 2: Check snapshot size/AZ (use size for step 3; AZ must match wp-web-23)
aws lightsail get-disk-snapshot \
  --region ap-southeast-2 \
  --disk-snapshot-name al2-rescue \
  --query 'diskSnapshot.{name:name,size:sizeInGb,az:fromDiskAvailabilityZone}'

# Step 3: Create rescue disk from snapshot (same AZ as wp-web-23)
aws lightsail create-disk-from-snapshot \
  --region ap-southeast-2 \
  --disk-name al2-rescue-disk \
  --disk-snapshot-name al2-rescue \
  --availability-zone ap-southeast-2a \
  --size-in-gb 20

# Step 4: Attach rescue disk to wp-web-23
aws lightsail attach-disk \
  --region ap-southeast-2 \
  --disk-name al2-rescue-disk \
  --instance-name wp-web-23 \
  --disk-path /dev/xvdf

# Step 5: SSH into wp-web-23, then mount and copy:
  
lsblk                                  # find the disk, e.g. xvdf1
sudo mkdir /mnt/rescue
sudo mount /dev/xvdf1 /mnt/rescue
sudo cp -a /mnt/rescue/usr/share/nginx/html/* ~/html/
# This disk-attach approach is AWS's documented method for recovering data from the root volume of a botched instance.
# aws cli to stop lightsail instance wp-web-23 
aws lightsail stop-instance \
  --instance-name wp-web-23 \
  --region ap-southeast-2
# aws cli to 