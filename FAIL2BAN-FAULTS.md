# Fail2ban faults

## Green Connect (`greenfarm`) — 2026-07-09

**IP:** `58.84.94.183` (admin office)

**Symptom:** A site admin could not reach green-connect.com.au after working in wp-admin.

**Cause:** Fail2ban jail `nginx-bad-request` bans any client that triggers three HTTP **400** responses in the nginx access log. While setting up **Google Site Kit**, the PageSpeed Insights check called `/wp-json/google-site-kit/.../pagespeed` and returned **400** three times (mobile, desktop, mobile). Fail2ban treated those as malicious bad requests and blocked the admin IP.

**Why it is a fault:** The filter does not distinguish legitimate wp-admin / plugin API traffic from actual attacks. Google Site Kit can return 400 when PageSpeed data is unavailable or misconfigured — that is an application error, not proof of abuse.

**Fix applied on server:**

1. Unbanned `58.84.94.183`
2. Added the IP to `ignoreip` in `/etc/fail2ban/jail.local`
3. Added `/etc/fail2ban/filter.d/nginx-bad-request.local` to ignore lines matching `/wp-json/google-site-kit/`

**One-line summary (non-technical):** Admin was blocked while setting up Google Site Kit because repeated PageSpeed check failures looked like suspicious traffic to the server.
