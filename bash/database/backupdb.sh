#!/bin/bash

# Configurations
DB_USER="itt-admin"          # Change to your MariaDB username
DB_PASS="GCdGb!fNmk!!3dH"      # Change to your MariaDB password
DB_HOST="152.69.175.15"
BACKUP_DIR="$HOME/backups"        # Change if needed
RETENTION_DAYS=3             # Number of days to keep backups

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Get a list of all databases (excluding system databases)
DATABASES=$(mysql -h $DB_HOST -u $DB_USER -p$DB_PASS -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema|mysql)")

# Loop through each database and create a backup
for DB in $DATABASES; do
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILE="$BACKUP_DIR/${DB}_backup_$TIMESTAMP.sql.gz"

    echo "[+] Creating backup for database: $DB"
    mysqldump -h $DB_HOST -u $DB_USER -p$DB_PASS --single-transaction --set-gtid-purged=OFF $DB | gzip > "$BACKUP_FILE"

    echo "[✔] Backup completed: $BACKUP_FILE"
done

# Delete old backups (older than retention period)
echo "[+] Deleting backups older than $RETENTION_DAYS days"
find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +$RETENTION_DAYS -exec rm {} \;

echo "[✔] All database backups completed successfully."