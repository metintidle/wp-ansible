#!/bin/bash

# Private key formatting script
# Usage: privatekey.sh <path_to_private_key_file>

if [ $# -ne 1 ]; then
  echo "Usage: $0 <private_key_file>"
  exit 1
fi

PRIVATE_KEY_PATH="$1"

# Read the key and format it properly
key_content=$(cat "$PRIVATE_KEY_PATH")

# Debug: show what we read
echo "Original key content length: ${#key_content}"

# Remove any existing newlines and spaces, then format properly
echo "$key_content" | tr -d '\n\r' |
  sed 's/-----BEGIN RSA PRIVATE KEY-----/-----BEGIN RSA PRIVATE KEY-----\n/' |
  sed 's/-----END RSA PRIVATE KEY-----/\n-----END RSA PRIVATE KEY-----/' |
  sed 's/\(.\{64\}\)/\1\n/g' |
  sed '/^$/d' >"${PRIVATE_KEY_PATH}.tmp"

# Debug: show what we created
echo "Formatted key content:"
cat "${PRIVATE_KEY_PATH}.tmp"
echo "Formatted key file size: $(wc -c <"${PRIVATE_KEY_PATH}.tmp")"

# Move the file
mv "${PRIVATE_KEY_PATH}.tmp" "$PRIVATE_KEY_PATH"
chmod 600 "$PRIVATE_KEY_PATH"

# Verify the final file
echo "Final file size: $(wc -c <"$PRIVATE_KEY_PATH")"
