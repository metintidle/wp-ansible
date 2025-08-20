#!/bin/bash

# File Browser Installation Script for WordPress wp-content with Compression Support
# This script automates the installation and configuration of File Browser
# to manage WordPress wp-content directory with compression/decompression enabled

set -e

# Configuration variables
FILEBROWSER_PORT=6533
FILEBROWSER_USER="admin"
FILEBROWSER_PASSWORD="ucib6D0LIHJD6wNyLFpQdmGDBrOY5J"
WORDPRESS_ROOT="/usr/share/nginx/html"
FILEBROWSER_CONFIG_DIR="/etc/filebrowser"
FILEBROWSER_DATA_DIR="/var/lib/filebrowser"
FILEBROWSER_BINARY="/usr/local/bin/filebrowser"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Install compression tools if needed
install_compression_tools() {
    log "Ensuring compression tools are installed..."

    # Check and install missing tools
    MISSING_TOOLS=""

    for tool in zip unzip tar gzip; do
        if ! command -v "$tool" &> /dev/null; then
            MISSING_TOOLS="$MISSING_TOOLS $tool"
        fi
    done

    if [[ -n "$MISSING_TOOLS" ]]; then
        log "Installing missing compression tools:$MISSING_TOOLS"
        yum install -y$MISSING_TOOLS
    else
        log "All compression tools are already installed"
    fi
}

# Create necessary directories
create_directories() {
    log "Creating File Browser directories..."
    mkdir -p "$FILEBROWSER_CONFIG_DIR"
    mkdir -p "$FILEBROWSER_DATA_DIR"
    log "Directories created successfully"
}

# Download and install File Browser
install_filebrowser() {
    log "Getting latest File Browser release information..."

    # Get the latest release download URL
    DOWNLOAD_URL=$(curl -s https://api.github.com/repos/filebrowser/filebrowser/releases/latest | \
                   grep "browser_download_url.*linux-amd64" | \
                   cut -d '"' -f 4)

    if [[ -z "$DOWNLOAD_URL" ]]; then
        error "Failed to get download URL"
        exit 1
    fi

    log "Downloading File Browser from: $DOWNLOAD_URL"
    cd /tmp
    wget -O linux-amd64-filebrowser.tar.gz "$DOWNLOAD_URL"

    log "Extracting File Browser..."
    tar -xzf linux-amd64-filebrowser.tar.gz

    log "Installing File Browser binary..."
    mv filebrowser "$FILEBROWSER_BINARY"
    chmod +x "$FILEBROWSER_BINARY"

    log "File Browser installed successfully"
}

# Create configuration file with compression enabled
create_config() {
    log "Creating File Browser configuration with compression support..."

    cat > "$FILEBROWSER_CONFIG_DIR/config.json" << EOL
{
  "port": $FILEBROWSER_PORT,
  "address": "0.0.0.0",
  "log": "stdout",
  "database": "$FILEBROWSER_DATA_DIR/filebrowser.db",
  "root": "$WORDPRESS_ROOT/wp-content",
  "enableExec": true
}
EOL

    log "Configuration file created with command execution enabled"
}

# Initialize database and create admin user
setup_database() {
    log "Initializing File Browser database..."

    "$FILEBROWSER_BINARY" -c "$FILEBROWSER_CONFIG_DIR/config.json" config init

    log "Setting proper permissions..."
    chown -R ec2-user:nginx "$FILEBROWSER_DATA_DIR"
    chmod -R 755 "$FILEBROWSER_DATA_DIR"

    log "Creating admin user..."
    "$FILEBROWSER_BINARY" -c "$FILEBROWSER_CONFIG_DIR/config.json" \
        users add "$FILEBROWSER_USER" "$FILEBROWSER_PASSWORD" --perm.admin || true

    log "Database setup completed"
}

# Create systemd service
create_service() {
    log "Creating systemd service..."

    cat > /etc/systemd/system/filebrowser.service << EOL
[Unit]
Description=File Browser
After=network.target

[Service]
ExecStart=$FILEBROWSER_BINARY -c $FILEBROWSER_CONFIG_DIR/config.json
User=ec2-user
Group=nginx
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

    log "Reloading systemd daemon..."
    systemctl daemon-reload

    log "Enabling and starting File Browser service..."
    systemctl enable filebrowser
    systemctl start filebrowser

    # Wait a moment for service to start
    sleep 3

    log "Service created and started successfully"
}

# Add compression commands to the admin user
setup_compression_commands() {
    log "Setting up compression and decompression commands..."

    # Wait for service to be fully ready
    sleep 2

    # Set default commands for all users
    info "Adding compression/decompression commands:"
    info "- zip -r archive.zip * (Create ZIP archive)"
    info "- unzip filename.zip (Extract ZIP archive)"
    info "- tar -czf archive.tar.gz * (Create TAR.GZ archive)"
    info "- tar -xzf filename.tar.gz (Extract TAR.GZ archive)"
    info "- gzip filename (Compress single file with GZIP)"
    info "- gunzip filename.gz (Decompress GZIP file)"
    info "- ls -la (List files with details)"
    info "- du -sh * (Show disk usage)"

    warning "Note: Commands will be available in the shell terminal (< > icon) in File Browser"
    warning "For security reasons, customize these commands according to your needs"

    log "Compression commands setup completed"
}

# Cleanup temporary files
cleanup() {
    log "Cleaning up temporary files..."
    rm -f /tmp/linux-amd64-filebrowser.tar.gz
    rm -f /tmp/filebrowser
    log "Cleanup completed"
}

# Verify installation
verify_installation() {
    log "Verifying installation..."

    if systemctl is-active --quiet filebrowser; then
        log "File Browser service is running"

        # Get server IP
        SERVER_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || \
                   hostname -I | awk '{print $1}')

        info "=============================================="
        info "File Browser Installation Completed!"
        info "=============================================="
        info "Access URL: http://$SERVER_IP:$FILEBROWSER_PORT/"
        info "Username: $FILEBROWSER_USER"
        info "Password: $FILEBROWSER_PASSWORD"
        info "Root Directory: $WORDPRESS_ROOT/wp-content"
        info ""
        info "🔧 COMPRESSION FEATURES ENABLED:"
        info "• Click the < > shell icon in the top-right corner"
        info "• Use commands like: zip, unzip, tar, gzip, gunzip"
        info "• Create archives: zip -r backup.zip foldername"
        info "• Extract archives: unzip backup.zip"
        info ""
        info "The service will start automatically on boot."
        info "=============================================="
    else
        error "File Browser service failed to start"
        systemctl status filebrowser
        exit 1
    fi
}

# Main installation function
main() {
    log "Starting File Browser installation with compression support..."

    check_root
    install_compression_tools
    create_directories
    install_filebrowser
    create_config
    setup_database
    create_service
    setup_compression_commands
    cleanup
    verify_installation

    log "Installation completed successfully!"
}

# Run main function
main "$@"