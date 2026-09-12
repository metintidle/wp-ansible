# AWS CLI — Lightsail AL2 → AL2023 migration

Shell scripts to migrate WordPress sites on **Amazon Lightsail** from **Amazon Linux 2** to **Amazon Linux 2023**, using **AWS CLI only** (no `auto-aws` / Playwright for migration itself).

Ansible playbooks in [`modules/`](../modules/) handle nginx, SSL, fail2ban, and ssh-config section moves.

## Layout

```
aws-cli/
├── README.md                 ← this file
├── lib/paths.sh              shared AWS_CLI_* / REPO_ROOT / SSH_CONFIG / state dir
├── auth/                     IAM login_session profiles
│   ├── setup-profile.sh
│   ├── aws-login.sh
│   └── aws-profile.sh
├── migrate/                  AL2 → AL2023
│   ├── migrate-al2-al2023.sh  orchestrator (start here)
│   ├── check-static-ip.sh
│   ├── discover-domains.sh
│   ├── attach-disk-new.sh     live attach phase
│   ├── migrate-detach.sh      live detach / static IP / delete AL2
│   ├── migrate-attach.sh      env-driven attach (local wrapper / CloudShell)
│   ├── migrate-local-attach.sh
│   ├── migrate-local-detach.sh
│   └── notes/                CloudShell command logs (not the live path)
├── dns/
│   ├── dns-manage.sh
│   └── records/              Route53 change-batch JSON (gitignored)
├── ssh/
│   ├── move-ssh-host-al2023.py
│   └── encode-ssh-pubkey-b64.sh
├── docs/
│   ├── aws-credential.md
│   └── aws-credential-issues.md
└── state/                    runtime .migrate-<host>.* (gitignored)
```

