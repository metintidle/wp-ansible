# AWS CLI `aws login` troubleshooting

Part of [`aws-cli/`](../README.md). Common reasons `aws login` or the [aws-credential.md](./aws-credential.md) workflow fails, and how to fix them.

## 1. Missing IAM permission (most likely)

Console access alone is not enough. AWS requires the **`SignInLocalDevelopmentAccess`** managed policy on the IAM user used for CLI login.

**Fix (manual):** In IAM → Users → your IAM user → Add permissions → attach **SignInLocalDevelopmentAccess** (`arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess`).

Without this policy, OAuth authorization fails with access denied when the CLI requests temporary credentials.

## 2. Outdated AWS CLI

`aws login` requires **AWS CLI v2.32.0 or higher**.

```bash
aws --version
```

Older versions report `invalid choice: 'login'`. Install the latest AWS CLI v2 from AWS.

## 3. Conflicting static credentials

If `~/.aws/credentials` contains `aws_access_key_id` / `aws_secret_access_key` blocks for the same profile names, the CLI may prefer static keys over the login session. That causes `ExpiredToken` or `AccessDenied`.

**Fix:** Remove those profile blocks from `~/.aws/credentials`. This workflow uses `login_session` in `~/.aws/config` only.

## 4. Incomplete profile configuration

Profiles need `login_session` in `~/.aws/config`:

```ini
[profile TongarraFamilyPractice]
region = ap-southeast-2
output = json
login_session = arn:aws:iam::YOUR_ACCOUNT_ID:user/YOUR_IAM_USERNAME
```

**Fix:** Run [`auth/setup-profile.sh`](../auth/setup-profile.sh) with profile name, account ID, and IAM username (see [aws-credential.md](./aws-credential.md)).

## 5. Headless or remote environments

On a server without a browser, use remote login:

```bash
aws login --remote --profile YOUR_PROFILE
# Open URL on a machine with a browser, sign in, paste authorization code
```

Local workstations can use [`auth/aws-login.sh`](../auth/aws-login.sh) (standard `aws login` opens the default browser).

## Checklist

1. AWS CLI **v2.32.0+**
2. **`SignInLocalDevelopmentAccess`** on the IAM user
3. No conflicting static keys in `~/.aws/credentials` for these profiles
4. `login_session` profiles in `~/.aws/config` ([`setup-profile.sh`](../auth/setup-profile.sh))
5. Active session ([`aws-login.sh`](../auth/aws-login.sh) or [`aws-profile.sh`](../auth/aws-profile.sh))

## Wrapper auto-login

[`aws-profile.sh`](../auth/aws-profile.sh) runs [`aws-login.sh`](../auth/aws-login.sh) when `aws sts get-caller-identity --profile X` fails, then executes the requested AWS command.

See [aws-cli README](../README.md) and [aws-credential.md](./aws-credential.md).
