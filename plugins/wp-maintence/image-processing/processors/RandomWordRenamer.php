<?php
/**
 * RULE: Alaway compelete error_log() with error_log("last_var_name".print_r($last_var_name,true)) it means use var name in above line
 * Random Word File Renaming System
 * Converts cryptic filenames to meaningful random word combinations
 * Ultra-lightweight for 512MB RAM servers
 */

class RandomWordRenamer {
    
    private $adjectives = [
        'amazing', 'awesome', 'beautiful', 'bright', 'calm', 'cheerful', 'clear', 'colorful',
        'cool', 'creative', 'cute', 'delightful', 'elegant', 'fantastic', 'fresh', 'gentle',
        'gorgeous', 'happy', 'lovely', 'magnificent', 'marvelous', 'perfect', 'pretty', 'quiet',
        'radiant', 'serene', 'shiny', 'smooth', 'soft', 'spectacular', 'stunning', 'sweet',
        'vibrant', 'vivid', 'warm', 'wonderful', 'cozy', 'dreamy', 'golden', 'peaceful',
        'sparkling', 'magical', 'charming', 'graceful', 'brilliant', 'dazzling', 'glowing', 'heavenly'
    ];
    
    private $nouns = [
        'sunset', 'mountain', 'ocean', 'forest', 'garden', 'flower', 'butterfly', 'rainbow',
        'cloud', 'star', 'moon', 'sun', 'tree', 'lake', 'river', 'beach', 'meadow', 'valley',
        'hill', 'sky', 'bird', 'cat', 'dog', 'rabbit', 'deer', 'fish', 'dolphin', 'eagle',
        'rose', 'tulip', 'lily', 'daisy', 'orchid', 'maple', 'oak', 'pine', 'cherry', 'apple',
        'pearl', 'diamond', 'crystal', 'gem', 'gold', 'silver', 'bronze', 'copper', 'jade', 'ruby',
        'house', 'cottage', 'castle', 'bridge', 'tower', 'lighthouse', 'church', 'palace', 'cabin', 'villa'
    ];
    
    private $used_combinations = [];
    
    public function __construct() {
        // Load used combinations from database to avoid duplicates
        $this->used_combinations = get_option('used_filename_combinations', []);
        
        add_action('init', array($this, 'init'));
    }
    
    public function init() {
        // Hook into upload process
        add_filter('wp_handle_upload_prefilter', array($this, 'rename_cryptic_files'), 1); // Before WebP processing
        
        // Add admin menu for bulk renaming
        // add_action('admin_menu', array($this, 'add_admin_menu'));
        
        // AJAX handlers
        add_action('wp_ajax_bulk_rename_files', array($this, 'bulk_rename_files'));
        add_action('wp_ajax_preview_renames', array($this, 'preview_renames'));
    }
    
    /**
     * Main renaming function for new uploads
     */
    public function rename_cryptic_files($file) {
        error_log("rename_cryptic_files");
        if (!$this->is_processable_file($file['name'])) {
            error_log("❌ Skipping non-processable file:". $file['name']);
            return $file;
        }
        
        $original_name = $file['name'];
        error_log("org name: $original_name");
        $isCy = $this->is_cryptic_filename($original_name);
        error_log("isCy: " . var_export($isCy, true));
        if ($isCy) {
            error_log("ready for change");

            $extension = pathinfo($original_name, PATHINFO_EXTENSION);
            $new_name = $this->generate_random_name() . '.' . $extension;
            error_log("new_name: " . $new_name);
            $file['name'] = $new_name;
            
            error_log("🏷️ Renamed cryptic file: {$original_name} → {$new_name}");
        }
        
        return $file;
    }
    
    /**
     * Detect cryptic filenames using patterns
     */
    private function is_cryptic_filename($filename) {
        $name_without_ext = pathinfo($filename, PATHINFO_FILENAME);
        
        // MD5-style hashes (32 hex chars)
        if (preg_match('/^[a-f0-9]{32}$/i', $name_without_ext)) {
            return true;
        }
        
        // Hex hashes (16-20 chars)
        if (preg_match('/^[a-f0-9]{16,20}$/i', $name_without_ext)) {
            return true;
        }
        
        // Mixed patterns with dots
        if (preg_match('/^[a-f0-9]{8,}\.[A-Za-z]+/', $name_without_ext)) {
            return true;
        }
        
        // Long numeric IDs (social media style)
        if (preg_match('/^\d{10,}_\d+_\d+_[no]$/', $name_without_ext)) {
            return true;
        }
        
        // WordPress timestamp hashes
        if (preg_match('/^e\d{13,}$/', $name_without_ext)) {
            return true;
        }
        
        // Pure numeric with dashes or underscores
        if (preg_match('/^\d+[-_]\w+$/', $name_without_ext) && strlen($name_without_ext) > 10) {
            return true;
        }
        
        // Mixed-case alphanumeric string (e.g., base62 IDs like 'ldE83Ar78UlARwsICTVJ')
        if (strlen($name_without_ext) >= 15 && preg_match('/[a-z]/', $name_without_ext) && preg_match('/[A-Z]/', $name_without_ext) && preg_match('/[0-9]/', $name_without_ext)) {
            return true;
        }
        
        // Very long alphanumeric strings
        // Catches long, non-descriptive names that are not pure hashes.
        if (strlen($name_without_ext) >= 20 && preg_match('/^[a-zA-Z0-9_-]+$/i', $name_without_ext)) {
            return true;
        }
        
        return false;
    }
    
