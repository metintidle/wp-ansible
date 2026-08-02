#!/bin/bash
echo "=== Searching 85.11.167.118 ==="
grep -F "85.11.167.118" /var/log/nginx/access.log /var/log/nginx/access.log-20260722 /var/log/nginx/error.log /var/log/nginx/error.log-20260722 2>/dev/null | head -n 30
