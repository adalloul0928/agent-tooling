import { describe, expect, it } from "vitest";
import {
  MAXIMUM_INSTRUCTION_BYTES,
  MAXIMUM_INSTRUCTION_CHARACTERS,
  validateSkillInstruction,
} from "../src/lib/skill-request";

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
