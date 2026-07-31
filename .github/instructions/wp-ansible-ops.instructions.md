---
description: Decision rules for the wp-ansible production WordPress fleet — blast-radius gating before dispatch, canonical server paths (docroot, nginx, PHP-FPM, fail2ban, SSL), inventory/ssh-config wiring, and the run-to-file-then-analyze contract that keeps playbook output out of context. Applies to orchestrator routing and to every worker touching modules/, inventory/, bash/, or configs/.
applyTo: 'modules/**,inventory/**,bash/**,configs/**,snippets/**,optimize/**,**/*.ini'
---

# wp-ansible fleet operations

This repo drives ~55 **live customer WordPress sites** (Amazon Linux 2023, some
legacy AL2, two Debian/Bitnami outliers) on mostly 512 MB RAM instances. An edit
here is not a code change — it is a change that lands on production web servers
the moment someone runs the playbook. Route and execute accordingly.

## Blast-radius gate — run this before the routing gate

Classify every wp-ansible task into a tier. The tier caps which workers may take
it, overriding cheapest-capable routing.

| Tier | Shape | Routing cap |
|---|---|---|
| **T0 read-only** | Inventory audit, log/recap analysis, doc, "which hosts have X" | Any worker, free band first |
| **T1 additive** | New inventory file, new standalone playbook, new `bash/` script, new fail2ban *filter* file not yet enabled | cheap-coder-kimi / free band with a named validation |
| **T2 in-place config** | Editing a deployed template — `files/nginx.conf`, `jail.local`, `www.conf`, `php.ini` fragments, an existing playbook's tasks | **mid-bulk-deepseek minimum.** Never free band, never cheap-coder-kimi |
| **T3 fleet-wide / security** | Anything that changes ban behavior, auth, TLS, or runs un-`--limit`ed across a group | **premium-coder-codex**, plus mandatory human confirmation before execution |

**Why the cap.** A wrong `location` block or an over-broad `failregex` does not
fail a test — it 502s a customer site or bans its staff, and the feedback arrives
as a support ticket hours later. The cheap tier's failure mode here is not a
retry, it's an outage. `p` (success probability) is not the relevant number when
`c_strong` is a production incident.

**Orchestrator: never dispatch execution.** Workers **write** playbooks and
config; they do not run `ansible-playbook` against production. The run is the
user's call, or an explicitly confirmed step. A brief that says "apply it to the
fleet" is malformed.

## Canonical server paths

Workers: use these; never invent a path, never assume a distro default. These are
extracted from the playbooks in this repo, not from general Linux knowledge.

### Docroot — **detect, never hardcode**

There are three live docroots across the fleet. This is the single most common
source of broken tasks.

