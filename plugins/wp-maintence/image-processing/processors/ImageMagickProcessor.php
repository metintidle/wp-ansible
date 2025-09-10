<?php
/**
 * ImageMagick-based Image Processing
 * Handles fast and limited ImageMagick processing modes
 */
class ImageMagickProcessor {
    
    private $max_width = 2560;
    private $max_height = 2560;
    private $webp_quality = 85;
    
    /**
     * Fast ImageMagick processing (high memory available)
     */
    public function process_fast($file_path, $width, $height, $mime_type) {
        if (!extension_loaded('imagick')) {
            throw new Exception('ImageMagick extension not available');
        }
        
        try {
            $imagick = new Imagick();
            
            // Allow more memory for speed
            Imagick::setResourceLimit(Imagick::RESOURCETYPE_MEMORY, 128 * 1024 * 1024); // 128MB
            Imagick::setResourceLimit(Imagick::RESOURCETYPE_MAP, 128 * 1024 * 1024);
            
            $imagick->readImage($file_path);
            $imagick->stripImage();
            
            // Resize if needed
            $needs_resize = ($width > $this->max_width || $height > $this->max_height);
            $new_width = $width;
            $new_height = $height;
            
            if ($needs_resize) {
                $ratio = min($this->max_width / $width, $this->max_height / $height);
                $new_width = intval($width * $ratio);
                $new_height = intval($height * $ratio);
                $imagick->resizeImage($new_width, $new_height, Imagick::FILTER_LANCZOS, 1);
            }
            
            // Convert to WebP
            $imagick->setImageFormat('webp');
            $imagick->setImageCompressionQuality($this->webp_quality);
            $imagick->writeImage($file_path);
            
            $imagick->clear();
            $imagick->destroy();
            
            return array(
                'success' => true,
                'method' => 'ImageMagick Fast',
                'resized' => $needs_resize,
                'new_width' => $new_width,
                'new_height' => $new_height
            );
            
        } catch (Exception $e) {
            throw new Exception('ImageMagick fast processing failed: ' . $e->getMessage());
        }
    }
    
    /**
     * Limited ImageMagick processing (medium memory available)
     */
    public function process_limited($file_path, $width, $height, $mime_type) {
        if (!extension_loaded('imagick')) {
            throw new Exception('ImageMagick extension not available');
        }
        
        try {
            $imagick = new Imagick();
            
            // Conservative memory limits
            Imagick::setResourceLimit(Imagick::RESOURCETYPE_MEMORY, 64 * 1024 * 1024); // 64MB
            Imagick::setResourceLimit(Imagick::RESOURCETYPE_MAP, 64 * 1024 * 1024);
            
            $imagick->readImage($file_path);
            $imagick->stripImage();
            
            // Resize if needed
            $needs_resize = ($width > $this->max_width || $height > $this->max_height);
            $new_width = $width;
            $new_height = $height;
            
            if ($needs_resize) {
                $ratio = min($this->max_width / $width, $this->max_height / $height);
                $new_width = intval($width * $ratio);
                $new_height = intval($height * $ratio);
                $imagick->resizeImage($new_width, $new_height, Imagick::FILTER_LANCZOS, 1);
            }
            
            $imagick->setImageFormat('webp');
            $imagick->setImageCompressionQuality($this->webp_quality);
            $imagick->writeImage($file_path);
            
            $imagick->clear();
            $imagick->destroy();
            
            return array(
                'success' => true,
                'method' => 'ImageMagick Limited',
                'resized' => $needs_resize,
                'new_width' => $new_width,
                'new_height' => $new_height
            );
            
        } catch (Exception $e) {
            throw new Exception('ImageMagick limited processing failed: ' . $e->getMessage());
        }
    }
    
    /**
     * Check if ImageMagick is available
     */
    public function is_available() {
        return extension_loaded('imagick');
    }
}
?>