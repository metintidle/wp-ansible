## Learned User Preferences

- Do not change `modules/2_wordpress/playbook.yml` for Ohara fleet one-off tuning (e.g. `AUTOSAVE_INTERVAL`); apply changes on live hosts via SSH or `bash/apply-elementor-low-ram.sh` only.
- Ohara live hosts: set `AUTOSAVE_INTERVAL` to `86400` in `wp-config.php`; keep `modules/2_wordpress/playbook.yml` at `300` for new Ansible provisions.

## Learned Workspace Facts

- Ohara WordPress fleet SSH config: `~/.ssh/ohara/config` (included from `~/.ssh/config` via `Include ./ohara/config`; not `.ssh/ohara/conf`); aliases include berkeley, bligh, station, warrilahotel, centralhotel, town, salamander, lake, fairfeild (Fairfield; typo in ohara config), and others.
- WordPress document root on Ohara hosts is typically `/home/ec2-user/html` (fallback `/var/www/html`).
- Elementor low-RAM optimization: `docs/elementor-low-ram-optimization.md`; deploy with `bash/apply-elementor-low-ram.sh`; install WP-CLI and run DB cleanup with `bash/install-wp-cli-cleanup.sh`.
- WP-CLI on Ohara hosts: `/usr/local/bin/wp` from the wp-cli gh-pages phar (same install method as `modules/2_wordpress/playbook.yml`).
- Some Ohara hosts use remote MySQL (`DB_HOST` in `wp-config.php`, no local MariaDB); e.g. `lake`.
- Ohara fleet PHP-FPM (`/etc/php-fpm.d/www.conf`, live hosts via `bash/apply-php-fpm-ondemand.sh`): `pm = ondemand`, `pm.max_children = 2`, `pm.process_idle_timeout = 15s`, `pm.max_requests = 200`, `rlimit_files = 1024`, `php_admin_value[memory_limit] = 96M`, `php_admin_value[max_execution_time] = 30`.
- Resmon wp-agent on Ohara fleet: deploy with `ansible-playbook -i inventory/ohara-hotels.ini modules/4_agent/playbook.yml`; set `WP_AGENT_TOKEN` on the controller; binary at `/opt/wp-agent/wp-agent`, systemd unit `wp-agent.service`.
- Disable page-load WP-Cron: `bash/disable-wp-cron.sh` sets `DISABLE_WP_CRON` in `wp-config.php` and adds ec2-user crontab `*/5 * * * * wp cron event run --due-now` via WP-CLI.
- Non-Ohara WordPress hosts (e.g. cccls, bateys, centrehealth, traffic) are in `~/.ssh/config` and `~/Library/CloudStorage/OneDrive-IT&TPTYLIMITED/ssh/config`; per-host PEM keys under `/Users/meti/.ssh/`; hparson fleet uses `~/Library/CloudStorage/OneDrive-IT&TPTYLIMITED/ssh/hparson/config` with shared key `~/.ssh/hparson/hp.pem`; use `SSH_CONFIG=~/.ssh/config` with fleet bash scripts, or inline `ansible_ssh_private_key_file` in batch inventories for Ansible.
- Per-site DB credential migration: `modules/2_wordpress/fix-db-credentials.yml` via `./bash/run-fix-db-credentials.sh <inventory> [ansible args]` (inventory is first positional arg, not `-i`); reads `DB_HOST` from each site's `wp-config.php`; controller needs `DB_ADMIN_USER`/`DB_ADMIN_PASS` (wrapper sources `~/.zshrc` or `modules/2_wordpress/.db-admin.env`); batch inventories under `inventory/wp-dbfix-batch*.ini`, `inventory/wp-dbfix-hparson.ini`, `inventory/dmfp-vcawol-wmeds.ini`; MySQL `raw` tasks must use `| quote` on passwords (`$` in `DB_ADMIN_PASS` breaks shell); central DB grant host is often `nlb-2025-0705-1013.publicsubnet.wpdb.oraclevcn.com`; on MySQL ERROR 1819 delete `modules/2_wordpress/.db-credentials/<host>.pass` and re-run; after migration remove `wp-config.php.bak-predbfix` on servers (old shared creds) but keep controller `.db-credentials/`; see `modules/2_wordpress/README-db-credentials.md`.
- Low-RAM AL2023/AL2 hosts (~512MB): Ansible `lineinfile` in `snippets/php-webshell-hardening.yml` may OOM during fix-db-credentials — apply same PHP/Nginx hardening via SSH instead; if MySQL client install OOMs, add 512MB swap before re-run (`pause_web_stack_for_ram=false` optional).
- graphify: read `graphify-out/GRAPH_REPORT.md` before architecture or codebase questions; run `graphify update .` after modifying code in a session.
