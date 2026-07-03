<?php
/**
 * Backup then delete unused media library attachments.
 *
 * Run via WP-CLI (as ec2-user):
 *   wp eval-file unused-media-cleanup.php
 *
 * Environment (set by run-unused-media-cleanup.sh or export manually):
 *   WP_CLEAN_DRY_RUN=1           Audit only — JSON manifest, no backup/delete
 *   WP_CLEAN_BACKUP_DIR          Default /home/ec2-user/backups/unused-media
 *   WP_CLEAN_BACKUP_RETENTION    Default 1 — keep N newest tarballs
 *   WP_CLEAN_MIN_AGE_DAYS        Default 7 — skip attachments newer than N days
 *   WP_CLEAN_MAX_PAGES           Default 10
 *   WP_CLEAN_MAX_POSTS           Default 50
 *
 * Only PNG, JPG, WebP, and video attachments are eligible.
 *
 * Exit codes: 0 ok, 1 backup failed, 2 partial delete failures, 3 backup dir inside webroot
 */
global $wpdb;

$dry_run = getenv('WP_CLEAN_DRY_RUN') === '1';
$backup_dir = rtrim(getenv('WP_CLEAN_BACKUP_DIR') ?: '/home/ec2-user/backups/unused-media', '/');
$backup_retention = max(1, (int) (getenv('WP_CLEAN_BACKUP_RETENTION') ?: 1));
$min_age_days = max(0, (int) (getenv('WP_CLEAN_MIN_AGE_DAYS') ?: 7));
$max_pages = max(1, (int) (getenv('WP_CLEAN_MAX_PAGES') ?: 10));
$max_posts = max(1, (int) (getenv('WP_CLEAN_MAX_POSTS') ?: 50));

$basedir = wp_upload_dir()['basedir'];
$date_stamp = gmdate('Y-m-d');
$backup_bundle = $backup_dir . '/unused-media-' . $date_stamp;
$manifest_path = $backup_bundle . '/manifest.json';
$archive = $backup_dir . '/unused-media-' . $date_stamp . '.tar.gz';

/**
 * Abort if backup directory is inside WordPress webroot.
 */
function wp_clean_validate_backup_dir(string $backup_dir): void {
    $backup_real = realpath($backup_dir);
    if ($backup_real === false) {
        $parent = dirname($backup_dir);
        $backup_real = realpath($parent);
        if ($backup_real === false) {
            return;
        }
        $backup_real = $backup_real . '/' . basename($backup_dir);
    }

    $abspath = realpath(ABSPATH);
    if ($abspath && strpos($backup_real, $abspath) === 0) {
        fwrite(STDERR, "ERROR: WP_CLEAN_BACKUP_DIR must be outside webroot (inside ABSPATH: $abspath)\n");
        exit(3);
    }

    $wp_content = realpath(WP_CONTENT_DIR);
    if ($wp_content && strpos($backup_real, $wp_content) === 0) {
        fwrite(STDERR, "ERROR: WP_CLEAN_BACKUP_DIR must be outside wp-content ($wp_content)\n");
        exit(3);
    }
}

function wp_clean_is_eligible_path(string $path): bool {
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    static $allowed = ['png', 'jpg', 'jpeg', 'webp', 'mp4', 'webm', 'mov', 'avi', 'mpeg', 'mpg', 'm4v', 'ogv', 'wmv', 'flv', '3gp'];
    return in_array($ext, $allowed, true);
}

function wp_clean_is_eligible_attachment(int $id): bool {
    $mime = get_post_mime_type($id);
    if (is_string($mime) && $mime !== '') {
        if (in_array($mime, ['image/jpeg', 'image/png', 'image/webp'], true)) {
            return true;
        }
        if (strpos($mime, 'video/') === 0) {
            return true;
        }
    }
    $rel = get_post_meta($id, '_wp_attached_file', true);
    return is_string($rel) && $rel !== '' && wp_clean_is_eligible_path($rel);
}

