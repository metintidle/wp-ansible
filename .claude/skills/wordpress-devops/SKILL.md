---
name: wordpress-devops
description: Operate the wp-ansible WordPress fleet — pick or build the right inventory, run module playbooks safely against AL2023/AL2 hosts, and analyze playbook output without flooding context. Triggers on: run a playbook, deploy to the fleet, apply fail2ban/nginx/ssl/cache changes, add a host to inventory, --limit a batch, "why did the play fail", "which hosts changed", ansible recap analysis, wp-cli over ansible.
---

# WordPress fleet DevOps (wp-ansible)

Ansible control of ~55 WordPress hosts (Amazon Linux 2023, some legacy AL2, two
Debian/Bitnami outliers). Most hosts are 512 MB RAM production sites serving real
customers. **Nothing here is a lab.**

## Non-negotiables

1. **Never run a playbook against a group without `--limit` on the first run.**
   One host, verified, then the rest.
2. **`--check --diff` before the real run** for anything touching nginx, php-fpm,
   fail2ban, or WordPress config. If a task can't run in check mode, say so
   rather than skipping straight to the live run.
3. **Never ban or lock out logged-in editors.** See the fail2ban rules below.
4. **Confirm with the user before the un-limited fleet-wide run.** Applying to 50
   production sites is outward-facing and hard to reverse.
5. **Playbook output never goes to context raw.** See "Running and analyzing" —
   this is the rule that keeps a session alive.

## Fleet topology

| Thing | Where |
|---|---|
| SSH host definitions (57 hosts) | [ssh-config](ssh-config) — hostnames, users, `.pem` paths |
| Inventories | [inventory/](inventory/) — one `.ini` per campaign, not one global inventory |
| Playbooks | [modules/](modules/) — numbered by deploy order (1_nginx-php → 7_cleanup) |
| Run artifacts | [logs/](logs/) — per-host reports written by playbooks via `delegate_to: localhost` |
| Shell helpers | [bash/](bash/) |

There is **no `ansible.cfg` and no default inventory**. Every command must pass
`-i inventory/<file>.ini` explicitly.

### How inventory and ssh-config connect

Inventories don't repeat connection detail — they point Ansible at the repo's
ssh-config:

```ini
[al2023_fail2ban:vars]
ansible_user=ec2-user
ansible_ssh_common_args=-F /Users/meti/Projects/wp-ansible/ssh-config -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/wp-<campaign>-known_hosts
```

So a bare hostname in a group (`bateys`, `cccls`) resolves through `ssh-config`.
Hosts **not** in ssh-config carry inline connection vars instead:

```ini
[wp_hosts]
dmfp ansible_host=3.104.41.157 ansible_ssh_private_key_file=/Users/meti/.ssh/dmfp.pem
```

Hosts behind a separate estate (ohara, hparson) use that estate's config:
`ansible_ssh_common_args=-F /Users/meti/.ssh/ohara/config`.

### Writing a new inventory

Campaign-scoped, named for the job, with a header that records **when it was
verified, what it excludes and why, and the exact command to run it**. Match the
existing style:

```ini
# <Fleet subset> — <what this campaign does>
# Verified <YYYY-MM-DD>; excludes <host> (<reason — e.g. Debian/Bitnami, DB-only>)
#
# Usage:
#   ansible-playbook -i inventory/<name>.ini modules/<n>_<mod>/playbook.yml --limit <group>

[<group>_needs_install]
# <what distinguishes this subgroup>
hosta
hostb

[<parent>:children]
<group>_needs_install

[<parent>:vars]
ansible_user=ec2-user
ansible_ssh_common_args=-F /Users/meti/Projects/wp-ansible/ssh-config -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/wp-<name>-known_hosts
```

Splitting by **remediation state** (`needs_install` / `needs_upgrade` / verified-
skip) is the house pattern — it makes reruns idempotent at the group level and
lets you stage rollout. Known non-AL hosts to exclude from AL playbooks:
`lwhydraulics`, `figtreesports` (Debian/Bitnami), `shiredb` (database server, no
nginx/WordPress).

Always `ansible-inventory -i inventory/<f>.ini --graph` to verify a new file
before running anything through it.

## Running and analyzing — context discipline

`ansible-playbook` against 20 hosts emits tens of thousands of tokens. Under this
project's context-mode rules, that output must not land in context.

**Ansible runs in Bash, not in the sandbox.** `ctx_execute` cannot reach the SSH
keys or ssh-config. So the pattern is: **run in Bash with all output redirected to
a file, then analyze the file in the sandbox.**

### The run

```bash
RUN=/private/tmp/claude-501/.../scratchpad/run-$(date +%s)
ansible-playbook -i inventory/<f>.ini modules/<m>/playbook.yml \
  --limit <host-or-group> --diff > "$RUN.log" 2>&1
echo "exit=$? log=$RUN.log"
```

Only the exit code and path enter context. Do **not** pipe to `tee`, do **not**
run without redirection, do **not** `cat` the log.

For long fleet runs, add `run_in_background: true` on the Bash call — you're
re-invoked when it exits, so don't poll.

### The analysis

```
ctx_execute_file(path: "<RUN>.log", language: "shell", code: "...")
```
or `ctx_execute` with a small parser. Print only:

- the **PLAY RECAP** line per host (ok/changed/unreachable/failed),
- host names grouped by outcome,
- for each distinct failure, the task name + the error message **once** (dedupe —
  the same failure across 20 hosts is one finding, not twenty),
