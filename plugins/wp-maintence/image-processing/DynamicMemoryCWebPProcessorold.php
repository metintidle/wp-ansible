<?php
/**
 * RULE: when write error_log, genearet error_log("last_var_name".print_r($last_var_name,true)) it means use var name in above line
 * Dynamic Memory-Aware CWebP Processing Coordinator
 * Main class that coordinates memory management and processing
 */

require_once dirname(__FILE__) . '/memory/MemoryManager.php';
require_once dirname(__FILE__) . '/processors/ImageMagickProcessor.php';
require_once dirname(__FILE__) . '/processors/CWebPProcessor.php';
require_once dirname(__FILE__) . '/processors/LowMemoryResizeProcessor.php'; // NEW
require_once dirname(__FILE__) . '/processors/RandomWordRenamer.php'; // NEW
require_once dirname(__FILE__) . '/utils/BinaryFinder.php';


class DynamicMemoryCWebPProcessorOld {

    private $cwebp_path;
    private $memory_manager;
    private $imagick_processor;
    private $cwebp_processor;
    private $low_memory_processor;
    private $renamer; // NEW
    
    private $high_memory_threshold = 500 * 1024 * 1024; // 500MB

    public function __construct() {
        $this->find_cwebp_binary();
        $this->memory_manager = new MemoryManager();
        $this->imagick_processor = new ImageMagickProcessor();
        $this->low_memory_processor = new LowMemoryResizeProcessor();
        $this->renamer = new RandomWordRenamer(); // NEW

        if ($this->cwebp_path) {
            $this->cwebp_processor = new CWebPProcessor($this->cwebp_path);
        }

        add_action('init', array($this, 'init'));
    }

    public function init() {
        if (!$this->cwebp_path) {
            add_action('admin_notices', array($this, 'missing_cwebp_notice'));
            return;
        }

        // We now hook into `wp_handle_upload` which runs *after* the file is moved.
        // This allows us to have the final path and not interfere with the original upload.
        add_filter('wp_handle_upload', array($this, 'create_webp_version'), 10, 2);
        add_filter('wp_generate_attachment_metadata', array($this, 'create_webp_for_all_sizes'), 10, 2);
    }

    /**
     * Modified processing that works with renamed files
     */
    public function process_with_two_modes($file) {
        // File has already been renamed by RandomWordRenamer (priority 1)
        // Now we process the WebP conversion

        if (!$this->is_processable_image($file['type'])) {
            return $file;
        }

        $start_time = microtime(true);
        $memory_status = $this->memory_manager->get_memory_status();

        $original_path = $file['tmp_name'];
        $image_info = getimagesize($original_path);

        if (!$image_info) {
            error_log("❌ Cannot read image info for: " . $file['name']);
            return $file;
        }

        $original_width = $image_info[0];
        $original_height = $image_info[1];
        $original_size = filesize($original_path);

        // Simple decision: High memory or Low memory mode
        $use_high_memory = $memory_status['effective_available'] > $this->high_memory_threshold;

        error_log(sprintf(
            "🔄 Processing renamed file: %s (Mode: %s)",
            $file['name'],
            $use_high_memory ? 'HIGH MEMORY' : 'LOW MEMORY'
        ));

        try {
            if ($use_high_memory) {
                $result = $this->process_high_memory_mode($original_path, $original_width, $original_height, $file['type']);
            } else {
                $result = $this->process_low_memory_mode($original_path, $original_width, $original_height, $file['type']);
            }

            if ($result['success']) {
                $processing_time = round((microtime(true) - $start_time), 2);
                $final_size = filesize($original_path);
                $compression_ratio = round((($original_size - $final_size) / $original_size) * 100, 1);

                // Ensure WebP extension (file was already renamed with random words)
                if (!str_ends_with($file['name'], '.webp')) {
                    $file['name'] = pathinfo($file['name'], PATHINFO_FILENAME) . '.webp';
                }
                $file['type'] = 'image/webp';

                error_log("✅ {$result['mode']} processing complete: {$compression_ratio}% compression in {$processing_time}s");

                if ($result['resized']) {
                    error_log("   Resized: {$original_width}x{$original_height} → {$result['new_width']}x{$result['new_height']}");
                }
            } else {
                error_log("❌ WebP processing failed: " . $result['error']);
            }
        } catch (Exception $e) {
            error_log("❌ Processing exception for {$file['name']}: " . $e->getMessage());
        }

        return $file;
    }

