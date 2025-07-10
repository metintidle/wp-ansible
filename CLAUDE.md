# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Ansible-based WordPress deployment and management system designed specifically for Amazon Linux 2 servers. The project provides complete infrastructure automation for deploying production-ready WordPress sites with modern web stack components.

## Architecture

The system uses a sequential deployment approach with separate playbooks for each component:

### Core Playbooks (Execute in Order)
1. **nginx-php.yml** - Nginx web server and PHP-FPM setup with performance optimizations
2. **wordpress.yml** - WordPress installation using WP-CLI with database integration
3. **ssl-certbot.yml** - SSL certificate automation with Let's Encrypt
4. **cache.yml** - FastCGI caching and object caching (SQLite-based)
5. **ftp.yml** - FTP server configuration for file management
6. **tools.yml** - Additional tools installation
7. **newrelic.yml** - Monitoring and performance tracking

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
- `bash/` - Shell scripts for maintenance tasks

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

## Performance Tuning

The system is optimized for servers with 512MB RAM:
- Memory-efficient PHP-FPM pools
- Optimized MySQL configurations
- FastCGI caching to reduce PHP processing
- Swap file configuration for memory management