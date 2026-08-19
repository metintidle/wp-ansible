# Module 8 — WordPress and OS auto-updates

Deploys scheduled update tooling for WordPress (ec2-user) and Amazon Linux 2023 (root).

## WordPress auto-updates

Runs as `ec2-user` (no `--allow-root`).

### Update policy (default)

| Target | Policy |
|--------|--------|
| **WordPress core** | Latest (major + minor) |
| **Plugins** | All except `elementor-pro` and `elementor` |
| **Elementor** (free) | Minor only within same major (e.g. 4.2.x → 4.3.x, not 5.x) |
| **Elementor Pro** | Never auto-updated |
| **Themes** | Off |

Scripts live in [`files/`](files/).

### Playbook — WordPress

```bash
# Deploy scripts only (cron off by default)
ansible-playbook -i inventory/ohara-hotels.ini modules/8_updates/playbook.yml --tags wp_updates

# Deploy + install weekly cron (03:00 Sunday, Australia/Sydney)
ansible-playbook -i inventory/ohara-hotels.ini modules/8_updates/playbook.yml \
  --tags wp_updates -e wp_auto_update_enable_cron=true

# Check what would update (no changes)
ansible-playbook -i inventory/ohara-hotels.ini modules/8_updates/playbook.yml \
  --tags wp_updates -e wp_auto_update_run_dry_run=true --limit station

# Remove cron
ansible-playbook -i inventory/ohara-hotels.ini modules/8_updates/playbook.yml \
  --tags wp_updates -e wp_auto_update_remove_cron=true
```

### WordPress variables

| Variable | Default | Description |
|----------|---------|-------------|
| `wp_auto_update_enable_cron` | `false` | Install weekly cron |
| `wp_auto_update_remove_cron` | `false` | Uninstall cron |
| `wp_auto_update_cron_schedule` | `0 3 * * 0` | Cron expression (Sunday 03:00) |
| `wp_auto_update_cron_tz` | `Australia/Sydney` | `CRON_TZ` for cron job |
| `wp_auto_update_plugins` | `1` | Enable plugin updates |
| `wp_auto_update_plugin_exclude` | `elementor-pro,elementor` | Excluded from bulk `--all` pass |
| `wp_auto_update_elementor_minor` | `1` | Elementor free: `--minor` only |
| `wp_auto_update_themes` | `0` | Update all themes |
| `wp_auto_update_core_minor_only` | `0` | Core minor-only instead of latest |

### WordPress manual run

```bash
WP_AUTO_UPDATE_DRY_RUN=1 ~/bin/run-wp-auto-update.sh   # check only
~/bin/run-wp-auto-update.sh                            # apply updates
```

### WordPress cron schedule

```cron
CRON_TZ=Australia/Sydney
0 3 * * 0 /home/ec2-user/bin/run-wp-auto-update.sh >> /home/ec2-user/logs/wp-auto-update.log 2>&1
```

Remove: `~/bin/install-wp-auto-update-cron.sh --remove`

---

## OS auto-upgrades (Amazon Linux 2023)

Root cron job that:

1. Stops `nginx` and `php-fpm`
2. Runs `dnf upgrade --releasever=2023 -y`
3. Restarts `php-fpm` and `nginx`

Scripts deploy to `/usr/local/bin/`. Logs: `/var/log/os-upgrade.log`.

Non-AL2023 hosts are skipped automatically.

### Playbook — OS upgrade

```bash
# Deploy scripts only (cron off by default)
ansible-playbook -i inventory/al2023-fail2ban.ini modules/8_updates/playbook.yml --tags os_upgrade --limit cccls

# Deploy + install cron (midnight every 3 days, Australia/Sydney)
ansible-playbook -i inventory/al2023-fail2ban.ini modules/8_updates/playbook.yml \
  --tags os_upgrade -e os_upgrade_enable_cron=true --limit cccls

# Remove cron
ansible-playbook -i inventory/al2023-fail2ban.ini modules/8_updates/playbook.yml \
  --tags os_upgrade -e os_upgrade_remove_cron=true --limit cccls
```

### OS upgrade variables

| Variable | Default | Description |
|----------|---------|-------------|
| `os_upgrade_enable_cron` | `false` | Install root cron |
| `os_upgrade_remove_cron` | `false` | Uninstall root cron |
| `os_upgrade_cron_schedule` | `0 0 */3 * *` | Midnight every 3 days |
| `os_upgrade_cron_tz` | `Australia/Sydney` | `CRON_TZ` for OS upgrade job |
| `os_upgrade_releasever` | `auto` | Passed to `dnf upgrade --releasever` (`auto` = latest AL2023 release offered by dnf) |
| `os_upgrade_install_dir` | `/usr/local/bin` | Script install path |
| `os_upgrade_log_file` | `/var/log/os-upgrade.log` | Upgrade log file |

### OS upgrade cron schedule

```cron
CRON_TZ=Australia/Sydney
# OS upgrade every 3 days at local midnight (Australia/Sydney)
0 0 */3 * * /usr/local/bin/os-upgrade-with-webstack-restart.sh >> /var/log/os-upgrade.log 2>&1
```

The wrapper auto-detects the latest AL2023 release (e.g. `2023.12.20260817`). Do not pin bare `2023` — current repo mirrors return 403 for that releasever.

Remove: `sudo /usr/local/bin/install-os-upgrade-cron.sh --remove`

### Notes

- Expect brief site downtime while nginx/php-fpm are stopped **only when updates are available**. If `dnf check-update` is clean, services stay up.
- `php-fpm` and `nginx` are **masked** during the upgrade so `fpm.sh` cannot restart PHP-FPM mid-`dnf`.
- Kernel updates may still require a manual reboot.
- Existing root cron jobs (e.g. `fpm.sh`, `cleanlogs.sh`) are preserved; the OS upgrade block is appended with its own `CRON_TZ`.

Manual one-host deploy (without Ansible) is also available via [`bash/install-os-upgrade-cron.sh`](../../bash/install-os-upgrade-cron.sh).
