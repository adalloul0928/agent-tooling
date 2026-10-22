import path from "node:path";
import { describe, expect, it } from "vitest";
import { isPathInside, normalizeFilePreference } from "../src/lib/paths";

describe("path safety", () => {
  it("accepts only descendants", () => {
    const app = path.join(path.sep, "Applications", "Agent Tooling.app");
    expect(
      isPathInside(app, path.join(app, "Contents", "Helpers", "agent-tooling")),
    ).toBe(true);
    expect(isPathInside(app, app)).toBe(false);
    expect(
      isPathInside(app, path.join(path.sep, "Applications", "Other.app")),
    ).toBe(false);
    expect(isPathInside(app, path.join(app, "..", "Other.app"))).toBe(false);
  });

  it("normalizes Raycast file preference values", () => {
    expect(normalizeFilePreference("/tmp/agent-tooling")).toBe(
      "/tmp/agent-tooling",
    );
    expect(normalizeFilePreference(["/tmp/agent-tooling"])).toBe(
      "/tmp/agent-tooling",
    );
    expect(normalizeFilePreference([])).toBeUndefined();
    expect(normalizeFilePreference(["one", "two"])).toBeUndefined();
  });
});
