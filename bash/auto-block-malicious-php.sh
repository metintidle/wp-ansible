#!/bin/bash
#####################################################################
# Auto-Block Malicious PHP Requests Script
#
# This script analyzes nginx error logs for "Primary script unknown"
# errors, extracts malicious PHP filenames, and automatically updates
# the security rules to block them.
#
# Features:
# - Parses nginx error logs for exploit attempts
# - Extracts unique malicious PHP filenames
# - Updates nginx security rules automatically
# - Optionally blocks attacking IPs with fail2ban
# - Creates backup before modifying files
#
# Usage:
#   ./auto-block-malicious-php.sh [options]
#
# Options:
#   --log FILE        Nginx error log file (default: /var/log/nginx/error.log)
#   --rules FILE      Security rules config (default: /etc/nginx/default.d/security.conf)
#   --dry-run         Show what would be done without making changes
#   --block-ips       Also block the attacking IPs with fail2ban
#   --days N          Only analyze logs from last N days (default: 7)
#   --help            Show this help message
#
#####################################################################

set -euo pipefail

# Default configuration
NGINX_ERROR_LOG="${NGINX_ERROR_LOG:-/var/log/nginx/error.log}"
SECURITY_RULES="${SECURITY_RULES:-/etc/nginx/default.d/security.conf}"
DRY_RUN=false
BLOCK_IPS=false
DAYS_BACK=7
BACKUP_DIR="/var/backups/nginx-security"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --log)
      NGINX_ERROR_LOG="$2"
      shift 2
      ;;
    --rules)
      SECURITY_RULES="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --block-ips)
      BLOCK_IPS=true
      shift
      ;;
    --days)
      DAYS_BACK="$2"
      shift 2
      ;;
    --help)
      grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Verify files exist
if [[ ! -f "$NGINX_ERROR_LOG" ]]; then
  log_error "Nginx error log not found: $NGINX_ERROR_LOG"
  exit 1
fi

if [[ ! -f "$SECURITY_RULES" ]]; then
  log_error "Security rules file not found: $SECURITY_RULES"
  exit 1
fi

# Check if running with sufficient permissions
if [[ ! -w "$SECURITY_RULES" ]] && [[ "$DRY_RUN" == false ]]; then
  log_error "No write permission for $SECURITY_RULES. Run with sudo or use --dry-run"
  exit 1
fi

log_info "Analyzing nginx error log: $NGINX_ERROR_LOG"
log_info "Last $DAYS_BACK days of logs"

# Extract malicious PHP requests from error log
# Look for "Primary script unknown" errors and extract the requested PHP file
MALICIOUS_REQUESTS=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | \
  awk '{
    # Extract the request path from the log line
    for(i=1; i<=NF; i++) {
      if($i == "request:") {
        # Get the HTTP request (e.g., "GET /malicious.php HTTP/1.1")
        request = $(i+1)
        # Remove quotes and method
        gsub(/"/, "", request)
        gsub(/GET |POST |HEAD |PUT |DELETE |OPTIONS /, "", request)
        # Remove HTTP version
        gsub(/ HTTP\/[0-9.]+/, "", request)
        # Extract just the PHP filename without path
        if (match(request, /\/([^\/\?]+\.php)/, arr)) {
          print arr[1]
        }
      }
    }
  }' | \
  # Remove .php extension
  sed 's/\.php$//' | \
  # Sort and get unique entries
  sort -u | \
  # Filter out legitimate WordPress files
  grep -vE '^(index|wp-login|wp-cron|wp-admin|admin-ajax|admin-post|xmlrpc)$' || true
)