Every script sources [`lib/paths.sh`](./lib/paths.sh) so paths stay correct no matter which folder you run from. Run commands from the **repo root**.

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| [AWS CLI 2.32.0+](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | Must support `aws login` |
| IAM `login_session` profile | See [docs/aws-credential.md](./docs/aws-credential.md) |
| `SignInLocalDevelopmentAccess` on IAM user | One-time per account |
| Ansible | For `nginx`, `ssl`, `fail2ban` phases |
| SSH access | `ssh-config` symlink → `~/.ssh/config`; host must be reachable |
| Lightsail **static IP** on AL2 | Required before attach — see [migrate/check-static-ip.sh](./migrate/check-static-ip.sh) |

## Quick start

```bash
cd /Users/meti/Projects/wp-ansible

# 1) Profile (once per account — skip if already in ~/.aws/config)
./aws-cli/auth/setup-profile.sh GerringongGP 203918858040 GerringongGP

# 2) Login (~12h session)
./aws-cli/auth/aws-login.sh GerringongGP
export AWS_PROFILE=GerringongGP

# 3) Preflight: AL2 must have a Lightsail static IP
SOURCE_PUBLIC_IP=3.104.213.239 ./aws-cli/migrate/check-static-ip.sh

# 4) Full migration (domain optional — auto-discovered)
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong
```

## Migration orchestrator

[`migrate/migrate-al2-al2023.sh`](./migrate/migrate-al2-al2023.sh) runs all phases in order.

```bash
./aws-cli/migrate/migrate-al2-al2023.sh <profile> <ssh-host> [domain] [phase]
```

| Argument | Description |
|----------|-------------|
| `profile` | AWS profile name (`~/.aws/config`) |
| `ssh-host` | `Host` alias in `ssh-config` |
| `domain` | Optional primary domain; omitted → auto-discover |
| `phase` | Step to run (default: `all`) |

### Phases

| Phase | Action |
|-------|--------|
| `discover-domains` | Find apex domains → `state/.migrate-<host>.domains` |
| `attach` | Create AL2023 instance, snapshot AL2 disk, attach rescue disk |
| `nginx` | [`modules/1_nginx-php/playbook.yml`](../modules/1_nginx-php/playbook.yml) — copy site from rescue disk |
| `plugins` | BBQ Firewall + SQLite Object Cache, auto-updates, lock BBQ — [`modules/2_wordpress/playbook-core-plugins.yml`](../modules/2_wordpress/playbook-core-plugins.yml) |
| `detach` | Detach rescue disk, move static IP AL2→AL2023, delete AL2 |
| `dns` | Route53 A/AAAA for **all** discovered domains |
| `ssl` | Let's Encrypt for up to 4 apex domains — [`modules/3_ssl/playbook.yml`](../modules/3_ssl/playbook.yml) |
| `fail2ban` | [`modules/5_security/playbook-fail2ban.yml`](../modules/5_security/playbook-fail2ban.yml) |
| `ssh-config` | Move host block to AL2023 WordPress section |
| `cleanup` | Delete `al2-rescue` disk snapshot + AL2 instance snapshots |
| `all` | Full flow with pause after `nginx` for wp-config verification, then `plugins` |

### Phase-by-phase example

```bash
export AWS_PROFILE=GerringongGP

./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong discover-domains
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong attach
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong nginx
# Verify wp-config.php on gerringong, then:
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong plugins
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong detach
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong dns
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong ssl
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong fail2ban
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong ssh-config
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong cleanup
```

**Do not re-run `detach`** after a successful cutover — it deletes the AL2 instance. If detach fails mid-way (e.g. AL2 delete only), fix manually; do not re-run full detach unless you understand current Lightsail state.

## Domain discovery

Sites with **multiple domains** (e.g. `gerringonggp.com.au` + `gfmp.net.au`) are handled automatically.

[`migrate/discover-domains.sh`](./migrate/discover-domains.sh) merges:

1. **Route53** — apex domains whose A record matches the AL2 IP (in the AWS account)
2. **ssh-config** — `# https://example.com/` comment above the `Host` block
3. **SSH** (`USE_SSH=1`) — nginx `server_name` + WordPress `siteurl` / `home`

```bash
./aws-cli/migrate/discover-domains.sh GerringongGP gerringong --write
cat aws-cli/state/.migrate-gerringong.domains
```

`dns` and `ssl` phases read `state/.migrate-<host>.domains`. SSL supports up to **4** apex domains (`domain_name` … `domain_name3`).

Domains on **external DNS** (not Route53 in that account) must be added manually to `state/.migrate-<host>.domains`.

## Static IP (critical)

Before `attach`, the AL2 instance must have a **Lightsail static IP** attached (same IP as `ssh-config` `HostName`):

```bash
SOURCE_PUBLIC_IP=<al2-ip> ./aws-cli/migrate/check-static-ip.sh
```

If missing, create one in Lightsail → Networking → attach to AL2 → update `ssh-config`, then continue.

During `detach`, the static IP moves from AL2 to `wp-web-23`. DNS can stay on the same IP when this succeeds.

## ssh-config step

[`ssh/move-ssh-host-al2023.py`](./ssh/move-ssh-host-al2023.py) (called by `ssh-config` phase):

1. Retags `# Amazon Linux 2` → `# Amazon Linux 2023`
2. Adds `# OS update cron installed`
3. Sets `HostName` to final static IP
4. **Cuts** the full block from the AL2 section
5. **Inserts** after the **WordPress AL2023** section header (`Stack: WordPress on nginx + php-fpm …`)
6. Increments the WordPress host count (`Amazon Linux 2023 — N hosts`)

WordPress hosts do **not** go in the static-nginx section (`Stack: Static website on nginx`).

Manual run:

```bash
python3 aws-cli/ssh/move-ssh-host-al2023.py ssh-config gerringong 3.104.213.239
```

## Local state files

Created under [`state/`](./state/) during migration (gitignored):

| File | Contents |
|------|----------|
| `.migrate-<host>.al2-ip` | Original AL2 public IP |
| `.migrate-<host>.al2-instance` | AL2 Lightsail instance name |
| `.migrate-<host>.final-ip` | Static IP after detach |
| `.migrate-<host>.domains` | Apex domains (one per line) |

Override the directory with `AWS_CLI_STATE=/path` if needed.

## Script reference

| Path | Purpose |
|------|---------|
| [lib/paths.sh](./lib/paths.sh) | Shared `AWS_CLI_*`, `REPO_ROOT`, `SSH_CONFIG`, `state/` |
| [auth/setup-profile.sh](./auth/setup-profile.sh) | Add `login_session` profile to `~/.aws/config` |
| [auth/aws-login.sh](./auth/aws-login.sh) | `aws login --profile` wrapper |
| [auth/aws-profile.sh](./auth/aws-profile.sh) | Run any `aws` command with auto-login |
| [migrate/migrate-al2-al2023.sh](./migrate/migrate-al2-al2023.sh) | Main migration orchestrator |
| [migrate/check-static-ip.sh](./migrate/check-static-ip.sh) | Preflight static IP check |
| [migrate/discover-domains.sh](./migrate/discover-domains.sh) | Domain discovery for DNS/SSL |
| [migrate/attach-disk-new.sh](./migrate/attach-disk-new.sh) | Live attach: AL2023 + snapshot + rescue disk |
| [migrate/migrate-detach.sh](./migrate/migrate-detach.sh) | Live detach, static IP move, delete AL2 |
| [migrate/migrate-attach.sh](./migrate/migrate-attach.sh) | Env-driven attach (CloudShell / local wrapper) |
| [migrate/migrate-local-attach.sh](./migrate/migrate-local-attach.sh) | Local wrapper around `migrate-attach.sh` |
| [migrate/migrate-local-detach.sh](./migrate/migrate-local-detach.sh) | Local wrapper around `migrate-detach.sh` |
| [dns/dns-manage.sh](./dns/dns-manage.sh) | Route53 zone + A/AAAA upsert |
| [ssh/move-ssh-host-al2023.py](./ssh/move-ssh-host-al2023.py) | ssh-config section move |
| [ssh/encode-ssh-pubkey-b64.sh](./ssh/encode-ssh-pubkey-b64.sh) | Base64-encode SSH public key for Lightsail import |

CloudShell command logs (do not run as the live path): [migrate/notes/aws-command-migration.sh](./migrate/notes/aws-command-migration.sh), [migrate/notes/deattached-disk.sh](./migrate/notes/deattached-disk.sh).

## Authentication

See [docs/aws-credential.md](./docs/aws-credential.md) and [docs/aws-credential-issues.md](./docs/aws-credential-issues.md).

Minimal aws-cli-only setup:

```bash
./aws-cli/auth/setup-profile.sh <ProfileName> <account-id> <iam-username>
./aws-cli/auth/aws-login.sh <ProfileName>
export AWS_PROFILE=<ProfileName>
```

Optional: [`auto-aws/`](../auto-aws/) for vault sync and Playwright login (`npm run sync-config`, `npm run cli-login`).

## Examples

| Site | Profile | SSH host | Domains |
|------|---------|----------|---------|
| Camden Surgery | `CamdenSurgery` | `camden` | `camdensurgery.com.au` |
| Skin and Vein | `SCSVC` | `skinandvien` | `skinandvein.com.au` |
| Gerringong GP | `GerringongGP` | `gerringong` | `gerringonggp.com.au`, `gfmp.net.au` |

```bash
# Gerringong — auto-discover both domains
./aws-cli/migrate/migrate-al2-al2023.sh GerringongGP gerringong

# Camden — explicit primary domain
./aws-cli/migrate/migrate-al2-al2023.sh CamdenSurgery camden camdensurgery.com.au nginx
```

## Troubleshooting

| Symptom | Likely cause | Action |
|---------|--------------|--------|
| `No Lightsail static IP` on attach | Ephemeral IP on AL2 | Create static IP in console, attach to AL2 |
| SSH timeout during `nginx` (firewalld) | firewalld started before SSH opened | Wait ~1 min, re-run `nginx` phase |
| `mkswap: /swapfile is mounted` on nginx re-run | Swap already configured | Safe to ignore if first run completed; re-run skips or use `--skip-tags swap` |
| `DeleteInstance … addons` | Lightsail AutoSnapshot addon | Fixed in `migrate-detach.sh` (`--force-delete-add-ons`) |
| `ansible.builtin.synchronize` error on SSL | Wrong FQCN in agent playbook | Use `install_wp_agent=false` (default in migrate script) |
| Host still in AL2 section after `ssh-config` | Wrong section marker matched | Re-run `ssh-config`; script targets AL2023 WordPress header only |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | New instance at same IP | `ssh-keygen -R <ip>` |
| **Never re-run `detach`** after AL2 deleted | Script may mis-identify AL2 | Use saved `state/.migrate-<host>.al2-instance`; delete AL2 manually if needed |

## Related

- [docs/aws-credential.md](./docs/aws-credential.md) — IAM login profiles
- [docs/aws-credential-issues.md](./docs/aws-credential-issues.md) — `aws login` troubleshooting
- [auto-aws/README.md](../auto-aws/README.md) — Playwright login alternative
- [modules/1_nginx-php/playbook.yml](../modules/1_nginx-php/playbook.yml) — copy site from rescue disk
- [modules/2_wordpress/playbook-core-plugins.yml](../modules/2_wordpress/playbook-core-plugins.yml) — BBQ + SQLite Object Cache, auto-updates, BBQ lock
- [modules/3_ssl/playbook.yml](../modules/3_ssl/playbook.yml) — SSL + optional wp-agent
- [modules/5_security/playbook-fail2ban.yml](../modules/5_security/playbook-fail2ban.yml) — fail2ban
- [AGENTS.md](../AGENTS.md) — fleet conventions (Ohara, fail2ban, WP-CLI)
