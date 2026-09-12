# AWS CLI login profiles (IAM users from Bitwarden vault)

Part of [`aws-cli/`](../README.md). This workflow lets you run any `aws` command locally using **console IAM credentials** from `aws-credentials.json` (Bitwarden export). Passwords stay in the vault file; they are **not** written to `~/.aws/credentials`.

Requires **AWS CLI v2.32.0+** with the `aws login` command. See [aws-credential-issues.md](./aws-credential-issues.md) for troubleshooting.

## Prerequisites

1. **Bitwarden export** at repo root: `aws-credentials.json` (gitignored). Each item needs:
   - `login.username` — IAM username
   - `login.password` — console password
   - custom field `account` — 12-digit AWS account ID

2. **AWS CLI 2.32.0+** — run `aws --version`.

3. **Node.js** — for `auto-aws` Playwright automation:
   ```bash
   cd auto-aws && npm install
   ```

## One-time setup

### 1. Sync profiles to `~/.aws/config`

Generates named profiles with `login_session` ARNs (no static access keys):

```bash
cd auto-aws
npm run sync-config
```

Each profile looks like:

```ini
[profile TongarraFamilyPractice]
region = ap-southeast-2
output = json
login_session = arn:aws:iam::285964549210:user/TongarraFamilyPractice
```

Profile name = trimmed IAM username. If two accounts share a username, the name is suffixed with the account ID.

Existing `~/.aws/config` is backed up with a timestamp before changes.

### 2. Bootstrap `SignInLocalDevelopmentAccess` (once per account)

`aws login` requires the managed policy **SignInLocalDevelopmentAccess** on the IAM user you sign in as. Run once per account:

```bash
npm run bootstrap -- --account TongarraFamilyPractice
```

This console-logs in via Playwright, opens CloudShell, checks `list-attached-user-policies`, and attaches the policy if missing. Pauses for MFA if prompted.

If bootstrap fails with `AccessDenied`, an admin must attach the policy manually.

## Daily use

### Log in

```bash
npm run cli-login -- --account TongarraFamilyPractice
```

This ensures the profile exists, runs `aws login --profile <name> --remote`, opens the authorize URL in Playwright, fills account ID + IAM username + password from the vault, completes OAuth consent, and submits the authorization code. Sessions are cached in `~/.aws/login/cache` (15-minute creds, auto-refresh up to 12 hours).

### Run AWS commands

```bash
aws sts get-caller-identity --profile TongarraFamilyPractice
aws lightsail get-instances --profile TongarraFamilyPractice
```

Or use the wrapper (auto `cli-login` when the session is missing or expired):

```bash
./aws-cli/auth/aws-profile.sh TongarraFamilyPractice lightsail get-instances
```

### Default profile

```bash
export AWS_PROFILE=TongarraFamilyPractice
aws lightsail get-instances
```

### Log out

```bash
aws logout --profile TongarraFamilyPractice
```

## Security notes

- Do **not** commit `aws-credentials.json`.
- Do **not** put console passwords or access keys in `~/.aws/credentials` for these profiles.
- `login_session` values in `~/.aws/config` are identity ARNs, not secrets.

## Related

- [aws-cli README](../README.md) — layout, migration orchestrator, script index
- [aws-credential-issues.md](./aws-credential-issues.md) — CLI version, policy, static-key conflicts
- [auto-aws/README.md](../../auto-aws/README.md) — console login, CloudShell provision/migrate
- [auth/setup-profile.sh](../auth/setup-profile.sh) — add a `login_session` profile without npm
- [auth/aws-login.sh](../auth/aws-login.sh) — `aws login --profile` wrapper
- [auth/aws-profile.sh](../auth/aws-profile.sh) — run any `aws` command with auto-login
