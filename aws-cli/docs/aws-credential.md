# AWS CLI login profiles (IAM `login_session`)

Part of [`aws-cli/`](../README.md). Run `aws` locally with **AWS CLI v2 `aws login`** and `login_session` profiles in `~/.aws/config`. Console passwords are **not** stored in `~/.aws/credentials`.

Requires **AWS CLI v2.32.0+**. See [aws-credential-issues.md](./aws-credential-issues.md) for troubleshooting.

## Prerequisites

1. **AWS CLI 2.32.0+** — `aws --version`.

2. **IAM user** with console sign-in and the managed policy **`SignInLocalDevelopmentAccess`** attached (once per user — see [issues doc](./aws-credential-issues.md#1-missing-iam-permission-most-likely)).

3. **Optional reference:** Bitwarden export `aws-credentials.json` at repo root (gitignored) with `login.username`, `login.password`, and custom field `account` (12-digit ID). Use it when filling in `setup-profile.sh`; the shell workflow does not read this file automatically.

## One-time setup per account

Add a `login_session` profile with [`auth/setup-profile.sh`](../auth/setup-profile.sh) (backs up existing `~/.aws/config`):

```bash
./aws-cli/auth/setup-profile.sh <ProfileName> <account-id> <iam-username>
# Example:
./aws-cli/auth/setup-profile.sh CamdenSurgery 122610501814 CamdenSurgery
```

Generated block:

```ini
[profile CamdenSurgery]
region = ap-southeast-2
output = json
login_session = arn:aws:iam::122610501814:user/CamdenSurgery
```

Repeat for each Lightsail customer profile. Profile name is usually the IAM username; use a unique name if the same username exists in another account.

## Daily use

### Log in

[`auth/aws-login.sh`](../auth/aws-login.sh) skips login when the session is already valid; otherwise runs `aws login` (browser sign-in):

```bash
./aws-cli/auth/aws-login.sh CamdenSurgery
export AWS_PROFILE=CamdenSurgery
aws sts get-caller-identity
```

Or invoke `aws login --profile <name>` directly. Sessions cache under `~/.aws/login/cache` (short-lived creds with refresh).

### Run AWS commands

```bash
aws lightsail get-instances --profile CamdenSurgery
```

Auto-login wrapper when the session is missing or expired:

```bash
./aws-cli/auth/aws-profile.sh CamdenSurgery lightsail get-instances
```

### Default profile

```bash
export AWS_PROFILE=CamdenSurgery
aws lightsail get-instances
```

### Log out

```bash
aws logout --profile CamdenSurgery
```

## Security notes

- Do **not** commit `aws-credentials.json`.
- Do **not** put static access keys in `~/.aws/credentials` for the same profile names — they override `login_session` and cause `ExpiredToken` / `AccessDenied`.
- `login_session` ARNs in `~/.aws/config` are not secrets.

## Related

- [aws-cli README](../README.md) — layout, migration orchestrator, script index
- [aws-credential-issues.md](./aws-credential-issues.md) — CLI version, policy, static-key conflicts
- [auth/setup-profile.sh](../auth/setup-profile.sh) — add or refresh a profile block
- [auth/aws-login.sh](../auth/aws-login.sh) — ensure active session
- [auth/aws-profile.sh](../auth/aws-profile.sh) — run any `aws` subcommand with auto-login
