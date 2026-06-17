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
5. **modules/5_security** - Fail2Ban, CrowdSec, geo firewall, strict whitelist
6. **modules/6_cache** - FastCGI caching and object caching (SQLite-based)
7. **tools** - Additional tools installation
8. **newrelic** - Monitoring and performance tracking (if used)

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

**Location:** `modules/5_security/files/security/restricts/`

**Files:**
- `strict-whitelist-maps.conf` - Map definitions (deployed to `/etc/nginx/conf.d/`)
- `00-strict-whitelist.conf` - Deny rule (deployed to `/etc/nginx/default.d/`)

**Playbook:** `modules/5_security/playbook-strict-whitelist.yml`

**Usage:**
```bash
# Enable strict whitelist
ansible-playbook -i hosts modules/5_security/playbook-strict-whitelist.yml -e "strict_whitelist_enabled=true"

# Disable strict whitelist
ansible-playbook -i hosts modules/5_security/playbook-strict-whitelist.yml -e "strict_whitelist_enabled=false"
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

# context-mode — MANDATORY routing rules

You have context-mode MCP tools available. These rules are NOT optional — they protect your context window from flooding. A single unrouted command can dump 56 KB into context and waste the entire session.

## BLOCKED commands — do NOT attempt these

### curl / wget — BLOCKED
Any Bash command containing `curl` or `wget` is intercepted and replaced with an error message. Do NOT retry.
Instead use:
- `ctx_fetch_and_index(url, source)` to fetch and index web pages
- `ctx_execute(language: "javascript", code: "const r = await fetch(...)")` to run HTTP calls in sandbox

### Inline HTTP — BLOCKED
Any Bash command containing `fetch('http`, `requests.get(`, `requests.post(`, `http.get(`, or `http.request(` is intercepted and replaced with an error message. Do NOT retry with Bash.
Instead use:
- `ctx_execute(language, code)` to run HTTP calls in sandbox — only stdout enters context

### WebFetch — BLOCKED
WebFetch calls are denied entirely. The URL is extracted and you are told to use `ctx_fetch_and_index` instead.
Instead use:
- `ctx_fetch_and_index(url, source)` then `ctx_search(queries)` to query the indexed content

## REDIRECTED tools — use sandbox equivalents

### Bash (>20 lines output)
Bash is ONLY for: `git`, `mkdir`, `rm`, `mv`, `cd`, `ls`, `npm install`, `pip install`, and other short-output commands.
For everything else, use:
- `ctx_batch_execute(commands, queries)` — run multiple commands + search in ONE call
- `ctx_execute(language: "shell", code: "...")` — run in sandbox, only stdout enters context

### Read (for analysis)
If you are reading a file to **Edit** it → Read is correct (Edit needs content in context).
If you are reading to **analyze, explore, or summarize** → use `ctx_execute_file(path, language, code)` instead. Only your printed summary enters context. The raw file content stays in the sandbox.

### Grep (large results)
Grep results can flood context. Use `ctx_execute(language: "shell", code: "grep ...")` to run searches in sandbox. Only your printed summary enters context.

## Tool selection hierarchy

1. **GATHER**: `ctx_batch_execute(commands, queries)` — Primary tool. Runs all commands, auto-indexes output, returns search results. ONE call replaces 30+ individual calls.
2. **FOLLOW-UP**: `ctx_search(queries: ["q1", "q2", ...])` — Query indexed content. Pass ALL questions as array in ONE call.
3. **PROCESSING**: `ctx_execute(language, code)` | `ctx_execute_file(path, language, code)` — Sandbox execution. Only stdout enters context.
4. **WEB**: `ctx_fetch_and_index(url, source)` then `ctx_search(queries)` — Fetch, chunk, index, query. Raw HTML never enters context.
5. **INDEX**: `ctx_index(content, source)` — Store content in FTS5 knowledge base for later search.

## Subagent routing

When spawning subagents (Agent/Task tool), the routing block is automatically injected into their prompt. Bash-type subagents are upgraded to general-purpose so they have access to MCP tools. You do NOT need to manually instruct subagents about context-mode.

## Output constraints

- Keep responses under 500 words.
- Write artifacts (code, configs, PRDs) to FILES — never return them as inline text. Return only: file path + 1-line description.
- When indexing content, use descriptive source labels so others can `ctx_search(source: "label")` later.

## ctx commands

| Command | Action |
|---------|--------|
| `ctx stats` | Call the `ctx_stats` MCP tool and display the full output verbatim |
| `ctx doctor` | Call the `ctx_doctor` MCP tool, run the returned shell command, display as checklist |
| `ctx upgrade` | Call the `ctx_upgrade` MCP tool, run the returned shell command, display as checklist |
