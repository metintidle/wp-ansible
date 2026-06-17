# CCCSL — Nginx & Elementor cache optimization

Guide for [cccsl.org.au](https://cccsl.org.au/) performance work on the **cccls** server (Amazon Linux 2023, Lightsail, WordPress + Elementor).

**SSH host:** `cccls`  
**Stack:** Nginx · PHP-FPM · WP Super Cache · Elementor / Elementor Pro · Route 53 DNS

---

## Summary

| Metric | Before | After |
|--------|--------|-------|
| Homepage (cached) | 5–20 s | **~40–80 ms** |
| Homepage (server-side cache hit) | ~200 ms+ | **~5 ms** |
| First load after cache clear | — | **~5 s** (WordPress boot) |
| Browser cache header | `max-age=3` | **`max-age=3600`** |
| Super Cache file lifetime | 30 min | **24 h** |

Root cause of slowness: every cache miss booted full WordPress (~6 s) plus a heavy Elementor page (~492 KB HTML, ~96 assets). Cached visitors were fast only when PHP served stale super-cache; nginx now serves static HTML directly.

---

## Architecture

```
Visitor (HTTPS)
    ↓
Route 53 → Lightsail (3.105.129.20)
    ↓
iptables (443 open, 80 closed inbound)
    ↓
Nginx
    ├─ try_files → /wp-content/cache/supercache/.../index-https.html  (cache HIT ~5 ms)
    └─ fallback → index.php → PHP-FPM → WordPress → Elementor         (cache MISS ~5 s)
            ↓
        Remote MySQL (152.69.175.15)
```

**Services (enabled):** `nginx`, `iptables`, `fail2ban`  
**Disabled:** `firewalld` (conflicted with fail2ban `iptables-multiport`)

---

## 1. Nginx — static Super Cache delivery

### What changed

Nginx serves pre-generated HTML from WP Super Cache **before** PHP runs. Logged-in users and admin paths still fall through to WordPress.

### Files

| File | Role |
|------|------|
| `/etc/nginx/nginx.conf` | `$wpsc_path` fix + `try_files` super-cache lookup |
| `/etc/nginx/default.d/supercache.conf` | Skip variables (POST, query string, cookies, admin) |
| `/etc/nginx/default.d/security.conf` | Static assets: `expires max`, immutable headers |

### Core `location /` block

```nginx
set $wpsc_path $uri;
if ($wpsc_path = /) { set $wpsc_path ""; }

location / {
    try_files /wp-content/cache/supercache/$http_host$wpsc_path/index-https.html $uri $uri/ /index.php?$args;
    add_header Cache-Control "public, max-age=3600" always;
}

location ~ ^/wp-content/cache/supercache/.+\.html$ {
    gzip_static on;
    add_header Cache-Control "public, max-age=3600" always;
    add_header X-Super-Cache "nginx-static" always;
}
```

> **Homepage path fix:** Without ` $wpsc_path = ""` for `/`, nginx looked for `cccsl.org.au//index-https.html` and returned 404 instead of falling back to PHP.

### Verify

```bash
curl -sI https://cccsl.org.au/ | grep -iE 'cache-control|x-super'
# Expect: Cache-Control: public, max-age=3600
#         X-Super-Cache: nginx-static   (on cache hit)
```

### Reload after edits

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## 2. WP Super Cache — PHP config

**File:** `/usr/share/nginx/html/wp-content/wp-cache-config.php`

| Setting | Value | Purpose |
|---------|-------|---------|
| `$cache_enabled` | `true` | Cache on |
| `$super_cache_enabled` | `true` | Static super-cache files |
| `$wp_cache_mod_rewrite` | `1` | Generate correct file layout for nginx |
| `$cache_max_time` | `86400` | Keep files 24 h |
| `$cache_time_interval` | `3600` | GC interval 1 h |
| `$cache_compression` | `1` | `.html.gz` alongside `.html` |

**Drop-in:** `wp-content/advanced-cache.php` (requires `WPCACHEHOME` in `wp-config.php`)

### Purge cache

```bash
sudo -u ec2-user wp cache flush --path=/usr/share/nginx/html
sudo rm -rf /usr/share/nginx/html/wp-content/cache/supercache/cccsl.org.au/*
```

### Warm cache (important after purge)

```bash
curl -s https://cccsl.org.au/ -o /dev/null
curl -s https://cccsl.org.au/whats-happening/ -o /dev/null
# First hit ~5 s; second hit ~5 ms
```

---

## 3. PHP-FPM tuning

**File:** `/etc/php-fpm.d/www.conf`

| Setting | Before | After |
|---------|--------|-------|
| `pm.max_children` | 2 | **3** |
| `pm.start_servers` | 1 | **2** |
| `pm.max_spare_servers` | 2 | **3** |

Server has **916 MB RAM**; each PHP worker uses ~100 MB. Do not raise `max_children` above 4 without upgrading the instance.

```bash
sudo systemctl restart php-fpm
```

---

## 4. Elementor optimizations

### Settings enabled (via WP-CLI)

```bash
sudo -u ec2-user wp option update elementor_optimized_image_loading yes --path=/usr/share/nginx/html
sudo -u ec2-user wp option update elementor_experiment-e_optimized_assets_loading active --path=/usr/share/nginx/html
sudo -u ec2-user wp option update elementor_experiment-e_lazyload active --path=/usr/share/nginx/html
```

`elementor_css_print_method` remains **external** (per-page CSS files in `wp-content/uploads/elementor/css/`).

### Critical: Elementor CSS regeneration

Running `wp elementor flush-css` **deletes** all `post-*.css` files. If super-cache still serves old HTML referencing those files, pages render **unstyled** (broken layout).

**Symptom:** Layout broken; browser shows 404 on e.g. `post-3783.css`.

**Fix — regenerate all Elementor pages:**

```bash
sudo -u ec2-user wp eval '
$ids = get_posts([
  "post_type" => ["page", "post", "elementor_library"],
  "posts_per_page" => -1,
  "post_status" => "any",
  "fields" => "ids",
  "meta_key" => "_elementor_edit_mode",
  "meta_value" => "builder",
]);
foreach ($ids as $id) {
  (new \Elementor\Core\Files\CSS\Post($id))->update();
}
echo "regenerated " . count($ids) . " pages\n";
' --path=/usr/share/nginx/html

# Then purge super-cache (see above)
```

### Modular templates (recommended, not yet done)

Homepage (post **150**) has **157 elements** but only **2** template widgets (Header/Footer). Converting inline sections to saved templates reduces per-page CSS and speeds cache misses.

Existing templates: `Header` (25), `Footer` (28), `secton4` (3776), `buttons-book-quote` (3749), `Our Services Template` (1463).

---

## 5. Firewall & fail2ban (context)

| Rule | State |
|------|-------|
| HTTPS (443) inbound | Open |
| HTTP (80) inbound | Closed |
| HTTP/HTTPS outbound | Open |
| SSH (22) | Open |

fail2ban uses **`iptables-multiport`** (not firewalld). Rules persist via `iptables-services`.

```bash
sudo fail2ban-client status
sudo iptables -L f2b-nginx-unknown-script -n -v
```

---

## 6. Troubleshooting

| Problem | Check | Fix |
|---------|-------|-----|
| Site unreachable on HTTPS | `sudo iptables -L -n` | Ensure 443 allowed; `sudo systemctl status nginx` |
| Page 404 after cache delete | nginx error log: `//index-https.html` | Confirm `$wpsc_path` homepage fix |
| Broken / messy layout | 404 on `post-XXXX.css` | Regenerate Elementor CSS (§4) + purge cache |
| Slow every visit | No `X-Super-Cache: nginx-static` | Purge cache, warm pages, check super-cache files exist |
| Logged-in admin slow | Expected | Cache skipped for `wordpress_logged_in` cookie |
| fail2ban bans not blocking | `iptables -L` empty f2b chains | `sudo systemctl restart fail2ban` |

### Useful paths

```
/usr/share/nginx/html/                          # WordPress root
/usr/share/nginx/html/wp-content/cache/supercache/cccsl.org.au/
/usr/share/nginx/html/wp-content/uploads/elementor/css/
/var/log/nginx/error.log
/var/log/fail2ban.log
```

### Backups created during setup

```
/etc/nginx/nginx.conf.bak-YYYYMMDD
/usr/share/nginx/html/wp-content/wp-cache-config.php.bak-YYYYMMDD
/etc/php-fpm.d/www.conf.bak-YYYYMMDD
```

---

## 7. CDN note (Route 53)

DNS uses **Route 53** nameservers (`awsdns-*`). Cloudflare Free requires moving nameservers away from Route 53.

**AWS-native alternative:** CloudFront in front of Lightsail, Route 53 ALIAS → CloudFront. No DNS provider change required.

---

## 8. Maintenance checklist

After WordPress/plugin updates or Elementor design changes:

- [ ] Regenerate Elementor CSS if layouts look wrong
- [ ] Purge WP Super Cache
- [ ] Warm key pages (`/`, `/whats-happening/`, service pages)
- [ ] Spot-check `curl -sI https://cccsl.org.au/` for `max-age=3600`
- [ ] Confirm no 404s on `post-*.css` in browser Network tab

---

## Related

- [README.md](../../README.md) — tickets-video project overview
- [docs/webpage/DESIGN.md](../webpage/DESIGN.md) — landing page design tokens (separate from CCCSL site)

---

*Last updated: 2026-06-05 — reflects production state on `cccls` after nginx super-cache, PHP-FPM, and Elementor performance work.*
