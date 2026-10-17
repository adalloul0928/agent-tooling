import { describe, expect, it } from "vitest";
import type {
  CreateSkillDraftInput,
  SkillProvider,
} from "../src/lib/contracts";
import {
  createSkillDraftArguments,
  DEFAULT_SKILL_PROVIDER,
  isSkillProvider,
  MAXIMUM_INSTRUCTION_BYTES,
  MAXIMUM_INSTRUCTION_CHARACTERS,
  SKILL_PROVIDERS,
  skillProviderTitle,
  validateSkillInstruction,
} from "../src/lib/skill-request";

describe("skill request arguments", () => {
  const request: CreateSkillDraftInput = {
    instruction: "Review a release branch before it ships.",
    provider: DEFAULT_SKILL_PROVIDER,
    scope: "global",
    targets: ["codex"],
  };

  it("asks Codex by default, with the arguments the extension always sent", () => {
    expect(DEFAULT_SKILL_PROVIDER).toBe("codex");
    expect(createSkillDraftArguments(request)).toEqual([
      "request",
      "create-skill",
      "--provider",
      "codex",
      "--scope",
      "global",
      "--targets",
      "codex",
      "--instruction-stdin",
      "--json",
    ]);
  });

  it("asks Claude Code when the person chooses it", () => {
    expect(
      createSkillDraftArguments({ ...request, provider: "claude" }),
    ).toEqual([
      "request",
      "create-skill",
      "--provider",
      "claude",
      "--scope",
      "global",
      "--targets",
      "codex",
      "--instruction-stdin",
      "--json",
    ]);
  });

  it("offers exactly the providers the helper accepts, Codex first", () => {
    expect(SKILL_PROVIDERS).toEqual(["codex", "claude"]);
    expect(SKILL_PROVIDERS.map(skillProviderTitle)).toEqual([
      "Codex",
      "Claude Code",
    ]);
  });

  it("refuses any other provider before the helper runs", () => {
    expect(isSkillProvider("gemini")).toBe(false);
    expect(isSkillProvider(undefined)).toBe(false);
    expect(() =>
      createSkillDraftArguments({
        ...request,
        provider: "gemini" as SkillProvider,
      }),
    ).toThrow("Choose Codex or Claude Code");
  });

  it("keeps the instruction out of the arguments for every provider", () => {
    for (const provider of SKILL_PROVIDERS) {
      expect(createSkillDraftArguments({ ...request, provider })).not.toContain(
        request.instruction,
      );
    }
  });

  it("passes a project folder only with project scope", () => {
    expect(
      createSkillDraftArguments({
        ...request,
        provider: "claude",
        scope: "project",
        targets: ["claude-code", "codex"],
        projectPath: "/tmp/example-project",
      }),
    ).toEqual([
      "request",
      "create-skill",
      "--provider",
      "claude",
      "--scope",
      "project",
      "--targets",
      "claude-code,codex",
      "--instruction-stdin",
      "--json",
      "--project",
      "/tmp/example-project",
    ]);
    expect(
      createSkillDraftArguments({
        ...request,
        projectPath: "/tmp/example-project",
      }),
    ).not.toContain("--project");
  });
});

describe("skill request validation", () => {
  it("accepts the exact character limit", () => {
    const instruction = "a".repeat(MAXIMUM_INSTRUCTION_CHARACTERS);
    expect(validateSkillInstruction(instruction)).toEqual({
      isValid: true,
      instruction,
    });
  });

  it("rejects one character over the limit", () => {
    expect(
      validateSkillInstruction("a".repeat(MAXIMUM_INSTRUCTION_CHARACTERS + 1)),
    ).toMatchObject({
      isValid: false,
    });
  });

  it("accepts exactly 65,536 UTF-8 bytes", () => {
    const instruction = "😀".repeat(MAXIMUM_INSTRUCTION_CHARACTERS);
    expect(new TextEncoder().encode(instruction)).toHaveLength(
      MAXIMUM_INSTRUCTION_BYTES,
    );
    expect(validateSkillInstruction(instruction)).toEqual({
      isValid: true,
      instruction,
    });
  });

  it("rejects a multibyte instruction over the byte limit even when its grapheme count is below the limit", () => {
    const grapheme = "👨‍👩‍👧‍👦";
    const instruction = grapheme.repeat(
      Math.floor(
        MAXIMUM_INSTRUCTION_BYTES / new TextEncoder().encode(grapheme).length,
      ) + 1,
    );
    expect(
      Array.from(
        new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(
          instruction,
        ),
      ).length,
    ).toBeLessThan(MAXIMUM_INSTRUCTION_CHARACTERS);
    expect(new TextEncoder().encode(instruction).length).toBeGreaterThan(
      MAXIMUM_INSTRUCTION_BYTES,
    );
    expect(validateSkillInstruction(instruction)).toMatchObject({
      isValid: false,
    });
  });
});