    /**
     * Generate unique random word combination
     */
    private function generate_random_name() {
        $max_attempts = 50;
        $attempts = 0;
        
        do {
            $adjective = $this->adjectives[array_rand($this->adjectives)];
            $noun = $this->nouns[array_rand($this->nouns)];
            $combination = $adjective . '-' . $noun;
            
            $attempts++;
            
            // Add number if combination exists
            if (in_array($combination, $this->used_combinations)) {
                $combination .= '-' . rand(1, 999);
            }
            
        } while (in_array($combination, $this->used_combinations) && $attempts < $max_attempts);
        
        // Store the combination
        $this->used_combinations[] = $combination;
        update_option('used_filename_combinations', $this->used_combinations);
        
        return $combination;
    }
    
    /**
     * Check if file should be processed
     */
    private function is_processable_file($filename) {
        $extension = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
        return in_array($extension, ['jpg', 'jpeg', 'png', 'gif', 'webp', 'pdf', 'doc', 'docx']);
    }
    
    /**
     * Add admin menu for bulk operations
     */
    public function add_admin_menu() {
        // add_media_page(
        //     'Rename Files',
        //     'Rename Files',
        //     'manage_options',
        //     'random-word-renamer',
        //     array($this, 'admin_page')
        // );
    }
    
    /**
     * Admin page for bulk renaming
     */
    public function admin_page() {
        ?>
        <div class="wrap">
            <h1>Random Word File Renamer</h1>
            
            <div class="card">
                <h2>Bulk Rename Existing Files</h2>
                <p>This will scan your media library and rename all cryptic filenames to random word combinations.</p>
                
                <button id="preview-renames" class="button">Preview Renames</button>
                <button id="bulk-rename" class="button button-primary" disabled>Start Bulk Rename</button>
                
                <div id="rename-progress" style="display:none; margin-top: 20px;">
                    <div id="progress-bar" style="width: 100%; background: #f1f1f1; border-radius: 3px;">
                        <div id="progress-fill" style="width: 0%; height: 20px; background: #4CAF50; border-radius: 3px; text-align: center; line-height: 20px; color: white; font-size: 12px;">0%</div>
                    </div>
                    <div id="rename-log" style="max-height: 300px; overflow-y: auto; border: 1px solid #ccc; padding: 10px; margin-top: 10px; font-family: monospace; font-size: 12px;"></div>
                </div>
            </div>
            
            <div class="card">
                <h2>Statistics</h2>
                <?php $this->show_statistics(); ?>
            </div>
        </div>
        
        <script>
        jQuery(document).ready(function($) {
            $('#preview-renames').click(function() {
                $(this).prop('disabled', true).text('Loading...');
                
                $.post(ajaxurl, {
                    action: 'preview_renames'
                }, function(response) {
                    if (response.success) {
                        $('#rename-log').html('<strong>Preview (' + response.data.count + ' files to rename):</strong><br>' + response.data.preview.join('<br>'));
                        $('#rename-progress').show();
                        $('#bulk-rename').prop('disabled', false);
                    } else {
                        alert('Error: ' + response.data);
                    }
                    $('#preview-renames').prop('disabled', false).text('Preview Renames');
                });
            });
            
            $('#bulk-rename').click(function() {
                if (!confirm('Are you sure you want to rename all cryptic files? This cannot be undone!')) {
                    return;
                }
                
                $(this).prop('disabled', true).text('Renaming...');
                $('#preview-renames').prop('disabled', true);
                
                $.post(ajaxurl, {
                    action: 'bulk_rename_files'
                }, function(response) {
                    if (response.success) {
                        $('#progress-fill').css('width', '100%').text('Complete!');
                        $('#rename-log').append('<br><strong>✅ Bulk rename completed! ' + response.data.renamed + ' files renamed.</strong>');
                    } else {
                        $('#rename-log').append('<br><strong>❌ Error: ' + response.data + '</strong>');
                    }
                    
                    $('#bulk-rename').prop('disabled', false).text('Start Bulk Rename');
                    $('#preview-renames').prop('disabled', false);
                });
            });
        });
        </script>
        <?php
    }
    
