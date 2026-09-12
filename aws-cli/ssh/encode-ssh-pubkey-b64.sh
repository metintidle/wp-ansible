#!/usr/bin/env bash
# Base64-encode an OpenSSH public key line for Lightsail import-key-pair.
# Usage: ./aws-cli/ssh/encode-ssh-pubkey-b64.sh /path/to/private.pem
set -euo pipefail
PEM="${1:?private key path required}"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
ssh-keygen -y -f "$PEM" > "$TMP"
cat "$TMP" | base64 | tr -d '\n'