# Also extract full paths for plugin exploits
MALICIOUS_PLUGIN_FILES=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | \
  awk '{
    for(i=1; i<=NF; i++) {
      if($i == "request:") {
        request = $(i+1)
        gsub(/"/, "", request)
        gsub(/GET |POST |HEAD |PUT |DELETE |OPTIONS /, "", request)
        gsub(/ HTTP\/[0-9.]+/, "", request)
        # Extract plugin file paths
        if (match(request, /\/wp-content\/plugins\/[^\/]+\/([^\/\?]+\.php)/, arr)) {
          print arr[1]
        }
      }
    }
  }' | \
  sed 's/\.php$//' | \
  sort -u | \
  grep -vE '^(index|admin)$' || true
)

# Count findings
ROOT_FILE_COUNT=$(echo "$MALICIOUS_REQUESTS" | grep -c . || echo "0")
PLUGIN_FILE_COUNT=$(echo "$MALICIOUS_PLUGIN_FILES" | grep -c . || echo "0")

log_info "Found $ROOT_FILE_COUNT unique malicious root-level PHP files"
log_info "Found $PLUGIN_FILE_COUNT unique malicious plugin PHP files"

# Display findings
if [[ $ROOT_FILE_COUNT -gt 0 ]]; then
  log_warning "Malicious root-level PHP files detected:"
  echo "$MALICIOUS_REQUESTS" | sed 's/^/  - /' | head -20
  if [[ $ROOT_FILE_COUNT -gt 20 ]]; then
    echo "  ... and $((ROOT_FILE_COUNT - 20)) more"
  fi
fi

if [[ $PLUGIN_FILE_COUNT -gt 0 ]]; then
  log_warning "Malicious plugin PHP files detected:"
  echo "$MALICIOUS_PLUGIN_FILES" | sed 's/^/  - /' | head -10
  if [[ $PLUGIN_FILE_COUNT -gt 10 ]]; then
    echo "  ... and $((PLUGIN_FILE_COUNT - 10)) more"
  fi
fi

# If no new malicious files found, exit
if [[ $ROOT_FILE_COUNT -eq 0 ]] && [[ $PLUGIN_FILE_COUNT -eq 0 ]]; then
  log_success "No new malicious PHP files detected!"
  exit 0
fi

# Extract current blocked patterns from security rules
CURRENT_PATTERNS=$(grep -oP 'location ~\* \^/\(([^)]+)\)\\\.php\$' "$SECURITY_RULES" | head -1 | sed 's/location ~\* \^\/(\(.*\))\\\.php\$/\1/' || echo "")

log_info "Current blocked patterns: $(echo "$CURRENT_PATTERNS" | tr '|' ' ')"

# Merge new patterns with existing ones
ALL_PATTERNS=$(echo -e "${CURRENT_PATTERNS//|/\\n}\n${MALICIOUS_REQUESTS}" | sort -u | paste -sd '|' -)

# Merge plugin patterns
CURRENT_PLUGIN_PATTERNS=$(grep -oP 'wp_filemanager\|[^)]+' "$SECURITY_RULES" | head -1 || echo "")
ALL_PLUGIN_PATTERNS=$(echo -e "${CURRENT_PLUGIN_PATTERNS//|/\\n}\n${MALICIOUS_PLUGIN_FILES}" | sort -u | paste -sd '|' -)

log_info "Updated patterns count: $(echo "$ALL_PATTERNS" | tr '|' '\n' | wc -l)"

# Prepare the new location block
NEW_ROOT_BLOCK="location ~* ^/(${ALL_PATTERNS})\\.php\$ {
  return 403;
}"

NEW_PLUGIN_BLOCK="location ~* ^/wp-content/plugins/.+/(${ALL_PLUGIN_PATTERNS})\\.php\$ {
  return 403;
}"

# Show what will be changed
echo ""
log_info "New root-level PHP blocking rule:"
echo "$NEW_ROOT_BLOCK"
echo ""
log_info "New plugin PHP blocking rule:"
echo "$NEW_PLUGIN_BLOCK"
echo ""

# Exit if dry-run
if [[ "$DRY_RUN" == true ]]; then
  log_warning "DRY RUN mode - no changes made"
  exit 0
fi

