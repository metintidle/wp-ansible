import type { Page } from "playwright";

const CLOUDSHELL_READY_TIMEOUT_MS = 180000;
const CREATE_INSTANCE_WAIT_MS = 120000;
const DEFAULT_COMMAND_WAIT_MS = 20000;

export async function openCloudShell(page: Page, region: string): Promise<void> {
  const cloudShellUrl = `https://${region}.console.aws.amazon.com/cloudshell/home?region=${region}`;
  console.log(`Opening CloudShell in ${region}…`);

  await page.goto(cloudShellUrl, { waitUntil: "domcontentloaded", timeout: 120000 });
  await waitForCloudShellTerminal(page);
  console.log("CloudShell terminal ready.");
}

async function waitForCloudShellTerminal(page: Page): Promise<void> {
  const selectors = [
    "textarea.xterm-helper-textarea",
    ".xterm-helper-textarea",
    ".terminal",
    "[data-testid='cloudshell-terminal']",
  ];

  for (const selector of selectors) {
    try {
      await page.locator(selector).first().waitFor({
        state: "visible",
        timeout: CLOUDSHELL_READY_TIMEOUT_MS,
      });
      return;
    } catch {
      // try next selector
    }
  }

  throw new Error(
    "CloudShell terminal did not appear. Check IAM permission AWSCloudShellFullAccess and region.",
  );
}

async function resolveTerminal(page: Page) {
  const textarea = page.locator("textarea.xterm-helper-textarea").first();
  if ((await textarea.count()) > 0) {
    return textarea;
  }
  return page.locator(".terminal, .xterm").first();
}

export async function runCommandsInCloudShell(
  page: Page,
  commands: string[],
): Promise<void> {
  const terminal = await resolveTerminal(page);

  for (let i = 0; i < commands.length; i++) {
    const cmd = commands[i].trim();
    if (!cmd) {
      continue;
    }

    console.log(
      `[${i + 1}/${commands.length}] ${cmd.slice(0, 100)}${cmd.length > 100 ? "…" : ""}`,
    );

    await terminal.click({ timeout: 10000 });
    await page.keyboard.press("Control+C");
    await page.waitForTimeout(300);

    await page.keyboard.insertText(cmd);
    await page.keyboard.press("Enter");

    const waitMs = cmd.includes("create-instances")
      ? CREATE_INSTANCE_WAIT_MS
      : DEFAULT_COMMAND_WAIT_MS;
    await page.waitForTimeout(waitMs);
  }

  console.log("All commands sent to CloudShell.");
}
