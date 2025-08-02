LOG_DIRS=(
  "/var/log/nginx"

)
for dir in "${LOG_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    echo "Cleaning logs in $dir"

    # Delete regular .log files older than 7 days
    find "$dir" -type f -name "*.log" -mtime +7 -exec rm -f {} \;

    # Delete compressed log/archive files regardless of age
    find "$dir" -type f \( -name "*.gz" -o -name "*.zip" -o -name "*.bz2" -o -name "*.xz" \) -exec rm -f {} \;
  fi
done

# 2. Clean system journal logs (older than 7 days)
echo "Cleaning system journal logs..."
# Uncomment the following line to enable journal cleanup
# journalctl --vacuum-time=7d

# 3. Clean temporary image files in /tmp
echo "Removing image files from /tmp..."
find /tmp -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.gif" -o -iname "*.webp" \) -exec rm -f {} \;

echo "[+] Cleanup complete: $(date)"
