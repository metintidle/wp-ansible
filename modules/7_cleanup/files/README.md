# Unused media cleanup (WP-CLI + cron)

Reusable tools to audit, back up, and delete **unused Media Library** attachments on WordPress + Elementor sites.

**Ansible deploy:** [`../playbook.yml`](../playbook.yml) (see [`../README.md`](../README.md)).

## Files

| File | Purpose |
|------|---------|
| [`unused-media-cleanup.php`](unused-media-cleanup.php) | Audit, tarball backup, delete unused attachments |
| [`run-unused-media-cleanup.sh`](run-unused-media-cleanup.sh) | Wrapper: WP root detect, lock, logging, env |
| [`install-unused-media-cron.sh`](install-unused-media-cron.sh) | ec2-user crontab: **01:00 Sydney**, 1st of month |
| [`north-fix-images.php`](north-fix-images.php) | One-off Elementor repair (North Nowra); not used by cron |
| [`nnt-backup-delete-unused.php`](nnt-backup-delete-unused.php) | **Deprecated** — use `unused-media-cleanup.php` |

## What gets deleted

- **PNG, JPG/JPEG, WebP, and video attachments only** (by mime type or file extension). PDF, SVG, and other types are skipped.
- Unused eligible attachments in the Media Library with **no detected usage** in:
  - Published pages/posts (configurable limits)
  - Elementor `_elementor_data` + templates
  - `postmeta` / `options` containing upload URLs
  - Elementor/theme CSS files

## What is NOT deleted

- Instagram Feed cache (`sb-instagram-feed-images/`) — purge via Smash Balloon plugin
- Orphan disk files with no attachment row
- Attachments newer than `WP_CLEAN_MIN_AGE_DAYS` (default 7)
- Anything still referenced in scanned content

**Elementor warning:** Media Cleaner lists Elementor as incompatible. This scan can miss drafts, popups, or content outside scan limits. Always dry-run first.

## Backup location (outside webroot)

Default: `/home/ec2-user/backups/unused-media/`

- Tarballs: `unused-media-YYYY-MM-DD.tar.gz`
- Manifest: `unused-media-YYYY-MM-DD/manifest.json`

Backups **must** stay outside `$WP_ROOT` and `wp-content/` so UpdraftPlus and similar plugins do not re-backup cleanup archives.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WP_CLEAN_DRY_RUN` | `0` | `1` = JSON manifest only |
| `WP_CLEAN_BACKUP_DIR` | `/home/ec2-user/backups/unused-media` | Outside webroot |
| `WP_CLEAN_BACKUP_RETENTION` | `1` | Keep N newest `.tar.gz` files |
| `WP_CLEAN_MIN_AGE_DAYS` | `7` | Skip recent uploads |
| `WP_CLEAN_MAX_PAGES` | `10` | Published pages to scan |
| `WP_CLEAN_MAX_POSTS` | `50` | Published posts to scan |

Optional host file: `/home/ec2-user/.wp-clean.env` (sourced by wrapper).

## Deploy per site

```bash
HOST=north
SSH_CONFIG=~/.ssh/ohara/config
CLEAN=~/Projects/Wordpress\ Plugins/wp-itt-toolbox/clean

ssh -F "$SSH_CONFIG" "$HOST" 'mkdir -p ~/bin ~/logs ~/backups/unused-media'
scp -F "$SSH_CONFIG" "$CLEAN/unused-media-cleanup.php" \
    "$CLEAN/run-unused-media-cleanup.sh" \
    "$CLEAN/install-unused-media-cron.sh" \
    "$HOST:~/bin/"
ssh -F "$SSH_CONFIG" "$HOST" 'chmod +x ~/bin/*.sh'

# 1. Dry-run
ssh -F "$SSH_CONFIG" "$HOST" 'WP_CLEAN_DRY_RUN=1 ~/bin/run-unused-media-cleanup.sh'

# 2. Manual run (backup + delete)
ssh -F "$SSH_CONFIG" "$HOST" '~/bin/run-unused-media-cleanup.sh'

# 3. Install cron (01:00 Sydney, 1st of month)
ssh -F "$SSH_CONFIG" "$HOST" '~/bin/install-unused-media-cron.sh'
```

From controller with wrapper locally:

```bash
WP_CLEAN_DRY_RUN=1 ./run-unused-media-cleanup.sh north
```

## Cron schedule

```cron
CRON_TZ=Australia/Sydney
0 1 1 * * /home/ec2-user/bin/run-unused-media-cleanup.sh >> /home/ec2-user/logs/wp-unused-media-cleanup.log 2>&1
```

Remove: `~/bin/install-unused-media-cron.sh --remove`

## Restore from backup

```bash
WP_ROOT=/usr/share/nginx/html   # verify per host
cd "$WP_ROOT/wp-content/uploads"
tar -xzf /home/ec2-user/backups/unused-media/unused-media-YYYY-MM-DD.tar.gz
```

This restores **files only**. Re-import to Media Library if you need attachment IDs back.

## After first delete

- Spot-check homepage and heavy image pages
- `wp elementor flush_css` if layouts break
- Verify backup path: `realpath ~/backups/unused-media` must not be under `realpath $WP_ROOT`

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success or nothing to delete |
| 1 | Backup failed |
| 2 | Partial delete failures |
| 3 | Backup dir inside webroot |

## Reference: North Nowra Tavern

First manual run (2026-06-30) removed 358 unused attachments (~640 MB). See `wp-ansible/docs/town-tover-images.md` in the Ansible repo.