function wp_clean_mark_used($id, $source, &$used_ids, &$attachment_map) {
    if (!isset($attachment_map[$id])) {
        return;
    }
    $used_ids[$id] = true;
}

function wp_clean_scan_content($content, $source, &$used_ids, &$attachment_map, &$basename_map) {
    if (empty($content)) {
        return;
    }
    if (preg_match_all('/"id"\s*:\s*(\d+)/', $content, $m)) {
        foreach ($m[1] as $id) {
            wp_clean_mark_used((int) $id, $source, $used_ids, $attachment_map);
        }
    }
    if (preg_match_all('/wp-image-(\d+)/', $content, $m)) {
        foreach ($m[1] as $id) {
            wp_clean_mark_used((int) $id, $source, $used_ids, $attachment_map);
        }
    }
    if (preg_match_all('#/wp-content/uploads/[^"\'\s\)]+#', $content, $m)) {
        foreach ($m[0] as $path) {
            $bn = basename(parse_url($path, PHP_URL_PATH));
            $bn_clean = preg_replace('/-\d+x\d+(\.[a-z]+)$/i', '$1', $bn);
            foreach ([$bn, $bn_clean] as $b) {
                if (isset($basename_map[$b])) {
                    foreach ($basename_map[$b] as $id) {
                        wp_clean_mark_used($id, $source, $used_ids, $attachment_map);
                    }
                }
            }
        }
    }
}

function wp_clean_collect_files($id, $basedir) {
    $paths = [];
    $rel = get_post_meta($id, '_wp_attached_file', true);
    if (!$rel) {
        return $paths;
    }
    $paths[] = $rel;
    $dir = dirname($rel);
    $full_dir = $basedir . '/' . $dir;
    $meta = wp_get_attachment_metadata($id);
    if ($meta && !empty($meta['sizes'])) {
        foreach ($meta['sizes'] as $size) {
            if (!empty($size['file'])) {
                $paths[] = $dir . '/' . $size['file'];
            }
        }
    }
    if ($meta && !empty($meta['file']) && $meta['file'] !== basename($rel)) {
        $paths[] = $dir . '/' . $meta['file'];
    }
    if (is_dir($full_dir)) {
        $stem = pathinfo(basename($rel), PATHINFO_FILENAME);
        $stem = preg_replace('/-scaled$/', '', $stem);
        foreach (glob($full_dir . '/' . $stem . '*') ?: [] as $abs) {
            $paths[] = $dir . '/' . basename($abs);
        }
    }
    $paths = array_values(array_unique(array_filter($paths)));
    return array_values(array_filter($paths, 'wp_clean_is_eligible_path'));
}

function wp_clean_prune_backups(string $backup_dir, int $keep): void {
    $pattern = $backup_dir . '/unused-media-*.tar.gz';
    $files = glob($pattern) ?: [];
    if (count($files) <= $keep) {
        return;
    }
    usort($files, static fn($a, $b) => filemtime($b) <=> filemtime($a));
    foreach (array_slice($files, $keep) as $old) {
        unlink($old);
        $bundle = preg_replace('/\.tar\.gz$/', '', $old);
        if (is_dir($bundle)) {
            array_map('unlink', glob($bundle . '/*') ?: []);
            rmdir($bundle);
        }
        echo "Pruned old backup: $old\n";
    }
}

