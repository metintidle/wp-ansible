<?php
/*
Plugin Name: ITT Maintenance
Description: Replaces default image upload resize with wp-itt-toolbox logic (first step: does not disable WP default sizes or original image).
Version: 0.1
Author: Your Name
*/

require_once dirname(__FILE__) . '/image-processing/DynamicMemoryCWebPProcessor.php';

// Global instance for admin interface access
global $dynamic_memory_cwebp_processor;
$dynamic_memory_cwebp_processor = new DynamicMemoryCWebPProcessor();
