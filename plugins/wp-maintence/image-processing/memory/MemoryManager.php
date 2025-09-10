<?php
/**
 * Memory Management for Image Processing
 * Monitors system and PHP memory to determine optimal processing modes
 */
class MemoryManager {
    
    // Memory thresholds for different processing modes
    private $memory_thresholds = array(
        'high_memory' => 200 * 1024 * 1024,    // 200MB+ available = fast processing
        'medium_memory' => 100 * 1024 * 1024,  // 100-200MB = balanced processing  
        'low_memory' => 50 * 1024 * 1024,      // 50-100MB = memory-efficient processing
        'critical_memory' => 30 * 1024 * 1024  // <50MB = ultra-conservative
    );
    
    /**
     * Get current system memory status
     */
    public function get_memory_status() {
        $status = array(
            'total_system_memory' => 0,
            'available_system_memory' => 0,
            'php_memory_limit' => 0,
            'php_memory_used' => memory_get_usage(true),
            'php_memory_available' => 0,
            'processing_mode' => 'low_memory'
        );
        
        // Get PHP memory limit
        $php_limit = ini_get('memory_limit');
        $status['php_memory_limit'] = $this->parse_memory_value($php_limit);
        $status['php_memory_available'] = $status['php_memory_limit'] - $status['php_memory_used'];
        
        // Get system memory (Linux)
        if (file_exists('/proc/meminfo')) {
            $meminfo = file_get_contents('/proc/meminfo');
            
            // Parse memory info
            if (preg_match('/MemTotal:\s+(\d+)\s+kB/', $meminfo, $matches)) {
                $status['total_system_memory'] = intval($matches[1]) * 1024;
            }
            
            if (preg_match('/MemAvailable:\s+(\d+)\s+kB/', $meminfo, $matches)) {
                $status['available_system_memory'] = intval($matches[1]) * 1024;
            } elseif (preg_match('/MemFree:\s+(\d+)\s+kB/', $meminfo, $matches_free) && 
                     preg_match('/Cached:\s+(\d+)\s+kB/', $meminfo, $matches_cached)) {
                // Fallback: Free + Cached as available
                $status['available_system_memory'] = (intval($matches_free[1]) + intval($matches_cached[1])) * 1024;
            }
        }
        
        // Determine processing mode based on available memory
        $available_memory = min($status['php_memory_available'], $status['available_system_memory']);
        
        if ($available_memory >= $this->memory_thresholds['high_memory']) {
            $status['processing_mode'] = 'high_memory';
        } elseif ($available_memory >= $this->memory_thresholds['medium_memory']) {
            $status['processing_mode'] = 'medium_memory';
        } elseif ($available_memory >= $this->memory_thresholds['low_memory']) {
            $status['processing_mode'] = 'low_memory';
        } else {
            $status['processing_mode'] = 'critical_memory';
        }
        
        $status['effective_available'] = $available_memory;
        
        return $status;
    }
    
    /**
     * Parse memory value from ini setting
     */
    private function parse_memory_value($value) {
        $value = trim($value);
        $number = intval($value);
        $unit = strtoupper(substr($value, -1));
        
        switch ($unit) {
            case 'G': return $number * 1024 * 1024 * 1024;
            case 'M': return $number * 1024 * 1024;
            case 'K': return $number * 1024;
            default: return $number;
        }
    }
    
    /**
     * Estimate memory needed for image processing
     */
    public function estimate_memory_needed($width, $height) {
        return $width * $height * 4 * 1.8; // RGBA + overhead
    }
    
    /**
     * Log detailed memory usage
     */
    public function log_memory_usage($context = '') {
        if (file_exists('/proc/meminfo')) {
            $meminfo = file_get_contents('/proc/meminfo');
            
            preg_match('/MemTotal:\s+(\d+)\s+kB/', $meminfo, $total);
            preg_match('/MemAvailable:\s+(\d+)\s+kB/', $meminfo, $available);
            
            $total_mb = isset($total[1]) ? round(intval($total[1]) / 1024, 1) : 'unknown';
            $available_mb = isset($available[1]) ? round(intval($available[1]) / 1024, 1) : 'unknown';
            $php_used_mb = round(memory_get_usage(true) / 1024 / 1024, 1);
            
            error_log("Memory {$context}: System {$available_mb}MB/{$total_mb}MB available, PHP using {$php_used_mb}MB");
        }
    }
}
?>