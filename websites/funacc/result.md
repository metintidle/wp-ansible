Top Errors (error_log-20230312)

121x: require_once wp-config.php permission denied → cascades to PHP Fatal “Failed opening required”
34x: FCGI backend issues → missing PHP-FPM socket /opt/bitnami/php/var/run/www.sock
7x: Apache start/resume notices
6x: client denied by server configuration → uploads/.htaccess, smack_uci_uploads
6x: Undefined constants ABSPATH/WPINC → missing WordPress bootstrap files
6x: WP core fatal errors (missing classes/functions) → WP not fully loaded
6x: Let’s Encrypt .well-known directory index forbidden
4x: PHP Notice/Warning during xmlrpc → temp file + max_input_vars
3x: invalid URI path probes (cgi-bin)
2x: SSL cert CN mismatch for www.example.com
Others: graceful restart, SIGTERM, partial results
Top Errors (error_log)

15x: client denied by server configuration → /opt/bitnami/apache/cgi-bin
Singles: invalid URI probes, SIGTERM, Apache start notices
Reusable Command

Run this to group similar errors (normalizes timestamps, pids, client IPs, line numbers):
sed -E "s/^\[[^]]+\] \[[^]]+\] (\[[^]]+\] )*//; s/\[client [^]]+\] //; s/\[pid [^]]+\] //; s/AH[0-9]+: //; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/<IP>/g; s/:[0-9]+/:<N>/g; s/ on line [0-9]+/ on line <N>/g; s/ line [0-9]+/ line <N>/g; s/ [0-9]+\b/ <N>/g" PATH/TO/error_log | sort | uniq -c | sort -nr | head -n 50

Permission denied errors (especially for wp-config.php)
Client denied by server configuration (uploads, .htaccess, cgi-bin, phpmyadmin, etc.)
Use of undefined constants and missing/corrupted WordPress core files
Class not found errors (WP_Dependencies, WP_Widget, etc.)
Directory index forbidden (no index file, directory listing disabled)
Invalid URI path (exploit attempts, blocked)
Partial results/incomplete processing (timeouts, client disconnects)
SSL certificate warnings
PHP input variable limits exceeded
