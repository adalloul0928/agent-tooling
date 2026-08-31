export const MINIMUM_INSTRUCTION_CHARACTERS = 10;
export const MAXIMUM_INSTRUCTION_CHARACTERS = 16_384;
export const MAXIMUM_INSTRUCTION_BYTES = 65_536;

export type SkillInstructionValidation =
  { isValid: true; instruction: string } | { isValid: false; message: string };

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

export function validateSkillInstruction(
  rawInstruction: string,
): SkillInstructionValidation {
  const instruction = rawInstruction.trim();
  const characterCount = Array.from(segmenter.segment(instruction)).length;
  if (characterCount < MINIMUM_INSTRUCTION_CHARACTERS) {
    return {
      isValid: false,
      message: `Describe the reusable workflow in at least ${MINIMUM_INSTRUCTION_CHARACTERS} characters.`,
    };
  }

  const byteCount = new TextEncoder().encode(instruction).byteLength;
  if (
    characterCount > MAXIMUM_INSTRUCTION_CHARACTERS ||
    byteCount > MAXIMUM_INSTRUCTION_BYTES
  ) {
    return {
      isValid: false,
      message:
        "Keep the instruction within 16,384 characters and 65,536 UTF-8 bytes.",
    };
  }

  return { isValid: true, instruction };
}
