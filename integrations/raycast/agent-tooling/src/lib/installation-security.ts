import { execFile } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access, lstat, realpath } from "node:fs/promises";
import path from "node:path";
import { isPathInside } from "./paths";

export const AGENT_TOOLING_BUNDLE_ID = "com.arendalloul.agent-tooling";
export const AGENT_TOOLING_HELPER_ID = "com.arendalloul.agent-tooling.cli";
export const AGENT_TOOLING_TEAM_ID = "434X69L4Z5";
export const AGENT_TOOLING_HELPER_RELATIVE_PATH = path.join(
  "Contents",
  "Helpers",
  "agent-tooling",
);

const CODESIGN_PATH = "/usr/bin/codesign";
const MAX_CODESIGN_OUTPUT_BYTES = 65_536;
const CODESIGN_TIMEOUT_MS = 10_000;

export interface CodeIdentity {
  identifier: string;
  teamIdentifier: string;
  authority: string;
}

export interface VerifiedInstallation {
  appPath: string;
  helperPath: string;
}

export type CodeIdentityVerifier = (
  codePath: string,
  expectedIdentifier: string,
) => Promise<CodeIdentity>;

export type CodesignRunner = (args: readonly string[]) => Promise<string>;

export class InstallationSecurityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InstallationSecurityError";
  }
}

export function developerIDRequirement(identifier: string): string {
  if (!/^[A-Za-z0-9][A-Za-z0-9.-]+$/.test(identifier)) {
    throw new InstallationSecurityError("Invalid code-signing identifier.");
  }
  return (
    `=identifier "${identifier}" and anchor apple generic` +
    " and certificate 1[field.1.2.840.113635.100.6.2.6] exists" +
    " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" +
    ` and certificate leaf[subject.OU] = "${AGENT_TOOLING_TEAM_ID}"`
  );
}

export function developmentHelperOverrideAllowed(
  isDevelopment: boolean,
  explicitlyEnabled: unknown,
): boolean {
  return isDevelopment && explicitlyEnabled === true;
}

export async function validatePackagedInstallation(
  candidateAppPath: string,
  verifyIdentity: CodeIdentityVerifier = verifyCodeIdentity,
): Promise<VerifiedInstallation> {
  let appPath: string;
  try {
    appPath = await realpath(candidateAppPath);
    const appMetadata = await lstat(appPath);
    if (!appMetadata.isDirectory() || path.extname(appPath) !== ".app") {
      throw new Error("not an app bundle");
    }
  } catch {
    throw new InstallationSecurityError(
      "The Agent Tooling application path is not a canonical app bundle.",
    );
  }

  const candidateHelperPath = path.join(
    appPath,
    AGENT_TOOLING_HELPER_RELATIVE_PATH,
  );
  let helperPath: string;
  try {
    helperPath = await realpath(candidateHelperPath);
    const helperMetadata = await lstat(helperPath);
    if (!helperMetadata.isFile()) throw new Error("not a regular file");
    await access(helperPath, fsConstants.X_OK);
  } catch {
    throw new InstallationSecurityError(
      "The Agent Tooling app does not contain an executable CLI helper.",
    );
  }
  if (!isPathInside(appPath, helperPath)) {
    throw new InstallationSecurityError(
      "The Agent Tooling helper resolves outside the canonical app bundle.",
    );
  }

  const appIdentity = await verifyIdentity(appPath, AGENT_TOOLING_BUNDLE_ID);
  const helperIdentity = await verifyIdentity(
    helperPath,
    AGENT_TOOLING_HELPER_ID,
  );
  assertExpectedIdentity(appIdentity, AGENT_TOOLING_BUNDLE_ID);
  assertExpectedIdentity(helperIdentity, AGENT_TOOLING_HELPER_ID);
  if (
    appIdentity.teamIdentifier !== helperIdentity.teamIdentifier ||
    appIdentity.authority !== helperIdentity.authority
  ) {
    throw new InstallationSecurityError(
      "The Agent Tooling app and helper do not have the same signing identity.",
    );
  }

  if (
    (await realpath(candidateAppPath)) !== appPath ||
    (await realpath(candidateHelperPath)) !== helperPath
  ) {
    throw new InstallationSecurityError(
      "The Agent Tooling installation changed during verification.",
    );
  }
  return { appPath, helperPath };
}

export async function validateDevelopmentHelper(
  candidatePath: string,
): Promise<string> {
  try {
    const helperPath = await realpath(candidatePath);
    const metadata = await lstat(helperPath);
    if (!metadata.isFile()) throw new Error("not a regular file");
    await access(helperPath, fsConstants.X_OK);
    return helperPath;
  } catch {
    throw new InstallationSecurityError(
      "The development CLI helper is missing or is not executable.",
    );
  }
}

export async function verifyCodeIdentity(
  codePath: string,
  expectedIdentifier: string,
  runCodesign: CodesignRunner = executeCodesign,
): Promise<CodeIdentity> {
  try {
    await runCodesign([
      "--verify",
      "--strict",
      "--verbose=2",
      "-R",
      developerIDRequirement(expectedIdentifier),
      codePath,
    ]);
    const details = await runCodesign(["--display", "--verbose=4", codePath]);
    const identity = parseCodeIdentity(details);
    assertExpectedIdentity(identity, expectedIdentifier);
    return identity;
  } catch (error) {
    if (error instanceof InstallationSecurityError) throw error;
    throw new InstallationSecurityError(
      "The Agent Tooling code signature is invalid or unauthorized.",
    );
  }
}

export function parseCodeIdentity(details: string): CodeIdentity {
  let identifier: string | undefined;
  let teamIdentifier: string | undefined;
  let authority: string | undefined;
  for (const line of details.split(/\r?\n/u)) {
    if (line.startsWith("Identifier=")) identifier = line.slice(11);
    else if (line.startsWith("TeamIdentifier="))
      teamIdentifier = line.slice(15);
    else if (line.startsWith("Authority=") && authority === undefined)
      authority = line.slice(10);
  }
  if (!identifier || !teamIdentifier || !authority) {
    throw new InstallationSecurityError(
      "The Agent Tooling code signature has incomplete identity metadata.",
    );
  }
  return { identifier, teamIdentifier, authority };
}

function assertExpectedIdentity(
  identity: CodeIdentity,
  expectedIdentifier: string,
): void {
  if (
    identity.identifier !== expectedIdentifier ||
    identity.teamIdentifier !== AGENT_TOOLING_TEAM_ID ||
    identity.authority.trim() === ""
  ) {
    throw new InstallationSecurityError(
      "The Agent Tooling code signature does not match the pinned identity.",
    );
  }
}

function executeCodesign(args: readonly string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      CODESIGN_PATH,
      [...args],
      {
        encoding: "utf8",
        maxBuffer: MAX_CODESIGN_OUTPUT_BYTES,
        timeout: CODESIGN_TIMEOUT_MS,
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        if (error) reject(error);
        else resolve(`${stdout}\n${stderr}`);
      },
    );
  });
}
