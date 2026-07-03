<?php
/**
 * @deprecated Use unused-media-cleanup.php via run-unused-media-cleanup.sh
 *
 * North Nowra Tavern–specific name retained for reference only.
 * New sites: deploy unused-media-cleanup.php + run-unused-media-cleanup.sh
 * from wp-itt-toolbox/clean/ (see README.md).
 */
fwrite(STDERR, "DEPRECATED: use unused-media-cleanup.php (WP_CLEAN_DRY_RUN=1 for audit)\n");
require dirname(__FILE__) . '/unused-media-cleanup.php';
