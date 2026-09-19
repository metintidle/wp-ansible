#!/usr/bin/env python3
"""DreamScape Reseller REST API — domains and DNS for Lightsail migration planning.

Auth: Api-Request-Id (md5) + Api-Signature = md5(request_id + api_key).
Docs: https://doc-reseller-api.ds.network/
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Dict, Iterator, List, Optional


DEFAULT_BASE = "https://reseller-api.ds.network"


def md5_hex(data: str) -> str:
    return hashlib.md5(data.encode("utf-8")).hexdigest()


class DreamscapeClient:
    def __init__(self, api_key: str, base_url: str = DEFAULT_BASE) -> None:
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")

    def request(self, method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        request_id = md5_hex(f"{uuid.uuid4()}{time.time()}")
        signature = md5_hex(request_id + self.api_key)
        headers = {
            "Accept": "application/json",
            "Api-Request-Id": request_id,
            "Api-Signature": signature,
        }
        data = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(body).encode("utf-8")

        url = self.base_url + path
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=90) as resp:
                raw = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {exc.code} {path}: {detail}") from exc

        payload = json.loads(raw)
        if not payload.get("status", True):
            raise RuntimeError(payload.get("error_message") or f"API error on {path}")
        return payload

    def get(self, path: str) -> Dict[str, Any]:
        return self.request("GET", path)

    def paginate(self, path: str, params: Optional[Dict[str, Any]] = None) -> Iterator[Dict[str, Any]]:
        page = 1
        params = dict(params or {})
        while True:
            q = dict(params)
            q["page"] = page
            query = urllib.parse.urlencode(q, doseq=True)
            payload = self.get(f"{path}?{query}")
            items = payload.get("data") or []
            if not isinstance(items, list):
                raise RuntimeError(f"Unexpected data shape on {path}")
            for item in items:
                yield item
            pagination = payload.get("pagination") or {}
            total_pages = int(pagination.get("total_pages") or 1)
            if page >= total_pages:
                break
            page += 1


def customer_blob(customer: Dict[str, Any]) -> str:
    parts = [
        str(customer.get("id", "")),
        str(customer.get("username", "")),
        str(customer.get("email", "")),
        str(customer.get("business_name", "")),
        str(customer.get("first_name", "")),
        str(customer.get("last_name", "")),
    ]
    return " ".join(parts).lower()


def find_customers(client: DreamscapeClient, query: str) -> List[Dict[str, Any]]:
    q = query.strip().lower()
    if not q:
        return []
    exact: List[Dict[str, Any]] = []
    partial: List[Dict[str, Any]] = []
    for customer in client.paginate("/customers"):
        username = str(customer.get("username", "")).lower()
        if username == q:
            exact.append(customer)
            continue
        if q in customer_blob(customer):
            partial.append(customer)
    return exact or partial


def list_domains_for_customer(client: DreamscapeClient, customer_id: int) -> List[Dict[str, Any]]:
    domains: List[Dict[str, Any]] = []
    for domain in client.paginate("/domains", {"customer_id": customer_id}):
        domain_id = domain["id"]
        dns_payload = client.get(f"/domains/{domain_id}/dns")
        domain["dns_records"] = dns_payload.get("data") or []
        domains.append(domain)
    return domains


def format_dns_line(domain_name: str, record: Dict[str, Any]) -> str:
    rtype = record.get("type", "?")
    sub = record.get("subdomain") or ""
    name = domain_name if not sub else f"{sub}.{domain_name}"
    content = record.get("content", "")
    if rtype == "MX" and record.get("priority") is not None:
        return f"  {rtype:6} {name:40} {record['priority']} {content}"
    return f"  {rtype:6} {name:40} {content}"


def cmd_list_customers(client: DreamscapeClient, query: str) -> int:
    matches = find_customers(client, query) if query else list(client.paginate("/customers"))
    for c in matches:
        print(
            f"{c.get('id')}\t{c.get('username')}\t{c.get('email')}\t{c.get('business_name') or ''}"
        )
    return 0


def cmd_fetch(
    client: DreamscapeClient,
    customer_id: Optional[int],
    customer_query: Optional[str],
    json_out: Optional[str],
    domains_out: Optional[str],
) -> int:
    customer: Optional[Dict[str, Any]] = None
    if customer_id is not None:
        for c in client.paginate("/customers"):
            if int(c.get("id", 0)) == customer_id:
                customer = c
                break
        if customer is None:
            raise RuntimeError(f"No customer with id {customer_id}")
    else:
        if not customer_query:
            raise RuntimeError("Set --customer-id or --customer-query")
        matches = find_customers(client, customer_query)
        if not matches:
            raise RuntimeError(f"No DreamScape customer matched query: {customer_query}")
        if len(matches) > 1:
            lines = [f"  {m.get('id')}: {m.get('username')} <{m.get('email')}>" for m in matches]
            raise RuntimeError(
                "Multiple customers matched; set DREAMSCAPE_CUSTOMER_ID:\n" + "\n".join(lines)
            )
        customer = matches[0]

    cid = int(customer["id"])
    domains = list_domains_for_customer(client, cid)
    export = {
        "customer": {
            "id": cid,
            "username": customer.get("username"),
            "email": customer.get("email"),
            "business_name": customer.get("business_name"),
        },
        "domains": domains,
    }

    if json_out:
        with open(json_out, "w", encoding="utf-8") as fh:
            json.dump(export, fh, indent=2)
            fh.write("\n")

    apex_domains = sorted({str(d.get("domain_name", "")).lower() for d in domains if d.get("domain_name")})
    if domains_out:
        with open(domains_out, "w", encoding="utf-8") as fh:
            for name in apex_domains:
                fh.write(f"{name}\n")

    label = customer.get("username") or customer.get("email") or cid
    print(f"DreamScape customer {label} (id={cid}): {len(domains)} domain(s)")
    for d in domains:
        name = d.get("domain_name", "?")
        print(f"\n{name}  (id={d.get('id')}, status_id={d.get('status_id')})")
        ns = d.get("name_servers") or []
        if ns:
            print("  NS (registrar):")
            for entry in ns:
                host = entry.get("host", "")
                print(f"    {host}")
        records = d.get("dns_records") or []
        if records:
            print("  DNS:")
            for rec in records:
                print(format_dns_line(name, rec))
        else:
            print("  DNS: (none)")

    if json_out:
        print(f"\nWrote {json_out}")
    if domains_out:
        print(f"Wrote apex list {domains_out}")

    if not apex_domains:
        print("WARNING: no domains for this customer", file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="DreamScape Reseller API — domains and DNS")
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list-customers", help="Search customers (or list all if query empty)")
    p_list.add_argument("query", nargs="?", default="")

    p_fetch = sub.add_parser("fetch", help="Fetch domains + DNS for one customer")
    p_fetch.add_argument("--customer-id", type=int, default=None)
    p_fetch.add_argument("--customer-query", default=None)
    p_fetch.add_argument("--json-out", default=None)
    p_fetch.add_argument("--domains-out", default=None)

    args = parser.parse_args()
    api_key = os.environ.get("DREAMSCAPE_API_KEY", "").strip()
    if not api_key:
        print("ERROR: set DREAMSCAPE_API_KEY (see aws-cli/dreamscape.env.example)", file=sys.stderr)
        return 1
    base = os.environ.get("DREAMSCAPE_API_BASE", DEFAULT_BASE).strip() or DEFAULT_BASE
    client = DreamscapeClient(api_key, base)

    try:
        if args.command == "list-customers":
            return cmd_list_customers(client, args.query)
        if args.command == "fetch":
            return cmd_fetch(
                client,
                args.customer_id,
                args.customer_query,
                args.json_out,
                args.domains_out,
            )
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
