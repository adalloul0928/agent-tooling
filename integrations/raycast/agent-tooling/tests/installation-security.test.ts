import {
  chmod,
  mkdir,
  mkdtemp,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  AGENT_TOOLING_BUNDLE_ID,
  AGENT_TOOLING_HELPER_ID,
  AGENT_TOOLING_TEAM_ID,
  CodeIdentity,
  CodeIdentityVerifier,
  developerIDRequirement,
  developmentHelperOverrideAllowed,
  validatePackagedInstallation,
  verifyCodeIdentity,
} from "../src/lib/installation-security";

const temporaryRoots: string[] = [];
const expectedAuthority = `Developer ID Application: AVAD Technologies LLC (${AGENT_TOOLING_TEAM_ID})`;

afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((root) => rm(root, { recursive: true })),
  );
});

describe("Agent Tooling installation security", () => {
  it("pins the app and helper to explicit Developer ID requirements", async () => {
    const invocations: readonly string[][] = [];
    const calls = invocations as string[][];
    const identity = await verifyCodeIdentity(
      "/Applications/Agent Tooling.app",
      AGENT_TOOLING_BUNDLE_ID,
      async (args) => {
        calls.push([...args]);
        if (args.includes("--display")) {
          return [
            `Identifier=${AGENT_TOOLING_BUNDLE_ID}`,
            `TeamIdentifier=${AGENT_TOOLING_TEAM_ID}`,
            `Authority=${expectedAuthority}`,
          ].join("\n");
        }
        return "";
      },
    );

    expect(identity.teamIdentifier).toBe(AGENT_TOOLING_TEAM_ID);
    expect(calls[0]).toEqual(
      expect.arrayContaining([
        "--verify",
        "--strict",
        "-R",
        developerIDRequirement(AGENT_TOOLING_BUNDLE_ID),
      ]),
    );
    const requirement = developerIDRequirement(AGENT_TOOLING_BUNDLE_ID);
    expect(requirement).toContain('identifier "com.arendalloul.agent-tooling"');
    expect(requirement).toContain('subject.OU] = "434X69L4Z5"');
    expect(requirement).toContain("1.2.840.113635.100.6.1.13");
  });

  it("accepts only canonical in-bundle helpers with the same identity", async () => {
    const { appPath, helperPath } = await makeInstallation();
    const verified = await validatePackagedInstallation(
      appPath,
      matchingVerifier(),
    );

    expect(verified).toEqual({
      appPath: await realpath(appPath),
      helperPath: await realpath(helperPath),
    });
  });

  it("rejects a helper symlink that escapes the canonical app bundle", async () => {
    const root = await temporaryRoot();
    const appPath = path.join(root, "Agent Tooling.app");
    const helpersPath = path.join(appPath, "Contents", "Helpers");
    const outsideHelper = path.join(root, "attacker-helper");
    await mkdir(helpersPath, { recursive: true });
    await writeFile(outsideHelper, "#!/bin/sh\nexit 0\n");
    await chmod(outsideHelper, 0o700);
    await symlink(outsideHelper, path.join(helpersPath, "agent-tooling"));

    await expect(
      validatePackagedInstallation(appPath, matchingVerifier()),
    ).rejects.toThrow("outside the canonical app bundle");
  });

  it("rejects wrong identifiers, teams, and mismatched app/helper authorities", async () => {
    const { appPath } = await makeInstallation();
    const wrongTeam = matchingVerifier({ teamIdentifier: "ATTACKER01" });
    await expect(
      validatePackagedInstallation(appPath, wrongTeam),
    ).rejects.toThrow("pinned identity");

    const wrongIdentifier: CodeIdentityVerifier = async () => ({
      identifier: "com.attacker.agent-tooling",
      teamIdentifier: AGENT_TOOLING_TEAM_ID,
      authority: expectedAuthority,
    });
    await expect(
      validatePackagedInstallation(appPath, wrongIdentifier),
    ).rejects.toThrow("pinned identity");

    const differentAuthorities: CodeIdentityVerifier = async (
      _codePath,
      identifier,
    ) => ({
      identifier,
      teamIdentifier: AGENT_TOOLING_TEAM_ID,
      authority:
        identifier === AGENT_TOOLING_HELPER_ID
          ? `Developer ID Application: Lookalike (${AGENT_TOOLING_TEAM_ID})`
          : expectedAuthority,
    });
    await expect(
      validatePackagedInstallation(appPath, differentAuthorities),
    ).rejects.toThrow("same signing identity");
  });

  it("allows unsigned overrides only with explicit development opt-in", () => {
    expect(developmentHelperOverrideAllowed(true, true)).toBe(true);
    expect(developmentHelperOverrideAllowed(true, false)).toBe(false);
    expect(developmentHelperOverrideAllowed(false, true)).toBe(false);
    expect(developmentHelperOverrideAllowed(false, "true")).toBe(false);
  });
});

async function temporaryRoot(): Promise<string> {
  const root = await mkdtemp(path.join(os.tmpdir(), "agent-tooling-raycast-"));
  temporaryRoots.push(root);
  return root;
}

async function makeInstallation(): Promise<{
  appPath: string;
  helperPath: string;
}> {
  const root = await temporaryRoot();
  const appPath = path.join(root, "Agent Tooling.app");
  const helperPath = path.join(appPath, "Contents", "Helpers", "agent-tooling");
  await mkdir(path.dirname(helperPath), { recursive: true });
  await writeFile(helperPath, "#!/bin/sh\nexit 0\n");
  await chmod(helperPath, 0o700);
  return { appPath, helperPath };
}

function matchingVerifier(
  override: Partial<CodeIdentity> = {},
): CodeIdentityVerifier {
  return async (_codePath, identifier) => ({
    identifier,
    teamIdentifier: AGENT_TOOLING_TEAM_ID,
    authority: expectedAuthority,
    ...override,
  });
}
