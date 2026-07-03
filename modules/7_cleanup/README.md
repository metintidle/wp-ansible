# Module 7 — Unused media cleanup

Deploys WP-CLI scripts to audit, back up (outside webroot), and delete unused **PNG, JPG, WebP, and video** Media Library attachments. Optional monthly cron: **01:00 Sydney**, 1st of each month.

Scripts live in [`files/`](files/). See [`files/README.md`](files/README.md) for behaviour, risks, and restore steps.

## Playbook

```bash
# Deploy scripts only (cron off by default)
ansible-playbook -i inventory/ohara-hotels.ini modules/7_cleanup/playbook.yml --limit north

# Deploy + install ec2-user cron
ansible-playbook -i inventory/ohara-hotels.ini modules/7_cleanup/playbook.yml \
  -e wp_clean_enable_cron=true --limit north

# Deploy + audit (no delete)
ansible-playbook -i inventory/ohara-hotels.ini modules/7_cleanup/playbook.yml \
  -e wp_clean_run_dry_run=true --limit north

# Remove cron
ansible-playbook -i inventory/ohara-hotels.ini modules/7_cleanup/playbook.yml \
  -e wp_clean_remove_cron=true --limit north
```

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `wp_clean_install_dir` | `/home/ec2-user/bin` | Script install path |
| `wp_clean_log_dir` | `/home/ec2-user/logs` | Log directory |
| `wp_clean_backup_dir` | `/home/ec2-user/backups/unused-media` | Tarballs (outside webroot) |
| `wp_clean_enable_cron` | `false` | Install monthly cron |
| `wp_clean_remove_cron` | `false` | Uninstall cron |
| `wp_clean_run_dry_run` | `false` | Run audit after deploy |
| `wp_clean_cron_tz` | `Australia/Sydney` | `CRON_TZ` for cron job |
| `wp_clean_min_age_days` | `7` | Written to `~/.wp-clean.env` |
| `wp_clean_backup_retention` | `1` | Keep N tarballs |
| `wp_root` | auto-detect | From inventory or first existing `wp-config.php` |

## Manual run on host

```bash
WP_CLEAN_DRY_RUN=1 ~/bin/run-unused-media-cleanup.sh   # audit
~/bin/run-unused-media-cleanup.sh                      # backup + delete
```

## Safety

Always dry-run on a new site before enabling `wp_clean_enable_cron`. Elementor sites can have false positives — see [`files/README.md`](files/README.md).
