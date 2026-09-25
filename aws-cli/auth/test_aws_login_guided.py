import importlib.util
import base64
import json
import pathlib
import queue
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sync_playwright = None


spec = importlib.util.spec_from_file_location("guided", pathlib.Path(__file__).with_name("aws-login-guided.py"))
guided = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guided)


class GuidedLoginTests(unittest.TestCase):
    def item(self, account="123456789012", username="Example"):
        return {"fields": [{"name": "account", "value": account}],
                "login": {"username": username, "password": "test-only"}}

    def test_matching_uses_account_and_username(self):
        result = guided.select_export_credential([self.item("000000000000"), self.item()], "123456789012", "Example")
        self.assertEqual(result["username"], "Example")

    def test_duplicate_and_missing_matches_fail(self):
        for items in ([], [self.item(), self.item()], [self.item(username="Other")]):
            with self.assertRaises(guided.LoginError):
                guided.select_export_credential(items, "123456789012", "Example")

    def test_loads_account_username_password_from_export(self):
        export = {"encrypted": False, "items": [self.item()]}
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
            json.dump(export, handle)
            handle.flush()
            result = guided.credentials_from_export(handle.name, "123456789012", "Example")
        self.assertEqual(result["password"], "test-only")

    def test_rejects_encrypted_or_invalid_export(self):
        for export in ({"encrypted": True, "items": [self.item()]},
                       {"encrypted": False, "items": "invalid"}):
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
                json.dump(export, handle)
                handle.flush()
                with self.assertRaises(guided.LoginError):
                    guided.credentials_from_export(handle.name, "123456789012", "Example")

    def test_whitespace_does_not_change_password(self):
        item = self.item(" 123456789012", " Example ")
        item["login"]["password"] = " secret with spaces "
        self.assertEqual(guided.select_export_credential([item], "123456789012", "Example")["password"], " secret with spaces ")

    def test_url_allowlist(self):
        region = "ap-southeast-2"
        self.assertTrue(guided.trusted_url(f"https://{region}.signin.amazonaws.com/authorize?state=test", region, True))
        self.assertTrue(guided.trusted_url(f"https://{region}.signin.aws.amazon.com/v1/authorize?state=test", region, True))
        self.assertTrue(guided.trusted_url(f"https://signin.{region}.amazonaws.com/authorize?state=test", region, True))
        for url in ("http://signin.aws.amazon.com/authorize", "https://signin.aws.amazon.com.evil.test/authorize",
                    "https://evil.test/authorize", "https://signin.aws.amazon.com:444/authorize",
                    "https://user@signin.aws.amazon.com/authorize", "https://signin.aws.amazon.com/signin"):
            self.assertFalse(guided.trusted_url(url, region, True))

    def test_browser_mode_defaults_to_headless_with_headed_override(self):
        parser = guided.build_parser()
        self.assertTrue(parser.parse_args(["Example"]).headless)
        self.assertTrue(parser.parse_args(["Example", "--headless"]).headless)
        self.assertFalse(parser.parse_args(["Example", "--headed"]).headless)

    def test_output_url_requires_terminator(self):
        output = queue.Queue()
        for character in "Open https://signin.ap-southeast-2.amazonaws.com/authorize?state=test\n":
            output.put(character)
        self.assertEqual(guided.wait_for_output(output, guided.authorization_url),
                         "https://signin.ap-southeast-2.amazonaws.com/authorize?state=test")

    def test_eof_fails_closed(self):
        output = queue.Queue()
        output.put(None)
        with self.assertRaises(guided.LoginError):
            guided.wait_for_output(output, guided.authorization_url)

    def test_identity_mismatch_fails(self):
        response = SimpleNamespace(returncode=0, stdout='{"Arn": "wrong"}')
        with patch.object(guided.subprocess, "run", return_value=response):
            with self.assertRaises(guided.LoginError):
                guided.verify_identity("Example", "expected", {})

    def test_profile_is_verified_only_for_exact_configured_arn(self):
        with patch.object(guided, "caller_identity_arn", return_value="expected"):
            self.assertTrue(guided.profile_is_verified("Example", "expected", {}))
        with patch.object(guided, "caller_identity_arn", return_value=None):
            self.assertFalse(guided.profile_is_verified("Example", "expected", {}))
        with patch.object(guided, "caller_identity_arn", return_value="wrong"):
            with self.assertRaises(guided.LoginError):
                guided.profile_is_verified("Example", "expected", {})

    def test_get_current_lightsail_instance_returns_first_instance(self):
        instance = {"name": "first", "state": {"name": "running"}}
        with patch.object(guided, "command_json", return_value=instance) as command:
            result = guided.get_current_lightsail_instance("Example", "ap-southeast-2", {})
        self.assertEqual(result, instance)
        self.assertIn("instances[0]", command.call_args.args[0])
        self.assertIn("--region", command.call_args.args[0])

    def test_get_current_lightsail_instance_handles_empty_account(self):
        with patch.object(guided, "command_json", return_value=None):
            self.assertIsNone(guided.get_current_lightsail_instance("Example", "ap-southeast-2", {}))

    def test_add_ssh_ip_to_current_instance_opens_and_verifies_rule(self):
        existing = {"portStates": [{"fromPort": 22, "toPort": 22, "protocol": "tcp",
                                    "cidrs": ["198.51.100.1/32"]}]}
        updated = {"portStates": [{"fromPort": 22, "toPort": 22, "protocol": "tcp",
                                   "cidrs": ["198.51.100.1/32", guided.LIGHTSAIL_SSH_CIDR]}]}
        with patch.object(guided, "command_json", side_effect=[existing,
                {"operation": {"status": "Succeeded"}}, updated]) as command:
            added = guided.add_ssh_ip_to_current_lightsail_instance(
                "Example", "ap-southeast-2", {"name": "instance-1"}, {})
        self.assertTrue(added)
        open_command = command.call_args_list[1].args[0]
        self.assertIn("open-instance-public-ports", open_command)
        self.assertIn(f"fromPort=22,toPort=22,protocol=tcp,cidrs={guided.LIGHTSAIL_SSH_CIDR}", open_command)

    def test_add_ssh_ip_to_current_instance_is_idempotent(self):
        current = {"portStates": [{"fromPort": 22, "toPort": 22, "protocol": "tcp",
                                   "cidrs": [guided.LIGHTSAIL_SSH_CIDR]}]}
        with patch.object(guided, "command_json", return_value=current) as command:
            added = guided.add_ssh_ip_to_current_lightsail_instance(
                "Example", "ap-southeast-2", {"name": "instance-1"}, {})
        self.assertFalse(added)
        command.assert_called_once()

    def test_main_skips_credentials_and_browser_when_profile_is_verified(self):
        with patch.object(guided.sys, "argv", ["aws-login-guided.py", "Example"]), \
                patch.object(guided.sys, "stdin", SimpleNamespace(isatty=lambda: False)), \
                patch.object(guided, "aws_environment", return_value={"safe": True}), \
                patch.object(guided, "profiles_from_config", return_value={
                    "Example": ("123456789012", "Example", "expected")}), \
                patch.object(guided, "profile_is_verified", return_value=True), \
                patch.object(guided, "credentials_from_export", side_effect=AssertionError), \
                patch.object(guided, "get_current_lightsail_instance", return_value={"name": "instance-1"}) as get_instance, \
                patch.object(guided, "add_ssh_ip_to_current_lightsail_instance", return_value=False) as add_ip:
            guided.main()
        get_instance.assert_called_once_with("Example", "ap-southeast-2", {"safe": True})
        add_ip.assert_called_once_with("Example", "ap-southeast-2", {"name": "instance-1"}, {"safe": True})

    def test_reads_copied_code_from_exact_aws_button(self):
        auth_code = "short-code"
        code = base64.b64encode(f"state=expected-state&code={auth_code}".encode()).decode("ascii")

        class Context:
            def grant_permissions(self, permissions, origin=None):
                self.granted = (permissions, origin)

        class Page:
            url = "https://ap-southeast-2.signin.aws.amazon.com/signin"

            def __init__(self):
                self.context = Context()
                self.clipboard = ""
                self.button = Button(self)

            def locator(self, selector):
                if selector == 'button[aria-label="Copy verification code"][title="Copy verification code"]':
                    return self.button
                raise AssertionError("DOM scan should not run when the copy button is present")

            def get_by_text(self, *_args, **_kwargs):
                return SimpleNamespace(count=lambda: 0)

            def evaluate(self, _script):
                return self.clipboard

            def is_closed(self):
                return False

            def wait_for_timeout(self, _timeout):
                pass

        class Button:
            def __init__(self, page):
                self.page = page
                self.clicks = 0

            @property
            def first(self):
                return self

            def count(self):
                self.count_calls = getattr(self, "count_calls", 0) + 1
                return 0 if self.count_calls == 1 else 1

            def is_visible(self):
                return True

            def is_enabled(self):
                return True

            def get_attribute(self, name):
                return {"aria-label": "Copy verification code", "title": "Copy verification code",
                        "type": "button"}[name]

            def click(self, timeout):
                self.clicks += 1
                self.page.clipboard = code

        page = Page()
        result = guided.verification_code_from_page(page, "expected-state", "ap-southeast-2", timeout=1)
        self.assertEqual(result, code)
        self.assertEqual(page.button.clicks, 1)
        self.assertEqual(page.context.granted,
                 (["clipboard-read", "clipboard-write"], "https://ap-southeast-2.signin.aws.amazon.com"))

    def test_local_secret_environment_not_forwarded_to_aws(self):
        with patch.dict(guided.os.environ, {"BW_SESSION": "secret", "AWS_ACCESS_KEY_ID": "key"}):
            env = guided.aws_environment()
        self.assertNotIn("BW_SESSION", env)
        self.assertNotIn("AWS_ACCESS_KEY_ID", env)

    def test_full_cli_exchange_with_mock_login(self):
        from unittest.mock import MagicMock
        factory = subprocess.Popen
        process_holder = []
        verification_code = base64.b64encode(b"state=test&code=mock-auth-code").decode("ascii")

        def start_mock(*arguments, **options):
            program = (
                "import sys; "
                "print('https://signin.ap-southeast-2.amazonaws.com/authorize?state=test', flush=True); "
                "code=input('Enter the authorization code displayed in your browser: '); "
                f"sys.exit(0 if code == {verification_code!r} else 1)"
            )
            process = factory([sys.executable, "-u", "-c", program], **options)
            process_holder.append(process)
            return process

        browser_api = MagicMock()
        with patch.object(guided.subprocess, "Popen", side_effect=start_mock), \
                patch.object(guided, "fill_fields"), \
                patch.object(guided, "verification_code_from_page", return_value=verification_code) as get_code, \
                patch.object(guided, "verify_identity") as verify:
            guided.login_profile("Example", ("123456789012", "Example", "expected"),
                                 {}, "ap-southeast-2", browser_api)
            verify.assert_called_once()
            get_code.assert_called_once_with(browser_api.chromium.launch.return_value.new_context.return_value.new_page.return_value,
                                             "test", "ap-southeast-2")
        self.assertEqual(process_holder[0].returncode, 0)
        browser_api.chromium.launch.return_value.close.assert_called_once()
        self.assertTrue(browser_api.chromium.launch.call_args.kwargs["headless"])

    def test_headless_browser_is_opt_in(self):
        from unittest.mock import MagicMock
        process = MagicMock()
        process.poll.return_value = 0
        process.stdout.read.return_value = ""
        process.stdin.closed = True
        browser_api = MagicMock()
        url = "https://signin.ap-southeast-2.amazonaws.com/authorize?state=test"
        with patch.object(guided.subprocess, "Popen", return_value=process), \
                patch.object(guided, "wait_for_output", side_effect=[url, guided.LoginError("stop")]), \
                patch.object(guided, "fill_fields") as fill:
            with self.assertRaises(guided.LoginError):
                guided.login_profile("Example", ("123456789012", "Example", "expected"),
                                     {}, "ap-southeast-2", browser_api, headless=True)
        self.assertTrue(browser_api.chromium.launch.call_args.kwargs["headless"])
        self.assertTrue(fill.call_args.kwargs["headless"])

    def test_unexpected_browser_error_reports_stage_not_details(self):
        from unittest.mock import MagicMock
        factory = subprocess.Popen

        def start_mock(*arguments, **options):
            program = "print('https://signin.ap-southeast-2.amazonaws.com/authorize?state=test', flush=True); input()"
            return factory([sys.executable, "-u", "-c", program], **options)

        with patch.object(guided.subprocess, "Popen", side_effect=start_mock), \
                patch.object(guided, "fill_fields", side_effect=RuntimeError("sensitive browser detail")):
            with self.assertRaises(guided.LoginError) as raised:
                guided.login_profile("Example", ("123456789012", "Example", "expected"),
                                     {}, "ap-southeast-2", MagicMock())
        self.assertIn("autofilling and submitting", str(raised.exception))
        self.assertIn("RuntimeError", str(raised.exception))
        self.assertNotIn("sensitive browser detail", str(raised.exception))

    def test_sign_in_click_does_not_wait_for_navigation(self):
        credentials = {"account": "123456789012", "username": "Example", "password": "test-only"}

        class Field:
            def __init__(self):
                self.value = ""

            def is_visible(self):
                return True

            def is_editable(self):
                return True

            def input_value(self):
                return self.value

            def fill(self, value, timeout):
                self.value = value
                self.timeout = timeout

        class Button:
            def is_visible(self):
                return True

            def is_enabled(self):
                return True

            def inner_text(self):
                return "Sign in"

            def get_attribute(self, name):
                return "submit" if name == "type" else None

            def click(self, **options):
                self.options = options
                if not options.get("no_wait_after"):
                    raise TimeoutError("navigation was slow")

        class Page:
            url = "https://ap-southeast-2.signin.aws.amazon.com/signin"

            def __init__(self):
                self.fields = {name: Field() for name in credentials}
                self.button = Button()

            def is_closed(self):
                return False

            def locator(self, selector):
                if selector == 'button[data-testid="btn-sign-in"]':
                    return SimpleNamespace(count=lambda: 0)
                if selector == 'button#signin_button[data-testid="sign-in"]':
                    return SimpleNamespace(count=lambda: 1, first=self.button)
                for name, field in self.fields.items():
                    if f"input#{name}" in selector:
                        return SimpleNamespace(count=lambda: 1, nth=lambda index: field)
                raise AssertionError("Unexpected selector")

        page = Page()
        guided.fill_fields(page, credentials, "ap-southeast-2", timeout=2)
        self.assertEqual(page.button.options, {"timeout": 15000, "no_wait_after": True})
        self.assertEqual({name: field.value for name, field in page.fields.items()}, credentials)
        self.assertTrue(all(field.timeout == 15000 for field in page.fields.values()))


