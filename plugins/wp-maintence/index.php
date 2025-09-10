<?php
/*
Plugin Name: IT&T Maintenance
Description: Optimize Harddisk space and database usge
Version: 1.0.2
Author: Meti Nejati
License: GPLv2 or later
Text Domain: itt-toolbox
*/

if (!defined('ABSPATH')) exit; // Exit if accessed directly

// Define plugin constants
define('ITT_TOOLBOX_VERSION', '1.0.2');
define('ITT_TOOLBOX_PLUGIN_URL', plugin_dir_url(__FILE__));
define('ITT_TOOLBOX_PLUGIN_PATH', plugin_dir_path(__FILE__));

/**
 * Main ITT Toolbox Plugin Loader Class
 * Entry point that initializes all plugin components
 */
require_once dirname(__FILE__) . '/image-processing/DynamicMemoryCWebPProcessor.php';

// Global instance for admin interface access
global $dynamic_memory_cwebp_processor;
$dynamic_memory_cwebp_processor = new DynamicMemoryCWebPProcessor();
