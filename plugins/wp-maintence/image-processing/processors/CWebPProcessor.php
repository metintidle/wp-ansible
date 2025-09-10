<?php
/**
 * CWebP-based Image Processing
 * Handles balanced and conservative CWebP processing modes
 */
class CWebPProcessor {
    
    private $cwebp_path;
    private $max_width = 2560;
    private $max_height = 2560;
    private $webp_quality = 70;
    private $min_quality = 50;
    private $max_quality = 85;
    
    public function __construct($cwebp_path) {
        $this->cwebp_path = $cwebp_path;
    }
    
    /**
     * Calculate optimal quality based on image characteristics
     * Uses netpbm tools for memory-efficient analysis
     */
    private function calculateOptimalQuality($file_path, $mime_type) {
        try {
            // First, verify that required tools are available
            $required_tools = ['pnmhistmap'];
            if ($mime_type === 'image/jpeg') {
                $required_tools[] = 'jpegtopnm';
            } elseif ($mime_type === 'image/png') {
                $required_tools[] = 'pngtopnm';
            }
            
            foreach ($required_tools as $tool) {
                $check_cmd = "which $tool 2>/dev/null";
                $tool_path = shell_exec($check_cmd);
                if (empty(trim($tool_path))) {
                    error_log("Required tool '$tool' not found in PATH");
                    return $this->webp_quality; // Fallback
                }
            }
            
            // Convert image to PNM format for analysis (memory efficient)
            $temp_pnm = $file_path . '.analysis.pnm';
            
            // Convert based on mime type
            if ($mime_type === 'image/jpeg') {
                $convert_cmd = "jpegtopnm " . escapeshellarg($file_path) . " > " . escapeshellarg($temp_pnm) . " 2>/dev/null";
            } elseif ($mime_type === 'image/png') {
                $convert_cmd = "pngtopnm " . escapeshellarg($file_path) . " > " . escapeshellarg($temp_pnm) . " 2>/dev/null";
            } else {
                // Fallback to default quality
                return $this->webp_quality;
            }
            
            exec($convert_cmd, $output, $return_code);
            if ($return_code !== 0 || !file_exists($temp_pnm)) {
                error_log("Convert to PNM failed. Command: $convert_cmd, Return code: $return_code, Output: " . implode(' ', $output));
                return $this->webp_quality; // Fallback
            }
            
            error_log("PNM file created successfully. Size: " . filesize($temp_pnm) . " bytes");
            
            // Instead of histogram, let's use a simpler approach with pnmfile to get basic stats
            // and sample pixels for analysis
            $info_cmd = "pnmfile " . escapeshellarg($temp_pnm);
            error_log("Info command: $info_cmd");
            
            $info_output = shell_exec($info_cmd . " 2>&1");
            error_log("Image info: " . var_export($info_output, true));
            
            // Sample some pixels for basic analysis using pnmcut and pnmdepth
            $sample_quality = $this->analyzeImageSampling($temp_pnm);
            
            // Clean up temp file immediately
            unlink($temp_pnm);
            
            return $sample_quality;
            
        } catch (Exception $e) {
            error_log("Quality analysis failed: " . $e->getMessage());
            return $this->webp_quality; // Fallback to default
        }
    }
    
