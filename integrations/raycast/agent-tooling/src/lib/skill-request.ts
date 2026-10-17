import type { CreateSkillDraftInput, SkillProvider } from "./contracts";

export const MINIMUM_INSTRUCTION_CHARACTERS = 10;
export const MAXIMUM_INSTRUCTION_CHARACTERS = 16_384;
export const MAXIMUM_INSTRUCTION_BYTES = 65_536;

/**
 * The assistants the helper's `request create-skill --provider` accepts, in
 * the order the form offers them. Codex stays the default: it was the only
 * choice before the helper accepted Claude Code.
 */
export const SKILL_PROVIDERS: readonly SkillProvider[] = ["codex", "claude"];
export const DEFAULT_SKILL_PROVIDER: SkillProvider = "codex";

const SKILL_PROVIDER_TITLES: Record<SkillProvider, string> = {
  codex: "Codex",
  claude: "Claude Code",
};

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

export function isSkillProvider(value: unknown): value is SkillProvider {
  return (
    typeof value === "string" &&
    (SKILL_PROVIDERS as readonly string[]).includes(value)
  );
}

export function skillProviderTitle(provider: SkillProvider): string {
  return SKILL_PROVIDER_TITLES[provider];
}

/**
 * The helper arguments for one skill-draft request. The instruction is never
 * one of them: it travels on stdin, so it stays out of argv and process lists.
 */
export function createSkillDraftArguments(
  input: CreateSkillDraftInput,
): string[] {
  if (!isSkillProvider(input.provider)) {
    throw new Error("Choose Codex or Claude Code to write the skill draft.");
  }
  const args = [
    "request",
    "create-skill",
    "--provider",
    input.provider,
    "--scope",
    input.scope,
    "--targets",
    input.targets.join(","),
    "--instruction-stdin",
    "--json",
  ];
  if (input.scope === "project" && input.projectPath) {
    args.push("--project", input.projectPath);
  }
  return args;
}
