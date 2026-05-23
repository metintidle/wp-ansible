# Graph Report - wp-ansible  (2026-05-23)

## Corpus Check
- 14 files · ~16,646 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 83 nodes · 116 edges · 8 communities detected
- Extraction: 91% EXTRACTED · 9% INFERRED · 0% AMBIGUOUS · INFERRED: 10 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]

## God Nodes (most connected - your core abstractions)
1. `RandomWordRenamer` - 13 edges
2. `DynamicMemoryCWebPProcessor` - 12 edges
3. `CWebPProcessor` - 11 edges
4. `LowMemoryResizeProcessor` - 9 edges
5. `MemoryManager` - 5 edges
6. `BinaryFinder` - 4 edges
7. `ImageMagickProcessor` - 4 edges
8. `fetchUrl()` - 2 edges
9. `updateBotIPs()` - 2 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Communities

### Community 0 - "Community 0"
Cohesion: 0.29
Nodes (1): RandomWordRenamer

### Community 1 - "Community 1"
Cohesion: 0.27
Nodes (1): CWebPProcessor

### Community 2 - "Community 2"
Cohesion: 0.33
Nodes (1): DynamicMemoryCWebPProcessor

### Community 3 - "Community 3"
Cohesion: 0.42
Nodes (1): LowMemoryResizeProcessor

### Community 5 - "Community 5"
Cohesion: 0.33
Nodes (1): MemoryManager

### Community 6 - "Community 6"
Cohesion: 0.29
Nodes (1): ImageMagickProcessor

### Community 8 - "Community 8"
Cohesion: 0.5
Nodes (1): BinaryFinder

### Community 9 - "Community 9"
Cohesion: 1.0
Nodes (2): fetchUrl(), updateBotIPs()

## Knowledge Gaps
- **Thin community `Community 0`** (14 nodes): `RandomWordRenamer.php`, `RandomWordRenamer`, `.add_admin_menu()`, `.admin_page()`, `.bulk_rename_files()`, `.__construct()`, `.generate_random_name()`, `.init()`, `.is_cryptic_filename()`, `.is_processable_file()`, `.preview_renames()`, `.rename_cryptic_files()`, `.show_statistics()`, `.update_database_references()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 1`** (12 nodes): `CWebPProcessor`, `.analyzeHistogram()`, `.analyzeImageSampling()`, `.analyzePixelValues()`, `.calculateOptimalQuality()`, `.__construct()`, `.convert_only()`, `.extractSample()`, `.parseTextFormatToPixels()`, `.process_balanced()`, `.process_conservative()`, `CWebPProcessor.php`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 2`** (11 nodes): `DynamicMemoryCWebPProcessor`, `.__construct()`, `.create_webp_version()`, `.find_cwebp_binary()`, `.init()`, `.is_processable_image()`, `.missing_cwebp_notice()`, `.process_high_memory_mode()`, `.process_low_memory_mode()`, `.process_with_two_modes()`, `DynamicMemoryCWebPProcessor.php`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 3`** (9 nodes): `LowMemoryResizeProcessor`, `.__construct()`, `.detect_tools()`, `.find_binary()`, `.resize_if_needed()`, `.resize_imagemagick_limited()`, `.resize_jpeg_streaming()`, `.resize_ppm_if_possible()`, `LowMemoryResizeProcessor.php`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 5`** (7 nodes): `.get_processing_stats()`, `MemoryManager`, `.estimate_memory_needed()`, `.get_memory_status()`, `.log_memory_usage()`, `.parse_memory_value()`, `MemoryManager.php`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 6`** (7 nodes): `.get_system_status()`, `ImageMagickProcessor`, `.is_available()`, `.process_fast()`, `.process_limited()`, `.get_available_tools()`, `ImageMagickProcessor.php`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 8`** (4 nodes): `BinaryFinder`, `.find_cwebp()`, `.test_binary()`, `BinaryFinder.php`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 9`** (3 nodes): `update-bot-ips.js`, `fetchUrl()`, `updateBotIPs()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `DynamicMemoryCWebPProcessor` connect `Community 2` to `Community 5`, `Community 6`?**
  _High betweenness centrality (0.139) - this node is a cross-community bridge._
- **Why does `LowMemoryResizeProcessor` connect `Community 3` to `Community 6`?**
  _High betweenness centrality (0.066) - this node is a cross-community bridge._