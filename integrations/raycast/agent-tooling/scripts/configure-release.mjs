import { readFileSync, writeFileSync } from "node:fs";

const configurationURL = new URL("../src/lib/signing-team.ts", import.meta.url);
if (process.argv[2] === "--check") {
  const configuration = readFileSync(configurationURL, "utf8");
  const manifest = JSON.parse(
    readFileSync(new URL("../package.json", import.meta.url), "utf8"),
  );
  if (
    !/^export const AGENT_TOOLING_TEAM_ID = "[A-Z0-9]{10}";\n$/.test(
      configuration,
    )
  ) {
    console.error("Configure the release signing team before publishing.");
    process.exit(64);
  }
  if (!manifest.author || manifest.author === "agent-tooling") {
    console.error(
      "Set the registered Raycast publisher in package.json before publishing.",
    );
    process.exit(64);
  }
  process.exit(0);
}

const teamID = process.env.MACOS_SIGNING_TEAM_ID;
if (!teamID || !/^[A-Z0-9]{10}$/.test(teamID)) {
  console.error(
    "Set MACOS_SIGNING_TEAM_ID to the ten-character release signing team.",
  );
  process.exit(64);
}

writeFileSync(
  configurationURL,
  `export const AGENT_TOOLING_TEAM_ID = "${teamID}";\n`,
);
console.log("Configured the extension's build-time signing identity.");
