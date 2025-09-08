Create three new behaviors (ordered above the default)

A) /wp-admin/*  (no cache, forward everything)
	•	Behaviors → Create behavior
	•	Path pattern: /wp-admin/*
	•	Origin: your origin (same as default)
	•	Viewer protocol policy: Redirect HTTP to HTTPS
	•	Allowed HTTP methods: GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE
	•	Cache policy: Managed-CachingDisabled
	•	Origin request policy: Managed-AllViewerExceptHostHeader
	•	Response headers policy: (optional) none
	•	Compress objects automatically: Yes
	•	Function associations/Lambdas: none

Reason: the dashboard needs cookies/headers and must not be cached, otherwise jquery.js and core admin assets get blocked/misordered.

⸻

B) /wp-includes/*  (cache OK, must keep query strings)
	•	Create behavior
	•	Path pattern: /wp-includes/*
	•	Viewer protocol policy: Redirect HTTP to HTTPS
	•	Allowed methods: GET, HEAD, OPTIONS
	•	Cache policy:
Choose Managed-UseOriginCacheControlHeaders-QueryStrings (if available in your account).
If you don’t see that, click Create cache policy and set:
	•	Name: UseOrigin-QueryStrings
	•	Include query strings in cache key: All
	•	Include cookies in cache key: None
	•	Include headers in cache key: None
	•	Leave TTLs to “use origin Cache-Control”
	•	Origin request policy: Managed-AllViewerExceptHostHeader
	•	Compress objects automatically: Yes

Reason: WP appends ?ver=... to core files; stripping query strings often causes “jQuery is not defined.”

⸻

C) /wp-content/*  (cache OK, must keep query strings)
	•	Create behavior
	•	Path pattern: /wp-content/*
	•	Viewer protocol policy: Redirect HTTP to HTTPS
	•	Allowed methods: GET, HEAD, OPTIONS
	•	Cache policy: same as (B) — UseOrigin…QueryStrings (or the custom one you created)
	•	Origin request policy: Managed-AllViewerExceptHostHeader
	•	Compress objects automatically: Yes

Reason: themes/plugins also rely on query strings for cache-busting.

⸻

2) Edit the Default (*) behavior
	•	Keep it for everything else (front-end pages).
	•	Viewer protocol policy: Redirect HTTP to HTTPS
	•	Allowed methods: GET, HEAD, OPTIONS (or add POST if you have forms that post to uncached URLs under /)
	•	Cache policy: You can keep UseOriginCacheControlHeaders, but if your pages vary by query string, switch to the same …QueryStrings policy you used above.
	•	Origin request policy: Managed-AllViewerExceptHostHeader
	•	Compress objects automatically: Yes

The warning in your screenshot says your current cache policy doesn’t include query strings. That’s the key change.

⸻

3) Order matters

After saving, drag the new behaviors above the default so the match order is:
	1.	/wp-admin/*
	2.	/wp-includes/*
	3.	/wp-content/*
	4.	Default (*)

⸻

4) Invalidate cache

CloudFront → Invalidations → Create invalidation → /*

⸻
