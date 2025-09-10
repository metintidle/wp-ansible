<?php
/**
 * Binary Finder Utility
 * Locates system binaries across different platforms
 */
class BinaryFinder {
    
    /**
     * Find CWebP binary across different platforms
     */
    public static function find_cwebp() {
        $paths = array(
            '/opt/homebrew/bin/cwebp',  // macOS Homebrew (Apple Silicon)
            '/usr/local/bin/cwebp',     // macOS Homebrew (Intel) / Linux
            '/usr/bin/cwebp',           // Linux system install
            'cwebp'                     // PATH lookup
        );
        
        foreach ($paths as $path) {
            $test = shell_exec(escapeshellarg($path) . ' -version 2>/dev/null');
            if ($test && !empty(trim($test))) {
                return $path;
            }
        }
        return false;
    }
    
    /**
     * Test if a binary exists and works
     */
    public static function test_binary($path, $expected_output = null) {
        $test = shell_exec(escapeshellarg($path) . ' -version 2>/dev/null');
        
        if ($expected_output) {
            return $test && strpos($test, $expected_output) !== false;
        }
        
        return !empty($test);
    }
}
?>