    /**
     * NEW: Create a WebP version without overwriting the original.
     * Hooks into `wp_handle_upload` to act on the final file.
     */
    public function create_webp_for_all_sizes($metadata, $attachment_id) {
        $upload_dir = wp_get_upload_dir();
        $attachment_path = get_attached_file($attachment_id);

        // Get the mime type of the original file
        $mime_type = get_post_mime_type($attachment_id);
        if (!$this->is_processable_image($mime_type)) {
            return $metadata;
        }

        $memory_status = $this->memory_manager->get_memory_status();

        $image_info = getimagesize($attachment_path);
        if (!$image_info) {
            error_log("❌ Cannot read image info for attachment: " . $attachment_path);
            return $metadata;
        }

        $base_path = dirname($attachment_path);
        $files_to_process = [];

        // 1. Add the original (full-size) image
        $files_to_process['full'] = [
            'path' => $attachment_path,
            'width' => $metadata['width'],
            'height' => $metadata['height']
        ];

        // 2. Add all intermediate sizes
        if (isset($metadata['sizes']) && is_array($metadata['sizes'])) {
            foreach ($metadata['sizes'] as $size => $size_info) {
                $files_to_process[$size] = [
                    'path' => $base_path . '/' . $size_info['file'],
                    'width' => $size_info['width'],
                    'height' => $size_info['height']
                ];
            }
        }

        error_log("Found " . count($files_to_process) . " sizes to convert to WebP for attachment ID {$attachment_id}");

        // Process each file
        foreach ($files_to_process as $size_name => $file_data) {
            $this->process_single_image_to_webp($file_data['path'], $file_data['width'], $file_data['height'], $mime_type, $memory_status);
        }

        return $metadata;
    }

    /**
     * Processes a single image file (original or thumbnail) to create a WebP version.
     * This is the core logic extracted from the previous `create_webp_version` function.
     */
    private function process_single_image_to_webp($source_path, $original_width, $original_height, $mime_type, $memory_status) {
        if (!file_exists($source_path)) {
            error_log("❌ Source file does not exist, skipping WebP creation: " . $source_path);
            return;
        }

        $start_time = microtime(true); // Define start_time here for accurate timing per image
        $original_size = filesize($source_path);

        // Create a temporary copy to process, so we don't alter the original upload
        $processing_path = $source_path . '.tmp';
        if (!copy($source_path, $processing_path)) {
            error_log("❌ Failed to create temporary copy for WebP processing.");
            return;
        }

        // Simple decision: High memory or Low memory mode
        $use_high_memory = $memory_status['effective_available'] > $this->high_memory_threshold;

        error_log(sprintf(
            "🔄 Creating WebP version for: %s (Mode: %s)",
            basename($source_path),
            $use_high_memory ? 'HIGH MEMORY' : 'LOW MEMORY'
        ));

        try {
            if ($use_high_memory) {
                $result = $this->process_high_memory_mode($processing_path, $original_width, $original_height, $mime_type);
            } else {
                $result = $this->process_low_memory_mode($processing_path, $original_width, $original_height, $mime_type);
            }

            if ($result['success']) {
                $processing_time = round((microtime(true) - $start_time), 2);
                $final_size = filesize($processing_path);
                $compression_ratio = round((($original_size - $final_size) / $original_size) * 100, 1);

                // The processed file is now a WebP. Rename it to its final destination.
                $webp_path = dirname($source_path) . '/' . pathinfo($source_path, PATHINFO_FILENAME) . '.webp';
                rename($processing_path, $webp_path);

                error_log("✅ WebP created: {$webp_path} ({$compression_ratio}% compression in {$processing_time}s)");

                if ($result['resized']) {
                    error_log("   Resized: {$original_width}x{$original_height} → {$result['new_width']}x{$result['new_height']}");
                }
            } else {
                error_log("❌ WebP processing failed: " . $result['error']);
            }
        } catch (Exception $e) {
            error_log("❌ WebP creation exception for " . basename($source_path) . ": " . $e->getMessage());
        } finally {
            // Clean up the temporary processing file if it still exists
            if (file_exists($processing_path)) {
                unlink($processing_path);
            }
        }
    }

