#!/bin/bash
#####################################################################
# Analyze Malicious Requests from Nginx Error Log (Local Version)
#
# This script analyzes a local nginx error log file and generates
# updated security rules that can be deployed to the server.
#
# Usage:
#   ./analyze-malicious-requests.sh [nginx_error_log_file]
#
#####################################################################

# Default to nginx.log in current directory
NGINX_ERROR_LOG="${1:-nginx.log}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if log file exists
if [[ ! -f "$NGINX_ERROR_LOG" ]]; then
  log_error "Log file not found: $NGINX_ERROR_LOG"
  echo ""
  echo "Usage: $0 [path/to/nginx/error.log]"
  exit 1
fi

log_info "Analyzing nginx error log: $NGINX_ERROR_LOG"
echo ""

# Extract malicious root-level PHP requests
MALICIOUS_ROOT_FILES=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | \
  grep -oP 'GET /[^/\s]+\.php|POST /[^/\s]+\.php|HEAD /[^/\s]+\.php' | \
  sed 's/GET \///; s/POST \///; s/HEAD \///' | \
  sed 's/\.php$//' | \
  sort -u | \
  grep -vE '^(index|wp-login|wp-cron|xmlrpc)$' || true
)

# Extract malicious plugin PHP files
MALICIOUS_PLUGIN_FILES=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | \
  grep -oP 'wp-content/plugins/[^/]+/[^/\s?]+\.php' | \
  sed 's/.*\///' | \
  sed 's/\.php$//' | \
  sort -u | \
  grep -vE '^(index|admin)$' || true
)

# Extract malicious wp-admin PHP files (non-standard)
MALICIOUS_ADMIN_FILES=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | \
  grep -oP 'wp-admin/[^/\s?]+\.php' | \
  sed 's/.*\///' | \
  sed 's/\.php$//' | \
  sort -u | \
  grep -vE '^(index|admin-ajax|admin-post|load-scripts|load-styles)$' || true
)

# Extract attacking IPs
ATTACKING_IPS=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | \
  grep -oP 'client: [0-9.]+' | \
  sed 's/client: //' | \
  sort | uniq -c | sort -rn)

# Count findings
ROOT_COUNT=$(echo "$MALICIOUS_ROOT_FILES" | grep -c . || echo "0")
PLUGIN_COUNT=$(echo "$MALICIOUS_PLUGIN_FILES" | grep -c . || echo "0")
ADMIN_COUNT=$(echo "$MALICIOUS_ADMIN_FILES" | grep -c . || echo "0")
IP_COUNT=$(echo "$ATTACKING_IPS" | grep -c . || echo "0")
TOTAL_REQUESTS=$(grep -c "Primary script unknown" "$NGINX_ERROR_LOG" || echo "0")

# Display summary
echo "═══════════════════════════════════════════════════════════════"
echo "                    MALICIOUS REQUEST ANALYSIS                  "
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Total 'Primary script unknown' errors: $TOTAL_REQUESTS"
echo "Unique malicious root-level PHP files: $ROOT_COUNT"
echo "Unique malicious plugin PHP files:     $PLUGIN_COUNT"
echo "Unique malicious wp-admin PHP files:   $ADMIN_COUNT"
echo "Unique attacking IP addresses:         $IP_COUNT"
echo ""

# Display root-level files
if [[ $ROOT_COUNT -gt 0 ]]; then
  log_warning "MALICIOUS ROOT-LEVEL PHP FILES:"
  echo "$MALICIOUS_ROOT_FILES" | while read -r file; do
    count=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | grep -c "/$file\.php" || echo "0")
    printf "  %-30s (attempted %3d times)\n" "$file.php" "$count"
  done
  echo ""
fi

# Display plugin files
if [[ $PLUGIN_COUNT -gt 0 ]]; then
  log_warning "MALICIOUS PLUGIN PHP FILES:"
  echo "$MALICIOUS_PLUGIN_FILES" | while read -r file; do
    count=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | grep -c "/$file\.php" || echo "0")
    printf "  %-30s (attempted %3d times)\n" "$file.php" "$count"
  done
  echo ""
fi

# Display wp-admin files
if [[ $ADMIN_COUNT -gt 0 ]]; then
  log_warning "MALICIOUS WP-ADMIN PHP FILES:"
  echo "$MALICIOUS_ADMIN_FILES" | while read -r file; do
    count=$(grep "Primary script unknown" "$NGINX_ERROR_LOG" | grep -c "wp-admin/$file\.php" || echo "0")
    printf "  %-30s (attempted %3d times)\n" "wp-admin/$file.php" "$count"
  done
  echo ""
fi

# Display top attacking IPs
if [[ $IP_COUNT -gt 0 ]]; then
  log_warning "TOP 15 ATTACKING IP ADDRESSES:"
  echo "$ATTACKING_IPS" | head -15 | while read -r count ip; do
    printf "  %-15s (%3d requests)\n" "$ip" "$count"
  done
  echo ""
fi

