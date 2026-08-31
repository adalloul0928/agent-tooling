import os from "node:os";
import { describe, expect, it } from "vitest";
import { redactMessage } from "../src/lib/redaction";

describe("error redaction", () => {
  it("redacts the home directory, secrets, and explicit sensitive values", () => {
    const result = redactMessage(
      `${os.homedir()}/private/file token=abc123 instruction text\nsecond line`,
      ["instruction text"],
    );

    expect(result).not.toContain(os.homedir());
    expect(result).not.toContain("abc123");
    expect(result).not.toContain("instruction text");
    expect(result).toContain("token=<redacted>");
    expect(result).not.toContain("\n");
  });

  it("bounds user-facing diagnostics", () => {
    expect(redactMessage("diagnostic ".repeat(50))).toHaveLength(238);
  });
});
