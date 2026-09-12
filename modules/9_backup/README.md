# Module 9 — WordPress site backup (root cron)

Independent WordPress backups outside the webroot. Replaces UpdraftPlus and WPvivid with a **root** cron job that writes to `/var/backups/wordpress/` (`root:root`, `0700`).

## What is backed up

| Include | Why |
|---------|-----|
| Database dump (`*_db_*.sql.gz`) | Posts, Elementor, users, options |
| `wp-config.php` | DB creds, salts, constants — not inside `wp-content` |
| `wp-content/` | Plugins, themes, uploads, mu-plugins |

**Not** backed up: `wp-admin/`, `wp-includes/`, root WP PHP (reinstall with `wp core download`). Excludes: `cache`, `upgrade`, `tmp`, `updraft`, `wpvividbackups`, `debug.log`.

Retention: **5** database dumps, **4** file archives. Archives are `chmod 600` with `chattr +i`.

## Schedule

Root cron, `CRON_TZ=Australia/Sydney`, base **01:00** daily plus per-host stagger (`cksum hostname % 45` minutes). Every host finishes before the module 8 auto-update at **03:00 Sunday**.

| Day | Database | Files tar |
|-----|----------|-----------|
| Sunday | Dump if due (weekly) | **Skipped** (auto-update at 03:00 changes plugins/themes) |
| Mon–Sat | Dump if newest > 7 days old | Tar if missing, > 14 days old, or fingerprint changed |

Quiet nights log `nothing due` and exit 0.

## Coordination with module 8

[Module 8](../8_updates/README.md) runs WordPress auto-updates as `ec2-user` at 03:00 Sunday.

1. **One MySQL dump on Sunday.** Backup cron (~01:00) writes `/run/wp-site-backup-db.stamp` after a successful dump. Auto-update skips its own `wp db export` when the stamp is newer than **12 hours**.
2. **Fallback.** If the stamp is missing or stale, auto-update still dumps to `/home/ec2-user/backups/wp-auto-update/` and aborts updates on failure.
3. **Shared locks.** Backup uses `flock` on `/var/backups/wordpress/.lock`. Auto-update uses `/tmp/wp-auto-update.lock`. Each script waits briefly if the other lock is held.
4. **Do not** point `WP_AUTO_UPDATE_BACKUP_DIR` at `/var/backups/wordpress` — that directory is not writable by `ec2-user`.

## Deploy

[`playbook.yml`](playbook.yml)

```bash
# Deploy script + cron (staggered 01:00 Sydney)
ansible-playbook -i inventory/ohara-hotels.ini modules/9_backup/playbook.yml

# One host
ansible-playbook -i inventory/ohara-hotels.ini modules/9_backup/playbook.yml --limit station

# Remove legacy backup plugins and delete wp-content/updraft + wpvividbackups
ansible-playbook -i inventory/ohara-hotels.ini modules/9_backup/playbook.yml \
  -e wp_site_backup_remove_legacy_plugins=true --limit station

# Scripts only (no cron)
ansible-playbook -i inventory/ohara-hotels.ini modules/9_backup/playbook.yml \
  -e wp_site_backup_enable_cron=false

# Remove cron
ansible-playbook -i inventory/ohara-hotels.ini modules/9_backup/playbook.yml \
  -e wp_site_backup_remove_cron=true
```

Fleet wrapper: [`bash/install-wp-site-backup.sh`](../../bash/install-wp-site-backup.sh)

```bash
INVENTORY=inventory/ohara-hotels.ini SSH_CONFIG=~/.ssh/ohara/config \
  ./bash/install-wp-site-backup.sh station

INVENTORY=inventory/ohara-hotels.ini ./bash/install-wp-site-backup.sh --remove-plugins station
```

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `wp_site_backup_enable_cron` | `true` | Install root cron |
| `wp_site_backup_remove_cron` | `false` | Uninstall cron |
| `wp_site_backup_cron_schedule` | `""` | Custom cron; empty = 01:00 + hostname stagger |
| `wp_site_backup_cron_tz` | `Australia/Sydney` | `CRON_TZ` |
| `wp_site_backup_remove_legacy_plugins` | `false` | `rm -rf` updraft/wpvividbackups dirs, uninstall plugins |
| `wp_site_backup_dir` | `/var/backups/wordpress` | Backup destination |
| `wp_site_backup_skip_hosts` | `capitalformwork`, `lwhydraulics`, `figtreesports` | Ansible `end_host` |

