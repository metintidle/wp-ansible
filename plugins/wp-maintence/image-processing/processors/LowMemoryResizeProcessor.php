<?php
class LowMemoryResizeProcessor {
    
    private $djpeg_path;
    private $cjpeg_path;
    private $tools_available = array();
    private $max_width = 2560;
    private $max_height = 2560;
    
    public function __construct() {
        $this->detect_tools();
    }
    
    /**
     * Detect available low-memory tools
     */
    private function detect_tools() {
        // JPEG tools (libjpeg-turbo-utils)
        $this->djpeg_path = $this->find_binary('djpeg');
        $this->cjpeg_path = $this->find_binary('cjpeg');
        
        if ($this->djpeg_path && $this->cjpeg_path) {
            $this->tools_available['jpeg_streaming'] = true;
            // error_log("✅ JPEG streaming tools available");
        }
        
        // ImageMagick as fallback
        if ($this->find_binary('convert') || $this->find_binary('magick')) {
            $this->tools_available['imagemagick_limited'] = true;
            // error_log("✅ ImageMagick limited mode available");
        }
    }
    
    /**
     * Find binary in common locations
     */
    private function find_binary($name) {
        $paths = array(
            '/usr/bin/' . $name,
            '/usr/local/bin/' . $name,
            $name // In PATH
        );
        
        foreach ($paths as $path) {
            $test = shell_exec("which {$path} 2>/dev/null || command -v {$path} 2>/dev/null");
            if ($test && trim($test)) {
                return trim($test);
            }
        }
        
        return false;
    }
    
    /**
     * Resize image if needed using ultra-low memory methods
     */
    public function resize_if_needed($file_path, $width, $height, $mime_type) {
        // Check if resize is needed
        if ($width <= $this->max_width && $height <= $this->max_height) {
            return array(
                'success' => true,
                'resized' => false,
                'method' => 'No resize needed',
                'new_width' => $width,
                'new_height' => $height
            );
        }
        
        error_log("Resizing needed: {$width}x{$height} → max {$this->max_width}x{$this->max_height}");
        
        // Try methods in order of memory efficiency
        if ($mime_type === 'image/jpeg' && isset($this->tools_available['jpeg_streaming']) && $this->tools_available['jpeg_streaming']) {
            return $this->resize_jpeg_streaming($file_path, $width, $height);
        } elseif (isset($this->tools_available['imagemagick_limited']) && $this->tools_available['imagemagick_limited']) {
            return $this->resize_imagemagick_limited($file_path, $width, $height);
        } else {
            return array(
                'success' => false,
                'error' => 'No low-memory resize tools available'
            );
        }
    }
    
    /**
     * Ultra-low memory JPEG resize using djpeg + cjpeg
     */
    private function resize_jpeg_streaming($file_path, $width, $height) {
        $start_time = microtime(true);
        
        // Calculate new dimensions
        $ratio = min($this->max_width / $width, $this->max_height / $height);
        $new_width = intval($width * $ratio);
        $new_height = intval($height * $ratio);
        
        $temp_id = uniqid('jpeg_resize_');
        $temp_ppm = sys_get_temp_dir() . '/' . $temp_id . '.ppm';
        $temp_resized = sys_get_temp_dir() . '/' . $temp_id . '_resized.jpg';
        
        try {
            // Step 1: Decompress JPEG to PPM (streaming)
            $djpeg_cmd = escapeshellarg($this->djpeg_path);
            $djpeg_cmd .= ' -pnm -fast';
            $djpeg_cmd .= ' ' . escapeshellarg($file_path);
            $djpeg_cmd .= ' > ' . escapeshellarg($temp_ppm);
            $djpeg_cmd .= ' 2>/dev/null';
            
            shell_exec($djpeg_cmd);
            
            if (!file_exists($temp_ppm) || filesize($temp_ppm) == 0) {
                throw new Exception('JPEG decompression failed');
            }
            
            // Step 2: Resize PPM (if tools available)
            $this->resize_ppm_if_possible($temp_ppm, $new_width, $new_height);
            
            // Step 3: Recompress to JPEG
            $cjpeg_cmd = escapeshellarg($this->cjpeg_path);
            $cjpeg_cmd .= ' -quality 85 -optimize -progressive';
            $cjpeg_cmd .= ' ' . escapeshellarg($temp_ppm);
            $cjpeg_cmd .= ' > ' . escapeshellarg($temp_resized);
            $cjpeg_cmd .= ' 2>/dev/null';
            
            shell_exec($cjpeg_cmd);
            
            if (!file_exists($temp_resized) || filesize($temp_resized) == 0) {
                throw new Exception('JPEG recompression failed');
            }
            
            // Replace original
            if (!rename($temp_resized, $file_path)) {
                throw new Exception('Failed to replace original file');
            }
            
            // Cleanup
            if (file_exists($temp_ppm)) unlink($temp_ppm);
            
            $processing_time = round(microtime(true) - $start_time, 2);
            
            return array(
                'success' => true,
                'resized' => true,
                'method' => 'JPEG Streaming',
                'new_width' => $new_width,
                'new_height' => $new_height,
                'processing_time' => $processing_time
            );
            
        } catch (Exception $e) {
            // Cleanup on failure
            if (file_exists($temp_ppm)) unlink($temp_ppm);
            if (file_exists($temp_resized)) unlink($temp_resized);
            
            return array(
                'success' => false,
                'error' => $e->getMessage()
            );
        }
    }
    