    /**
     * Analyze image using multiple smaller samples instead of one large sample
     * More memory efficient and works with available netpbm tools
     */
    private function analyzeImageSampling($temp_pnm) {
        try {
            // Get image dimensions and basic info
            $info_cmd = "pnmfile " . escapeshellarg($temp_pnm) . " 2>/dev/null";
            $info = shell_exec($info_cmd);
            
            if (!$info) {
                error_log("Could not get image info");
                return $this->webp_quality;
            }
            
            // Extract dimensions - pnmfile output format: "filename: PPM raw, W by H maxval N"
            if (preg_match('/(\d+)\s+by\s+(\d+)/', $info, $matches)) {
                $width = intval($matches[1]);
                $height = intval($matches[2]);
                error_log("Image dimensions: {$width}x{$height}");
            } else {
                error_log("Could not parse image dimensions from: $info");
                return $this->webp_quality;
            }
            
            // Define multiple sample positions for better coverage
            $sample_positions = [
                ['name' => 'center', 'x_ratio' => 0.5, 'y_ratio' => 0.5],
                ['name' => 'top_left', 'x_ratio' => 0.25, 'y_ratio' => 0.25],
                ['name' => 'top_right', 'x_ratio' => 0.75, 'y_ratio' => 0.25],
                ['name' => 'bottom_left', 'x_ratio' => 0.25, 'y_ratio' => 0.75],
                ['name' => 'bottom_right', 'x_ratio' => 0.75, 'y_ratio' => 0.75]
            ];
            
            // Sample size - smaller per sample but multiple samples
            $sample_size = min(120, min($width, $height) / 6); // 120x120 or 1/6 size
            
            // For very small images, reduce sample size but keep minimum
            if ($sample_size < 50) {
                $sample_size = min(50, min($width, $height) / 2);
            }
            
            error_log("Using sample size: {$sample_size}x{$sample_size}");
            
            $all_pixel_values = [];
            $successful_samples = 0;
            
            foreach ($sample_positions as $position) {
                $sample_pixels = $this->extractSample($temp_pnm, $width, $height, $sample_size, $position);
                
                if ($sample_pixels !== false && !empty($sample_pixels)) {
                    $all_pixel_values = array_merge($all_pixel_values, $sample_pixels);
                    $successful_samples++;
                    error_log("Successfully extracted {$position['name']} sample with " . count($sample_pixels) . " pixels");
                } else {
                    error_log("Failed to extract {$position['name']} sample");
                }
            }
            
            if (empty($all_pixel_values)) {
                error_log("No pixel data extracted from any samples");
                return $this->webp_quality;
            }
            
            error_log("Total pixels from $successful_samples samples: " . count($all_pixel_values));
            
            // Analyze combined pixel values
            return $this->analyzePixelValues($all_pixel_values);
            
        } catch (Exception $e) {
            error_log("Multiple samples analysis failed: " . $e->getMessage());
            return $this->webp_quality;
        }
    }

    /**
     * Extract a single sample from the image at specified position
     */
    private function extractSample($temp_pnm, $width, $height, $sample_size, $position) {
        try {
            // Calculate sample position
            $x_offset = max(0, min($width - $sample_size, intval($width * $position['x_ratio'] - $sample_size / 2)));
            $y_offset = max(0, min($height - $sample_size, intval($height * $position['y_ratio'] - $sample_size / 2)));
            
            // Ensure we don't go beyond image boundaries
            $actual_width = min($sample_size, $width - $x_offset);
            $actual_height = min($sample_size, $height - $y_offset);
            
            $sample_file = $temp_pnm . ".sample_{$position['name']}";
            $cut_cmd = "pnmcut -left $x_offset -top $y_offset -width $actual_width -height $actual_height " 
                    . escapeshellarg($temp_pnm) . " > " . escapeshellarg($sample_file) . " 2>/dev/null";
            
            exec($cut_cmd, $output, $return_code);
            if ($return_code !== 0 || !file_exists($sample_file)) {
                error_log("Failed to create {$position['name']} sample: $cut_cmd");
                return false;
            }
            
            // Convert sample to text format for analysis
            $text_file = $sample_file . '.txt';
            $text_cmd = "pnmtoplainpnm " . escapeshellarg($sample_file) . " > " . escapeshellarg($text_file) . " 2>/dev/null";
            
            exec($text_cmd, $output, $return_code);
            if ($return_code !== 0 || !file_exists($text_file)) {
                error_log("Failed to convert {$position['name']} sample to text format");
                // Clean up
                if (file_exists($sample_file)) unlink($sample_file);
                return false;
            }
            
            // Parse the text format
            $pixel_values = $this->parseTextFormatToPixels($text_file);
            
            // Clean up temp files
            if (file_exists($sample_file)) unlink($sample_file);
            if (file_exists($text_file)) unlink($text_file);
            
            return $pixel_values;
            
        } catch (Exception $e) {
            error_log("Failed to extract {$position['name']} sample: " . $e->getMessage());
            return false;
        }
    }

