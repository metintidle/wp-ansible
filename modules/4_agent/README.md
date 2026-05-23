# Module 4 — Resmon wp-agent

Installs the **Resmon** Rust wp-agent (`/opt/wp-agent/wp-agent`) and systemd unit on
Amazon Linux 2023 WordPress hosts (standard nginx + `/usr/share/nginx/html` layout).

This is **not** `modules/monitoring/` (`wp-agent-wp.sh` / cron reporting).

Hub: `https://monitoring.itt.com.au` — Socket.io namespace `/wp-agent`.

## When to run

| Order | Module | Why |
|-------|--------|-----|
| 1 | `1_nginx-php` | Nginx, PHP, document root |
| 2 | `2_wordpress` | WP-CLI + WordPress |
| 3 | `3_ssl` | HTTPS + `wp search-replace` (imports this module by default) |
| — | `4_agent` | Agent needs `wp-config.php` + `wp` for site identity |

`3_ssl/playbook.yml` ends with `import_playbook: ../4_agent/playbook.yml` so new sites
get the agent after the canonical HTTPS URL is set.

## Binary (Amazon Linux 2023 x86_64)

Prebuilt artifact: `files/wp-agent-linux-x86_64` — compiled on **Amazon Linux 2023**
(`greenfarm` by default): native **glibc** ELF, `-C target-cpu=x86-64-v2`.

**Rebuild on AL2023 (recommended):**

```bash
# Uses SSH host greenfarm; override: WP_BUILD_HOST=your-al2023-host
modules/4_agent/scripts/build-wp-agent-binary.sh
```

**Rebuild on Mac (static musl; works on AL2023, better for mixed AL2+AL2023):**

```bash
modules/4_agent/scripts/build-wp-agent-binary.sh --local
# or: pnpm nx run wp-agent:build:linux  (needs zig + cargo-zigbuild)
```

The AL2023-native binary targets **AL2023 only** (glibc 2.34). Legacy **Amazon Linux 2**
hosts need the `--local` musl static build or an on-host build on AL2.

## Token

`AGENT_TOKEN` must equal `WP_AGENT_TOKEN` on the monitoring hub (`~/resmon/server/.env`).

```bash
export WP_AGENT_TOKEN='…'   # same value as hub
ansible-playbook -i hosts modules/4_agent/playbook.yml
```

Or `-e wp_agent_token=…` / Ansible Vault (`group_vars/example.yml`).

## Run standalone

```bash
ansible-playbook -i hosts modules/4_agent/playbook.yml \
  -e "wp_agent_token=${WP_AGENT_TOKEN}"
```

Skip agent during SSL run:

```bash
ansible-playbook -i hosts modules/3_ssl/playbook.yml \
  -e domain_name=example.com \
  -e install_wp_agent=false
```

## On-host build (slow; no prebuilt binary)

```bash
ansible-playbook -i hosts modules/4_agent/playbook.yml \
  -e wp_agent_build_on_host=true \
  -e wp_agent_src_path=/path/to/resmon/apps/wp-agent \
  -e "wp_agent_token=${WP_AGENT_TOKEN}"
```

## Verify

```bash
sudo systemctl status wp-agent
sudo journalctl -u wp-agent -f
```

Expect `connected (socket.io /wp-agent)` and a stable `agent_id` from `siteurl` + `blogname`.

Dashboard: Website panel → maintenance row / Agent control.
