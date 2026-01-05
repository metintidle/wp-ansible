#!/bin/bash

# Script to remove backup files older than last month
# Backup files follow the pattern: *_YYYY-MM-DD-HH-MM_backup_*.zip*

# Set the backup directory - adjust this path as needed
BACKUP_DIR="/home/ec2-user/html/wp-content/wpvividbackups"

# Calculate the cutoff date (1 month ago from today)
CUTOFF_DATE=$(date -d "1 month ago" +%Y-%m-%d 2>/dev/null || date -v-1m +%Y-%m-%d)

echo "==========================================="
echo "Backup Cleanup Script"
echo "==========================================="
echo "Cutoff date: Files older than $CUTOFF_DATE will be removed"
echo "Backup directory: $BACKUP_DIR"
echo ""

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Error: Backup directory does not exist: $BACKUP_DIR"
    echo "Please update BACKUP_DIR variable in this script."
    exit 1
fi

# Counter for files
REMOVED_COUNT=0
KEPT_COUNT=0
TOTAL_SIZE=0

# Find all backup files and process them
while IFS= read -r file; do
    # Extract date from filename using regex
    # Pattern: tahmoorinn.com.au_wpvivid-*_YYYY-MM-DD-HH-MM_backup_*
    if [[ $(basename "$file") =~ _([0-9]{4}-[0-9]{2}-[0-9]{2})-[0-9]{2}-[0-9]{2}_ ]]; then
        FILE_DATE="${BASH_REMATCH[1]}"

        # Compare dates
        if [[ "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
            # Get file size for reporting
            FILE_SIZE=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
            TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))

            echo "Removing: $(basename "$file") (Date: $FILE_DATE)"
            rm -f "$file"
            REMOVED_COUNT=$((REMOVED_COUNT + 1))
        else
            KEPT_COUNT=$((KEPT_COUNT + 1))
        fi
    fi
done < <(find "$BACKUP_DIR" -type f \( -name "*wpvivid*_backup_*.zip*" -o -name "*wpvivid*.zip*" \) 2>/dev/null)

# Convert bytes to human-readable format
TOTAL_SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))

echo ""
echo "==========================================="
echo "Cleanup Summary"
echo "==========================================="
echo "Files removed: $REMOVED_COUNT"
echo "Files kept: $KEPT_COUNT"
echo "Space freed: ${TOTAL_SIZE_MB} MB"
echo "==========================================="

exit 0
