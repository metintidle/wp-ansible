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

## Generate or renew SSL after DNS is fixed

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
