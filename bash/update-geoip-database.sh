#!/bin/bash
# This script downloads and configures the MaxMind GeoLite2 database for use with xt_geoip.

# --- Configuration ---
# IMPORTANT: You must sign up for a free MaxMind account to get a license key.
# 1. Go to https://www.maxmind.com/en/geolite2/signup
# 2. Create an account and generate a new license key.
# 3. Paste your license key below.
MAXMIND_LICENSE_KEY="YOUR_LICENSE_KEY_HERE"

GEOIP_DIR="/usr/share/xt_geoip"
DATABASE_URL="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country-CSV&license_key=${MAXMIND_LICENSE_KEY}&suffix=zip"

# --- Execution ---

# Exit immediately if a command exits with a non-zero status.
set -e

# 1. Check for license key
if [ "$MAXMIND_LICENSE_KEY" = "YOUR_LICENSE_KEY_HERE" ]; then
    echo "Error: MaxMind license key is not set. Please edit this script to add your key."
    exit 1
fi

# 2. Install required tools
echo "Installing required tools (curl, unzip)..."
yum install -y curl unzip

# 3. Download and extract the database
echo "Downloading GeoLite2 database..."
curl -s -o /tmp/GeoLite2-Country-CSV.zip "$DATABASE_URL"

echo "Extracting database..."
unzip -o -q /tmp/GeoLite2-Country-CSV.zip -d /tmp/geoip_temp

# 4. Create the target directory for xt_geoip
echo "Creating GeoIP directory: $GEOIP_DIR"
mkdir -p "$GEOIP_DIR"

# 5. Convert the CSV to the format required by xt_geoip
echo "Converting CSV to xt_geoip format..."
/usr/libexec/xtables-addons/xt_geoip_build -D "$GEOIP_DIR" -S /tmp/geoip_temp/GeoLite2-Country-Locations-en.csv /tmp/geoip_temp/GeoLite2-Country-Blocks-IPv4.csv

# 6. Clean up temporary files
echo "Cleaning up..."
rm -rf /tmp/GeoLite2-Country-CSV.zip /tmp/geoip_temp

echo "GeoIP database update complete."