## Manual run

```bash
sudo /usr/local/bin/wp-site-backup.sh
tail -f /var/log/wp-site-backup.log
```

## Restore

1. Clean docroot (or new instance). Install matching core:
   ```bash
   wp core download --version=$(cat /var/backups/wordpress/*_files_*.version | head -1) --path=/home/ec2-user/html
   ```
2. Extract files archive into docroot (paths are relative: `wp-config.php`, `wp-content/`):
   ```bash
   sudo tar -xzf /var/backups/wordpress/<site>_files_YYYYMMDD_HHMMSS.tar.gz -C /home/ec2-user/html
   sudo chown -R ec2-user:nginx /home/ec2-user/html/wp-content
   ```
3. Import database:
   ```bash
   gunzip -c /var/backups/wordpress/<site>_db_YYYYMMDD_HHMMSS.sql.gz \
     | wp db import - --path=/home/ec2-user/html
   ```

Before extracting, remove immutability: `sudo chattr -i /var/backups/wordpress/<archive>`.

## Verify on one host

Pick one Ohara WordPress host (not `capitalformwork`, `lwhydraulics`, or `figtreesports`).

1. Deploy backup cron and optionally remove legacy plugins:
   ```bash
   ansible-playbook -i inventory/ohara-hotels.ini modules/9_backup/playbook.yml \
     -e wp_site_backup_remove_legacy_plugins=true --limit station
   ```
2. Confirm plugins gone:
   ```bash
   ssh station 'wp plugin is-installed updraftplus --path=/home/ec2-user/html; echo exit:$?'
   ssh station 'test ! -d /home/ec2-user/html/wp-content/updraft && echo updraft absent'
   ```
3. Confirm backup dir not readable by web user:
   ```bash
   ssh station 'sudo -u nginx ls /var/backups/wordpress'   # expect Permission denied
   ```
4. First manual backup:
   ```bash
   ssh station 'sudo /usr/local/bin/wp-site-backup.sh'
   ssh station 'ls -la /var/backups/wordpress/'
   ssh station 'cat /run/wp-site-backup-db.stamp'
   ```
5. Files archive contents (no core):
   ```bash
   ssh station 'tar -tzf /var/backups/wordpress/*_files_*.tar.gz | head'
   # Expect wp-config.php and wp-content/ only — no wp-admin/ or wp-includes/
   ```
6. Second run should log nothing due:
   ```bash
   ssh station 'sudo /usr/local/bin/wp-site-backup.sh; tail -3 /var/log/wp-site-backup.log'
   ```
7. Auto-update skips duplicate dump when stamp is fresh:
   ```bash
   ssh station 'WP_AUTO_UPDATE_DRY_RUN=1 /home/ec2-user/bin/run-wp-auto-update.sh | grep -i dump'
   # Expect: Skip: fresh dump from wp-site-backup
   ```
8. With stamp removed, dry-run plans fallback dump:
   ```bash
   ssh station 'sudo rm -f /run/wp-site-backup-db.stamp'
   ssh station 'WP_AUTO_UPDATE_DRY_RUN=1 /home/ec2-user/bin/run-wp-auto-update.sh | grep -i dump'
   ```
9. Immutability on archives:
   ```bash
   ssh station 'lsattr /var/backups/wordpress/*.gz'
   ```
10. Site still serves:
    ```bash
    curl -sI https://<site-domain>/ | head -1
    ```

On Sunday, step 5 may show no files archive (files tar skipped); database dump and stamp should still appear.

## Files

| Path on host | Role |
|--------------|------|
| `/usr/local/bin/wp-site-backup.sh` | Backup + smart scheduler |
| `/usr/local/bin/install-wp-site-backup-cron.sh` | Root crontab installer |
| `/var/backups/wordpress/` | Archives (`0700`) |
| `/var/log/wp-site-backup.log` | Log |
| `/run/wp-site-backup-db.stamp` | DB dump freshness for module 8 |
| `/etc/wp-site-backup.env` | `WP_ROOT`, backup dir |
