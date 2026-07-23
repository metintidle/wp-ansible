#!/usr/bin/env bash
# Ensure every nginx server block listening on 443 includes default.d snippets.
# Certbot sometimes omits the include when it creates the SSL server block.
set -euo pipefail

cfg="${1:-/etc/nginx/nginx.conf}"
include_line='    include /etc/nginx/default.d/*.conf;'

python3 - "$cfg" "$include_line" <<'PY'
import sys

path, include_line = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)

def server_blocks(text_lines):
    blocks = []
    i = 0
    while i < len(text_lines):
        if "server" in text_lines[i] and "{" in text_lines[i]:
            depth = 0
            start = i
            while i < len(text_lines):
                depth += text_lines[i].count("{")
                depth -= text_lines[i].count("}")
                i += 1
                if depth == 0:
                    blocks.append((start, i))
                    break
            continue
        i += 1
    return blocks

def block_has_ssl(block_lines):
    return any("443" in line and "listen" in line for line in block_lines)

def block_has_include(block_lines):
    return any("include /etc/nginx/default.d/*.conf" in line for line in block_lines)

def insert_include(block_lines):
    for idx, line in enumerate(block_lines):
        if line.lstrip().startswith("location "):
            return block_lines[:idx] + [include_line + "\n", "\n"] + block_lines[idx:]
    if block_lines and block_lines[-1].strip() == "}":
        return block_lines[:-1] + [include_line + "\n", block_lines[-1]]
    return block_lines + [include_line + "\n"]

changed = False
for start, end in reversed(server_blocks(lines)):
    block = lines[start:end]
    if not block_has_ssl(block) or block_has_include(block):
        continue
    lines[start:end] = insert_include(block)
    changed = True

if not changed:
    print("UNCHANGED")
    sys.exit(0)

import shutil

backup = path + ".bak.ansible-ssl-include"
shutil.copy2(path, backup)
open(path, "w", encoding="utf-8").writelines(lines)
print("UPDATED")
PY
