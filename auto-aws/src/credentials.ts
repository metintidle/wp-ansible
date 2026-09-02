import { readFileSync } from "node:fs";

export interface AwsAccount {
  name: string;
  accountId: string;
  username: string;
  password: string;
}

interface BitwardenField {
  name: string;
  value: string;
}

interface BitwardenItem {
  name: string;
  fields?: BitwardenField[];
  login?: {
    username?: string;
    password?: string;
  };
}

interface BitwardenExport {
  items?: BitwardenItem[];
}

export function loadCredentials(credentialsPath: string): AwsAccount[] {
  const raw = JSON.parse(readFileSync(credentialsPath, "utf8")) as BitwardenExport;
  const accounts: AwsAccount[] = [];

  for (const item of raw.items ?? []) {
    const accountField = item.fields?.find((f) => f.name === "account");
    const username = item.login?.username?.trim();
    const password = item.login?.password;

    if (!accountField?.value || !username || !password) {
      continue;
    }

    accounts.push({
      name: item.name.trim(),
      accountId: accountField.value.trim(),
      username,
      password,
    });
  }

  return accounts;
}

export function findAccount(
  accounts: AwsAccount[],
  query: string,
): AwsAccount | undefined {
  const q = query.trim().toLowerCase();
  return accounts.find(
    (a) =>
      a.accountId === q ||
      a.name.toLowerCase() === q ||
      a.name.toLowerCase().includes(q) ||
      a.username.toLowerCase() === q,
  );
}
