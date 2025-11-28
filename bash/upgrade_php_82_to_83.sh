#!/bin/bash

# PHP 8.2 to 8.3 Upgrade Script for Amazon Linux 2
# This script upgrades PHP from version 8.2 to 8.3

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (use sudo)"
    exit 1
fi

log "Starting PHP 8.2 to 8.3 upgrade process..."

# Backup current PHP configuration
log "Creating backup of current PHP configuration..."
BACKUP_DIR="/root/php_upgrade_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup PHP configuration files
cp -r /etc/php.ini "$BACKUP_DIR/" 2>/dev/null || warn "Could not backup /etc/php.ini"
cp -r /etc/php.d/ "$BACKUP_DIR/" 2>/dev/null || warn "Could not backup /etc/php.d/"
cp -r /etc/php-fpm.d/ "$BACKUP_DIR/" 2>/dev/null || warn "Could not backup /etc/php-fpm.d/"

log "Backup created in: $BACKUP_DIR"

# Stop PHP-FPM service
log "Stopping PHP-FPM service..."
systemctl stop php-fpm || warn "Could not stop php-fpm service"

# Remove all PHP 8.2 packages
log "Removing all PHP 8.2 packages..."
sudo dnf remove -y php8.2* || warn "Could not remove some PHP 8.2 packages"

# Update package index
log "Updating package index..."
dnf update -y

# Install PHP 8.3 packages
log "Installing PHP 8.3 packages..."
sudo dnf install -y php8.3 php8.3-fpm php8.3-mysqlnd php8.3-mbstring php8.3-intl php8.3-devel php8.3-gd php8.3-zip

# Install additional packages that might be needed
log "Installing additional PHP packages..."
ADDITIONAL_PACKAGES=(
    "php-opcache"
    "php-pear"
    "php-sqlite3"
)

for package in "${ADDITIONAL_PACKAGES[@]}"; do
    log "Installing $package..."
    dnf install -y "$package" || warn "Could not install $package"
done

# Restore configuration files
log "Restoring PHP configuration..."

# Copy back php.ini settings
if [ -f "$BACKUP_DIR/php.ini" ]; then
    log "Restoring php.ini settings..."
    # Copy custom settings while preserving PHP 8.3 defaults
    grep -E "^(upload_max_filesize|post_max_size|max_execution_time|memory_limit|realpath_cache_size|realpath_cache_ttl|session\.save_path)" "$BACKUP_DIR/php.ini" > /tmp/custom_php_settings.ini 2>/dev/null || true

    if [ -s /tmp/custom_php_settings.ini ]; then
        cat /tmp/custom_php_settings.ini >> /etc/php.ini
        log "Custom PHP settings restored"
    fi
    rm -f /tmp/custom_php_settings.ini
fi

# Restore PHP-FPM configuration
if [ -d "$BACKUP_DIR/php-fpm.d" ]; then
    log "Restoring PHP-FPM configuration..."
    # Restore www.conf with custom settings
    if [ -f "$BACKUP_DIR/php-fpm.d/www.conf" ]; then
        # Extract custom settings
        grep -E "^(user|group|pm|pm\.max_children|pm\.start_servers|pm\.min_spare_servers|pm\.max_spare_servers|pm\.max_requests)" "$BACKUP_DIR/php-fpm.d/www.conf" > /tmp/custom_fmp_settings.conf 2>/dev/null || true

        if [ -s /tmp/custom_fmp_settings.conf ]; then
            # Apply custom settings to new configuration
            while IFS= read -r line; do
                setting=$(echo "$line" | cut -d'=' -f1 | xargs)
                value=$(echo "$line" | cut -d'=' -f2- | xargs)
                sed -i "s|^${setting}.*|${setting} = ${value}|" /etc/php-fpm.d/www.conf
            done < /tmp/custom_fmp_settings.conf
            log "PHP-FPM custom settings restored"
        fi
        rm -f /tmp/custom_fmp_settings.conf
    fi
fi

# Reinstall PECL extensions
log "Updating PECL channel..."
pecl channel-update pecl.php.net || warn "Could not update PECL channel"

# Check if igbinary was installed and reinstall
if pecl list | grep -q igbinary; then
    log "Reinstalling igbinary extension..."
    pecl uninstall igbinary || warn "Could not uninstall old igbinary"
    pecl install igbinary || warn "Could not install igbinary"
fi

# Configure OPcache
log "Configuring OPcache..."
OPCACHE_CONFIG="/etc/php.d/10-opcache.ini"
cat > "$OPCACHE_CONFIG" << 'EOF'
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=300
opcache.fast_shutdown=1
opcache.save_comments=0
opcache.load_comments=0
opcache.max_file_size=1M
opcache.huge_code_pages=0
EOF

# Enable and start PHP-FPM
log "Starting and enabling PHP-FPM service..."
systemctl enable php-fpm
systemctl start php-fpm

# Restart Nginx if it's running
if systemctl is-active --quiet nginx; then
    log "Restarting Nginx..."
    systemctl restart nginx
fi

# Verify installation
log "Verifying PHP installation..."
PHP_VERSION=$(php -v | head -n 1)
log "Current PHP version: $PHP_VERSION"

if echo "$PHP_VERSION" | grep -q "8.3"; then
    log "✅ PHP 8.3 installation successful!"
else
    error "❌ PHP 8.3 installation may have failed. Current version: $PHP_VERSION"
fi

# Test PHP-FPM status
if systemctl is-active --quiet php-fpm; then
    log "✅ PHP-FPM is running successfully"
else
    error "❌ PHP-FPM is not running"
    systemctl status php-fpm
fi

# Display summary
log "=== UPGRADE SUMMARY ==="
log "Backup location: $BACKUP_DIR"
log "PHP version: $(php -v | head -n 1)"
log "PHP-FPM status: $(systemctl is-active php-fpm)"
log "Nginx status: $(systemctl is-active nginx 2>/dev/null || echo 'not running')"

log "PHP upgrade completed successfully!"
log "Please test your websites to ensure everything is working correctly."
log "If you encounter issues, you can restore from the backup at: $BACKUP_DIR"