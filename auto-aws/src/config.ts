import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const AUTO_AWS_ROOT = resolve(__dirname, "..");

export interface ProvisionConfig {
  region: string;
  availabilityZone: string;
  instanceName: string;
  blueprintId: string;
  bundleId: string;
  ipAddressType: string;
  staticIpName: string;
  sshAllowCidrs: string[];
  commandScript: string;
}

const DEFAULT_CONFIG: ProvisionConfig = {
  region: "ap-southeast-2",
  availabilityZone: "ap-southeast-2a",
  instanceName: "wp-web-23",
  blueprintId: "amazon_linux_2023",
  bundleId: "nano_3_2",
  ipAddressType: "ipv4",
  staticIpName: "StaticIp-1",
  sshAllowCidrs: [
    "111.220.137.221/32",
    "43.245.170.89/32",
    "158.180.7.100/32",
  ],
  commandScript: "../aws-command.sh",
};

export function loadConfig(): ProvisionConfig {
  const configPath = resolve(AUTO_AWS_ROOT, "config.json");
  if (!existsSync(configPath)) {
    return {
      ...DEFAULT_CONFIG,
      commandScript: resolve(AUTO_AWS_ROOT, DEFAULT_CONFIG.commandScript),
    };
  }

  const parsed = JSON.parse(readFileSync(configPath, "utf8")) as Partial<ProvisionConfig>;
  const merged = { ...DEFAULT_CONFIG, ...parsed };

  if (!merged.commandScript.startsWith("/")) {
    merged.commandScript = resolve(AUTO_AWS_ROOT, merged.commandScript);
  }

  return merged;
}

export function buildLightsailCommands(config: ProvisionConfig): string[] {
  const sshCidrs = config.sshAllowCidrs.join(",");
  return [
    `aws lightsail create-instances --instance-names ${config.instanceName} --availability-zone ${config.availabilityZone} --blueprint-id ${config.blueprintId} --bundle-id ${config.bundleId} --ip-address-type ${config.ipAddressType} --region ${config.region}`,
    `aws lightsail put-instance-public-ports --region ${config.region} --instance-name ${config.instanceName} --port-infos fromPort=22,toPort=22,protocol=tcp,cidrs=${sshCidrs} fromPort=80,toPort=80,protocol=tcp,cidrs=0.0.0.0/0 fromPort=443,toPort=443,protocol=tcp,cidrs=0.0.0.0/0`,
    `aws lightsail allocate-static-ip --static-ip-name ${config.staticIpName} --region ${config.region}`,
    `aws lightsail attach-static-ip --static-ip-name ${config.staticIpName} --instance-name ${config.instanceName} --region ${config.region}`,
    `aws lightsail get-instance --instance-name ${config.instanceName} --region ${config.region} --query instance.publicIpAddress --output text`,
  ];
}

export function loadCommandsFromScript(scriptPath: string): string[] {
  if (!existsSync(scriptPath)) {
    throw new Error(`Command script not found: ${scriptPath}`);
  }

  const content = readFileSync(scriptPath, "utf8");
  const commands: string[] = [];
  let current = "";

  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }

    if (line.trimEnd().endsWith("\\")) {
      current += line.trimEnd().slice(0, -1).trim() + " ";
      continue;
    }

    current += line.trim();
    if (current.trim()) {
      commands.push(current.trim());
    }
    current = "";
  }

  if (current.trim()) {
    commands.push(current.trim());
  }

  return commands;
}

export function getAutoAwsRoot(): string {
  return AUTO_AWS_ROOT;
}
