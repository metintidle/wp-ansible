<?php
/**
 * Plugin Name: Protect BBQ Firewall
 * Description: Locks BBQ Firewall (block-bad-queries): hide from Plugins for everyone except itt-admin, no deactivate/delete, reinstalls if missing, forces auto-updates for BBQ and SQLite Object Cache.
 */

if (!defined('ABSPATH')) {
    exit;
}

const ITT_BBQ_SLUG = 'block-bad-queries';
const ITT_BBQ_MAIN = 'block-bad-queries/block-bad-queries.php';
const ITT_SQLITE_CACHE_SLUG = 'sqlite-object-cache';
const ITT_BBQ_VISIBLE_USER = 'itt-admin';

function itt_bbq_is_protected_plugin($plugin_file)
{
    return is_string($plugin_file) && strpos($plugin_file, ITT_BBQ_SLUG . '/') === 0;
}

function itt_bbq_viewer_is_itt_admin()
{
    if (defined('WP_CLI') && WP_CLI) {
        return true;
    }
    if (!function_exists('wp_get_current_user')) {
        return false;
    }
    $user = wp_get_current_user();
    return $user instanceof WP_User
        && $user->exists()
        && strcasecmp($user->user_login, ITT_BBQ_VISIBLE_USER) === 0;
}

function itt_bbq_load_plugin_admin()
{
    if (!function_exists('activate_plugin')) {
        require_once ABSPATH . 'wp-admin/includes/plugin.php';
    }
}

add_filter('all_plugins', 'itt_bbq_hide_from_plugins_screen');
function itt_bbq_hide_from_plugins_screen($plugins)
{
    if (itt_bbq_viewer_is_itt_admin()) {
        return $plugins;
    }
    unset($plugins[ITT_BBQ_MAIN]);
    return $plugins;
}

add_action('load-plugins.php', 'itt_bbq_hide_updates_on_plugin_screens');
add_action('load-update-core.php', 'itt_bbq_hide_updates_on_plugin_screens');
function itt_bbq_hide_updates_on_plugin_screens()
{
    add_filter('site_transient_update_plugins', 'itt_bbq_hide_from_update_screen');
}

function itt_bbq_hide_from_update_screen($value)
{
    if (itt_bbq_viewer_is_itt_admin() || !is_object($value)) {
        return $value;
    }
    unset($value->response[ITT_BBQ_MAIN], $value->no_update[ITT_BBQ_MAIN]);
    return $value;
}

add_action('admin_menu', 'itt_bbq_hide_admin_menus', PHP_INT_MAX);
function itt_bbq_hide_admin_menus()
{
    if (itt_bbq_viewer_is_itt_admin()) {
        return;
    }
    remove_menu_page('bbq');
    remove_submenu_page('options-general.php', 'bbq');
    remove_submenu_page('options-general.php', 'block-bad-queries');
}

add_filter('plugin_action_links', 'itt_bbq_hide_plugin_actions', 10, 2);
add_filter('network_admin_plugin_action_links', 'itt_bbq_hide_plugin_actions', 10, 2);
function itt_bbq_hide_plugin_actions($actions, $plugin_file)
{
    if (itt_bbq_is_protected_plugin($plugin_file)) {
        unset($actions['delete'], $actions['deactivate']);
    }
    return $actions;
}

add_action('delete_plugin', 'itt_bbq_block_delete', 0);
function itt_bbq_block_delete($plugin_file)
{
    if (!itt_bbq_is_protected_plugin($plugin_file)) {
        return;
    }
    wp_die(
        'BBQ Firewall is locked by mu-plugin protect-bbq-firewall.php and cannot be deleted.',
        'Plugin protected',
        array('response' => 403)
    );
}

add_action('deactivated_plugin', 'itt_bbq_reactivate', 10, 2);
function itt_bbq_reactivate($plugin_file, $network_deactivating)
{
    if (!itt_bbq_is_protected_plugin($plugin_file)) {
        return;
    }
    itt_bbq_load_plugin_admin();
    activate_plugin($plugin_file, '', (bool) $network_deactivating, true);
}

add_filter('auto_update_plugin', 'itt_bbq_force_auto_update', 10, 2);
function itt_bbq_force_auto_update($update, $item)
{
    $slugs = array(ITT_BBQ_SLUG, ITT_SQLITE_CACHE_SLUG);
    if (!empty($item->slug) && in_array($item->slug, $slugs, true)) {
        return true;
    }
    if (!empty($item->plugin)) {
        foreach ($slugs as $slug) {
            if (strpos($item->plugin, $slug . '/') === 0) {
                return true;
            }
        }
    }
    return $update;
}

add_action('init', 'itt_bbq_ensure_installed', 1);
function itt_bbq_ensure_installed()
{
    if (defined('WP_INSTALLING') && WP_INSTALLING) {
        return;
    }

    $plugin_path = WP_PLUGIN_DIR . '/' . ITT_BBQ_MAIN;
    if (!file_exists($plugin_path)) {
        itt_bbq_reinstall();
    }

    itt_bbq_load_plugin_admin();
    if (file_exists(WP_PLUGIN_DIR . '/' . ITT_BBQ_MAIN) && !is_plugin_active(ITT_BBQ_MAIN)) {
        activate_plugin(ITT_BBQ_MAIN, '', false, true);
    }
}

function itt_bbq_reinstall()
{
    if (get_transient('itt_bbq_reinstall_lock')) {
        return false;
    }
    set_transient('itt_bbq_reinstall_lock', 1, 10 * MINUTE_IN_SECONDS);

    require_once ABSPATH . 'wp-admin/includes/file.php';
    require_once ABSPATH . 'wp-admin/includes/plugin.php';
    require_once ABSPATH . 'wp-admin/includes/class-wp-upgrader.php';

    $skin = new Automatic_Upgrader_Skin();
    $upgrader = new Plugin_Upgrader($skin);
    $result = $upgrader->install('https://downloads.wordpress.org/plugin/block-bad-queries.latest-stable.zip');

    return $result && !is_wp_error($result);
}
