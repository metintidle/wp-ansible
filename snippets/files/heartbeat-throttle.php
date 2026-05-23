<?php
/**
 * Plugin Name: Heartbeat & Editor Throttle
 * Description: Reduces PHP-FPM worker contention on low-RAM servers.
 * @see docs/elementor-low-ram-optimization.md
 */

add_filter('heartbeat_settings', function ($settings) {
    $settings['interval'] = 120;
    return $settings;
}, PHP_INT_MAX);

add_filter('elementor/editor/heartbeat_options', function ($settings) {
    if (is_array($settings)) {
        $settings['interval'] = 180;
    }
    return $settings;
}, 10, 1);

add_action('init', function () {
    if (!is_admin()) {
        wp_deregister_script('heartbeat');
    }
});