- any `changed` task names when you ran `--check` (that's the pending diff).

Then index it for follow-up questions:
`ctx_index(content: "<your summary>", source: "ansible-run-<module>-<date>")`.

If the user asks a follow-up ("what about host X"), `ctx_search` the indexed run
or re-grep the log in the sandbox — never re-read it into context.

### Structured output when you need it

For machine-parseable results (e.g. building a remediation inventory from a
survey run), set the JSON callback and write to the scratchpad:

```bash
ANSIBLE_STDOUT_CALLBACK=ansible.posix.json ansible-playbook ... > "$RUN.json" 2>&1
```

Note the JSON callback buffers until the play ends — no live progress. Use it for
short survey plays, not long deploys.

### Facts and ad-hoc checks

Same rule. `ansible -i inventory/<f>.ini <group> -m setup` is enormous:

```bash
ansible -i inventory/<f>.ini <group> -a "nginx -v" --tree "$RUN.d" > /dev/null 2>&1
```
then read `$RUN.d/` in the sandbox. Several playbooks already do the local-report
trick themselves — `fix-shell-rest.yml` writes per-host nginx versions to
[logs/report-nginx-v.log](logs/report-nginx-v.log) via `delegate_to: localhost`.
When you need a fleet survey, prefer adding that pattern to the play over
scraping stdout.

## Module map

Deploy order matters; each is standalone but assumes the prior ones.

| Module | Playbook | Notes |
|---|---|---|
| 1_nginx-php | `playbook.yml`, `fix-shell-rest.yml`, `multisite.yml` | nginx + PHP-FPM; `fix-shell-rest.yml` blocks REST user enumeration |
| 2_wordpress | `playbook.yml`, `fix-db-credentials.yml` | WP-CLI install; see `README-db-credentials.md` |
| 3_ssl | `playbook.yml` | Let's Encrypt; **imports 4_agent** unless `install_wp_agent=false`; POSTs siteurl to the resmon hub |
| 4_agent | `playbook.yml` | resmon wp-agent; needs `WP_AGENT_TOKEN` on the controller |
| 5_security | `playbook-fail2ban.yml`, `-crowdsec`, `-strict-whitelist`, `-auto-block`, `geoip-firewall.yml` | see fail2ban rules below |
| 6_cache | `playbook.yml` | FastCGI + SQLite object cache |
| 7_cleanup, tools, database, ftp, monitoring, migration, teleport | | ancillary |

Controller-side env vars (set on the Semaphore/Ansible controller, **not** the WP
host): `WP_MAINTENANCE_WEBHOOK_TOKEN`, `WP_MAINTENANCE_WEBHOOK_URL`,
`WP_AGENT_TOKEN`. Missing webhook token = notify task skips, provision still
succeeds.

## Fail2Ban rules for this fleet

Bans on these hosts hit real customers, and the sites are low-RAM so PHP-FPM
socket exhaustion produces log lines that *look* like attacks.

- **A logged-in editor must never be bannable.** Any new jail or filter must have
  an `ignoreregex` (or cookie/authenticated bypass) covering authenticated
  WordPress traffic before it ships.
- The `nginx-unknown-script` filter caused a false-positive ban wave when PHP-FPM
  socket errors were logged as 404s on `.php` paths. Don't reintroduce a filter
  that matches on FPM-socket-derived 404s.
- An **empty `ignoreregex`** on the php filter caused wp-login 404 bans (bateys,
  Jul 2026 audit). Empty is not a safe default — it's the bug.
- After any fail2ban change: `fail2ban-client status <jail>` on the limited host,
  confirm zero banned IPs that belong to the customer, *then* widen.

See [docs/FILE2BAN.md](docs/FILE2BAN.md),
[fail2ban-logged-in-users.md](fail2ban-logged-in-users.md), and
[docs/fail2ban-stop-loggin-usser-claud.md](docs/fail2ban-stop-loggin-usser-claud.md).
Ban-list snapshots live in `docs/al2023-fail2ban-blocked-ips-*.md`; the survey
script is [bash/list-fail2ban-blocked-ips.sh](bash/list-fail2ban-blocked-ips.sh).

## WordPress operations

WP-CLI lives at `/usr/local/bin/wp`. The **docroot is not fixed** — three are
live across the fleet: `/usr/share/nginx/html` (canonical, the `root` in
`modules/1_nginx-php/files/nginx.conf`), `/home/ec2-user/html` (symlink to it,
and the `wp_root` default in `modules/2_wordpress/playbook.yml`), and
`/var/www/html` (legacy hosts). `CLAUDE.md` claims `/var/www/html` is the
docroot; that's wrong for the canonical stack. Probe for `wp-load.php` the way
`modules/5_security/playbook-wp-fail2ban-auth.yml` does rather than hardcoding.
Full path map: [.github/instructions/wp-ansible-ops.instructions.md](.github/instructions/wp-ansible-ops.instructions.md).

Run WP-CLI through
`ansible ... -m shell -a "wp --path={{ wp_root }} <cmd> --allow-root"` and route
the output through the file-then-sandbox pattern above — `wp option get`,
`wp plugin list`, `wp db check` across the fleet all produce context floods.

Before writing a one-off shell task, check [bash/](bash/) — the recurring fixes
are already scripted there (`apply-elementor-low-ram.sh`,
`apply-php-fpm-ondemand.sh`, `disable-wp-cron.sh`, `auto-block-malicious-php.sh`,
the PHP upgrade pair). Prefer shipping an existing script over inlining new shell
into a playbook.

> Note: `CLAUDE.md` cites `bash/fix-wordpress-siteurl.sh` and
> `docs/fix-wrong-site-url-assets.md` — neither exists in the tree. For siteurl
> repair after SSL, use `wp search-replace` directly (dry-run first) rather than
> hunting for those files.

## Before you finish

Report honestly: which hosts succeeded, which changed, which failed and why, and
which were **not** attempted because you limited the run. "Applied to 3 of 22
hosts, remaining 19 pending your go-ahead" is a complete answer. Silently
widening scope is not.
