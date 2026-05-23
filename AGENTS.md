## Learned User Preferences

- Do not change `modules/2_wordpress/playbook.yml` for Ohara fleet one-off tuning (e.g. `AUTOSAVE_INTERVAL`); apply changes on live hosts via SSH or `bash/apply-elementor-low-ram.sh` only.
- Ohara live hosts: set `AUTOSAVE_INTERVAL` to `86400` in `wp-config.php`; keep `modules/2_wordpress/playbook.yml` at `300` for new Ansible provisions.

## Learned Workspace Facts

- Ohara WordPress fleet SSH config: `~/.ssh/ohara/config` (not `.ssh/ohara/conf`); aliases include berkeley, bligh, station, warrilahotel, centralhotel, town, salamander, lake, and others.
- WordPress document root on Ohara hosts is typically `/home/ec2-user/html` (fallback `/var/www/html`).
- Elementor low-RAM optimization: `docs/elementor-low-ram-optimization.md`; deploy with `bash/apply-elementor-low-ram.sh`; install WP-CLI and run DB cleanup with `bash/install-wp-cli-cleanup.sh`.
- WP-CLI on Ohara hosts: `/usr/local/bin/wp` from the wp-cli gh-pages phar (same install method as `modules/2_wordpress/playbook.yml`).
- Ohara live hosts use `AUTOSAVE_INTERVAL` `86400` in `wp-config.php`; new provisions via Ansible still get `300` from the playbook.
- Some Ohara hosts use remote MySQL (`DB_HOST` in `wp-config.php`, no local MariaDB); e.g. `lake`.
- Ohara fleet PHP-FPM (`/etc/php-fpm.d/www.conf`, live hosts via `bash/apply-php-fpm-ondemand.sh`): `pm = ondemand`, `pm.max_children = 2`, `pm.process_idle_timeout = 15s`, `pm.max_requests = 200`, `rlimit_files = 1024`, `php_admin_value[memory_limit] = 96M`, `php_admin_value[max_execution_time] = 30`.
- graphify: read `graphify-out/GRAPH_REPORT.md` before architecture or codebase questions; run `graphify update .` after modifying code in a session.
