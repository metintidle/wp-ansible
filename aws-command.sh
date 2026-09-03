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
aws lightsail create-disk-snapshot \
  --region ap-southeast-2 \
  --instance-name Amazon_Linux_2023-1 \
  --disk-snapshot-name wmeds-rescue
  #1. Lightsail → Snapshots → Disk snapshots → ⋮ next to lifeimaging-rescue → Create new disk → same AZ → Create
  #2. Create a fresh Amazon Linux 2023 instance (this becomes your new server). Attach the rescue disk: Storage → Attach disk
  #3. Browser-SSH into the fresh instance (clean sshd = works), then mount and copy:
  
lsblk                                  # find the disk, e.g. xvdf1
sudo mkdir /mnt/rescue
sudo mount /dev/xvdf1 /mnt/rescue
sudo cp -a /mnt/rescue/usr/share/nginx/html/wp-content/uploads ~/uploads-backup
This disk-attach approach is AWS's documented method for recovering data from the root volume of a botched instance.