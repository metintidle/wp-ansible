#!/bin/bash
# Disable WordPress built-in cron and setup system cron
# Run this on the server to immediately fix WP-Cron issues

set -e

echo "=== Disabling WordPress built-in cron ==="

# Add DISABLE_WP_CRON to wp-config.php if not already present
if ! grep -q "DISABLE_WP_CRON" /home/ec2-user/html/wp-config.php; then
    # Find the line with DB_COLLATE and add after it
    sudo sed -i "/define.*DB_COLLATE/a define('DISABLE_WP_CRON', true);" /home/ec2-user/html/wp-config.php
    echo "✓ Added DISABLE_WP_CRON to wp-config.php"
else
    echo "✓ DISABLE_WP_CRON already exists in wp-config.php"
fi

echo ""
echo "=== Setting up system cron job ==="

# Add cron job if it doesn't exist
(crontab -l 2>/dev/null | grep -q "wp cron event run") && echo "✓ Cron job already exists" || {
    (crontab -l 2>/dev/null; echo "*/5 * * * * cd /home/ec2-user/html && /usr/local/bin/wp cron event run --due-now > /dev/null 2>&1") | crontab -
    echo "✓ Added system cron job (runs every 5 minutes)"
}

echo ""
echo "=== Verification ==="
echo "Checking DISABLE_WP_CRON setting:"
grep "DISABLE_WP_CRON" /home/ec2-user/html/wp-config.php || echo "NOT FOUND"

echo ""
echo "Current cron jobs for ec2-user:"
crontab -l

echo ""
echo "✓ Done! WordPress cron will now run via system cron every 5 minutes."
echo "✓ This will significantly reduce PHP-FPM usage."