    /**
     * Parse the plain text PNM format and extract pixel values
     */
    private function parseTextFormatToPixels($text_file) {
        $content = file_get_contents($text_file);
        if (!$content) {
            return false;
        }
        
        $lines = explode("\n", trim($content));
        $data_started = false;
        $pixel_values = [];
        
        foreach ($lines as $line) {
            $line = trim($line);
            if (empty($line) || $line[0] === '#') continue;
            
            if (!$data_started) {
                if (preg_match('/^P[123]$/', $line)) continue; // Format
                if (preg_match('/^\d+\s+\d+$/', $line)) continue; // Dimensions
                if (preg_match('/^\d+$/', $line)) { // Max value
                    $data_started = true;
                    continue;
                }
            } else {
                // Parse pixel data
                $values = preg_split('/\s+/', $line);
                foreach ($values as $val) {
                    if (is_numeric($val)) {
                        $pixel_values[] = intval($val);
                    }
                }
            }
        }
        
        return $pixel_values;
    }

    /**
     * Enhanced pixel analysis with better thresholds for multiple samples
     */
    private function analyzePixelValues($pixel_values) {
        $total_pixels = count($pixel_values);
        if ($total_pixels === 0) return $this->webp_quality;
        
        $dark_pixels = 0;
        $bright_pixels = 0;
        $mid_dark_pixels = 0;  // New: mid-range dark pixels
        $mid_bright_pixels = 0; // New: mid-range bright pixels
        $variance_sum = 0;
        $mean = array_sum($pixel_values) / $total_pixels;
        
        foreach ($pixel_values as $value) {
            // Multiple threshold analysis
            if ($value < 60) $dark_pixels++;           // Very dark
            elseif ($value < 120) $mid_dark_pixels++;  // Mid-range dark
            
            if ($value > 220) $bright_pixels++;        // Very bright
            elseif ($value > 160) $mid_bright_pixels++; // Mid-range bright
            
            $variance_sum += pow($value - $mean, 2);
        }
        
        $dark_ratio = $dark_pixels / $total_pixels;
        $bright_ratio = $bright_pixels / $total_pixels;
        $mid_dark_ratio = $mid_dark_pixels / $total_pixels;
        $mid_bright_ratio = $mid_bright_pixels / $total_pixels;
        $variance = $variance_sum / $total_pixels;
        
        error_log("Enhanced analysis - Dark: $dark_ratio, Mid-dark: $mid_dark_ratio, Bright: $bright_ratio, Mid-bright: $mid_bright_ratio, Variance: $variance");
        
        // Enhanced decision logic for multiple samples:
        
        // High shadow detail needed
        if ($dark_ratio > 0.015 || $mid_dark_ratio > 0.10) {
            $quality = min($this->max_quality, $this->webp_quality + 8);
            error_log("Shadow detail detected, increasing quality to $quality");
            return $quality;
        }
        
        // High bright content - can compress more
        if ($bright_ratio > 0.025 || $mid_bright_ratio > 0.15) {
            $quality = max($this->min_quality, $this->webp_quality - 12);
            error_log("High bright content, decreasing quality to $quality");
            return $quality;
        }
        
        // High complexity (detailed image)
        if ($variance > 1200) {
            $quality = max($this->min_quality, $this->webp_quality - 8);
            error_log("High complexity (variance: $variance), decreasing quality to $quality");
            return $quality;
        }
        
        // Low complexity (flat/simple image) - aggressive compression
        if ($variance < 600) {
            $quality = max($this->min_quality, $this->webp_quality - 15);
            error_log("Low complexity (variance: $variance), aggressively decreasing quality to $quality");
            return $quality;
        }
        
        // Medium complexity range
        if ($variance < 900) {
            $quality = max($this->min_quality, $this->webp_quality - 10);
            error_log("Medium-low complexity (variance: $variance), moderately decreasing quality to $quality");
            return $quality;
        }
        
        error_log("Using default quality: {$this->webp_quality}");
        return $this->webp_quality;
    }
  

