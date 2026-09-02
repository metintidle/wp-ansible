# auto-aws — Playwright AWS Console + CloudShell bot

Automates **IAM console sign-in** and runs Lightsail commands in **CloudShell** using credentials from `aws-credentials.json` (Bitwarden export).

This avoids creating access keys on your Mac. It uses browser automation instead — fragile if AWS changes the sign-in UI, and slower than CLI profiles for 20+ accounts.

## Prerequisites

- Node.js 20+
- Chromium (installed via `npm install` postinstall hook)
- `aws-credentials.json` at repo root (already gitignored)
- IAM user permissions: **AWSCloudShellFullAccess** + Lightsail create/manage

## Setup

```bash
cd auto-aws
npm install
cp config.example.json config.json   # optional — edit instance name, bundle, SSH IPs
```

## List accounts

```bash
npm run list
```

## Login only (test credentials / MFA)

```bash
npm run login -- --account BetterHealthQuarter --pause
```

## Provision one account (CloudShell + aws-command.sh)

```bash
npm run provision -- --account 178795223049 --pause
```

Uses `../aws-command.sh` by default. `--pause` keeps the browser open until you press Enter.

## Provision all accounts (batch)

```bash
npm run provision -- --all --pause
```

Runs sequentially. Each account uses a separate browser profile under `auto-aws/profiles/<account-id>/` so repeat runs may skip re-login.

## Options

| Flag | Description |
|------|-------------|
| `--account <query>` | Match account ID, username, or name (partial) |
| `--all` | Run every account in the vault export |
| `--headed` | Show browser (default) |
| `--headless` | Headless mode (MFA will fail) |
| `--pause` | Wait for Enter before closing browser |
| `--built-in` | Use built-in Lightsail commands from `config.json` instead of `aws-command.sh` |
| `--credentials <path>` | Path to Bitwarden JSON export |
| `--slow-mo <ms>` | Slow down Playwright actions |

## What it does

1. Opens `https://<account-id>.signin.aws.amazon.com/console`
2. Fills IAM username + password from vault
3. Waits for MFA if prompted (complete in browser — up to 5 minutes)
4. Opens CloudShell in `ap-southeast-2` (from config)
5. Types each command from `aws-command.sh` into the terminal

## Files

| Path | Purpose |
|------|---------|
| `src/index.ts` | CLI entry |
| `src/aws-login.ts` | Console sign-in |
| `src/cloudshell.ts` | CloudShell terminal automation |
| `src/credentials.ts` | Parse Bitwarden export |
| `src/config.ts` | Region, bundle, firewall IPs |
| `config.example.json` | Copy to `config.json` to customize |
| `profiles/` | Per-account browser sessions (gitignored) |
| `logs/` | Error screenshots (gitignored) |

## Limitations

- **MFA**: Headed mode only; you complete MFA manually in the browser.
- **CloudShell UI**: Terminal selectors may break if AWS updates the console.
- **Duplicate runs**: `create-instances` fails if the instance name already exists.
- **Security**: Browser profiles and vault file contain secrets — never commit them.
- **Better long-term**: Create access keys once per account and use `aws configure --profile` + local `bash aws-command.sh` with `AWS_PROFILE`.

## Security

- `aws-credentials.json` and `auto-aws/profiles/` must stay out of git.
- Prefer access keys or IAM Identity Center for production automation over console password bots.
