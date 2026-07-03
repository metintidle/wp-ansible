<?php
/**
 * Plugin Name: IT&T WP Fail2Ban Auth Logger
 * Description: Logs WordPress authentication events to journald (via PHP syslog,
 *              ident "wp-fail2ban", facility authpriv) so Fail2Ban can ban real
 *              credential brute-force. Runs server-side AFTER WordPress validates
 *              the login, so unlike an nginx cookie check it cannot be spoofed.
 *              Deploy as a must-use plugin: copy to wp-content/mu-plugins/.
 * Author: IT&T
 * Version: 1.0.0
 *
 * Pairs with:
 *   modules/5_security/files/fail2ban/filter/wordpress-auth.conf
 *   [wordpress-auth] jail (backend=systemd, journalmatch SYSLOG_IDENTIFIER=wp-fail2ban)
 *
 * Log message grammar (the part Fail2Ban's failregex matches):
 *   authentication failure for '<user>' from <ip>      -> counts toward a ban
 *   blocked user enumeration attempt from <ip>          -> counts toward a ban
 *   accepted authentication for '<user>' from <ip>      -> informational (LOG_INFO)
 */

if (!defined('ABSPATH')) {
    exit; // never served directly
}

if (!defined('ITT_F2B_IDENT')) {
    define('ITT_F2B_IDENT', 'wp-fail2ban');
}

/**
 * Best-effort real client IP.
 * On the direct-EC2 fleet, nginx sets fastcgi_param REMOTE_ADDR $remote_addr, so
 * REMOTE_ADDR already is the real client (matches the nginx access-log IP). Only
 * fall back to the first X-Forwarded-For hop when the request came via loopback
 * (i.e. a local reverse proxy). The value is validated as an IP; anything invalid
 * becomes "-" so it can never match <HOST> and can never trigger a ban.
 */
function itt_f2b_client_ip() {
    $ip = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
    if (in_array($ip, array('127.0.0.1', '::1'), true) && !empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
        $parts = explode(',', $_SERVER['HTTP_X_FORWARDED_FOR']);
        $ip = trim($parts[0]);
    }
    return filter_var($ip, FILTER_VALIDATE_IP) ? $ip : '-';
}

/**
 * Sanitise an attacker-controlled username before it goes into a security log.
 * Strips CR/LF and non-printable bytes (prevents log injection / forged lines)
 * and caps length.
 */
function itt_f2b_clean_user($username) {
    $username = (string) $username;
    $username = preg_replace('/[^\x20-\x7E]/', '', $username); // printable ASCII only
    $username = str_replace(array("'", "\\"), '', $username);
    if ($username === '') {
        $username = 'unknown';
    }
    return substr($username, 0, 64);
}

/**
 * @param int    $priority One of the LOG_* constants (LOG_NOTICE for bannable events).
 * @param string $message  Already-sanitised message body.
 */
function itt_f2b_log($priority, $message) {
    // Never let logging break the login flow: if syslog is disabled via
    // disable_functions, silently no-op instead of throwing on a login hook.
    if (!function_exists('openlog') || !function_exists('syslog')) {
        return;
    }
    // openlog per call keeps the ident correct across FPM worker reuse.
    openlog(ITT_F2B_IDENT, LOG_PID | LOG_NDELAY, LOG_AUTHPRIV);
    syslog($priority, $message);
    closelog();
}

// Failed login (covers wp-login.php form auth AND XML-RPC, both route through
// wp_authenticate -> wp_login_failed). This is the key signal: real credential
// brute-force returns HTTP 200 to nginx, so only PHP can see it.
add_action('wp_login_failed', function ($username) {
    itt_f2b_log(
        LOG_NOTICE,
        sprintf("authentication failure for '%s' from %s", itt_f2b_clean_user($username), itt_f2b_client_ip())
    );
}, 10, 1);

// Successful login — informational only (never used by the ban filter). Useful
// for incident triage: "was this banned IP ever a real logged-in session?".
add_action('wp_login', function ($user_login) {
    itt_f2b_log(
        LOG_INFO,
        sprintf("accepted authentication for '%s' from %s", itt_f2b_clean_user($user_login), itt_f2b_client_ip())
    );
}, 10, 1);

// User-enumeration probe (?author=N on the front end). Belt-and-suspenders for
// hosts without the nginx `if ($args ~* "author=\d+")` block; harmless if nginx
// already 403s it (PHP simply never runs).
add_action('init', function () {
    if (!is_admin() && isset($_GET['author']) && is_numeric($_GET['author'])) {
        itt_f2b_log(LOG_NOTICE, sprintf('blocked user enumeration attempt from %s', itt_f2b_client_ip()));
    }
});
