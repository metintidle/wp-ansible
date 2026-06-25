# Fail2Ban: stop banning logged-in WordPress editors (dynamic-IP safe)

## Context

On the **lifeimaging** host (AWS Lightsail, ~1 GB RAM, AL2023, WordPress + Elementor), editors get firewall-banned during normal admin work. Two causes:

1. **Over-broad access.log filters.** [`nginx-php-url-hack.conf`](modules/5_security/files/fail2ban/filter/nginx-php-url-hack.conf) line 3 matches `wp-admin*.php` on **any status (incl. 200)**, and line 1 matches `.php` on **403**. With `maxretry=2`, an editor is banned after 2 normal admin clicks or 2 nginx-403s. [`non-wordpress-requests.conf`](modules/5_security/files/fail2ban/filter/non-wordpress-requests.conf) only exempts paths that returned **200**, so an admin/REST request returning 403/5xx is not exempt.

2. **Rate-limit bans.** On a saturated 1 GB box, a busy Elementor session can trip nginx `limit_req` → 503 → the built-in `nginx-limit-req` jail (reads error.log) bans the editor. The original plan's **cookie-aware logging is rejected**: `map $http_cookie` only checks the raw header string, so any attacker sending `Cookie: wordpress_logged_in_x=1` would bypass every filter — and it can't help `nginx-limit-req` at all (error.log has no cookie field).

**Editors are on dynamic/home IPs**, so `ignoreip` whitelisting is not viable. The fix must be **behavior-based and unspoofable**.

