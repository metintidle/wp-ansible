# DreamScape Reseller REST API

- Swagger / method reference: https://doc-reseller-api.ds.network/swagger
- Production API base: `https://reseller-api.ds.network`
- Auth: `Api-Request-Id` (md5, unique per request) and `Api-Signature` = md5(`request_id` + API key). See [integration docs](https://doc-reseller-api.ds.network/#integration_with_dreamscape_reseller_rest_api).

## Credentials in this repo

Store the API key locally in **`aws-cli/dreamscape.env`** (gitignored). Start from [`dreamscape.env.example`](dreamscape.env.example).

Reseller ID is optional for API calls; keep it in the env file for your own reference.

## Corrimal Family Medical (migration)

| Field | Value |
|--------|--------|
| Customer | Shilpa Attri |
| DreamScape username | `corrimalfamilymed` (not the AWS IAM name) |
| Customer ID | `10797825` |
| Domain | `corrimalfamilymedical.com.au` |
| Current DNS (DreamScape) | apex + www → `27.124.125.173` |
| Registrar NS | `ns3.parkme.com.au`, `ns4.parkme.com.au` |

Use `DREAMSCAPE_CUSTOMER_ID` or `DREAMSCAPE_CUSTOMER_QUERY=corrimalfamilymed` in `dreamscape.env`. The SSH/AWS profile alias can stay `corrimalfamilymedical`; it will **not** match DreamScape unless you set the query explicitly.

## Fetch domains + DNS (migration / new Lightsail)

```bash
./aws-cli/dns/dreamscape-fetch.sh list-customers corrimalfamilymed
./aws-cli/dns/dreamscape-fetch.sh fetch

# Lightsail create — dreamscape phase (uses dreamscape.env)
./aws-cli/create/al2023-lightsail-wordpress.sh corrimalfamilymedical corrimalfamilymedical dreamscape

# Or full pipeline (auto DreamScape when dreamscape.env has customer id/query)
./aws-cli/create/al2023-lightsail-wordpress.sh corrimalfamilymedical corrimalfamilymedical all
```

Lightsail create runs DreamScape fetch in the `all` phase when `aws-cli/dreamscape.env` has `DREAMSCAPE_CUSTOMER_ID` or `DREAMSCAPE_CUSTOMER_QUERY` set.