// --- Audit ---
$attachments = $wpdb->get_results("
    SELECT p.ID, p.post_title, p.post_date, pm.meta_value AS attached_file
    FROM {$wpdb->posts} p
    LEFT JOIN {$wpdb->postmeta} pm ON p.ID = pm.post_id AND pm.meta_key = '_wp_attached_file'
    WHERE p.post_type = 'attachment' AND p.post_status = 'inherit'
");

$attachment_map = [];
$basename_map = [];
foreach ($attachments as $a) {
    $attachment_map[$a->ID] = $a;
    if (empty($a->attached_file)) {
        continue;
    }
    $bn = basename($a->attached_file);
    $basename_map[$bn][] = $a->ID;
    $stem = pathinfo($bn, PATHINFO_FILENAME);
    $basename_map[$stem][] = $a->ID;
}

$used_ids = [];
$cutoff = $min_age_days > 0 ? strtotime("-{$min_age_days} days") : 0;

$pages = get_posts([
    'post_type' => 'page',
    'post_status' => 'publish',
    'numberposts' => $max_pages,
    'orderby' => 'menu_order title',
    'order' => 'ASC',
]);
foreach ($pages as $p) {
    $src = "page:{$p->ID}";
    wp_clean_scan_content($p->post_content, $src, $used_ids, $attachment_map, $basename_map);
    wp_clean_scan_content(get_post_meta($p->ID, '_elementor_data', true), $src . ' [elementor]', $used_ids, $attachment_map, $basename_map);
    $thumb = get_post_thumbnail_id($p->ID);
    if ($thumb) {
        wp_clean_mark_used((int) $thumb, $src . ' [featured]', $used_ids, $attachment_map);
    }
}

foreach (get_posts(['post_type' => 'post', 'post_status' => 'publish', 'numberposts' => $max_posts]) as $p) {
    $src = "post:{$p->ID}";
    wp_clean_scan_content($p->post_content, $src, $used_ids, $attachment_map, $basename_map);
    wp_clean_scan_content(get_post_meta($p->ID, '_elementor_data', true), $src . ' [elementor]', $used_ids, $attachment_map, $basename_map);
}

foreach ($wpdb->get_results("SELECT ID, post_type FROM {$wpdb->posts} WHERE post_type IN ('elementor_library','elementor_snippet') AND post_status='publish'") as $t) {
    wp_clean_scan_content(get_post_meta($t->ID, '_elementor_data', true), "{$t->post_type}:{$t->ID}", $used_ids, $attachment_map, $basename_map);
}

$custom_logo = get_theme_mod('custom_logo');
if ($custom_logo) {
    wp_clean_mark_used((int) $custom_logo, 'theme_mod:custom_logo', $used_ids, $attachment_map);
}
$site_icon = get_option('site_icon');
if ($site_icon) {
    wp_clean_mark_used((int) $site_icon, 'option:site_icon', $used_ids, $attachment_map);
}

foreach ($wpdb->get_results("SELECT post_id, meta_key, meta_value FROM {$wpdb->postmeta} WHERE meta_value LIKE '%wp-content/uploads%'") as $row) {
    wp_clean_scan_content($row->meta_value, "meta:{$row->post_id}/{$row->meta_key}", $used_ids, $attachment_map, $basename_map);
}
foreach ($wpdb->get_results("SELECT option_name, option_value FROM {$wpdb->options} WHERE option_value LIKE '%wp-content/uploads%'") as $row) {
    wp_clean_scan_content($row->option_value, "option:{$row->option_name}", $used_ids, $attachment_map, $basename_map);
}
// ohara-resturan-menu stores attachment IDs in plain numeric options (no uploads URL in value).
foreach ($wpdb->get_results("SELECT option_name, option_value FROM {$wpdb->options} WHERE option_name LIKE 'restaurant_menu_pdf_id%'") as $row) {
    $id = (int) $row->option_value;
    if ($id > 0) {
        wp_clean_mark_used($id, "option:{$row->option_name}", $used_ids, $attachment_map);
    }
}

$css_content = '';
foreach ([$basedir . '/elementor/css', get_stylesheet_directory(), get_template_directory()] as $dir) {
    if (!is_dir($dir)) {
        continue;
    }
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, RecursiveDirectoryIterator::SKIP_DOTS));
    foreach ($it as $f) {
        if ($f->getExtension() === 'css') {
            $css_content .= file_get_contents($f->getPathname()) . "\n";
        }
    }
}
wp_clean_scan_content($css_content, 'css_files', $used_ids, $attachment_map, $basename_map);

