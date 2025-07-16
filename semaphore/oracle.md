# Setup on Oracle  

Details is in Notion 

```shell
podman run -d \
  --name semaphore \
  --restart unless-stopped \
  -p 3000:3000 \
  -e SEMAPHORE_DB_USER="itt-admin" \
  -e SEMAPHORE_DB_PASS='GCdGb!fNmk!!3dH' \
  -e SEMAPHORE_DB_HOST="152.69.175.15" \
  -e SEMAPHORE_DB_PORT="3306" \
  -e SEMAPHORE_DB_DIALECT="mysql" \
  -e SEMAPHORE_DB="semaphore_anisble" \
  -e SEMAPHORE_PLAYBOOK_PATH="/tmp/semaphore/" \
  -e SEMAPHORE_ADMIN="admin" \
  -e SEMAPHORE_ACCESS_KEY_ENCRYPTION="gs72mPntFATGJs9qK0pQ0rKtfidlexiMjYCH9gWKhTU=" \
  semaphoreui/semaphore:latest
```