# Generate updated security rules
if [[ $ROOT_COUNT -gt 0 ]] || [[ $PLUGIN_COUNT -gt 0 ]]; then
  echo "═══════════════════════════════════════════════════════════════"
  echo "              RECOMMENDED SECURITY RULE UPDATES                "
  echo "═══════════════════════════════════════════════════════════════"
  echo ""

  if [[ $ROOT_COUNT -gt 0 ]]; then
    ROOT_PATTERN=$(echo "$MALICIOUS_ROOT_FILES" | paste -sd '|')
    log_info "Add these patterns to root-level PHP blocking rule:"
    echo ""
    echo "location ~* ^/(${ROOT_PATTERN})\\.php\$ {"
    echo "  return 403;"
    echo "}"
    echo ""
  fi

  if [[ $PLUGIN_COUNT -gt 0 ]]; then
    PLUGIN_PATTERN=$(echo "$MALICIOUS_PLUGIN_FILES" | paste -sd '|')
    log_info "Add these patterns to plugin PHP blocking rule:"
    echo ""
    echo "location ~* ^/wp-content/plugins/.+/(${PLUGIN_PATTERN})\\.php\$ {"
    echo "  return 403;"
    echo "}"
    echo ""
  fi

  if [[ $ADMIN_COUNT -gt 0 ]]; then
    ADMIN_PATTERN=$(echo "$MALICIOUS_ADMIN_FILES" | paste -sd '|')
    log_info "Add these patterns to wp-admin PHP blocking rule:"
    echo ""
    echo "location ~* ^/wp-admin/(${ADMIN_PATTERN})\\.php\$ {"
    echo "  return 403;"
    echo "}"
    echo ""
  fi
fi

# Display recommendations
echo "═══════════════════════════════════════════════════════════════"
echo "                      RECOMMENDATIONS                           "
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [[ $TOTAL_REQUESTS -gt 0 ]]; then
  log_warning "ACTION REQUIRED:"
  echo "  1. The security rules in security-rules.conf need to be updated"
  echo "  2. Deploy updated rules to server using Ansible:"
  echo "     ansible-playbook -i hosts modules/4_security/playbook-fail2ban.yml"
  echo ""
  echo "  3. Consider blocking repeat offender IPs with fail2ban"
  echo ""

  if [[ $IP_COUNT -gt 10 ]]; then
    log_warning "High number of attacking IPs detected ($IP_COUNT)"
    echo "     Consider setting up fail2ban auto-blocking:"
    echo "     ansible-playbook -i hosts modules/4_security/playbook-auto-block.yml -e 'enable_cron=true'"
    echo ""
  fi
else
  log_success "No malicious requests found in the log file!"
  echo "  Your security rules are working effectively."
  echo ""
fi

# Offer to update security-rules.conf automatically
if [[ $ROOT_COUNT -gt 0 ]] || [[ $PLUGIN_COUNT -gt 0 ]]; then
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  read -p "Would you like to automatically update security-rules.conf? (yes/no): " -r

  if [[ $REPLY =~ ^[Yy]es$ ]]; then
    SECURITY_RULES="modules/4_security/files/security/security-rules.conf"

    if [[ ! -f "$SECURITY_RULES" ]]; then
      log_error "Security rules file not found: $SECURITY_RULES"
      exit 1
    fi

    # Create backup
    BACKUP_FILE="${SECURITY_RULES}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SECURITY_RULES" "$BACKUP_FILE"
    log_success "Backup created: $BACKUP_FILE"

    # Read current patterns from the file
    CURRENT_ROOT=$(grep -oP 'location ~\* \^/\(\K[^)]+(?=\)\\\.php)' "$SECURITY_RULES" | head -1 || echo "")
    CURRENT_PLUGIN=$(grep -oP 'wp-content/plugins/.+/\(\K[^)]+(?=\)\\\.php)' "$SECURITY_RULES" | head -1 || echo "")

    # Merge patterns
    ALL_ROOT=$(echo -e "${CURRENT_ROOT//|/\\n}\n${MALICIOUS_ROOT_FILES}" | sort -u | paste -sd '|')
    ALL_PLUGIN=$(echo -e "${CURRENT_PLUGIN//|/\\n}\n${MALICIOUS_PLUGIN_FILES}" | sort -u | paste -sd '|')

    # Update root-level block
    if [[ $ROOT_COUNT -gt 0 ]] && [[ -n "$ALL_ROOT" ]]; then
      # Find and replace the first root-level malicious PHP location block
      perl -i -pe "
        BEGIN { \$done = 0; }
        if (/^location ~\* \^\\/\([^)]+\)\\\\\.php\\\$/ && !\$done) {
          \$_ = \"location ~* ^/(${ALL_ROOT})\\\\.php\\\$ {\\n\";
          \$done = 1;
        }
      " "$SECURITY_RULES"
      log_success "Updated root-level PHP blocking patterns"
    fi

    # Update plugin block
    if [[ $PLUGIN_COUNT -gt 0 ]] && [[ -n "$ALL_PLUGIN" ]]; then
      perl -i -pe "
        BEGIN { \$done = 0; }
        if (/^location ~\* \^\/wp-content\/plugins\/.+\/\([^)]+\)\\\\\.php\\\$/ && !\$done) {
          \$_ = \"location ~* ^/wp-content/plugins/.+/(${ALL_PLUGIN})\\\\.php\\\$ {\\n\";
          \$done = 1;
        }
      " "$SECURITY_RULES"
      log_success "Updated plugin PHP blocking patterns"
    fi

    echo ""
    log_success "Security rules file updated!"
    log_info "Next steps:"
    echo "  1. Review the changes in: $SECURITY_RULES"
    echo "  2. Deploy to server with:"
    echo "     ansible-playbook -i hosts modules/4_security/playbook-fail2ban.yml"
    echo ""
  else
    log_info "Skipped automatic update. You can manually update the security rules."
  fi
fi

echo "═══════════════════════════════════════════════════════════════"
log_success "Analysis complete!"
echo "═══════════════════════════════════════════════════════════════"