@unittest.skipUnless(sync_playwright, "Install auth/requirements.txt and Chromium for browser tests")
class BrowserAutofillTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(headless=True)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def test_fills_and_submits_exact_aws_sign_in_button(self):
        context = self.browser.new_context()
        try:
            html = '''<form><input id="account"><input id="username"><input id="password" type="password"><button id="signin_button" data-testid="sign-in" type="submit">Sign in</button></form>
<script>document.querySelector('form').addEventListener('submit', event => { event.preventDefault(); window.didSignIn = true; });</script>'''
            context.route("**/*", lambda route: route.fulfill(content_type="text/html", body=html))
            page = context.new_page()
            page.goto("https://ap-southeast-2.signin.aws.amazon.com/signin")
            credentials = {"account": "123456789012", "username": "Example", "password": "test-only"}
            guided.fill_fields(page, credentials, "ap-southeast-2", timeout=2)
            self.assertTrue(page.evaluate("window.didSignIn"))
            for field, value in credentials.items():
                self.assertEqual(page.locator(f"#{field}").input_value(), value)
        finally:
            context.close()

    def test_clicks_only_the_named_aws_continue_button(self):
        context = self.browser.new_context()
        try:
            html = """<button data-testid="btn-sign-in" aria-label="Continue to sign in" type="submit">Continue to sign in</button>
<script>document.body.addEventListener('click', event => {
const button = event.target.closest('button'); if (!button) return; event.preventDefault();
if (button.dataset.testid === 'btn-sign-in') { window.didContinue = true;
document.body.innerHTML = '<form><input id="account"><input id="username"><input id="password" type="password"><button id="signin_button" data-testid="sign-in" type="submit">Sign in</button></form>'; }
else if (button.dataset.testid === 'sign-in') { window.didSignIn = true; }
});</script>"""
            context.route("**/*", lambda route: route.fulfill(content_type="text/html", body=html))
            page = context.new_page()
            page.goto("https://ap-southeast-2.signin.aws.amazon.com/signin")
            credentials = {"account": "123456789012", "username": "Example", "password": "test-only"}
            guided.fill_fields(page, credentials, "ap-southeast-2", timeout=2)
            self.assertTrue(page.evaluate("window.didContinue"))
            self.assertTrue(page.evaluate("window.didSignIn"))
            for field, value in credentials.items():
                self.assertEqual(page.locator(f"#{field}").input_value(), value)
        finally:
            context.close()

    def test_reads_and_reveals_verification_code_with_matching_state(self):
        auth_code = "mock-auth-code-" + "x" * 100
        code = base64.b64encode(f"state=expected-state&code={auth_code}".encode()).decode("ascii")
        html = f'''<button id="reveal">Show the full verification code</button>
<pre id="verification" style="display:none">{code}</pre>
<script>document.querySelector('#reveal').addEventListener('click', () => {{ document.querySelector('#verification').style.display = 'block'; }});</script>'''
        context = self.browser.new_context()
        try:
            context.route("**/*", lambda route: route.fulfill(content_type="text/html", body=html))
            page = context.new_page()
            page.goto("https://ap-southeast-2.signin.aws.amazon.com/signin")
            result = guided.verification_code_from_page(page, "expected-state", "ap-southeast-2", timeout=2)
            self.assertEqual(result, code)
        finally:
            context.close()

    def test_copies_verification_code_from_exact_aws_button(self):
        auth_code = "mock-auth-code-" + "x" * 100
        code = base64.b64encode(f"state=expected-state&code={auth_code}".encode()).decode("ascii")
        html = f'''<button aria-label="Copy verification code" title="Copy verification code" type="button">Copy verification code</button>
<script>document.querySelector('button').addEventListener('click', () => navigator.clipboard.writeText('{code}'));</script>'''
        context = self.browser.new_context()
        try:
            context.route("**/*", lambda route: route.fulfill(content_type="text/html", body=html))
            page = context.new_page()
            page.goto("https://ap-southeast-2.signin.aws.amazon.com/signin")
            result = guided.verification_code_from_page(page, "expected-state", "ap-southeast-2", timeout=2)
            self.assertEqual(result, code)
        finally:
            context.close()

    def test_rejects_verification_code_for_different_login_state(self):
        auth_code = "mock-auth-code-" + "x" * 100
        code = base64.b64encode(f"state=other-state&code={auth_code}".encode()).decode("ascii")
        context = self.browser.new_context()
        try:
            context.route("**/*", lambda route: route.fulfill(
                content_type="text/html", body=f'<button>Show the full verification code</button><pre>{code}</pre>'))
            page = context.new_page()
            page.goto("https://ap-southeast-2.signin.aws.amazon.com/signin")
            with self.assertRaises(guided.LoginError):
                guided.verification_code_from_page(page, "expected-state", "ap-southeast-2", timeout=0.25)
        finally:
            context.close()

    def test_verification_page_error_identifies_operation_without_details(self):
        class BrokenLocator:
            def evaluate_all(self, _script):
                raise RuntimeError("sensitive browser detail")

        class Page:
            url = "https://ap-southeast-2.signin.aws.amazon.com/signin"

            def get_by_text(self, *_args, **_kwargs):
                return SimpleNamespace(count=lambda: 1, first=SimpleNamespace(
                    is_visible=lambda: True, click=lambda timeout: None))

            def is_closed(self):
                return False

            def locator(self, selector):
                if selector.startswith("button["):
                    return SimpleNamespace(count=lambda: 0)
                return BrokenLocator()

            def wait_for_timeout(self, _timeout):
                pass

        with self.assertRaises(guided.LoginError) as raised:
            guided.verification_code_from_page(Page(), "expected-state", "ap-southeast-2", timeout=1)
        self.assertIn("reading visible verification-code text", str(raised.exception))
        self.assertIn("builtins.RuntimeError", str(raised.exception))
        self.assertNotIn("sensitive browser detail", str(raised.exception))

    def test_prefilled_wrong_account_stops_before_password(self):
        context = self.browser.new_context()
        try:
            context.route("**/*", lambda route: route.fulfill(
                content_type="text/html", body='<input id="account" value="000000000000"><input id="username"><input id="password">'))
            page = context.new_page()
            page.goto("https://ap-southeast-2.signin.aws.amazon.com/signin")
            with self.assertRaises(guided.LoginError):
                guided.fill_fields(page, {"account": "123456789012", "username": "Example", "password": "test-only"},
                                   "ap-southeast-2", timeout=2)
            self.assertEqual(page.locator("#password").input_value(), "")
        finally:
            context.close()

    def test_untrusted_page_receives_no_credentials(self):
        context = self.browser.new_context()
        try:
            context.route("**/*", lambda route: route.fulfill(
                content_type="text/html", body='<input id="account"><input id="username"><input id="password">'))
            page = context.new_page()
            page.goto("https://untrusted.example/signin")
            with self.assertRaises(guided.LoginError):
                guided.fill_fields(page, {"account": "123456789012", "username": "Example", "password": "test-only"},
                                   "ap-southeast-2", timeout=0.1)
            self.assertEqual(page.locator("#password").input_value(), "")
        finally:
            context.close()


if __name__ == "__main__":
    unittest.main()