# Per-site database credentials

## The problem this fixes
Every site was provisioned with the **same** `DB_USER` / `DB_PASS` (shared env
vars). On the central MySQL host that one account can read/write **all** site
databases — so a single leaked `wp-config.php` exposes the whole fleet.

## The fix
Each site gets its **own** MySQL user with a strong password, granted privileges
on **only its own database** AND bound to **only that host's source address**
(`GRANT ... ON \`dbname\`.* TO 'user'@'<that-host-ip>'`). So even a stolen
credential is useless from anywhere except the host it belongs to.

- New installs: `playbook.yml` generates per-site, host-bound creds.
- Existing ~30 sites: `fix-db-credentials.yml` migrates them in place and also
  applies PHP/Nginx **web-shell hardening** (`snippets/php-webshell-hardening.yml`).

The grant host is auto-detected (the address the central DB actually sees for the
host). Override with `-e db_grant_host=1.2.3.4`, or `-e db_grant_host='%'` to keep
a wildcard.

## One-time setup (on the Ansible controller, do NOT commit)

**Option A — env file (recommended):**
```bash
cp modules/2_wordpress/.db-admin.env.example modules/2_wordpress/.db-admin.env
# edit .db-admin.env, then:
source modules/2_wordpress/.db-admin.env
# or use the wrapper:
./bash/run-fix-db-credentials.sh -i inventory/ohara-hotels.ini --limit berkeley
```

**Option B — export in shell profile (`~/.zshrc`):**
```bash
export DB_ADMIN_USER='...'
export DB_ADMIN_PASS='...'
```

`fix-db-credentials.yml` reads `DB_HOST` from each site's `wp-config.php`. `DB_HOST` in
`.db-admin.env` is only for `playbook.yml` new provisions.

## Migrate the existing fleet
Uses your existing inventories (which wire up `~/.ssh/config`).
```bash
# Safe: one host first
ansible-playbook -i inventory/ohara-hotels.ini modules/2_wordpress/fix-db-credentials.yml --limit berkeley

# Then the whole group(s)
ansible-playbook -i inventory/ohara-hotels.ini   modules/2_wordpress/fix-db-credentials.yml
ansible-playbook -i inventory/wp-agent-batch.ini modules/2_wordpress/fix-db-credentials.yml
```
The playbook verifies the new user can reach the DB **before** rewriting
`wp-config.php`, backs up `wp-config.php` to `wp-config.php.bak-predbfix`, then
runs `wp db check`. It is idempotent — safe to re-run.

## Generated credentials
Recorded per host on the controller at
`modules/2_wordpress/.db-credentials/<host>.yml` (git-ignored, mode 0600).
Passwords also persist in `<host>.pass` so re-runs reuse the same value.

## Web-shell hardening (bundled)
`fix-db-credentials.yml` and `modules/1_nginx-php/playbook.yml` apply
`snippets/php-webshell-hardening.yml`:
- Disables shell-spawning PHP functions for **FPM only** (WP-CLI/cron keep them).
- Denies PHP execution under `wp-content/{uploads,cache,upgrade}` in Nginx.
- `expose_php = Off`, `allow_url_include = off`.
- `open_basedir` is **off by default** (most likely to break plugins); enable per
  host after testing: `-e php_harden_open_basedir=true`.

## Retiring the old shared admin (manual, one-time)

> ⚠️ The old shared account is the **database admin** AND it was embedded in every
> `wp-config.php`, so treat its password as **compromised**. Do **NOT** `DROP` it
> or `REVOKE ALL` from it — that destroys your admin and can break the server.
> The correct sequence is **verify unused → rotate password → restrict host**.
> (Removing the wildcard `@'%'` *host entry* is fine — but only after a
> host-restricted replacement is confirmed working. That removes remote
> reachability without deleting your admin identity.)

**1. Verify no site still authenticates as it** (read-only, changes nothing):
```bash
ansible-playbook -i inventory/ohara-hotels.ini   modules/2_wordpress/verify-shared-admin-unused.yml -e old_admin_user=<admin>
ansible-playbook -i inventory/wp-agent-batch.ini modules/2_wordpress/verify-shared-admin-unused.yml -e old_admin_user=<admin>
```
The play fails loudly for any host whose `DB_USER` is still the old admin — run
`fix-db-credentials.yml` on those first.

**2. Audit where it can connect and what it can do** (on the DB host):
```sql
SELECT user, host FROM mysql.user WHERE user='<admin>';
SHOW GRANTS FOR '<admin>'@'<host>';
```

**3. Rotate the (compromised) password** — only now that nothing uses it:
```sql
ALTER USER '<admin>'@'<host>' IDENTIFIED BY '<new-strong-password>';
-- then update DB_ADMIN_PASS on your controller.
```

**4. Restrict where it can log in from** — the key hardening:

If it is MySQL **root** / the primary admin → keep it usable only from the DB host:
```sql
CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED BY '<new-strong-password>';
-- grant what root needs to 'root'@'localhost', confirm you can log in locally, THEN:
DROP USER IF EXISTS 'root'@'%';     -- removes only the remote/wildcard host entry
FLUSH PRIVILEGES;
-- administer over an SSH tunnel to the DB host from then on.
```

If it is a **named admin** reachable from the web tier → rebind it to your bastion IP:
```sql
CREATE USER IF NOT EXISTS '<admin>'@'<your-admin-ip>' IDENTIFIED BY '<new-strong-password>';
GRANT ALL PRIVILEGES ON *.* TO '<admin>'@'<your-admin-ip>' WITH GRANT OPTION;
FLUSH PRIVILEGES;
-- confirm the new entry works, THEN remove the wildcard one:
DROP USER IF EXISTS '<admin>'@'%';
FLUSH PRIVILEGES;
```
