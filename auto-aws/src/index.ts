import { mkdirSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { chromium } from "playwright";
import { loginToAws } from "./aws-login.js";
import { openCloudShell, runCommandsInCloudShell } from "./cloudshell.js";
import {
  buildLightsailCommands,
  getAutoAwsRoot,
  loadConfig,
  loadCommandsFromScript,
  type ProvisionConfig,
} from "./config.js";
import { findAccount, loadCredentials, type AwsAccount } from "./credentials.js";

interface CliOptions {
  credentialsPath: string;
  headed: boolean;
  slowMo: number;
  accountQuery?: string;
  all: boolean;
  useScript: boolean;
  pauseBeforeClose: boolean;
}

function parseArgs(argv: string[]): { command: string; options: CliOptions } {
  const options: CliOptions = {
    credentialsPath: resolve(getAutoAwsRoot(), "../aws-credentials.json"),
    headed: true,
    slowMo: 0,
    all: false,
    useScript: true,
    pauseBeforeClose: false,
  };

  let command = "provision";

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];

    if (arg === "list" || arg === "login" || arg === "provision") {
      command = arg;
      continue;
    }

    if (arg === "--headed") {
      options.headed = true;
      continue;
    }

    if (arg === "--headless") {
      options.headed = false;
      continue;
    }

    if (arg === "--all") {
      options.all = true;
      continue;
    }

    if (arg === "--built-in") {
      options.useScript = false;
      continue;
    }

    if (arg === "--pause") {
      options.pauseBeforeClose = true;
      continue;
    }

    if (arg === "--credentials" && argv[i + 1]) {
      options.credentialsPath = resolve(argv[++i]);
      continue;
    }

    if (arg === "--account" && argv[i + 1]) {
      options.accountQuery = argv[++i];
      continue;
    }

    if (arg === "--slow-mo" && argv[i + 1]) {
      options.slowMo = Number(argv[++i]);
      continue;
    }
  }

  return { command, options };
}

function selectAccounts(accounts: AwsAccount[], options: CliOptions): AwsAccount[] {
  if (options.all) {
    return accounts;
  }

  if (options.accountQuery) {
    const match = findAccount(accounts, options.accountQuery);
    if (!match) {
      throw new Error(`No account matched "${options.accountQuery}"`);
    }
    return [match];
  }

  throw new Error(
    "Specify --account <name|account-id|username> or --all for batch runs.",
  );
}

function getCommands(config: ProvisionConfig, useScript: boolean): string[] {
  if (useScript) {
    return loadCommandsFromScript(config.commandScript);
  }
  return buildLightsailCommands(config);
}

async function runForAccount(
  account: AwsAccount,
  config: ProvisionConfig,
  options: CliOptions,
  mode: "login" | "provision",
): Promise<void> {
  const logsDir = resolve(getAutoAwsRoot(), "logs");
  if (!existsSync(logsDir)) {
    mkdirSync(logsDir, { recursive: true });
  }

  const profileDir = resolve(getAutoAwsRoot(), "profiles", account.accountId);
  if (!existsSync(profileDir)) {
    mkdirSync(profileDir, { recursive: true });
  }

  const browser = await chromium.launchPersistentContext(profileDir, {
    headless: !options.headed,
    slowMo: options.slowMo,
    viewport: { width: 1400, height: 900 },
    locale: "en-AU",
  });

  const page = browser.pages()[0] ?? (await browser.newPage());

  try {
    await loginToAws(page, account);

    if (mode === "login") {
      console.log(`Login-only complete for ${account.name}.`);
      if (options.pauseBeforeClose) {
        console.log("Press Enter in this terminal when done inspecting the browser…");
        await new Promise<void>((resolve) => {
          process.stdin.once("data", () => resolve());
        });
      }
      return;
    }

    await openCloudShell(page, config.region);
    const commands = getCommands(config, options.useScript);
    await runCommandsInCloudShell(page, commands);

    if (options.pauseBeforeClose) {
      console.log("Commands sent. Inspect CloudShell output, then press Enter to close…");
      await new Promise<void>((resolve) => {
        process.stdin.once("data", () => resolve());
      });
    }
  } catch (error) {
    const screenshotPath = resolve(
      logsDir,
      `${account.accountId}-${Date.now()}-error.png`,
    );
    await page.screenshot({ path: screenshotPath, fullPage: true }).catch(() => {});
    console.error(`Failed for ${account.name}:`, error);
    console.error(`Screenshot: ${screenshotPath}`);
    throw error;
  } finally {
    await browser.close();
  }
}

function printAccountList(accounts: AwsAccount[]): void {
  console.log(`Found ${accounts.length} accounts with IAM credentials:\n`);
  for (const account of accounts) {
    console.log(
      `  ${account.accountId}  ${account.username.padEnd(28)}  ${account.name}`,
    );
  }
}

async function main(): Promise<void> {
  const { command, options } = parseArgs(process.argv.slice(2));
  const config = loadConfig();

  if (!existsSync(options.credentialsPath)) {
    throw new Error(
      `Credentials file not found: ${options.credentialsPath}\n` +
        "Export Bitwarden items to aws-credentials.json at repo root (gitignored).",
    );
  }

  const accounts = loadCredentials(options.credentialsPath);

  if (command === "list") {
    printAccountList(accounts);
    return;
  }

  const selected = selectAccounts(accounts, options);

  console.log(
    `Running ${command} for ${selected.length} account(s). Headed=${options.headed}`,
  );

  for (const account of selected) {
    console.log(`\n=== ${account.name} (${account.accountId}) ===`);
    await runForAccount(account, config, options, command);
    console.log(`=== Done: ${account.name} ===\n`);
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
