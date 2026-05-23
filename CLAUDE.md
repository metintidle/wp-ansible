# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Ansible-based WordPress deployment and management system for **Amazon Linux 2023** (and legacy AL2) WordPress hosts. The project provides complete infrastructure automation for deploying production-ready WordPress sites with modern web stack components.

## Architecture

The system uses a sequential deployment approach with separate playbooks for each component:

### Core Playbooks (Execute in Order)
1. **modules/1_nginx-php** - Nginx web server and PHP-FPM setup with performance optimizations
2. **modules/2_wordpress** - WordPress installation using WP-CLI with database integration
3. **modules/3_ssl** - SSL certificate automation with Let's Encrypt (imports **4_agent** by default)
4. **modules/4_agent** - Resmon wp-agent (Socket.io to monitoring hub; see `modules/4_agent/README.md`)
5. **modules/6_cache** - FastCGI caching and object caching (SQLite-based)
6. **tools** - Additional tools installation
7. **newrelic** - Monitoring and performance tracking (if used)

### Key Components

#### Web Stack
- **Nginx** - Web server with FastCGI caching enabled
- **PHP-FPM** - PHP processor with OPcache optimization
- **MariaDB** - Database server (amazon-linux-extras install)
- **WordPress** - Managed via WP-CLI v2.11.0

#### Security Layer
- **Fail2Ban** - Intrusion prevention with custom Nginx filters
- **CrowdSec** - Security monitoring and threat detection
- **Custom security rules** - Located in `configs/security/` and `security/`

#### Performance Optimization
- **FastCGI caching** - Nginx-based caching with custom cache blocks
- **Object caching** - SQLite-based WordPress object caching
- **OPcache** - PHP optimization configurations in `optimize/`
- **Memory optimization** - Configured for 512MB RAM servers

## Directory Structure

### Configuration Management
- `configs/` - Nginx, PHP, and security configurations
  - `nginx.conf` - Main Nginx configuration
  - `security/` - Security rules and fail2ban configurations
  - `cache_block.conf` - FastCGI cache settings
  - `file_cache.conf` - File caching configuration

### Tools and Utilities
- `tools/` - Additional service installations (Redis, NewRelic, SMTP, Vector)
- `utility/` - Helper scripts (Bitwarden, domain management, password generation)
- `snippets/` - Reusable Ansible task snippets
- `bash/` - Shell scripts for maintenance tasks (e.g. `fix-wordpress-siteurl.sh`, `database/backupdb.sh`)
- `docs/` - Documentation (e.g. `fix-wrong-site-url-assets.md`, `FILE2BAN.md`)

### Optimization and Monitoring
- `optimize/` - Performance tuning configurations
  - `mysqld.ini` - MySQL optimization settings
  - PHP OPcache configurations
- `logs/` - Extensive logging setup with Nginx access/error logs

## Common Commands

### Ansible Execution
```bash
# Run individual playbooks (execute in order)
ansible-playbook -i hosts nginx-php.yml
ansible-playbook -i hosts wordpress.yml
ansible-playbook -i hosts ssl-certbot.yml
ansible-playbook -i hosts cache.yml
ansible-playbook -i hosts ftp.yml
ansible-playbook -i hosts tools.yml
ansible-playbook -i hosts newrelic.yml

# Run with specific inventory
ansible-playbook -i your_inventory_file playbook.yml
```

### WordPress Management
```bash
# WP-CLI is installed at /usr/local/bin/wp
# WordPress directory: /var/www/html/
```

### Database Operations
```bash
# MariaDB service management
systemctl start mariadb
systemctl status mariadb
```

## Environment Variables

The system expects these environment variables for database connectivity:
- `DB_USER` - Database username
- `DB_PASS` - Database password  
- `DB_HOST` - Database host
- `db_name` - Database name (defined in playbook vars)

### resmon hub (wp_site_mapping webhook)

After SSL + `wp search-replace` (HTTPS siteurl), `modules/3_ssl/playbook.yml` POSTs final `siteurl`/`blogname` to the resmon hub. Set on the **Semaphore / Ansible controller** (not on the WP host):

- `WP_MAINTENANCE_WEBHOOK_TOKEN` — shared secret; must match hub env `WP_MAINTENANCE_WEBHOOK_TOKEN`
- `WP_MAINTENANCE_WEBHOOK_URL` — optional; default `https://monitoring.itt.com.au/api/website/maintenance/webhook/new-site`

If the token is unset, the notify task is skipped (provision still succeeds).

### Resmon wp-agent (modules/4_agent)

- Installed automatically at the end of **modules/3_ssl** unless `install_wp_agent=false`.
- Ships prebuilt `modules/4_agent/files/wp-agent-linux-x86_64` (AL2023 x86_64 musl static). Rebuild: `modules/4_agent/scripts/build-wp-agent-binary.sh` or `wp_agent_build_on_host=true`.
- Set `WP_AGENT_TOKEN` on the controller (must match hub `WP_AGENT_TOKEN` on monitoring.itt.com.au).
- Legacy cron “wp-agent” scripts live under `modules/monitoring/` — different system.

## Prerequisites

### AWS Infrastructure
- Amazon Linux 2 EC2 instance
- Route53 DNS records (A records for domain and www subdomain)
- Security groups with required ports open:
  - HTTP/HTTPS: 80, 443
  - FTP: 21-22, 20000-201000 (passive mode)

### Required Variables
- `inventory_hostname` - Used for site URL configuration
- Domain-specific variables for SSL certificate generation

## Security Considerations

- Custom Fail2Ban filters for WordPress-specific attacks
- Security headers configuration in Nginx
- CrowdSec integration for advanced threat detection
- Separate security configuration files in `configs/security/`
- **Strict Path Whitelist** - Optional feature for small fixed-content sites (see below)

### Strict Path Whitelist (Optional)

For small sites with fixed content (e.g., 2-3 pages), you can enable a strict whitelist that blocks all requests except allowed paths.

**Location:** `modules/4_security/files/security/restricts/`

**Files:**
- `strict-whitelist-maps.conf` - Map definitions (deployed to `/etc/nginx/conf.d/`)
- `00-strict-whitelist.conf` - Deny rule (deployed to `/etc/nginx/default.d/`)

**Playbook:** `modules/4_security/playbook-strict-whitelist.yml`

**Usage:**
```bash
# Enable strict whitelist
ansible-playbook -i hosts modules/4_security/playbook-strict-whitelist.yml -e "strict_whitelist_enabled=true"

# Disable strict whitelist
ansible-playbook -i hosts modules/4_security/playbook-strict-whitelist.yml -e "strict_whitelist_enabled=false"
```

**Allowed for anonymous users:**
- `/`, `/contact-us`, `/our-services` (public pages)
- `/modri` (custom login URL)
- `/wp-admin/admin-ajax.php`, `/wp-json/*` (for forms and features)
- `/wp-cron.php`, `/robots.txt`, `/favicon.ico`, `/sitemap*`
- Static files (js, css, images, fonts, etc.)

**After login:** All restrictions are bypassed (WordPress cookie detected)

## Performance Tuning

The system is optimized for servers with 512MB RAM:
- Memory-efficient PHP-FPM pools
- Optimized MySQL configurations
- FastCGI caching to reduce PHP processing
- Swap file configuration for memory management