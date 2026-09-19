## Learned User Preferences

- Do not change provision playbooks for one-off live-host tuning (e.g. Ohara `AUTOSAVE_INTERVAL`, PHP-FPM/nginx/cache on a single host); apply on hosts via SSH or `bash/` fleet scripts only.
- Ohara live hosts: set `AUTOSAVE_INTERVAL` to `86400` in `wp-config.php`; keep `modules/2_wordpress/playbook.yml` at `300` for new Ansible provisions.
- Ansible WP-CLI tasks: run as `ec2-user` (`become: false`, `become_user: ec2-user`); do not run as root or use `--allow-root` unless explicitly required.
- Before bulk destructive cleanup on live WordPress hosts (e.g. unused media), tarball-backup with manifest first; user may remove backup after site verification.
- Ohara fail2ban false-positive for a trusted IP: add to repo `modules/5_security/files/fail2ban/jail.local` and `jail.local.hardened` `[DEFAULT] ignoreip`, deploy/reload on all Ohara hotel hosts — not only `unbanip` on one host.
- Maintenance-cron scope policy (stated 2026-09-19): OS-upgrade cron and `wp-site-backup.sh` cron are for ALL AL2023 servers (backup = all WordPress hosts; static/non-WordPress hosts n/a). WP auto-update cron (`run-wp-auto-update.sh`) ONLY on maintenance-plan hosts — never install it on other hosts; remove if found elsewhere. The plan membership CHANGES over time: NEVER hard-code host names; resolve the live list with `./bash/maintenance-plan-hosts.sh` (rule: all `Host` entries in `~/.ssh/ohara/config` + hosts in `~/.ssh/config` whose block carries the marker comment `# Maintenance plan — IT&T monitoring and security` + EXCEPTIONS_IN/EXCEPTIONS_OUT in that script; as of 2026-09-19 it resolves to 22 hosts).

## Learned Workspace Facts