$unused_ids = [];
$skipped_young = 0;
$manifest = [
    'site' => get_site_url(),
    'created' => gmdate('c'),
    'dry_run' => $dry_run,
    'min_age_days' => $min_age_days,
    'backup_dir' => $backup_dir,
    'attachments' => [],
    'files' => [],
    'total_bytes' => 0,
];

foreach ($attachment_map as $id => $a) {
    if (!wp_clean_is_eligible_attachment((int) $id)) {
        continue;
    }
    if (isset($used_ids[$id])) {
        continue;
    }
    if ($cutoff && strtotime($a->post_date) > $cutoff) {
        $skipped_young++;
        continue;
    }
    $unused_ids[] = (int) $id;
    $files = wp_clean_collect_files($id, $basedir);
    $entry = [
        'id' => (int) $id,
        'title' => $a->post_title,
        'post_date' => $a->post_date,
        'attached_file' => $a->attached_file,
        'files' => [],
    ];
    foreach ($files as $rel) {
        $abs = $basedir . '/' . $rel;
        if (is_file($abs)) {
            $sz = filesize($abs);
            $entry['files'][] = ['path' => $rel, 'bytes' => $sz];
            $manifest['files'][] = $rel;
            $manifest['total_bytes'] += $sz;
        }
    }
    $manifest['attachments'][] = $entry;
}

$manifest['unused_count'] = count($unused_ids);
$manifest['skipped_too_new'] = $skipped_young;
$manifest['unused_mb'] = round($manifest['total_bytes'] / 1048576, 2);

if ($dry_run) {
    echo json_encode($manifest, JSON_PRETTY_PRINT);
    exit(0);
}

if (empty($unused_ids)) {
    echo "No unused attachments to delete (skipped $skipped_young too new).\n";
    exit(0);
}

wp_clean_validate_backup_dir($backup_dir);

if (!is_dir($backup_dir)) {
    mkdir($backup_dir, 0750, true);
}
if (!is_dir($backup_bundle)) {
    mkdir($backup_bundle, 0750, true);
}
file_put_contents($manifest_path, json_encode($manifest, JSON_PRETTY_PRINT));

$filelist = $backup_bundle . '/filelist.txt';
$lines = [];
foreach (array_unique($manifest['files']) as $rel) {
    if (is_file($basedir . '/' . $rel)) {
        $lines[] = $rel;
    }
}
file_put_contents($filelist, implode("\n", $lines) . "\n");

$cmd = sprintf(
    'cd %s && tar -czf %s -T %s 2>&1',
    escapeshellarg($basedir),
    escapeshellarg($archive),
    escapeshellarg($filelist)
);
exec($cmd, $tar_out, $tar_rc);
if ($tar_rc !== 0) {
    fwrite(STDERR, "BACKUP FAILED: " . implode("\n", $tar_out) . "\n");
    exit(1);
}

echo "Backup: $archive (" . round(filesize($archive) / 1048576, 1) . " MB, " . count($lines) . " files)\n";
echo "Manifest: $manifest_path\n";

wp_clean_prune_backups($backup_dir, $backup_retention);

require_once ABSPATH . 'wp-admin/includes/image.php';
$deleted = 0;
$failed = [];
foreach ($unused_ids as $id) {
    if (wp_delete_attachment($id, true)) {
        $deleted++;
    } else {
        $failed[] = $id;
    }
}

echo "Deleted attachments: $deleted / " . count($unused_ids) . "\n";
if ($failed) {
    echo "Failed IDs: " . implode(', ', $failed) . "\n";
    exit(2);
}

$after = (int) $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_type='attachment' AND post_status='inherit'");
echo "Media library count after: $after\n";
echo "Uploads size: ";
passthru('du -sh ' . escapeshellarg($basedir));