Confirmed safe already (no filter matches these): **500 / 502 / 504** are matched by no jail, so PHP-saturation errors never cause a ban. The real ban vectors are: `.php` 403/200 on admin (fix #1), admin/REST 403 (fix #2), and `limit_req` 503 (fix #3).

## Approach

### 1. Harden [`nginx-php-url-hack.conf`](modules/5_security/files/fail2ban/filter/nginx-php-url-hack.conf)

Remove the `wp-admin.*\.php` catch-all (root cause) and narrow the `.php` line to **404 only** (scanner probing missing files). 5xx and 403 on `.php` no longer match.

```ini
[Definition]
failregex = ^<HOST> - .* "(GET|POST|HEAD) .*\.php.*" 404 .*$
            ^<HOST> - .* "(GET|POST|HEAD) .*shell.*\.php.*" .*$
ignoreregex =
```

### 2. Broaden ignoreregex in [`non-wordpress-requests.conf`](modules/5_security/files/fail2ban/filter/non-wordpress-requests.conf)

Keep all attack `failregex` patterns unchanged. Change the path-based `ignoreregex` to exempt WordPress admin/REST/content paths at **any status** (remove the trailing ` 200 `). Path-based = unspoofable (reflects the real requested URL).

```ini
ignoreregex = ^<HOST> -.*"(GET|POST|HEAD) /(wp-admin|wp-login\.php|wp-content|wp-includes|admin-ajax\.php|index\.php|wp-cron\.php|wp-json|favicon\.ico|robots\.txt).*"
```

### 3. Make `nginx-limit-req` zone-aware (login-zone bans only)

New filter **`modules/5_security/files/fail2ban/filter/nginx-limit-req-login.conf`** that matches nginx `limiting requests` lines **only for `zone="security_login"`** (wp-login brute force). Bursts on `zone=one` (global 30r/s) and `zone=security_api` (admin-ajax, used by Elementor) are throttled by nginx but **never banned** — so editors on dynamic IPs are safe. Model on the stock `nginx-limit-req.conf` regex:

```ini
[Definition]
failregex = ^\s*\[error\] \d+#\d+: \*\d+ limiting requests, excess: [\d\.]+ by zone "security_login", client: <HOST>,
ignoreregex =
```

In [`jail.local`](modules/5_security/files/fail2ban/jail.local), point the limit-req jail at the new filter and keep it on error.log:

```ini
[nginx-limit-req]
enabled  = true
filter   = nginx-limit-req-login
logpath  = /var/log/nginx/error.log
maxretry = 5
```

Trade-off (confirmed with user): anonymous floods on the global zone get 503-throttled but not firewall-banned; CrowdSec + geo-firewall remain as additional layers.

### 4. Reconcile the rate-limit zone conflict

[`modules/1_nginx-php/files/security/general.conf`](modules/1_nginx-php/files/security/general.conf) defines `zone=one rate=1r/s` and omits `security_login`/`security_api`; [`modules/5_security/files/security/general.conf`](modules/5_security/files/security/general.conf) uses `30r/s` and defines all three. Both deploy to `/etc/nginx/conf.d/security.conf` (module 1 at [playbook.yml:168](modules/1_nginx-php/playbook.yml:168); module 5 at [playbook-fail2ban.yml:14](modules/5_security/playbook-fail2ban.yml:14)). Make module 1's `general.conf` identical to module 5's (30r/s + all three zones) so a standalone module-1 re-run can't (a) drop the rate to 1r/s and cause editor 503s, or (b) break `nginx -t` by leaving `security_login`/`security_api` undefined.

### 5. Playbook deploy + validation in [`playbook-fail2ban.yml`](modules/5_security/playbook-fail2ban.yml)

- Add a copy task for the new `nginx-limit-req-login.conf` filter (mirror the existing filter-copy tasks at lines 57–71).
- Replace the bare nginx `service: restarted` (line 204) with `nginx -t` validation → `reload`. Reload **nginx before fail2ban**.
- Add post-deploy `fail2ban-regex` checks (with `failonerror`/registered output) using synthetic log lines:
  - MUST NOT match (0 hits): `"GET /wp-admin/post.php?action=elementor" 200`, `"POST /wp-admin/admin-ajax.php" 500`, `"GET /wp-admin/edit.php" 403`, an Elementor preview pretty-URL 403, and a `limiting requests ... by zone "one"` error line.
  - MUST match: a random `.php` 404 probe, a `shell.php` hit, and `limiting requests ... by zone "security_login"`.
- **Drop entirely** from the original plan: `wp-fail2ban-log.conf`, the `main_wp` log_format, and edits to [`modules/1_nginx-php/files/nginx.conf`](modules/1_nginx-php/files/nginx.conf) / [`configs/nginx-ssl.conf`](configs/nginx-ssl.conf). No access-log format change needed.

## Files changed

| File | Change |
|------|--------|
| [`modules/5_security/files/fail2ban/filter/nginx-php-url-hack.conf`](modules/5_security/files/fail2ban/filter/nginx-php-url-hack.conf) | remove wp-admin line; `.php` → 404 only; keep shell |
| [`modules/5_security/files/fail2ban/filter/non-wordpress-requests.conf`](modules/5_security/files/fail2ban/filter/non-wordpress-requests.conf) | path ignoreregex → any status (drop ` 200 `) |
| `modules/5_security/files/fail2ban/filter/nginx-limit-req-login.conf` | **new** — login-zone-only limit_req matcher |
| [`modules/5_security/files/fail2ban/jail.local`](modules/5_security/files/fail2ban/jail.local) | `nginx-limit-req` uses new filter + explicit error.log logpath |
| [`modules/1_nginx-php/files/security/general.conf`](modules/1_nginx-php/files/security/general.conf) | match module 5: `30r/s` + define `security_login`/`security_api` |
| [`modules/5_security/playbook-fail2ban.yml`](modules/5_security/playbook-fail2ban.yml) | deploy new filter, `nginx -t`+reload, fail2ban-regex validation |

No change to `maxretry` thresholds (after filter fixes the access.log jails only match real attacks). The `jail.local.hardened` draft and `jail.local` already agree on jail structure; only the limit-req jail block changes.

## Verification

1. **Local (no host needed):** run `fail2ban-regex` against the synthetic lines above for all three filters; confirm the MUST-NOT-match set yields 0 and the MUST-match set yields hits.
2. **Deploy:**
   ```bash
   ansible-playbook -i 'lifeimaging,' modules/5_security/playbook-fail2ban.yml \
     -e ansible_host=13.54.18.208 ansible_ssh_private_key_file=~/.ssh/lifeimaging.pem
   ```
   (Or `ssh -F ssh-config lifeimaging` per the incident doc.)
3. **On host:**
   ```bash
   sudo nginx -t && sudo systemctl reload nginx
   sudo fail2ban-client reload
   sudo fail2ban-client status nginx-php-url-hack
   sudo fail2ban-client status nginx-non-wordpress
   sudo fail2ban-client status nginx-limit-req
   ```
4. **Behavioral check:** edit a page in Elementor while watching `sudo tail -f /var/log/fail2ban/banned-ips.log` — your IP must not appear. Confirm wp-login brute force still bans via the security_login zone.
5. **Unban any currently-affected editor IP:**
   ```bash
   sudo fail2ban-client set nginx-php-url-hack unbanip <IP>
   sudo fail2ban-client set nginx-limit-req unbanip <IP>
   ```

## Out of scope / non-goals

- No 502/503/504 added to any `failregex` (would ban users during PHP-FPM saturation).
- No cookie/`wp_auth` logging, no nginx access-log format change (spoofable + unnecessary).
- No `ignoreip` IP whitelist (editors are on dynamic IPs).
- No changes to PHP-FPM/swap/supercache capacity work (already done per `docs/lifeimaging-incident-and-fixes.md`).