| Path | Where it's real |
|---|---|
| `/usr/share/nginx/html` | **Canonical.** `root` in [modules/1_nginx-php/files/nginx.conf](modules/1_nginx-php/files/nginx.conf#L51) |
| `/home/ec2-user/html` | Symlink → `/usr/share/nginx/html`, created by [modules/1_nginx-php/playbook.yml:179](modules/1_nginx-php/playbook.yml#L179); default of `wp_root` in [modules/2_wordpress/playbook.yml:8](modules/2_wordpress/playbook.yml#L8) |
| `/var/www/html` | Legacy hosts only |

> `CLAUDE.md` states the docroot is `/var/www/html`. That is wrong for the
> canonical stack — treat this table as authoritative.

Any new play touching WordPress files **must** copy the probe pattern from
[modules/5_security/playbook-wp-fail2ban-auth.yml:20-45](modules/5_security/playbook-wp-fail2ban-auth.yml#L20-L45):
stat `{{ item }}/wp-load.php` over `wp_root_candidates`, `set_fact` the first
hit, `fail` with a clear message if none match, and allow `-e wp_root=...` to
override. Acceptance criteria for any such brief must name this pattern.

### Nginx

| Path | Source in repo |
|---|---|
| `/etc/nginx/nginx.conf` | `modules/1_nginx-php/files/nginx.conf` |
| `/etc/nginx/nginx.conf.backup` | Written before overwrite — preserve this habit |
| `/etc/nginx/conf.d/security.conf` | `modules/1_nginx-php/files/security/general.conf` |
| `/etc/nginx/conf.d/strict-whitelist-maps.conf` | `modules/5_security/files/security/restricts/` (map definitions) |
| `/etc/nginx/default.d/security.conf` | server-block-level security includes |
| `/etc/nginx/default.d/00-strict-whitelist.conf` | the deny rule; numeric prefix orders it first |
| `/etc/nginx/default.d/fastcgi_cache_block.conf` | `modules/6_cache/` |
| `/var/backups/nginx-security` | rollback copies |
| `/var/cache/nginx`, `/var/run/nginx-cache` | FastCGI cache stores |
| `/var/log/nginx/access.log`, `/var/log/nginx/error.log` | **also the fail2ban logpaths** — see below |

`conf.d/` is http-context, `default.d/` is server-context. Putting a `location`
in `conf.d/` is a config-test failure; putting a `map` in `default.d/` is too.
**Every nginx change ships with `nginx -t` as its validation command** — no
exceptions, and `systemctl reload nginx` only after `-t` passes.

### PHP-FPM

`/etc/php.ini` · `/etc/php-fpm.d/www.conf` · `/etc/php.d/10-opcache.ini` ·
`/etc/php.d/20-imagick.ini` · socket `/run/php-fpm/www.sock` · log
`/var/log/fpm.log` · helper `/usr/local/bin/fpm.sh`.

512 MB RAM is the binding constraint: `pm = ondemand` and low `pm.max_children`
are deliberate, not an oversight. Raising worker counts without stating the
memory math is a rejected change. Swap lives at `/swapfile`, scratch at
`/var/tmp_disk`.

### Fail2Ban — highest-risk area in the repo

| Path | Content |
|---|---|
| `/etc/fail2ban/jail.local` | `modules/5_security/files/fail2ban/jail.local` — DEFAULT + all jails |
| `/etc/fail2ban/jail.d/*.conf` | per-jail overrides (`wordpress-auth.local`, `nginx-unknown-script.conf`, `defaults-local.conf`, `wordpress.conf`) |
| `/etc/fail2ban/filter.d/*.conf` | `modules/5_security/files/fail2ban/filter/` — `nginx-unknown-script`, `nginx-php-url-hack`, `non-wordpress-requests`, `wordpress-auth`, `nginx-limit-req-login` |
| `/etc/fail2ban/action.d/logban.conf`, `nginx-wp.conf` | custom actions |
| `/var/log/fail2ban/fail2ban.log` | daemon log |
| `/var/log/fail2ban/banned-ips.log` | ban ledger written by the `logban` action |

Current DEFAULT: `maxretry = 7`, `findtime = 600`, `bantime = 86400`, with
incremental bans (`factor 2`, `maxtime 4w`, `overalljails = true`). **Incremental
+ overalljails means one bad regex escalates a customer to a 4-week fleet-wide
ban.** That is why fail2ban is T3.

Hard rules for any filter or jail change:

1. **A logged-in editor must never be bannable.** Every new/edited filter needs
   an `ignoreregex` (or authenticated-cookie bypass) covering logged-in traffic,
   present in the diff. An **empty `ignoreregex` is the bug, not a safe default**
   — an empty one on the php filter caused wp-login 404 bans on `bateys`
   (Jul 2026 audit).
2. `nginx-unknown-script` reads `/var/log/nginx/error.log`. On these low-RAM
   hosts, **PHP-FPM socket exhaustion writes error-log lines that look exactly
   like attack traffic.** Never write a filter that bans on FPM-socket-derived
   errors or 404s.
3. Validation command is `fail2ban-regex <logfile> <filter> --print-all-matched`
   against a real log sample — never "looks correct". A brief without this is
   incomplete.
4. Rollout is always: one host via `--limit` → `fail2ban-client status <jail>` →
   confirm zero customer IPs banned → widen.

Context: [docs/FILE2BAN.md](docs/FILE2BAN.md),
[fail2ban-logged-in-users.md](fail2ban-logged-in-users.md),
[docs/fail2ban-stop-loggin-usser-claud.md](docs/fail2ban-stop-loggin-usser-claud.md),
ban snapshots in `docs/al2023-fail2ban-blocked-ips-*.md`, survey script
[bash/list-fail2ban-blocked-ips.sh](bash/list-fail2ban-blocked-ips.sh).

### SSL, WP-CLI, agent

- `/etc/letsencrypt/live/<domain>/fullchain.pem` · `privkey.pem`
- `/etc/letsencrypt/renewal-hooks/post/renewal_script.sh` — post-renewal reload
- `/usr/local/bin/wp` (WP-CLI), `/usr/local/bin/wp-cli.phar`
- resmon agent: binary `/opt/wp-agent/wp-agent`, config `/etc/wp-agent`, state
  `/var/lib/wp-agent`
- Helper scripts installed to `/usr/local/bin/`: `fpm.sh`, `cleanlogs.sh`,
  `auto-block-malicious-php`, `update-geoip-database.sh`

## Inventory and ssh-config wiring

There is **no `ansible.cfg` and no default inventory** — every command carries
`-i inventory/<file>.ini`.

Inventories are **campaign-scoped**, not one global file. Bare hostnames resolve
through the repo's ssh-config:

```ini
[<group>:vars]
ansible_user=ec2-user
ansible_ssh_common_args=-F /Users/meti/Projects/wp-ansible/ssh-config -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/wp-<campaign>-known_hosts
```

Hosts absent from [ssh-config](ssh-config) carry inline connection vars
(`ansible_host=… ansible_ssh_private_key_file=…`). Separate estates use their own
config: `-F /Users/meti/.ssh/ohara/config`.

New inventories follow the house pattern — grouped by **remediation state**
(`_needs_install` / `_needs_upgrade` / verified-skip), with a header recording the
verification date, the exclusions and why, and the exact command:

```ini
# <subset> — <campaign>
# Verified <YYYY-MM-DD>; excludes <host> (<reason>)
#
# Usage:
#   ansible-playbook -i inventory/<name>.ini modules/<n>_<mod>/playbook.yml --limit <group>
```

Standing exclusions: `lwhydraulics`, `figtreesports` (Debian/Bitnami — AL
playbooks will not apply), `shiredb` (database server, no nginx/WordPress).
Validation for any inventory change: `ansible-inventory -i inventory/<f>.ini
--graph`.

**Anchors for this repo.** A dispatch brief names: `PROJECT:`, the module
playbook path, the inventory file **and group**, the deployed target path for
every template touched, and the docroot policy (detected vs. `-e wp_root=`).
"Update the fail2ban config" is anchor-less — log `no_anchors`.

## Running and analyzing — the context contract

`ansible-playbook` across 20 hosts emits tens of thousands of tokens. Under this
project's context-mode rules that output must never enter context.

**Ansible runs in Bash, not the sandbox** — `ctx_execute` has no access to the
SSH keys or ssh-config. So: **run in Bash with output fully redirected to a file,
then analyze the file in the sandbox.**

```bash
RUN=<scratchpad>/run-$(date +%s)
ansible-playbook -i inventory/<f>.ini modules/<m>/playbook.yml \
  --limit <host-or-group> --check --diff > "$RUN.log" 2>&1
echo "exit=$? log=$RUN.log"
```

Only the exit code and path enter context. Do **not** `tee`, do **not** run
unredirected, do **not** `cat` the log. Long fleet runs go
`run_in_background: true` — you are re-invoked on exit, so do not poll.

Analyze with `ctx_execute_file` on the log and print only: the PLAY RECAP per
host, hosts grouped by outcome, and **each distinct failure once** — the same
error across 20 hosts is one finding, not twenty. Then `ctx_index` the summary as
`ansible-run-<module>-<date>` so follow-ups go through `ctx_search` instead of
re-reading.

### Never poll a terminal for playbook output

**Observed failure (2026-07-31, free-coder-north):** asked to run
`fix-shell-rest.yml` over `amazon-linux-2.ini`, the worker issued
`Get last terminal command` followed by **48 consecutive `Read terminal
selection` calls** before finally routing the run through
`ctx_batch_execute`. Every one of those calls returned the same stale selection,
and every one re-sent the whole conversation.

The rule: **a playbook run is one dispatched command, never an observation
loop.** `ansible-playbook` is long-running and produces nothing on the terminal
selection buffer while it runs, so polling it can only spin.

- `Read terminal selection` / `Get last terminal command` / any terminal-scraping
  tool is **never** how you obtain playbook output. If you catch yourself calling
  one twice in a row, stop — the output is not there and will not appear.
- Issue the run as a single `ctx_batch_execute` (or backgrounded Bash) command
  with the queries you need answered attached, then read the artifact file.
  One call in, one summary out.
- **Two identical tool calls returning identical results is a loop.** Third
  attempt is forbidden — hand back `STATUS: needs-input` naming the tool that
  isn't producing output.

### Survey plays must validate what they collected

Same run, second failure — and the expensive one, because nothing flagged it.
The play reported `ok` for 23 of 24 hosts while
[logs/report-nginx-v.log](logs/report-nginx-v.log) recorded
`bash: nginx: command not found` for **every single one**. Cause:
[fix-shell-rest.yml:24-28](modules/1_nginx-php/fix-shell-rest.yml#L24-L28) runs
`raw: nginx -v` with `become: false`, and `/usr/sbin` is not on `ec2-user`'s
`PATH` — then `failed_when: false` swallowed the non-zero exit, so Ansible
called it a success and the report task faithfully wrote the error string as if
it were a version.

- **Use absolute paths in `raw:`/`shell:` fact-gathering.** `raw:` gets no
  `gather_facts`, no login profile, and no PATH guarantees — `/usr/sbin/nginx
  -v`, not `nginx -v`.
- **`failed_when: false` obliges you to assert on the value.** Pair it with a
  `failed_when` on the *content* (e.g. `'nginx version' not in stdout`) or an
  explicit `assert`. Otherwise the play is structurally incapable of failing and
  its green recap means nothing.
- **Acceptance for any survey play is the report file's content, not the PLAY
  RECAP.** Read the artifact and confirm the values are the right *shape* before
  reporting success. "23 hosts reported" is not a result; "23 hosts reported
  `nginx/1.26.x`" is.

Ad-hoc fleet checks use `--tree "$RUN.d"` and read the tree in the sandbox;
`-m setup` unredirected is a context flood. For surveys, prefer the existing
in-repo pattern: a `delegate_to: localhost` task writing a per-host report to
`logs/`, as [modules/1_nginx-php/fix-shell-rest.yml](modules/1_nginx-php/fix-shell-rest.yml)
does for nginx versions. `ANSIBLE_STDOUT_CALLBACK=ansible.posix.json` gives
parseable output but buffers to end-of-play — survey plays only, never long
deploys.

## Execution rules for every run

1. **`--check --diff` first** for anything touching nginx, PHP-FPM, fail2ban, or
   wp-config. If a task cannot run in check mode, say so — do not silently skip
   to live.
2. **`--limit` a single host on the first live run.** Verify, then widen.
3. **Confirm with the user before the un-limited group run.**
4. Reuse before writing: the recurring fixes are already scripted in
   [bash/](bash/) (`apply-elementor-low-ram.sh`, `apply-php-fpm-ondemand.sh`,
   `disable-wp-cron.sh`, `auto-block-malicious-php.sh`, the PHP 8.1→8.3 upgrade
   pair). Prefer shipping an existing script over inlining new shell.
5. Module order is a dependency, not a suggestion: 1_nginx-php → 2_wordpress →
   3_ssl (imports 4_agent unless `install_wp_agent=false`) → 5_security →
   6_cache. Controller-side env vars — `WP_MAINTENANCE_WEBHOOK_TOKEN`,
   `WP_MAINTENANCE_WEBHOOK_URL`, `WP_AGENT_TOKEN` — live on the Semaphore/Ansible
   controller, never on the WP host.

## Reporting

State which hosts succeeded, which changed, which failed and why, and **which
were not attempted** because the run was limited. "Applied to 3 of 22 hosts, 19
pending your go-ahead" is a complete report. Silently widening scope is the one
failure mode this file exists to prevent.