# Ask for confirmation
read -p "Do you want to update the security rules? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
  log_warning "Aborted by user"
  exit 0
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Backup current security rules
BACKUP_FILE="$BACKUP_DIR/security.conf.$(date +%Y%m%d_%H%M%S).bak"
cp "$SECURITY_RULES" "$BACKUP_FILE"
log_success "Backup created: $BACKUP_FILE"

# Update the security rules file
# Replace the first location block that matches the pattern
perl -i -pe '
  BEGIN {
    $new_root = q{'"$NEW_ROOT_BLOCK"'};
    $new_plugin = q{'"$NEW_PLUGIN_BLOCK"'};
    $replaced_root = 0;
    $replaced_plugin = 0;
    $in_root_block = 0;
    $in_plugin_block = 0;
  }

  # Match start of root-level malicious PHP block
  if (/^location ~\* \^\/\([^)]+\)\\\.php\$/ && !$replaced_root) {
    $in_root_block = 1;
    $_ = $new_root . "\n";
    $replaced_root = 1;
    next;
  }

  # Skip lines inside root block being replaced
  if ($in_root_block) {
    if (/^}/) {
      $in_root_block = 0;
      $_ = "";
    } else {
      $_ = "";
    }
  }

  # Match start of plugin malicious PHP block
  if (/^location ~\* \^\/wp-content\/plugins\/.+\/\([^)]+\)\\\.php\$/ && !$replaced_plugin) {
    $in_plugin_block = 1;
    $_ = $new_plugin . "\n";
    $replaced_plugin = 1;
    next;
  }

  # Skip lines inside plugin block being replaced
  if ($in_plugin_block) {
    if (/^}/) {
      $in_plugin_block = 0;
      $_ = "";
    } else {
      $_ = "";
    }
  }
' "$SECURITY_RULES"

log_success "Security rules updated successfully!"

# Test nginx configuration
log_info "Testing nginx configuration..."
if nginx -t 2>&1 | grep -q "successful"; then
  log_success "Nginx configuration test passed!"

  # Reload nginx
  log_info "Reloading nginx..."
  systemctl reload nginx
  log_success "Nginx reloaded successfully!"
else
  log_error "Nginx configuration test failed! Restoring backup..."
  cp "$BACKUP_FILE" "$SECURITY_RULES"
  log_success "Backup restored. Please check the configuration manually."
  exit 1
fi

# Block IPs if requested
if [[ "$BLOCK_IPS" == true ]]; then
  log_info "Extracting attacking IP addresses..."

  ATTACKING_IPS=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | \
    awk '{
      for(i=1; i<=NF; i++) {
        if($i == "client:") {
          ip = $(i+1)
          gsub(/,/, "", ip)
          print ip
        }
      }
    }' | sort -u)

  IP_COUNT=$(echo "$ATTACKING_IPS" | grep -c . || echo "0")
  log_info "Found $IP_COUNT unique attacking IPs"

  if command -v fail2ban-client &> /dev/null; then
    log_info "Blocking IPs with fail2ban..."
    echo "$ATTACKING_IPS" | while read -r ip; do
      if [[ -n "$ip" ]]; then
        fail2ban-client set nginx-unknown-script banip "$ip" 2>/dev/null || true
        echo "  - Banned: $ip"
      fi
    done
    log_success "IPs blocked via fail2ban"
  else
    log_warning "fail2ban not found. Install fail2ban to enable IP blocking."
  fi
fi

# Summary
echo ""
log_success "=== Summary ==="
echo "  Root-level patterns blocked: $(echo "$ALL_PATTERNS" | tr '|' '\n' | wc -l)"
echo "  Plugin patterns blocked: $(echo "$ALL_PLUGIN_PATTERNS" | tr '|' '\n' | wc -l)"
echo "  Backup location: $BACKUP_FILE"
if [[ "$BLOCK_IPS" == true ]]; then
  echo "  IPs blocked: $IP_COUNT"
fi
echo ""
log_success "Security rules updated and active!"
