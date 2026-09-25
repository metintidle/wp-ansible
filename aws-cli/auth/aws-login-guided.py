#!/usr/bin/env python3
"""Sequential AWS sign-in using credentials from a local Bitwarden JSON export."""

import argparse
import base64
import configparser
import ipaddress
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, parse_qsl, urlsplit

LIGHTSAIL_SSH_CIDR = "20.193.75.72/32"


class LoginError(Exception):
    pass


def profiles_from_config(path):
    config = configparser.ConfigParser(interpolation=None)
    if not config.read(path):
        raise LoginError("AWS config not found.")
    profiles = {}
    for section in config.sections():
        if not section.startswith("profile "):
            continue
        arn = config.get(section, "login_session", fallback="")
        match = re.fullmatch(r"arn:aws:iam::([0-9]{12}):user/(.+)", arn)
        if match:
            profiles[section[8:]] = (match[1], match[2].split("/")[-1], arn)
    return profiles


def select_export_credential(items, account, username):
    matches = []
    for item in items:
        fields = item.get("fields") or []
        accounts = [str(field.get("value") or "").strip() for field in fields
                    if field.get("name", "").lower() == "account"]
        login = item.get("login") or {}
        if account in accounts and (login.get("username") or "").strip() == username:
            matches.append(login)
    if len(matches) != 1:
        raise LoginError("Expected exactly one matching export item; resolve missing or duplicate account/username entries.")
    if not matches[0].get("password"):
        raise LoginError("The matching export item has no password.")
    return {"account": account, "username": username, "password": matches[0]["password"]}


def trusted_url(url, region, authorize=False):
    parsed = urlsplit(url)
    hosts = {"signin.aws.amazon.com", f"{region}.signin.amazonaws.com",
             f"{region}.signin.aws.amazon.com", f"signin.{region}.amazonaws.com"}
    return (parsed.scheme == "https" and parsed.hostname in hosts
            and parsed.port in (None, 443) and not parsed.username and not parsed.password
            and (not authorize or parsed.path in {"/authorize", "/v1/authorize"}))


def credentials_from_export(path, account, username):
    try:
        export = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise LoginError("Cannot read the credentials export; check its path and JSON format.") from None
    if not isinstance(export, dict) or export.get("encrypted") is not False:
        raise LoginError("Expected an unencrypted Bitwarden JSON export; encrypted exports are unsupported.")
    items = export.get("items")
    if not isinstance(items, list):
        raise LoginError("The credentials export has no valid items list.")
    return select_export_credential(items, account, username)


def command_json(arguments, env=None):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True,
                                timeout=45, env=env)
        if result.returncode:
            raise LoginError("AWS CLI command failed; check the local login and profile configuration.")
        return json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        raise LoginError("AWS CLI command unavailable, timed out, or returned invalid JSON.") from None


