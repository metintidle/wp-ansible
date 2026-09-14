#!/usr/bin/env python3
"""Move or add an ssh-config Host block in the WordPress AL2023 section.

Called by ./aws-cli/migrate/migrate-al2-al2023.sh (ssh-config phase) and
./aws-cli/create/al2023-lightsail-wordpress.sh (new site).

Usage:
    python3 aws-cli/ssh/move-ssh-host-al2023.py <ssh-config> <host-alias> [hostname]
    python3 aws-cli/ssh/move-ssh-host-al2023.py --add <ssh-config> <host-alias> <hostname> [identity] [domain] [profile]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

WORDPRESS_AL2023_MARKER = (
    "# Stack: WordPress on nginx + php-fpm (no local MySQL — database is remote/external)"
)
OS_CRON_TAG = "# OS update cron installed"
AL2023_SECTION_HEADER = re.compile(r"^# Amazon Linux 2023 — (\d+) hosts\s*$")


def is_al2023_wordpress_section_header(lines: list[str], marker_idx: int) -> bool:
    """True when the WordPress stack marker belongs to the AL2023 section, not AL2."""
    header_start = marker_idx
    for j in range(marker_idx - 1, max(marker_idx - 8, -1), -1):
        if lines[j].startswith("# ==="):
            header_start = j
            break
    header = "\n".join(lines[header_start : marker_idx + 1])
    if "Amazon Linux 2023" in header:
        return True
    if re.search(r"Amazon Linux 2\b", header, re.I) and "2023" not in header:
        return False
    return False


def wordpress_section_header_end(lines: list[str]) -> int:
    """Index of the closing === line for the AL2023 WordPress section header."""
    for i, line in enumerate(lines):
        if WORDPRESS_AL2023_MARKER not in line:
            continue
        if not is_al2023_wordpress_section_header(lines, i):
            continue
        for j in range(i + 1, len(lines)):
            if lines[j].startswith("# ==="):
                return j
    raise SystemExit(f"AL2023 WordPress section marker not found: {WORDPRESS_AL2023_MARKER}")


def parse_host_block(lines: list[str], alias: str) -> tuple[int, int]:
    host_idx = -1
    for i, line in enumerate(lines):
        if line.startswith("Host "):
            names = line.replace("Host ", "", 1).strip().split()
            if alias in names:
                if host_idx >= 0:
                    raise SystemExit(f"Duplicate Host {alias} in ssh-config")
                host_idx = i

    if host_idx < 0:
        raise SystemExit(f"Host {alias} not found in ssh-config")

    block_start = host_idx
    for j in range(host_idx - 1, -1, -1):
        prev = lines[j]
        if prev.startswith("Host ") or prev.startswith("# ==="):
            break
        if prev.startswith("#"):
            block_start = j
        elif prev.strip() == "":
            break
        else:
            break

    block_end = host_idx
    for j in range(host_idx + 1, len(lines)):
        line = lines[j]
        if line.startswith("Host "):
            break
        if re.match(r"^\s+\S", line):
            block_end = j
        elif line.strip() == "" and j == block_end + 1:
            block_end = j
        else:
            break

    return block_start, block_end


def retag_block(block: list[str]) -> list[str]:
    out: list[str] = []
    for line in block:
        if re.match(r"^#\s*Amazon Linux 2\b", line, re.I) and "2023" not in line:
            out.append(re.sub(r"Amazon Linux 2", "Amazon Linux 2023", line, flags=re.I))
        else:
            out.append(line)
    return out


def set_hostname(block: list[str], ip: str) -> list[str]:
    return [
        re.sub(r"^\s*HostName\s+.*", f"    HostName {ip}", line)
        if re.match(r"^\s*HostName\s+", line)
        else line
        for line in block
    ]


def add_os_cron_tag(block: list[str]) -> list[str]:
    if any(OS_CRON_TAG in line for line in block):
        return block

    for i, line in enumerate(block):
        if line.startswith("Host "):
            return block[:i] + [OS_CRON_TAG] + block[i:]

    return block


def was_al2_block(block: list[str]) -> bool:
    return any(
        re.match(r"^#\s*Amazon Linux 2\b", line, re.I) and "2023" not in line
        for line in block
    )


def in_wordpress_al2023_section(lines: list[str], block_start: int) -> bool:
    return block_start > wordpress_section_header_end(lines)


def find_wordpress_insert_line(lines: list[str]) -> int:
    """First Host/comment line after the WordPress section header (not static nginx section)."""
    header_end = wordpress_section_header_end(lines)
    insert_at = header_end + 1
    while insert_at < len(lines) and lines[insert_at].strip() == "":
        insert_at += 1
    return insert_at


def bump_wordpress_host_count(lines: list[str]) -> list[str]:
    for i, line in enumerate(lines):
        if WORDPRESS_AL2023_MARKER not in line:
            continue
        if not is_al2023_wordpress_section_header(lines, i):
            continue
        for j in range(i - 1, max(i - 6, -1), -1):
            match = AL2023_SECTION_HEADER.match(lines[j])
            if match:
                count = int(match.group(1)) + 1
                lines[j] = f"# Amazon Linux 2023 — {count} hosts"
                return lines
    return lines


def prepare_block(block: list[str], hostname: str | None) -> list[str]:
    if hostname:
        block = set_hostname(block, hostname)
    block = retag_block(block)
    return add_os_cron_tag(block)


def tilde_identity(path: str) -> str:
    """Store IdentityFile as ~/.ssh/... when the key lives under $HOME."""
    home = str(Path.home())
    expanded = str(Path(path).expanduser())
    if expanded.startswith(home + "/"):
        return "~/" + expanded[len(home) + 1 :]
    return path


def host_exists(lines: list[str], alias: str) -> bool:
    for line in lines:
        if line.startswith("Host "):
            names = line.replace("Host ", "", 1).strip().split()
            if alias in names:
                return True
    return False


def add_host(
    config_path: Path,
    alias: str,
    hostname: str,
    identity: str,
    domain: str | None = None,
    profile: str | None = None,
) -> None:
    """Insert a new Host block into the AL2023 WordPress section, or update IP if present."""
    content = config_path.read_text(encoding="utf-8")
    lines = content.splitlines()

    if host_exists(lines, alias):
        move_host(config_path, alias, hostname)
        return

    ident = tilde_identity(identity)
    block = ["# Amazon Linux 2023"]
    if domain:
        block.append(f"# https://{domain}/")
    if profile:
        block.append(f"# AWS profile: {profile}")
    block.extend(
        [
            f"Host {alias}",
            f"    HostName {hostname}",
            "    User ec2-user",
            f"    IdentityFile {ident}",
            "",
        ]
    )

    insert_at = find_wordpress_insert_line(lines)
    new_lines = lines[:insert_at] + block + lines[insert_at:]
    new_lines = bump_wordpress_host_count(new_lines)
    config_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    print(f"ssh-config Host {alias} added to AL2023 WordPress section ({config_path})")


def move_host(config_path: Path, alias: str, hostname: str | None) -> None:
    content = config_path.read_text(encoding="utf-8")
    lines = content.splitlines()
    block_start, block_end = parse_host_block(lines, alias)
    original_block = lines[block_start : block_end + 1]
    block = prepare_block(original_block.copy(), hostname)

    if in_wordpress_al2023_section(lines, block_start):
        result = lines[:block_start] + block + lines[block_end + 1 :]
        config_path.write_text("\n".join(result) + "\n", encoding="utf-8")
        print(f"ssh-config Host {alias} already in AL2023 WordPress section — updated tags/IP")
        return

    from_al2 = was_al2_block(original_block)
    without = lines[:block_start] + lines[block_end + 1 :]
    insert_at = find_wordpress_insert_line(without)

    new_lines = without[:insert_at] + block + [""] + without[insert_at:]
    if from_al2 or not in_wordpress_al2023_section(lines, block_start):
        new_lines = bump_wordpress_host_count(new_lines)

    config_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    print(f"ssh-config Host {alias} moved to AL2023 WordPress section ({config_path})")


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] in ("--add", "add"):
        if len(sys.argv) < 5:
            raise SystemExit(
                f"Usage: {sys.argv[0]} --add <ssh-config> <host-alias> <hostname> "
                "[identity] [domain] [profile]"
            )
        config_path = Path(sys.argv[2]).expanduser()
        alias = sys.argv[3]
        hostname = sys.argv[4]
        identity = sys.argv[5] if len(sys.argv) > 5 else f"~/.ssh/{alias}.pem"
        domain = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else None
        profile = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else None
        add_host(config_path, alias, hostname, identity, domain, profile)
        return

    if len(sys.argv) < 3:
        raise SystemExit(
            f"Usage: {sys.argv[0]} <ssh-config> <host-alias> [hostname]\n"
            f"       {sys.argv[0]} --add <ssh-config> <host-alias> <hostname> "
            "[identity] [domain] [profile]"
        )

    config_path = Path(sys.argv[1]).expanduser()
    alias = sys.argv[2]
    hostname = sys.argv[3] if len(sys.argv) > 3 else None
    move_host(config_path, alias, hostname)


if __name__ == "__main__":
    main()
