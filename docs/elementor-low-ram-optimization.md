# Elementor Edit Mode Speed Optimization for 512MB RAM Servers

## Ohara hotel SSH hosts

SSH config: `~/.ssh/ohara/config` (use `ssh -F ~/.ssh/ohara/config <alias>` if it is not in your default `~/.ssh/config`).

| SSH alias | Site |
|-----------|------|
| `berkeley` | Berkeley Hotel |
| `bligh` | Bligh Park Hotel |
| `station` | Station Hotel |
| `warrilahotel` | Warilla Hotel |
| `centralhotel` | Central Hotel Blacktown |
| `town` | Town Tavern |
| `salamander` | Salamander |
| `lake` | Lake |

Apply to all Ohara WordPress hosts from this repo:

```bash
chmod +x bash/apply-elementor-low-ram.sh
./bash/apply-elementor-low-ram.sh
```

Single host: `./bash/apply-elementor-low-ram.sh berkeley`

If WP-CLI is missing on a host, install it and run revision/transient/DB cleanup:

```bash
./bash/install-wp-cli-cleanup.sh bligh station warrilahotel town lake
```

---

**Target stack:** Amazon Linux 2023 · Nginx · PHP-FPM 8.1 (`pm = ondemand`, `pm.max_children = 2`, 96MB memory limit) · WordPress · Oracle HeatWave MySQL · 512MB RAM (~200MB baseline usage)

Ohara live hosts: apply pool settings with `bash/apply-php-fpm-ondemand.sh`.

**Goal:** Speed up Elementor's edit mode without increasing server memory.

---

## The Real Bottleneck

On a 2-worker PHP-FPM setup, the slowdown isn't memory — it's **worker contention**. Heartbeat requests are uncacheable POST requests to `admin-ajax.php` that bypass page caching. Every single pulse requires a dedicated PHP worker to process, and WordPress must perform a full bootstrap (core + plugins + theme) for each request.

With `pm.max_children = 2`:
- Default Heartbeat fires every **15 seconds** in the editor
- Default autosave fires every **60 seconds**
- One editor session can lock **50% of your PHP workers** every 15 seconds

Throttling these reduces editor-generated worker hits by roughly **8x** without touching RAM allocation.

---

## Top Recommendation: Throttle the Heartbeat API

Add to your active theme's `functions.php` (or create a small mu-plugin in `/home/ec2-user/html/wp-content/mu-plugins/heartbeat-throttle.php`):

```php
<?php
/**
 * Plugin Name: Heartbeat & Editor Throttle
 * Description: Reduces PHP-FPM worker contention on low-RAM servers.
 */

// Throttle WordPress Heartbeat in admin (post editor)
add_filter('heartbeat_settings', function($settings) {
    $settings['interval'] = 120; // default 15s → 120s (max allowed)
    return $settings;
}, PHP_INT_MAX);

// Throttle Elementor's own editor heartbeat
add_filter('elementor/editor/heartbeat_options', function($settings) {
    if (is_array($settings)) {
        $settings['interval'] = 180; // 3 minutes
    }
    return $settings;
}, 10, 1);

// Kill heartbeat entirely on the frontend (nothing needs it there)
add_action('init', function() {
    if (!is_admin()) {
        wp_deregister_script('heartbeat');
    }
});
```

---

## wp-config.php Constants

Add before `/* That's all, stop editing! */`:

```php
// Keep only 3 revisions per post (massive DB shrink)
define('WP_POST_REVISIONS', 3);

// Autosave every 24 hours (effectively off; default is 60 seconds)
define('AUTOSAVE_INTERVAL', 86400); // 24 hours = effectively off

// Empty trash faster (less DB cruft)
define('EMPTY_TRASH_DAYS', 7);

// Disable file editing in admin (security + slight speed)
define('DISALLOW_FILE_EDIT', true);
```

---

## One-Time Cleanup (WP-CLI)

Run from the WordPress root to clean existing bloat:

```bash
cd /home/ec2-user/html

# Delete all existing post revisions
wp post delete $(wp post list --post_type='revision' --format=ids) --force

# Clean expired transients
wp transient delete --expired

# Optimize database tables
wp db optimize
```

---

## Elementor → Settings → Features

Enable these (zero memory cost, real speed gains):

- **Inline Font Icons** — renders icons as inline SVGs instead of loading Font Awesome and eIcons, removing extra CSS and font files
- **Optimized Gutenberg Loading** — dequeues unused Gutenberg block editor scripts/styles
- **Optimized Image Loading** — applies `fetchpriority="high"` on LCP images and `loading="lazy"` below the fold

Then disable any individual widgets you don't use (each widget toggle reduces editor load).

---

## Nginx Tweak: Skip Cache for Elementor Preview

Your existing `cache_block.conf` skips cache for `/wp-admin/` but **not** the frontend editor preview (`?elementor-preview=...`). Add this to `cache_block.conf`:

```nginx
if ($request_uri ~* "elementor-preview|action=elementor") {
  set $skip_cache 1;
}
```

Reload Nginx after editing:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## Verification

After applying changes, check editor network activity in Chrome DevTools → Network tab while in Elementor edit mode:

- `admin-ajax.php` requests should drop from ~4/minute to ~1 every 2-3 minutes
- Editor responsiveness improves immediately (no server restart needed for PHP/JS changes)
- `fpm.log` should show fewer concurrent worker spikes

---

## Memory Budget After Changes

| Component | Before | After |
|-----------|--------|-------|
| PHP-FPM workers (editor active) | 2/2 saturated | 1/2 saturated |
| Heartbeat requests/min (editor) | ~4 | ~0.5 |
| Autosave requests/min | ~1 | ~0 (86400s interval) |
| RAM usage | Unchanged | Unchanged |

The win is **CPU and worker availability**, not memory.

---

## Why This Beats Adding RAM

Adding RAM lets you increase `pm.max_children`, but that only helps if the workers are blocked on real work. Heartbeat/autosave requests are *artificial* contention — they're scheduled overhead, not user-driven load. Removing the artificial load is free; adding RAM costs money and still leaves the worker thrashing.
