# Guided AWS profile login

This opt-in helper processes selected IAM-user profiles sequentially. The existing
`aws-login.sh` helper is unchanged. No firewall operations are performed.

## Setup

Requires AWS CLI 2.32 or later and Python 3.10+.
The IAM user needs AWS's `SignInLocalDevelopmentAccess` managed policy (or
equivalent permissions), including permission for remote authentication.

```bash
python3 -m venv "$HOME/.local/share/wp-ansible/aws-login-venv"
source "$HOME/.local/share/wp-ansible/aws-login-venv/bin/activate"
python -m pip install -r aws-cli/auth/requirements.txt
python -m playwright install chromium
```

The helper reads an unencrypted Bitwarden JSON export. Keep that file local,
restrict its permissions, and never send passwords or authorization codes to an
agent. The default is the repo-root `aws_credentials.json`; override it with
`--credentials-file` or `AWS_CREDENTIALS_FILE`.

```bash
chmod 600 aws_credentials.json
```

Export items must have a custom field named `account` holding the 12-digit AWS
account ID, plus a login username and password. Matching uses account ID and
username, not the item title. Duplicate matches stop the sequence; resolve them
in Bitwarden before continuing.

## Run from the repository root

```bash
source "$HOME/.local/share/wp-ansible/aws-login-venv/bin/activate"
python aws-cli/auth/aws-login-guided.py --list
python aws-cli/auth/aws-login-guided.py --check-export BerkeleyHotel
python aws-cli/auth/aws-login-guided.py BerkeleyHotel CamelliaHotel
```

Use `--credentials-file /path/to/export.json` if the export is outside the repo.
`--check-export` reports only whether each profile has one match; it never prints
credentials or contacts AWS.

Omit profile arguments for a numbered multi-selection prompt. Profiles come
from `AWS_CONFIG_FILE` or `~/.aws/config`; only IAM-user `login_session` ARNs
are supported. Use `--region` to override the Sydney default.

For each profile the helper runs `aws login --remote --profile ...`, opens the
fresh authorization URL in a separate, non-persistent Chromium context, and
fills account, username, and password on allowlisted AWS sign-in origins only.
It clicks only the AWS continuation button whose test ID and accessible label
are exactly `btn-sign-in` and `Continue to sign in`, then submits the credential
form only through `button#signin_button[data-testid="sign-in"]` with the exact
label `Sign in`, after checking the account and username. Approve any consent
screen yourself. When AWS displays its verification code, the helper reveals
and reads it locally, verifies its embedded state against this login attempt,
and sends it directly to the waiting CLI. The code is never printed or prompted
for in the terminal. The helper then requires `sts get-caller-identity` to
match the configured IAM-user ARN before continuing.

The helper never approves profile-identity overwrite prompts. If the browser
shows the wrong account, cancel rather than authorizing it. Any failed profile
stops the sequence; rerun explicitly for remaining profiles. Ctrl-C terminates
the pending CLI login and closes the browser. Completed sessions remain cached
by the AWS CLI; this is not a logout operation.

No screenshots, traces, or persistent browser profiles are created. Passwords
remain in process memory during autofill; Python cannot guarantee memory
zeroization. AWS stores temporary session tokens in its normal login cache.
The helper does not modify the export. Keep it excluded from Git and remove it
when no longer required. Its contents are plaintext while stored and parsed.

Form selectors are conservative and may need updates if AWS changes its pages.
If AWS changes these exact button selectors or labels, the helper fails closed
without submitting credentials. Consent remains manual; verification-code
capture is automatic and bound to the active login state.
The current AWS site and real credentials have not been exercised by tests.

## Verification

```bash
python -m unittest discover -s aws-cli/auth -p 'test_aws_login_guided.py' -v
```

Tests use fake export records, a simulated CLI exchange, and intercepted browser
pages. They do not contact AWS or read the real export. Browser tests require Playwright
and Chromium; without Playwright they are explicitly skipped.

The unencrypted `aws_credentials.json` export is ignored by Git, but ignoring a
file does not encrypt it or remove prior history. Rotate credentials exposed in
chat or elsewhere, and remove the plaintext export when no longer required.