    /**
     * Show statistics about files
     */
    private function show_statistics() {
        $uploads = wp_upload_dir();
        $upload_path = $uploads['basedir'];
        
        $total_files = 0;
        $cryptic_files = 0;
        
        $iterator = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($upload_path, RecursiveDirectoryIterator::SKIP_DOTS)
        );
        
        foreach ($iterator as $file) {
            if ($file->isFile() && $this->is_processable_file($file->getFilename())) {
                $total_files++;
                if ($this->is_cryptic_filename($file->getFilename())) {
                    $cryptic_files++;
                }
            }
        }
        
        echo "<p><strong>Total processable files:</strong> {$total_files}</p>";
        echo "<p><strong>Files with cryptic names:</strong> {$cryptic_files}</p>";
        echo "<p><strong>Used name combinations:</strong> " . count($this->used_combinations) . "</p>";
        
        if ($cryptic_files > 0) {
            echo "<p style='color: orange;'>⚠️ {$cryptic_files} files need renaming</p>";
        } else {
            echo "<p style='color: green;'>✅ All files have readable names!</p>";
        }
    }
    
    /**
     * AJAX: Preview what files will be renamed
     */
    public function preview_renames() {
        $uploads = wp_upload_dir();
        $upload_path = $uploads['basedir'];
        
        $preview = [];
        $count = 0;
        
        $iterator = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($upload_path, RecursiveDirectoryIterator::SKIP_DOTS)
        );
        
        foreach ($iterator as $file) {
            if ($file->isFile() && $this->is_processable_file($file->getFilename())) {
                $filename = $file->getFilename();
                if ($this->is_cryptic_filename($filename)) {
                    $extension = pathinfo($filename, PATHINFO_EXTENSION);
                    $new_name = $this->generate_random_name() . '.' . $extension;
                    $preview[] = "📝 {$filename} → {$new_name}";
                    $count++;
                    
                    if ($count >= 20) { // Limit preview
                        $preview[] = "... and " . ($count > 20 ? ($count - 20) . " more" : "more") . " files";
                        break;
                    }
                }
            }
        }
        
        wp_send_json_success(['preview' => $preview, 'count' => $count]);
    }
    
    /**
     * AJAX: Bulk rename files
     */
    public function bulk_rename_files() {
        $uploads = wp_upload_dir();
        $upload_path = $uploads['basedir'];
        
        $renamed = 0;
        $errors = 0;
        
        $iterator = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($upload_path, RecursiveDirectoryIterator::SKIP_DOTS)
        );
        
        foreach ($iterator as $file) {
            if ($file->isFile() && $this->is_processable_file($file->getFilename())) {
                $old_path = $file->getPathname();
                $filename = $file->getFilename();
                
                if ($this->is_cryptic_filename($filename)) {
                    $extension = pathinfo($filename, PATHINFO_EXTENSION);
                    $new_name = $this->generate_random_name() . '.' . $extension;
                    $new_path = dirname($old_path) . '/' . $new_name;
                    
                    if (rename($old_path, $new_path)) {
                        $renamed++;
                        
                        // Update database references
                        $this->update_database_references($filename, $new_name);
                    } else {
                        $errors++;
                    }
                }
            }
        }
        
        wp_send_json_success(['renamed' => $renamed, 'errors' => $errors]);
    }
    
    /**
     * Update database references to renamed files
     */
    private function update_database_references($old_name, $new_name) {
        global $wpdb;
        
        // Update attachment posts
        $wpdb->query($wpdb->prepare("
            UPDATE {$wpdb->posts} 
            SET post_title = %s, post_name = %s 
            WHERE post_type = 'attachment' AND guid LIKE %s
        ", 
            pathinfo($new_name, PATHINFO_FILENAME),
            sanitize_title($new_name),
            '%' . $old_name
        ));
        
        // Update post content references
        $wpdb->query($wpdb->prepare("
            UPDATE {$wpdb->posts} 
            SET post_content = REPLACE(post_content, %s, %s)
        ", $old_name, $new_name));
        
        // Update metadata
        $wpdb->query($wpdb->prepare("
            UPDATE {$wpdb->postmeta} 
            SET meta_value = REPLACE(meta_value, %s, %s) 
            WHERE meta_key = '_wp_attached_file'
        ", $old_name, $new_name));
    }
}

// Initialize the renamer


?>