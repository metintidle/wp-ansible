# Firewall & connectivity checklist

Use this when debugging "can't reach the server", SSL renewal failures, or blocking issues.

---

## On the server (SSH in and run)

### 1. Host firewall

- **firewalld:** `sudo systemctl status firewalld`
- **iptables:** `sudo iptables -L -n`
- **nftables:** `sudo nft list ruleset`
- **UFW:** `sudo ufw status`

If none are active, filtering is done only at **AWS Security Group** (and Nginx).

### 2. Listening ports

```bash
sudo ss -tlnp
```

Expect at least:

- **22** — SSH
- **80** — HTTP (Nginx, needed for Certbot)
- **443** — HTTPS (Nginx)

### 3. Local HTTP/HTTPS

```bash
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/
curl -sk -o /dev/null -w "%{http_code}" https://127.0.0.1/
```

Non-5xx means Nginx is responding locally; if the site is unreachable from the internet, the issue is usually **Security Group** or **DNS**.

### 4. Nginx security (rate limits / deny)

- Rate limiting: `sudo grep -r limit_req /etc/nginx/`
- Deny rules: `sudo grep -r 'deny\|allow' /etc/nginx/` (e.g. `deny all` for `.user.ini` is normal)

### 5. Optional: Fail2Ban / CrowdSec

- Fail2Ban: `sudo systemctl status fail2ban`
- CrowdSec: `sudo systemctl status crowdsec`

If not installed, see [modules/4_security/](../modules/4_security/) and [docs/FILE2BAN.md](FILE2BAN.md).

---

## AWS (console)

### Security group

- **Inbound:** Allow **22** (SSH), **80** (HTTP), **443** (HTTPS) from the right sources (e.g. 0.0.0.0/0 for 80/443 if the site is public).
- **Certbot:** Let's Encrypt must reach **port 80** from the internet; ensure an inbound rule allows that (e.g. 0.0.0.0/0 on 80).

See [CLAUDE.md](../CLAUDE.md) for required ports (including FTP if used).

---

## After changing the server's public IP

When you attach a **new Elastic IP** (or a new instance) and point the domain to it:

1. **Route53** — Update **A** records to the new IPv4 (e.g. `52.63.152.247`) and **AAAA** records to the new IPv6 (e.g. `2406:da1c:c73:da00:db86:28a2:3298:4c58`) for the root domain and `www`. Wait a few minutes for TTL (e.g. 300 s).
2. **SSH / Ansible** — If you use a host alias (e.g. `centrehealth2`) or an inventory file with the old IP, update:
   - **~/.ssh/config** — `Host centrehealth2` → `Hostname 52.63.152.247` (or your new IPv4).
   - **Ansible inventory** (e.g. `hosts`) — use the new IPv4 for that host.
3. **Security group** — Rules are attached to the instance; no change needed unless you moved to a new instance (then attach the same or a new group with 22, 80, 443).
4. **SSL** — Certificates are for the **domain**, not the IP. No Certbot re-issue needed. Future renewals will validate via the new IP once DNS points there.
5. **Verify** — Open `https://yourdomain.com/` and run `sudo certbot renew --nginx --dry-run` if you want to confirm renewal will work.

---

## Project links

- [CLAUDE.md](../CLAUDE.md) — Prerequisites, security groups, ports
- [README.md](../README.md) — FTP ports
- [docs/ssl-dns-troubleshooting.md](ssl-dns-troubleshooting.md) — DNS and Certbot
- [modules/4_security/](../modules/4_security/) — Fail2Ban, CrowdSec, strict whitelist
