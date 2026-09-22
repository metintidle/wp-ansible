# SSL & DNS troubleshooting

Use this guide when Certbot renewal fails with DNS errors (e.g. "no valid A records", "NXDOMAIN", or "no valid AAAA records").

---

## Requirements for Let's Encrypt (Certbot)

Certbot uses **HTTP-01** challenge: Let's Encrypt must reach your server over the internet for each domain. DNS must point to your server **before** obtaining or renewing a certificate.

### Route53 (and other DNS) checklist

| Record type | Purpose |
|-------------|--------|
| **A** | IPv4 — **Required.** Both the root domain and `www` must have A records pointing to your server’s public IPv4 (e.g. EC2 elastic IP). |
| **AAAA** | IPv6 — Optional. Only add if your server has a public IPv6 and is reachable on it. |

- **Root domain:** e.g. `muccshellharbour.com.au` → A (and optionally AAAA) → your server IP.
- **www:** e.g. `www.muccshellharbour.com.au` → A (and optionally AAAA) → same server IP.
- **TTL:** 300 seconds is fine; allow a few minutes for propagation after changes.
- **Delegation:** The domain’s nameservers at your registrar must point to the Route53 hosted zone that contains these records. If they don’t, the world won’t see your A/AAAA records.

---

## Common Certbot DNS errors

| Error | Meaning | Fix |
|-------|--------|-----|
| **no valid A records found** | No IPv4 address for the domain points to a reachable server. | Add/update A records in Route53 for the domain and `www`, then wait for propagation and retry. |
| **no valid AAAA records found** | No IPv6 address (or server not reachable via IPv6). | Either add correct AAAA records if you use IPv6, or rely on A records only; Certbot only needs one working address family. |
| **NXDOMAIN** | The name does not exist in DNS (e.g. missing `www` record or wrong zone). | Create the missing A (and AAAA if needed) record(s) in the correct hosted zone and ensure nameserver delegation is correct. |
| **Site not reachable / timeout** | DNS returns no A record (only SOA) or NXDOMAIN, so the browser cannot get an IP. | Add A records in Route53 for both the root (e.g. `muccshellharbour.com.au`) and `www`, pointing to the server’s public IPv4. Ensure record names match the zone (apex = blank or `@` for root). |

---

## Wrong certificate over IPv6 only (AAAA points at another server)

**Symptom:** HTTPS works for a site over IPv4, but a browser shows **another site's certificate** — usually with that other site's content or a 404. The server itself is healthy: this is a DNS (AAAA) problem, not a certificate problem.

**Cause:** the domain's **AAAA record points at a different server** (typically another customer's). Browsers and tools prefer IPv6, so IPv6-capable visitors reach the wrong host, which has no matching `server_name` and answers with its default (first) vhost certificate. IPv4 visitors reach the right host and see the right certificate.

This happened in this fleet to `gerringonggp.com.au` (and `gfmp.net.au` + their `www`): the AAAA records held the Tongarra Family Practice host `2406:da1c:f1e:dc00:371d:f5a3:741:8281`, so IPv6 visitors were served `tongarrafamilypractice.com`, while the A records (`3.104.213.239`, the Gerringong host) were correct.

**Tooling root cause:** `aws-cli/dns/dns-manage.sh` fell back to hard-coded Tongarra IPs (`IPV4=13.211.239.203`, `IPV6=2406:da1c:f1e:dc00:371d:f5a3:741:8281`) whenever `IPV4` / `IPV6` were empty. Bash `:-` treats an empty value as unset, so a failed Lightsail IPv6 lookup during a migration silently published the wrong AAAA. The script now refuses those defaults for any domain other than `tongarrafamilypractice.com`, and `aws-cli/migrate/migrate-al2-al2023.sh` warns when Lightsail reports no IPv6.

### Diagnose

```bash
# 1) A and AAAA for the domain
dig +short gerringonggp.com.au A
dig +short gerringonggp.com.au AAAA

# 2) Which certificate does the AAAA address serve?
openssl s_client -connect '[2406:da1c:f1e:dc00:371d:f5a3:741:8281]:443' \
  -servername gerringonggp.com.au </dev/null 2>/dev/null | openssl x509 -noout -subject

# 3) On the real host: its own global IPv6, listeners, vhost names
ssh <host> 'ip -6 addr show scope global; sudo ss -lntp | grep -E ":(80|443)"'
ssh <host> "sudo grep -rhE 'server_name' /etc/nginx/ | sort -u"
```

A certificate subject that does not match the domain confirms the AAAA record is wrong. A cert subject matching a *different customer's* domain means IPv6 visitors are on the wrong server entirely.

### Fix

