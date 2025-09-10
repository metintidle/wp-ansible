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


class DynamicMemoryCWebPProcessor {
    
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
        
        // Disable WordPress processing
        add_filter('intermediate_image_sizes_advanced', '__return_empty_array', 999);
        add_filter('big_image_size_threshold', '__return_false', 999);
        
        // IMPORTANT: Process in correct order
        // 1. First rename (priority 1)
        // 2. Then WebP process (priority 10)
        add_filter('wp_handle_upload_prefilter', array($this, 'process_with_two_modes'), 10);
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