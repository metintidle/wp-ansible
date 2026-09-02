import type { Page } from "playwright";
import type { AwsAccount } from "./credentials.js";

const SIGN_IN_HOST = "signin.aws.amazon.com";

export async function loginToAws(page: Page, account: AwsAccount): Promise<void> {
  const signInUrl = `https://${account.accountId}.signin.aws.amazon.com/console`;
  console.log(`Opening sign-in for ${account.name} (${account.accountId})…`);

  await page.goto(signInUrl, { waitUntil: "domcontentloaded", timeout: 60000 });

  const usernameInput = page.locator(
    'input[name="username"], input[id="username"], input[type="email"]',
  );
  await usernameInput.waitFor({ state: "visible", timeout: 30000 });
  await usernameInput.fill(account.username);

  const passwordInput = page.locator('input[name="password"], input[type="password"]');
  await passwordInput.waitFor({ state: "visible", timeout: 15000 });
  await passwordInput.fill(account.password);

  const signInButton = page.locator(
    '#signin_button, button[data-testid="sign-in-submit-button"], input[type="submit"]',
  );
  await signInButton.first().click();

  await waitForSignInComplete(page, account);
}

async function waitForSignInComplete(page: Page, account: AwsAccount): Promise<void> {
  const mfaInput = page.locator(
    'input[name="mfaToken"], input[id="mfaToken"], input[placeholder*="MFA"]',
  );

  const deadline = Date.now() + 300000;

  while (Date.now() < deadline) {
    const url = page.url();

    if (url.includes("console.aws.amazon.com") && !url.includes(SIGN_IN_HOST)) {
      console.log(`Signed in to ${account.name}.`);
      return;
    }

    const errorAlert = page.locator(
      ".awsui-alert-type-error, [data-testid='error-message'], .aws-signin-error",
    );
    if (await errorAlert.first().isVisible().catch(() => false)) {
      const text = await errorAlert.first().textContent();
      throw new Error(`Sign-in failed for ${account.name}: ${text?.trim() ?? "unknown error"}`);
    }

    if (await mfaInput.first().isVisible().catch(() => false)) {
      console.log(
        `MFA required for ${account.name}. Complete MFA in the browser (5 min timeout)…`,
      );
      await page.waitForURL(
        (u) => u.hostname.includes("console.aws.amazon.com"),
        { timeout: 300000 },
      );
      console.log(`MFA complete for ${account.name}.`);
      return;
    }

    await page.waitForTimeout(1000);
  }

  throw new Error(`Sign-in timed out for ${account.name}`);
}