- Ohara WordPress fleet SSH config: `~/.ssh/ohara/config` (included from `~/.ssh/config` via `Include ./ohara/config`; not `.ssh/ohara/conf`); 12 aliases: berkeley, bligh, town, camellia, north, salamander, station, tahmoorin, fairfeild (Fairfield; typo), warrilahotel, lake, centralhotel; `Host lake` is duplicated in main `~/.ssh/config` but ohara Include wins (first match); `town` = Town Tavern Blacktown (`towntavern.com.au`); `north` = North Nowra Tavern (`northnowratavern.com.au`) — do not pick host by domain name alone.
- WordPress document root on Ohara hosts is typically `/home/ec2-user/html` (fallback `/var/www/html`); some hosts use nginx package root `/usr/share/nginx/html` (e.g. Ohara `north`) — verify per host before WP-CLI (`/usr/local/bin/wp`, gh-pages phar per `modules/2_wordpress/playbook.yml`).
- Low-RAM hosts (~512MB–1GB): Elementor tuning via `docs/elementor-low-ram-optimization.md`, `bash/apply-elementor-low-ram.sh`, `bash/install-wp-cli-cleanup.sh`; Ansible `lineinfile` in `snippets/php-webshell-hardening.yml` may OOM during fix-db-credentials — apply PHP/Nginx hardening via SSH (FPM-only `disable_functions` includes `shell_exec`/`exec`/`proc_open`; WP-CLI/cron unaffected); `modules/1_nginx-php/playbook.yml` creates 1GB `/swapfile` (no fstab) — verify `swapon --show` on OOM/503 hosts. Standard WebP plugin: `itt-webp-compressor` from `plugins/itt-webp-compressor.zip` via `modules/2_wordpress/playbook.yml` (replaces wordpress.org `plus-webp`); needs `proc_open` in FPM — Ohara live fleet has proc_open enabled (stock hardening snippet still disables for new provisions unless updated); stock repos lack `libvips` and bundled `jpegtran` has no `-scale` flag, so low-memory compression uses netpbm/`cwebp` pipeline or rebuilt binaries.
- Unused media cleanup: `modules/7_cleanup/playbook.yml` deploys scripts to `/home/ec2-user/bin/`, logs `/home/ec2-user/logs/`, backups `/home/ec2-user/backups/unused-media/` (outside webroot); monthly cron 01:00 Sydney 1st of month (`wp_clean_enable_cron=true`); dry-run first with `-e wp_clean_run_dry_run=true`; default scan `WP_CLEAN_MAX_PAGES=10`, `WP_CLEAN_MAX_POSTS=50`, `WP_CLEAN_MIN_AGE_DAYS=7` — raise limits before trusting zero-candidate audits on large Elementor sites; eligible types PNG/JPG/JPEG/WebP/video only (not PDF/SVG); `ohara-resturan-menu` sites: whitelist `restaurant_menu_pdf_id*` option IDs or menu PDFs can be misclassified as unused.
- Ohara fleet uses remote MySQL at `152.69.175.15` (`DB_HOST` in `wp-config.php`, no local MariaDB); central DB name often differs from SSH alias (e.g. `fairfeild` → `fairfieldhotel`, `lake` → `lakeillawarrahotel`).
- Ohara fleet PHP-FPM (`/etc/php-fpm.d/www.conf`, live hosts via `bash/apply-php-fpm-ondemand.sh`): `pm = ondemand`, `pm.max_children = 2`, `pm.process_idle_timeout = 15s`, `pm.max_requests = 200`, `rlimit_files = 1024`, `php_admin_value[memory_limit] = 96M`, `php_admin_value[max_execution_time] = 30`.
- Resmon wp-agent on Ohara fleet: deploy with `ansible-playbook -i inventory/ohara-hotels.ini modules/4_agent/playbook.yml`; set `WP_AGENT_TOKEN` on the controller; binary at `/opt/wp-agent/wp-agent`, systemd unit `wp-agent.service`.
- Disable page-load WP-Cron: `bash/disable-wp-cron.sh` sets `DISABLE_WP_CRON` in `wp-config.php` and adds ec2-user crontab `*/5 * * * * wp cron event run --due-now` via WP-CLI.
- Non-Ohara WordPress hosts (e.g. cccls, bateys, lifeimaging, chippingnortonmedical, centrehealth, traffic) are in `~/.ssh/config` and `~/Library/CloudStorage/OneDrive-IT&TPTYLIMITED/ssh/config`; docroot typically `~/html` with `ec2-user:nginx` ownership (`lifeimaging` exception: AWS Lightsail AL2023, `/usr/share/nginx/html`, remote MySQL `152.69.175.15`; runbooks `docs/lifeimaging-incident-and-fixes.md`, `lifeimage-report.md`); `capitalformwork` is static HTML (Inance template), not WordPress — docroot `/usr/share/nginx/html`; `lwhydraulics` is PyroCMS/FormTools (not WordPress), docroot `/usr/share/nginx/html`, excluded from `al2023-fail2ban.ini` — see `lwhydraulics.md`; main `~/.ssh/config` is grouped into `# Amazon Linux 2` and `# Amazon Linux 2023` sections; Ohara (`~/.ssh/ohara/config`) and hparson fleets are all AL2023; `figtreesports` is listed under AL2023 but is Debian 11 Bitnami (`User bitnami`) — verify OS before AL2023 playbooks; per-host PEM keys under `/Users/meti/.ssh/`; hparson fleet uses `~/Library/CloudStorage/OneDrive-IT&TPTYLIMITED/ssh/hparson/config` with shared key `~/.ssh/hparson/hp.pem`; use `SSH_CONFIG=~/.ssh/config` with fleet bash scripts, or inline `ansible_ssh_private_key_file` in batch inventories for Ansible.
- Local dev convenience: project-root `ssh-config` symlink to `~/.ssh/config`, gitignored via `.gitignore` (not committed).
- Per-site DB credential migration: `modules/2_wordpress/fix-db-credentials.yml` via `./bash/run-fix-db-credentials.sh <inventory> [ansible args]` (inventory is first positional arg, not `-i`); reads `DB_HOST` from each site's `wp-config.php`; controller needs `DB_ADMIN_USER`/`DB_ADMIN_PASS` (wrapper sources `~/.zshrc` or `modules/2_wordpress/.db-admin.env`); batch inventories under `inventory/wp-dbfix-batch*.ini`, `inventory/wp-dbfix-batch-missing.ini`, `inventory/wp-dbfix-hparson.ini`, `inventory/dmfp-vcawol-wmeds.ini`, `inventory/ohara-hotels.ini` (Ohara: `ansible_ssh_common_args=-F ~/.ssh/ohara/config`); hosts not in repo inventories use inline `-i 'host,'` with `ansible_host`/`ansible_ssh_private_key_file`/`wp_root` (if `-F ssh-config` breaks Ansible SSH parsing, set `ansible_host` + `ansible_ssh_private_key_file` explicitly); install WP-CLI on host first if missing; MySQL `raw` tasks must use `| quote` on passwords (`$` in `DB_ADMIN_PASS` breaks shell); WP-CLI fact reads redirect stderr so Imagick/PHP warnings do not break DB parsing; central DB grant host is often `nlb-2025-0705-1013.publicsubnet.wpdb.oraclevcn.com`; on MySQL ERROR 1819 delete `modules/2_wordpress/.db-credentials/<host>.pass` and re-run; after migration delete all docroot `wp-config.php*` except live `wp-config.php` on servers (old shared creds) but keep controller `.db-credentials/`; see `modules/2_wordpress/README-db-credentials.md`.
- Hardened fail2ban: deploy with `modules/5_security/playbook-fail2ban.yml`; batch inventory `inventory/al2023-fail2ban.ini` — 25 SSH-verified AL2023 hosts from main `ssh-config` (excludes `lwhydraulics`, `figtreesports`); groups `al2023_fail2ban_skip` (`lifeimaging` only — full hardened verified), `al2023_fail2ban_needs_upgrade` (partial/stale filters: `bateys`, `cccls`, `venkatesanfamilyoffice`, `greenfarm`, `vcawol` — bateys had empty `nginx-php-url-hack`/`nginx-unknown-script` ignoreregex Jul 2026), `al2023_fail2ban_needs_install` (remainder) — inventory dated; `needs_upgrade`/`needs_install` hosts may already run 9 jails but still ship legacy 3-line `nginx-unknown-script` (pattern #2 `No such file or directory` included); redeploy syncs repo filter (#1 Primary script unknown + #3 access forbidden only; #2 excluded after North Nowra FPM-socket false positives); `jail.local` enables 9 jails (24h ban, `iptables-allports`, `recidive`), `loglevel = NOTICE` (drops `Found` noise, keeps `Ban`/`Unban` for `recidive`); custom `logtarget` `/var/log/fail2ban/fail2ban.log` is outside package logrotate — playbook deploys `/etc/logrotate.d/fail2ban-main` with `fail2ban-client flushlogs` postrotate (not `truncate`); `banned-ips.log` rotation needs no fail2ban reload (`logban` reopens each write); custom filters `non-wordpress-requests` (attack patterns + path ignoreregex for wp-admin/REST at any status), `nginx-php-url-hack` (.php 404 + shell only), `nginx-limit-req-login` (security_login zone only — not global `one`/`security_api`), `nginx-unknown-script`; editor-safe = path-based ignoreregex only (no cookie bypass — spoofable); keep `modules/1_nginx-php/files/security/general.conf` identical to `modules/5_security/files/security/general.conf` (30r/s + security_login/security_api zones); playbook includes nginx `main_wp` via `/etc/nginx/wp-fail2ban-log.inc` before `access_log`; deploy: filters → logban → jail.local → `nginx -t` reload → fail2ban restart; validate filters with `fail2ban-regex` via temp log files (stdin unreliable on AL2023); per-host audits in `docs/security/` and `docs/ohara/`; Bateys SSH alias is `bateys` (not `batesy`).

## Jira (WordPress / WEPC) — Atlassian MCP defaults

Apply these defaults on **any prompt** in this repo that creates or updates a Jira issue, without being asked first. Use the Atlassian MCP tools (Atlassian Rovo MCP plugin). Do not ask for project, board, or assignee unless the user overrides them.

### Site and board

- `cloudId`: `d44de458-5093-4475-aa45-852744950502` (call `getAccessibleAtlassianResources` only if this fails)
- Project: **WordPress** (`WEPC`, id `10005`)
- Board: **WEPC board** (id `6`) — team-managed; issues in `WEPC` appear on this board. Do not create issues in any other project.
- Default issue type: **Task** (`10024`). Use Epic/Subtask only if the user asks.
- Dates: `Australia/Sydney` (`YYYY-MM-DD`)

### Create defaults

On `createJiraIssue`:

- `projectKey`: `WEPC`
- `assignee`: `712020:511898f6-d703-4a94-9c60-86d6ac340b7f` (Mahdi / mahdi@itt.com.au)
- **Start date** (`customfield_10015`) = the issue **created date** (Sydney calendar day of `created`). On create that is the create timestamp, not a separate planned-start date.
- Leave **Due date** empty on create unless the user sets one
- Always include a **Description** (never create with summary only)
- Default **status**: move the issue to **In Progress** (the board's "Doing" column, status id `10024`) on create — pass `transition: { "id": "21" }` on `createJiraIssue`, or call `transitionJiraIssue` (transition id `21`) immediately after create. Do not leave new issues in To Do unless the user asks.

Pass Start date on create from that created day. If create returns a `created` timestamp, use that date; if Start date is missing or wrong, `editJiraIssue` it to the created date.

### Description (required)

Write for **non-technical management**. Professional, direct, outcome-focused. No code, file paths, framework names, or implementation jargon.

Use this markdown shape every time:

```
**Business Goal**
<1–2 sentences: why this work exists and the value it delivers to the project or user.>

**Summary of Work**
- <plain-English outcome>
- <plain-English outcome>
- <optional third outcome>
```

- **Business Goal**: 1–2 sentences only.
- **Summary of Work**: 2–3 bullets of what was accomplished or added (functionality and benefit, not how it was built).
- Summary/title can stay slightly more specific; Description must stay high-level.

Example:

```
createJiraIssue(
  cloudId="d44de458-5093-4475-aa45-852744950502",
  projectKey="WEPC",
  issueType="Task",
  summary="...",
  description="**Business Goal**\n...\n\n**Summary of Work**\n- ...\n- ...",
  assignee="712020:511898f6-d703-4a94-9c60-86d6ac340b7f",
  additional_fields={"Start date": "<created date YYYY-MM-DD>"}
)
```

### Move to Done

When transitioning to **Done** (status id `10025`):

1. `listJiraIssueTransitions` if the transition name is unknown
2. `transitionJiraIssue` with `fields: { "duedate": "<today Australia/Sydney>" }`
3. If due date was not accepted on the transition, `editJiraIssue` with `fields: { "duedate": "<today>" }`

Do not overwrite an existing due date unless the user asks.

### Automatic lifecycle — create and close without being asked

- **Auto-create**: when a prompt in this repo is a concrete work task (host changes, fixes, installs, config changes, cleanup, deploys, incident response, multi-step implementation work), create the WEPC issue **before starting the work** using all Create defaults above — Task, assignee Mahdi, status In Progress (`transition: { "id": "21" }` on create), Start date = created date, Description in the required format. Name the issue key (e.g. `WEPC-123`) when starting the work.
- **Skip auto-create** for: questions, read-only status checks/lookups, conversation, or trivial no-impact checks.
- **Auto-close**: when the work finishes successfully, transition to **Done** (transition id `31`) and set **Due date** = today (`Australia/Sydney`) in the same transition; if the due date is rejected on transition, set it with `editJiraIssue`. Never overwrite an existing due date. State the closed issue key in the final reply.
- **If work fails or stalls**: do not close — leave the issue In Progress and name it as blocked in the reply so it stays visible on the board.

### Overrides

If the user names another assignee, project, start date, or due date, use their values. Do not look up Mahdi again unless the stored accountId fails.
