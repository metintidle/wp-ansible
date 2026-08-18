# Module 8 — WordPress auto-updates

Deploys WP-CLI scripts for scheduled WordPress updates. Runs as `ec2-user` (no `--allow-root`).

## Update policy (default)

| Target | Policy |
|--------|--------|
| **WordPress core** | Latest (major + minor) |
| **Plugins** | All except `elementor-pro` and `elementor` |
| **Elementor** (free) | Minor only within same major (e.g. 4.2.x → 4.3.x, not 5.x) |
| **Elementor Pro** | Never auto-updated |
| **Themes** | Off |

Scripts live in [`files/`](files/).

## Playbook

```bash
# Deploy scripts only (cron off by default)
ansible-playbook -i inventory/ohara-hotels.ini modules/8_updates/playbook.yml

# Deploy + install weekly cron (03:00 Sunday, Australia/Sydney)
ansible-playbook -i inventory/ohara-hotels.ini modules/8_updates/playbook.yml \
  -e wp_auto_update_enable_cron=true

# Check what would update (no changes)
ansible-playbook -i inventory/ohara-hotels.ini modules/8_updates/playbook.yml \
  -e wp_auto_update_run_dry_run=true --limit station

# Remove cron
ansible-playbook -i inventory/ohara-hotels.ini modules/8_updates/playbook.yml \
  -e wp_auto_update_remove_cron=true
```

## Variables

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

## Manual run on host

```bash
WP_AUTO_UPDATE_DRY_RUN=1 ~/bin/run-wp-auto-update.sh   # check only
~/bin/run-wp-auto-update.sh                            # apply updates
```

## Cron schedule

```cron
CRON_TZ=Australia/Sydney
0 3 * * 0 /home/ec2-user/bin/run-wp-auto-update.sh >> /home/ec2-user/logs/wp-auto-update.log 2>&1
```

Remove: `~/bin/install-wp-auto-update-cron.sh --remove`