    /**
     * Analyze histogram to determine optimal quality
     */
    private function analyzeHistogram($histogram) {
        error_log("analyzeHistogram");

        $lines = explode("\n", trim($histogram));
        $total_pixels = 0;
        $dark_pixels = 0;
        $color_variance = 0;
        $unique_colors = 0;
        
        foreach ($lines as $line) {
            if (preg_match('/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/', $line, $matches)) {
                $r = intval($matches[1]);
                $g = intval($matches[2]); 
                $b = intval($matches[3]);
                $count = intval($matches[4]);
                
                $total_pixels += $count;
                $unique_colors++;
                
                // Check for dark pixels (shadows/blacks)
                $brightness = ($r + $g + $b) / 3;
                if ($brightness < 80) { // Dark threshold
                    $dark_pixels += $count;
                }
                
                // Calculate color variance (complexity indicator)
                $color_variance += abs($r - $g) + abs($g - $b) + abs($r - $b);
            }
        }
        
        if ($total_pixels == 0) return $this->webp_quality;
        
        $dark_ratio = $dark_pixels / $total_pixels;
        $complexity_score = ($unique_colors / $total_pixels) * 10000; // Normalize
        
        // Decision logic:
        // High dark ratio (>30%) = higher quality for shadow detail
        // High complexity (many colors) = lower quality (compression handles it well)
        error_log("analyze Histogram");

        if ($dark_ratio > 0.3) {
            // Images with significant dark areas need higher quality
            return min($this->max_quality, $this->webp_quality + 10);
        } elseif ($complexity_score > 50) {
            // Complex colorful images can use lower quality
            return max($this->min_quality, $this->webp_quality - 15);
        }
        
        return $this->webp_quality; // Default for balanced images
    }
    
    /**
     * NEW: Convert to WebP without resizing (memory safe)
     */
    public function convert_only($file_path, $mime_type) {
        $temp_webp = $file_path . '.webp.tmp';
        $start_time = microtime(true);
        
        // Calculate optimal quality based on image content
        $optimal_quality = $this->calculateOptimalQuality($file_path, $mime_type);
        error_log("CWebP convert-only: Using quality $optimal_quality (default: {$this->webp_quality})");
        
        $command = escapeshellarg($this->cwebp_path);
        $command .= ' -q ' . intval($optimal_quality);
        $command .= ' -m 6';        // Balanced method
        $command .= ' -mt';         // Multi-threading
        $command .= ' -low_memory'; // Force low memory mode
        
        // NO RESIZE - just conversion
        if ($mime_type === 'image/png') {
            $command .= ' -lossless';
        }
        
        $command .= ' -quiet';
        $command .= ' ' . escapeshellarg($file_path);
        $command .= ' -o ' . escapeshellarg($temp_webp);
        $command .= ' 2>&1';
        
        error_log("CWebP convert-only: " . $command);
        
        $output = shell_exec($command);
        $processing_time = round(microtime(true) - $start_time, 2);
        
        if (file_exists($temp_webp) && filesize($temp_webp) > 0) {
            if (rename($temp_webp, $file_path)) {
                return array(
                    'success' => true,
                    'processing_time' => $processing_time
                );
            } else {
                unlink($temp_webp);
                return array('success' => false, 'error' => 'Failed to rename file');
            }
        } else {
            if (file_exists($temp_webp)) unlink($temp_webp);
            return array('success' => false, 'error' => 'WebP conversion failed: ' . ($output ?: 'Unknown'));
        }
    }
    
    // ... (keep existing methods: process_balanced, process_conservative)
    
