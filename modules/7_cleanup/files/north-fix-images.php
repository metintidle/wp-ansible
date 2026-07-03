<?php
/**
 * North Nowra Tavern — fix broken images (2026-06-30)
 */
$home_id = 4432;
$replacement_id = 3199; // Background-image-min.webp (already used site-wide)

$url = wp_get_attachment_url($replacement_id);
if (!$url) {
    fwrite(STDERR, "ERROR: replacement attachment $replacement_id has no URL\n");
    exit(1);
}

$raw = get_post_meta($home_id, '_elementor_data', true);
if (empty($raw)) {
    fwrite(STDERR, "ERROR: no _elementor_data on page $home_id\n");
    exit(1);
}

$before_has_877 = (strpos($raw, '"id":877') !== false) || (strpos($raw, '"id": 877') !== false);
$before_has_image04 = strpos($raw, 'Image04-scaled.webp') !== false;

// Replace deleted mobile background attachment ID and stale URL.
$raw = preg_replace(
    '#"background_image_mobile"\s*:\s*\{[^}]*"id"\s*:\s*877[^}]*\}#',
    '"background_image_mobile":{"url":"' . esc_url_raw($url) . '","id":' . $replacement_id . ',"size":"","source":"library"}',
    $raw,
    -1,
    $count
);

if ($count === 0) {
    // Fallback: string replace known broken fragments.
    $raw = str_replace(
        ['"url":"\/wp-content\/uploads\/2024\/09\/Image04-scaled.webp","id":877', '"url":"\\/wp-content\\/uploads\\/2024\\/09\\/Image04-scaled.webp","id":877'],
        '"url":"' . esc_url_raw($url) . '","id":' . $replacement_id,
        $raw,
        $count2
    );
    $count = $count2;
}

if ($count === 0) {
    fwrite(STDERR, "WARN: background_image_mobile id 877 not found; no elementor patch applied\n");
} else {
    update_post_meta($home_id, '_elementor_data', wp_slash($raw));
    echo "Patched home mobile background: 877/Image04 -> $replacement_id ($url)\n";
}

// Regenerate attachment metadata for broken refs.
$fix_ids = [4447, 4578, 3205, 3221];
require_once ABSPATH . 'wp-admin/includes/image.php';

foreach ($fix_ids as $id) {
    $file = get_attached_file($id);
    if (!$file || !file_exists($file)) {
        echo "SKIP meta $id: file missing ($file)\n";
        continue;
    }
    $meta = wp_generate_attachment_metadata($id, $file);
    if (empty($meta)) {
        echo "FAIL meta $id: wp_generate_attachment_metadata returned empty\n";
        continue;
    }
    wp_update_attachment_metadata($id, $meta);
    echo "OK meta $id: " . basename($file) . " (" . count($meta['sizes'] ?? []) . " sizes)\n";
}

// Remove failed 0-byte WebP orphan (plus-webp); attachment 5110 uses 69.jpg.
$webp = WP_CONTENT_DIR . '/uploads/2026/06/69.webp';
if (file_exists($webp)) {
    $sz = filesize($webp);
    if ($sz === 0) {
        unlink($webp);
        echo "Deleted empty $webp\n";
    } else {
        echo "KEEP $webp ($sz bytes)\n";
    }
} else {
    echo "No 69.webp to delete\n";
}

echo "DONE\n";