    private function process_high_memory_mode($file_path, $width, $height, $mime_type) {
        try {
            $result = $this->imagick_processor->process_fast($file_path, $width, $height, $mime_type);
            $result['mode'] = 'HIGH MEMORY';
            return $result;
        } catch (Exception $e) {
            error_log('High memory mode failed, falling back to low memory: ' . $e->getMessage());
            return $this->process_low_memory_mode($file_path, $width, $height, $mime_type);
        }
    }

    private function process_low_memory_mode($file_path, $width, $height, $mime_type) {
        try {
            $resize_result = $this->low_memory_processor->resize_if_needed($file_path, $width, $height, $mime_type);

            if (!$resize_result['success']) {
                throw new Exception('Low memory resize failed: ' . $resize_result['error']);
            }

            $webp_result = $this->cwebp_processor->convert_only($file_path, $mime_type);

            if (!$webp_result['success']) {
                throw new Exception('WebP conversion failed: ' . $webp_result['error']);
            }

            return array(
                'success' => true,
                'mode' => 'LOW MEMORY',
                'method' => $resize_result['method'] . ' + CWebP Convert-Only',
                'resized' => $resize_result['resized'],
                'new_width' => $resize_result['new_width'] ?? $width,
                'new_height' => $resize_result['new_height'] ?? $height
            );

        } catch (Exception $e) {
            return array(
                'success' => false,
                'mode' => 'LOW MEMORY',
                'error' => $e->getMessage()
            );
        }
    }

    private function find_cwebp_binary() {
        $this->cwebp_path = BinaryFinder::find_cwebp();
        return $this->cwebp_path !== false;
    }

    private function is_processable_image($mime_type) {
        return in_array($mime_type, array('image/jpeg', 'image/png', 'image/gif'));
    }

    public function missing_cwebp_notice() {
        echo '<div class="notice notice-error"><p>';
        echo '<strong>CWebP not found:</strong> Install with <code>sudo dnf install libwebp-tools</code>';
        echo '</p></div>';
    }

    public function get_system_status() {
        $memory_status = $this->memory_manager->get_memory_status();
        $use_high_memory = $memory_status['effective_available'] > $this->high_memory_threshold;

        return array(
            'cwebp_path' => $this->cwebp_path ?: 'Not found',
            'cwebp_available' => !empty($this->cwebp_path),
            'imagick_available' => $this->imagick_processor->is_available(),
            'low_memory_tools' => $this->low_memory_processor->get_available_tools(),
            'memory_status' => $memory_status,
            'processing_mode' => $use_high_memory ? 'High Memory (ImageMagick)' : 'Low Memory (Streaming)',
            'renamer_available' => class_exists('RandomWordRenamer'),
            'processing_enabled' => !empty($this->cwebp_path)
        );
    }

    public function get_processing_stats() {
        $memory_status = $this->memory_manager->get_memory_status();
        $use_high_memory = $memory_status['effective_available'] > $this->high_memory_threshold;

        return array(
            'total_processed' => 0, // You may want to implement a counter
            'success_rate' => 100,
            'average_compression' => 0,
            'current_mode' => $use_high_memory ? 'High Memory' : 'Low Memory',
            'memory_usage' => $memory_status,
            'last_processed' => 'None',
            'errors_count' => 0
        );
    }
}

?>

?>