def aws_environment():
    env = os.environ.copy()
    for name in ("BW_SESSION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
                 "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN", "AWS_PROFILE",
                 "AWS_DEFAULT_PROFILE"):
        env.pop(name, None)
    env.update(AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off", PYTHONUNBUFFERED="1")
    return env


def caller_identity_arn(profile, env):
    identity = command_json(["aws", "sts", "get-caller-identity", "--profile", profile,
                             "--output", "json", "--no-cli-pager"], env)
    return identity.get("Arn")


def profile_is_verified(profile, expected_arn, env):
    try:
        actual_arn = caller_identity_arn(profile, env)
    except LoginError:
        return False
    if actual_arn and actual_arn != expected_arn:
        raise LoginError("AWS identity does not match the configured IAM user; stopping.")
    return actual_arn == expected_arn


def verify_identity(profile, expected_arn, env):
    if caller_identity_arn(profile, env) != expected_arn:
        raise LoginError("AWS identity does not match the configured IAM user; stopping.")


def get_current_lightsail_instance(profile, region, env):
    instance = command_json(["aws", "lightsail", "get-instances", "--profile", profile,
                             "--region", region, "--query", "instances[0]",
                             "--output", "json", "--no-cli-pager"], env)
    if instance is not None and not isinstance(instance, dict):
        raise LoginError("AWS CLI returned an invalid Lightsail instance response.")
    return instance


def add_ssh_ip_to_current_lightsail_instance(profile, region, instance, env):
    instance_name = instance.get("name")
    if not instance_name:
        raise LoginError("The current Lightsail instance has no name.")

    def current_ssh_cidrs():
        response = command_json(["aws", "lightsail", "get-instance-port-states",
                                 "--profile", profile, "--region", region,
                                 "--instance-name", instance_name,
                                 "--output", "json", "--no-cli-pager"], env)
        port_states = response.get("portStates") if isinstance(response, dict) else None
        if not isinstance(port_states, list):
            raise LoginError("AWS CLI returned invalid Lightsail port-state data.")
        return {
            cidr
            for port in port_states
            if port.get("fromPort") == 22 and port.get("toPort") == 22 and port.get("protocol") == "tcp"
            for cidr in (port.get("cidrs") or [])
        }

    approved_ip = ipaddress.ip_interface(LIGHTSAIL_SSH_CIDR).ip
    if any(approved_ip in ipaddress.ip_network(cidr, strict=False)
           for cidr in current_ssh_cidrs()):
        return False

    operation = command_json(["aws", "lightsail", "open-instance-public-ports",
                              "--profile", profile, "--region", region,
                              "--instance-name", instance_name,
                              "--port-info", f"fromPort=22,toPort=22,protocol=tcp,cidrs={LIGHTSAIL_SSH_CIDR}",
                              "--output", "json", "--no-cli-pager"], env)
    operation_details = operation.get("operation") if isinstance(operation, dict) else None
    if not isinstance(operation_details, dict) or operation_details.get("status") != "Succeeded":
        raise LoginError("Lightsail did not confirm the SSH port update.")
    if LIGHTSAIL_SSH_CIDR not in current_ssh_cidrs():
        raise LoginError("The SSH IP was not present after the Lightsail firewall update.")
    return True


def read_characters(stream, output):
    try:
        while True:
            character = stream.read(1)
            if not character:
                break
            output.put(character)
    finally:
        output.put(None)


def wait_for_output(output, predicate, timeout=60):
    deadline = time.monotonic() + timeout
    buffer = ""
    while time.monotonic() < deadline:
        try:
            character = output.get(timeout=min(1, max(0.01, deadline - time.monotonic())))
        except queue.Empty:
            continue
        if character is None:
            raise LoginError("AWS login ended before the expected prompt.")
        buffer = (buffer + character)[-16384:]
        found = predicate(buffer)
        if found:
            return found
    raise LoginError("Timed out waiting for AWS login.")


def authorization_url(text):
    match = re.search(r"https://[^\s\x1b]+(?=\s)", text)
    return match.group(0) if match else None


def fill_fields(page, credentials, region, timeout=180, headless=False):
    selectors = {
        "account": 'input#account, input[name="account"], input#accountId, input[name="accountId"], input#resolving_input',
        "username": 'input#username, input[name="username"]',
        "password": 'input#password, input[name="password"]',
    }
    deadline = time.monotonic() + timeout
    filled = set()
    continue_clicked = False
    if headless:
        print("Autofill ready. Headless sign-in cannot complete manual AWS consent screens.")
    else:
        print("Autofill ready. AWS sign-in will advance; complete any consent screen in the browser.")
    while time.monotonic() < deadline:
        if page.is_closed():
            raise LoginError("Login browser was closed.")
        if trusted_url(page.url, region):
            continue_buttons = page.locator('button[data-testid="btn-sign-in"]')
            if continue_buttons.count() == 1:
                button = continue_buttons.first
                if button.is_visible():
                    label = page_operation("reading the AWS continuation button", lambda: button.get_attribute("aria-label"))
                    text = page_operation("reading the AWS continuation button", lambda: " ".join(button.inner_text().split()))
                    if label != "Continue to sign in" or text != "Continue to sign in":
                        raise LoginError("Unexpected AWS sign-in continuation button; refusing to click it.")
                    if not continue_clicked:
                        page_operation("continuing to AWS sign-in", lambda:
                            button.click(timeout=15000, no_wait_after=True))
                        continue_clicked = True
                        page.wait_for_timeout(250)
                        continue
            for field, selector in selectors.items():
                elements = page.locator(selector)
                for index in range(elements.count()):
                    element = elements.nth(index)
                    if element.is_visible() and element.is_editable():
                        current = page_operation(f"reading AWS {field} field", element.input_value)
                        if current and field != "password" and current.strip() != credentials[field]:
                            raise LoginError("The browser shows a different account or username; cancel and check the selected profile.")
                        if not current:
                            page_operation(f"filling AWS {field} field", lambda:
                                element.fill(credentials[field], timeout=15000))
                        filled.add(field)
            if {"username", "password"} <= filled:
                sign_in_buttons = page.locator('button#signin_button[data-testid="sign-in"]')
                if sign_in_buttons.count() == 1:
                    button = sign_in_buttons.first
                    if button.is_visible() and button.is_enabled():
                        label = page_operation("reading the AWS sign-in button", lambda: " ".join(button.inner_text().split()))
                        button_type = page_operation("reading the AWS sign-in button", lambda: button.get_attribute("type"))
                        if button_type != "submit" or label != "Sign in":
                            raise LoginError("Unexpected AWS sign-in submit button; refusing to click it.")
                        page_operation("submitting the verified AWS sign-in form", lambda:
                            button.click(timeout=15000, no_wait_after=True))
                        return
        page.wait_for_timeout(500)
    raise LoginError("AWS sign-in form did not match the expected handoff; no credentials were submitted.")


def page_operation(operation, callback):
    try:
        return callback()
    except Exception as error:
        error_type = type(error)
        name = f"{error_type.__module__}.{error_type.__name__}"
        raise LoginError(f"Unexpected failure while {operation} ({name}); details suppressed.") from None


def verification_code_from_page(page, expected_state, region, timeout=60):
    if not trusted_url(page.url, region):
        raise LoginError("Refusing to read a verification code outside the trusted AWS sign-in page.")

    copied = False
    revealed = False
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        closed = page_operation("checking the AWS sign-in page", page.is_closed)
        current_url = page_operation("checking the AWS sign-in address", lambda: page.url)
        if closed or not trusted_url(current_url, region):
            raise LoginError("AWS sign-in page closed or changed origin before code capture.")
        if not copied:
            copy_button = page_operation("finding the verification-code copy button", lambda:
                page.locator('button[aria-label="Copy verification code"][title="Copy verification code"]'))
            copy_button_count = page_operation("checking the verification-code copy button", copy_button.count)
            if copy_button_count > 1:
                raise LoginError("Multiple verification-code copy buttons found; refusing to choose one.")
            if copy_button_count == 1:
                button = copy_button.first
                details = page_operation("checking the verification-code copy button", lambda: (
                    button.is_visible(), button.is_enabled(), button.get_attribute("aria-label"),
                    button.get_attribute("title"), button.get_attribute("type")))
                if details != (True, True, "Copy verification code", "Copy verification code", "button"):
                    raise LoginError("Unexpected AWS verification-code copy button; refusing to click it.")
                parsed_url = urlsplit(current_url)
                origin = f"{parsed_url.scheme}://{parsed_url.netloc}"
                page_operation("granting scoped clipboard access", lambda:
                    page.context.grant_permissions(["clipboard-read", "clipboard-write"], origin=origin))
                page_operation("copying the verification code", lambda: button.click(timeout=3000))
                copied = True
            elif not revealed:
                reveal = page_operation("finding the verification-code reveal control",
                                        lambda: page.get_by_text("Show the full verification code", exact=True))
                if page_operation("checking the verification-code reveal control", reveal.count) == 1 and \
                        page_operation("checking verification-code reveal visibility", reveal.first.is_visible):
                    page_operation("revealing the verification code", lambda: reveal.first.click(timeout=3000))
                    revealed = True
                    page_operation("waiting for the verification code", lambda: page.wait_for_timeout(250))
                    continue
        if copied:
            values = [page_operation("reading the copied verification code", lambda:
                page.evaluate("() => navigator.clipboard.readText()"))]
        elif revealed:
            text_values = page_operation("reading visible verification-code text", lambda:
                page.locator("body *").evaluate_all("""elements => elements
                    .filter(element => element.childElementCount === 0 &&
                        element.getClientRects().length > 0 &&
                        getComputedStyle(element).visibility !== 'hidden')
                    .map(element => element.innerText || element.textContent || '')"""))
            field_values = page_operation("reading verification-code fields", lambda:
                page.locator("input, textarea").evaluate_all("""elements => elements
                    .filter(element => element.getClientRects().length > 0)
                    .map(element => element.value || '')"""))
            values = [*text_values, *field_values]
        else:
            page_operation("waiting for the verification code", lambda: page.wait_for_timeout(250))
            continue
        codes = set()
        for value in values:
            candidate = re.sub(r"\s+", "", value)
            if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", candidate):
                continue
            try:
                payload = base64.b64decode(candidate).decode("utf-8")
            except (ValueError, UnicodeDecodeError):
                continue
            parameters = dict(parse_qsl(payload, keep_blank_values=True))
            if parameters.get("state") == expected_state and parameters.get("code"):
                codes.add(candidate)
        if len(codes) == 1:
            return codes.pop()
        if len(codes) > 1:
            raise LoginError("Multiple verification codes matched this login; refusing to choose one.")
        page_operation("waiting for the verification code", lambda: page.wait_for_timeout(250))
    raise LoginError("No verification code matching this login was found on the AWS page.")


def login_profile(profile, expected, credentials, region, playwright, headless=True):
    env = aws_environment()
    process = subprocess.Popen(["aws", "login", "--remote", "--profile", profile,
                                "--region", region, "--no-cli-pager"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, env=env)
    output = queue.Queue()
    reader = threading.Thread(target=read_characters, args=(process.stdout, output), daemon=True)
    reader.start()
    browser = None
    stage = "waiting for the AWS authorization URL"
    try:
        url = wait_for_output(output, authorization_url)
        if not trusted_url(url, region, authorize=True):
            raise LoginError("AWS returned an unexpected authorization URL; refusing to open it.")
        expected_state = parse_qs(urlsplit(url).query).get("state", [None])[0]
        if not expected_state:
            raise LoginError("AWS authorization URL omitted its state; refusing to continue.")
        browser_env = {key: value for key, value in env.items()
                       if not key.startswith(("AWS_", "BW_"))}
        stage = "launching the isolated browser"
        browser = playwright.chromium.launch(headless=headless, env=browser_env)
        context = browser.new_context()
        page = context.new_page()
        stage = "opening the trusted AWS sign-in page"
        page.goto(url, wait_until="domcontentloaded", timeout=60000)
        stage = "autofilling and submitting the verified AWS sign-in form"
        fill_fields(page, credentials, region, headless=headless)
        stage = "waiting for AWS to display its verification code"
        wait_for_output(output, lambda text: re.search(r"authorization code[^\n]*:", text, re.I))
        stage = "extracting and validating the verification code"
        verification_code = verification_code_from_page(page, expected_state, region)
        stage = "forwarding the verification code to AWS CLI"
        process.stdin.write(verification_code + "\n")
        process.stdin.flush()
        verification_code = None
        process.stdin.close()
        if process.wait(timeout=60):
            raise LoginError("AWS login did not complete. No profile-overwrite prompt was approved.")
        stage = "verifying the resulting AWS identity"
        verify_identity(profile, expected[2], env)
        print(f"Verified: {profile}")
    except LoginError:
        raise
    except Exception as error:
        raise LoginError(f"Unexpected failure while {stage} ({type(error).__name__}); details suppressed.") from None
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        reader.join(timeout=2)
        process.stdout.close()
        if not process.stdin.closed:
            process.stdin.close()
        if browser:
            browser.close()


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profiles", nargs="*", help="Ordered profile names; omit for interactive selection")
    parser.add_argument("--list", action="store_true", help="List supported profiles without reading the export or contacting AWS")
    default_export = os.environ.get(
        "AWS_CREDENTIALS_FILE",
        str(Path(__file__).resolve().parents[2] / "aws_credentials.json"),
    )
    parser.add_argument("--credentials-file", type=Path, default=Path(default_export).expanduser(),
                        help="Bitwarden JSON export path (default: AWS_CREDENTIALS_FILE or repo aws_credentials.json)")
    parser.add_argument("--check-export", action="store_true", help="Check unique export matches without opening a browser or logging in")
    parser.add_argument("--region", default="ap-southeast-2")
    browser_mode = parser.add_mutually_exclusive_group()
    browser_mode.add_argument("--headless", dest="headless", action="store_true",
                              help="Run without a visible browser (default)")
    browser_mode.add_argument("--headed", dest="headless", action="store_false",
                              help="Show the browser for manual AWS consent screens")
    parser.set_defaults(headless=True)
    return parser


def main():
    args = build_parser().parse_args()
    if not re.fullmatch(r"[a-z]{2}-[a-z]+-[0-9]+", args.region):
        raise LoginError("Unsupported AWS region format.")
    config_path = Path(os.environ.get("AWS_CONFIG_FILE", "~/.aws/config")).expanduser()
    profiles = profiles_from_config(config_path)
    names = list(profiles)
    if args.list or not args.profiles:
        for index, name in enumerate(names, 1):
            print(f"{index}. {name}")
    if args.list:
        return
    selected = args.profiles
    if not selected:
        if not sys.stdin.isatty():
            raise LoginError("Run profile selection in an interactive terminal.")
        choices = input("Select profile numbers in order, separated by spaces: ").split()
        if not choices or any(not choice.isdigit() or not 1 <= int(choice) <= len(names) for choice in choices):
            raise LoginError("Invalid profile selection.")
        selected = [names[int(choice) - 1] for choice in choices]
    selected = list(dict.fromkeys(selected))
    if any(name not in profiles for name in selected):
        raise LoginError("Unknown profile or unsupported login_session; only configured IAM users are supported.")
    if args.check_export:
        for name in selected:
            credential = credentials_from_export(args.credentials_file, *profiles[name][:2])
            credential.clear()
            print(f"Unique export match: {name}")
        return
    env = aws_environment()
    login_names = []
    for name in selected:
        if profile_is_verified(name, profiles[name][2], env):
            print(f"Already verified: {name}")
        else:
            login_names.append(name)
    if login_names:
        if not sys.stdin.isatty():
            raise LoginError("Run sign-in in an interactive terminal; authorization codes must not pass through an agent.")
        from playwright.sync_api import sync_playwright
        with sync_playwright() as playwright:
            for name in login_names:
                credential = credentials_from_export(args.credentials_file, *profiles[name][:2])
                try:
                    print(f"Signing in: {name}")
                    login_profile(name, profiles[name], credential, args.region, playwright, headless=args.headless)
                finally:
                    credential.clear()

    for name in selected:
        instance = get_current_lightsail_instance(name, args.region, env)
        if instance is None:
            print(f"No Lightsail instances found: {name}")
            continue
        details = {
            "name": instance.get("name"),
            "publicIpAddress": instance.get("publicIpAddress"),
            "state": (instance.get("state") or {}).get("name"),
            "blueprintName": instance.get("blueprintName"),
            "bundleId": instance.get("bundleId"),
            "availabilityZone": instance.get("availabilityZone"),
            "createdAt": instance.get("createdAt"),
        }
        print(f"First Lightsail instance for {name}:")
        print(json.dumps(details, indent=2))
        added = add_ssh_ip_to_current_lightsail_instance(name, args.region, instance, env)
        if added:
            print(f"Added {LIGHTSAIL_SSH_CIDR} to SSH port 22 for {instance['name']}.")
        else:
            print(f"SSH port 22 already allows {LIGHTSAIL_SSH_CIDR} for {instance['name']}.")


if __name__ == "__main__":
    try:
        main()
    except LoginError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        sys.exit(130)
    except Exception:
        print("ERROR: Login helper failed; details suppressed to avoid leaking credentials or authorization URLs.", file=sys.stderr)
        sys.exit(1)