    /**
     * Resize using ImageMagick with strict memory limits
     */
    private function resize_imagemagick_limited($file_path, $width, $height) {
        $convert_path = $this->find_binary('convert') ?: $this->find_binary('magick');
        
        if (!$convert_path) {
            return array('success' => false, 'error' => 'ImageMagick not available');
        }
        
        $start_time = microtime(true);
        
        // Calculate new dimensions
        $ratio = min($this->max_width / $width, $this->max_height / $height);
        $new_width = intval($width * $ratio);
        $new_height = intval($height * $ratio);
        
        $temp_output = $file_path . '.resized.tmp';
        
        $command = escapeshellarg($convert_path);
        $command .= ' -limit memory 32MB -limit map 32MB'; // Very strict limits
        $command .= ' -limit disk 1GB -limit thread 1';
        $command .= ' ' . escapeshellarg($file_path);
        $command .= ' -resize ' . $new_width . 'x' . $new_height;
        $command .= ' -strip';
        $command .= ' ' . escapeshellarg($temp_output);
        $command .= ' 2>&1';
        
        $output = shell_exec($command);
        $processing_time = round(microtime(true) - $start_time, 2);
        
        if (file_exists($temp_output) && filesize($temp_output) > 0) {
            if (rename($temp_output, $file_path)) {
                return array(
                    'success' => true,
                    'resized' => true,
                    'method' => 'ImageMagick Limited',
                    'new_width' => $new_width,
                    'new_height' => $new_height,
                    'processing_time' => $processing_time
                );
            } else {
                unlink($temp_output);
                return array('success' => false, 'error' => 'Failed to replace file');
            }
        } else {
            if (file_exists($temp_output)) unlink($temp_output);
            return array('success' => false, 'error' => 'ImageMagick resize failed: ' . ($output ?: 'Unknown error'));
        }
    }
    
    /**
     * Attempt to resize PPM file
     */
    private function resize_ppm_if_possible($ppm_path, $new_width, $new_height) {
        // Try netpbm tools
        $scale_tool = $this->find_binary('pnmscale');
        if ($scale_tool) {
            $temp_resized = $ppm_path . '.resized';
            $scale_cmd = escapeshellarg($scale_tool);
            $scale_cmd .= ' -width ' . $new_width . ' -height ' . $new_height;
            $scale_cmd .= ' ' . escapeshellarg($ppm_path);
            $scale_cmd .= ' > ' . escapeshellarg($temp_resized);
            $scale_cmd .= ' 2>/dev/null';
            
            shell_exec($scale_cmd);
            
            if (file_exists($temp_resized) && filesize($temp_resized) > 0) {
                rename($temp_resized, $ppm_path);
                error_log("✅ PPM resized using netpbm");
                return true;
            }
        }
        
        error_log("⚠️  No PPM resize tools - keeping original dimensions");
        return false;
    }
    
    /**
     * Get available tools for admin display
     */
    public function get_available_tools() {
        $tools = array();
        
        if (isset($this->tools_available['jpeg_streaming']) && $this->tools_available['jpeg_streaming']) {
            $tools[] = 'JPEG Streaming (djpeg/cjpeg)';
        }
        
        if (isset($this->tools_available['imagemagick_limited']) && $this->tools_available['imagemagick_limited']) {
            $tools[] = 'ImageMagick Limited';
        }
        
        return empty($tools) ? array('None available') : $tools;
    }
}