    public function process_balanced($file_path, $width, $height, $mime_type) {
        $temp_webp = $file_path . '.webp.tmp';
        
        // Calculate optimal quality based on image content
        $optimal_quality = $this->calculateOptimalQuality($file_path, $mime_type);
        error_log("CWebP balanced: Using quality $optimal_quality (default: {$this->webp_quality})");
        
        $command = escapeshellarg($this->cwebp_path);
        $command .= ' -q ' . intval($optimal_quality);
        $command .= ' -m 6';        // Balanced method
        $command .= ' -mt';         // Multi-threading
        $command .= ' -pass 2';     // Fewer passes for speed
        $command .= ' -segments 2'; // 2 segments for 2 vCPUs
        
        // Resize if needed
        $needs_resize = ($width > $this->max_width || $height > $this->max_height);
        $new_width = $width;
        $new_height = $height;
        
        if ($needs_resize) {
            $ratio = min($this->max_width / $width, $this->max_height / $height);
            $new_width = intval($width * $ratio);
            $new_height = intval($height * $ratio);
            $command .= ' -resize ' . $new_width . ' ' . $new_height;
        }
        
        if ($mime_type === 'image/png') {
            $command .= ' -lossless';
        }
        
        $command .= ' -quiet';
        $command .= ' ' . escapeshellarg($file_path);
        $command .= ' -o ' . escapeshellarg($temp_webp);
        $command .= ' 2>&1';
        
        $output = shell_exec($command);
        
        if (file_exists($temp_webp) && filesize($temp_webp) > 0) {
            rename($temp_webp, $file_path);
            
            return array(
                'success' => true,
                'method' => 'CWebP Balanced',
                'resized' => $needs_resize,
                'new_width' => $new_width,
                'new_height' => $new_height
            );
        } else {
            if (file_exists($temp_webp)) unlink($temp_webp);
            throw new Exception('CWebP balanced processing failed: ' . ($output ?: 'Unknown error'));
        }
    }
    
    public function process_conservative($file_path, $width, $height, $mime_type) {
        $temp_webp = $file_path . '.webp.tmp';
        
        // Calculate optimal quality based on image content
        $optimal_quality = $this->calculateOptimalQuality($file_path, $mime_type);
        error_log("CWebP conservative: Using quality $optimal_quality (default: {$this->webp_quality})");
        
        $command = escapeshellarg($this->cwebp_path);
        $command .= ' -q ' . intval($optimal_quality);
        $command .= ' -m 6';            // Maximum compression
        $command .= ' -mt';             // Multi-threading
        $command .= ' -pass 4';         // More passes
        $command .= ' -segments 2';     // 2 segments
        $command .= ' -low_memory';     // Force low memory mode
        
        // Resize if needed
        $needs_resize = ($width > $this->max_width || $height > $this->max_height);
        $new_width = $width;
        $new_height = $height;
        
        if ($needs_resize) {
            $ratio = min($this->max_width / $width, $this->max_height / $height);
            $new_width = intval($width * $ratio);
            $new_height = intval($height * $ratio);
            $command .= ' -resize ' . $new_width . ' ' . $new_height;
        }
        
        if ($mime_type === 'image/png') {
            $command .= ' -lossless';
        }
        
        $command .= ' -quiet';
        $command .= ' ' . escapeshellarg($file_path);
        $command .= ' -o ' . escapeshellarg($temp_webp);
        $command .= ' 2>&1';
        
        error_log("CWebP conservative: " . $command);
        
        $output = shell_exec($command);
        
        if (file_exists($temp_webp) && filesize($temp_webp) > 0) {
            rename($temp_webp, $file_path);
            
            return array(
                'success' => true,
                'method' => 'CWebP Conservative',
                'resized' => $needs_resize,
                'new_width' => $new_width,
                'new_height' => $new_height
            );
        } else {
            if (file_exists($temp_webp)) unlink($temp_webp);
            throw new Exception('CWebP conservative processing failed: ' . ($output ?: 'Unknown error'));
        }
    }
}
?>