1. Repoint the AAAA record at the host's **own** IPv6 address — or delete it if the host has no usable IPv6 (IPv4-only domains still pass the HTTP-01 challenge).
2. Check the host's IPv6 is reachable **from outside** before repointing. On Lightsail, firewall rules are per address family, so a host can hold an IPv6 address in the OS and still drop all inbound IPv6 traffic:

   ```bash
   # from another IPv6-capable host
   ping6 -c 2 <host-ipv6>
   nc -6 -z -w 5 <host-ipv6> 443 && echo OPEN || echo FILTERED
   ```

3. Wait out the TTL (300s), re-check `dig`, then verify the certificate over IPv6 again.

A host whose IPv6 is filtered or dead is worse than having no AAAA record at all: dual-stack clients wait for a timeout before falling back to IPv4, and IPv6-only clients fail outright.

### Fleet-wide check

Compare every domain's AAAA with the address each host actually holds:

```bash
for d in $(grep -hE '^#[[:space:]]*https?://' ~/.ssh/config | sed -E 's|^#[[:space:]]*https?://||; s|/$||' | sort -u); do
  printf '%-40s AAAA=%s\n' "$d" "$(dig +short "$d" AAAA | tr '\n' ' ')"
done
```

Then confirm each host's own address with `ssh <host> 'ip -6 addr show scope global'`. Records that point at an address no host owns (or at another host's address) cause either the wrong-site/wrong-cert symptom above or silent IPv6 breakage.

---


Once DNS has propagated (A and optionally AAAA point to your server), **on the server** run one of the following.

**Renew existing certificate (or get a new one if validation failed before):**
```bash
sudo certbot renew --nginx --force-renewal
```

**First-time certificate for a domain (or re-issue after DNS fix):**
```bash
sudo certbot --nginx --non-interactive --redirect --agree-tos -d muccshellharbour.com.au -d www.muccshellharbour.com.au
```
(Replace the domain with yours. Use the same email as in [modules/3_ssl/playbook.yml](../modules/3_ssl/playbook.yml) if you prefer consistency.)

Then reload Nginx if Certbot doesn’t do it via hooks:
```bash
sudo systemctl reload nginx
```

**From your machine:** SSH to the server first (use the new IP if you changed it, e.g. `ssh centrehealth2` or `ssh ec2-user@52.63.152.247`), then run the commands above.

---

## Retry renewal after fixing DNS

1. Ensure A (and AAAA if applicable) records in Route53 point to your server and delegation is correct.
2. Wait a few minutes for DNS propagation.
3. On the server, run:

   ```bash
   sudo certbot renew --nginx
   ```

   To force renewal (e.g. to test immediately):

   ```bash
   sudo certbot renew --nginx --force-renewal
   ```

4. Reload Nginx if you run renewal manually (the Certbot post-hook from this project may do it for you):

   ```bash
   sudo systemctl reload nginx
   ```

---

## What if Let's Encrypt has an issue?

Sometimes renewal fails and the cause is unclear. Rule out Let's Encrypt outages and connectivity:

### 1. Check Let's Encrypt status
- **Official status:** [https://letsencrypt.status.io](https://letsencrypt.status.io) — current incidents and history.
- If there is an active incident, wait for it to be resolved and retry renewal; no change on your server is needed.

### 2. Check connectivity from your server
From the server (e.g. over SSH), test that it can reach the ACME API:

```bash
curl -sI --connect-timeout 5 https://acme-v02.api.letsencrypt.org/directory
```

- **HTTP/2 200** (or 200) → Let's Encrypt is reachable; the problem is likely **DNS** (e.g. A/AAAA records or delegation) or **firewall** (port 80 not open from the internet). See [docs/firewall-connectivity-checklist.md](firewall-connectivity-checklist.md).
- **Timeout or connection error** → Outbound HTTPS from the server may be blocked, or Let's Encrypt may be having issues; check the status page.

### 3. Your earlier failure (ssl-error.log)
The failure in [../ssl-error.log](../ssl-error.log) was **DNS** (“no valid A records”, “NXDOMAIN”), not a Let's Encrypt outage. After adding A (and AAAA) records in Route53, the certificate was valid and renewal reported “not yet due for renewal”.

---

## Project links

- **SSL playbook:** [modules/3_ssl/playbook.yml](../modules/3_ssl/playbook.yml) — initial certificate setup and Certbot timer.
- **SSL error log (example):** [../ssl-error.log](../ssl-error.log) — sample Certbot renewal failure log for reference.
- **Main README:** [../README.md](../README.md) — overview and DNS note.

If renewal keeps failing after adding A/AAAA records, check nameserver delegation and that the server’s security group allows HTTP (port 80) from the internet so Let's Encrypt can complete the challenge.
