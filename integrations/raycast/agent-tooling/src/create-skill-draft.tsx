import {
  Action,
  ActionPanel,
  Form,
  Icon,
  Toast,
  popToRoot,
  showToast,
} from "@raycast/api";
import { useState } from "react";
import {
  createSkillDraft,
  openAgentToolingRoute,
  userMessageForError,
} from "./lib/agent-tooling";
import { SkillScope, SkillTarget } from "./lib/contracts";
import { validateSkillInstruction } from "./lib/skill-request";

interface CreateSkillFormValues {
  instruction: string;
  scope: SkillScope;
  targets: SkillTarget[];
  projectPath?: string[];
}

export default function CreateSkillDraftCommand() {
  const [scope, setScope] = useState<SkillScope>("global");
  const [instructionError, setInstructionError] = useState<string>();
  const [projectError, setProjectError] = useState<string>();
  const [targetError, setTargetError] = useState<string>();
  const [isSubmitting, setIsSubmitting] = useState(false);

  async function submit(values: CreateSkillFormValues) {
    const instructionValidation = validateSkillInstruction(values.instruction);
    const projectPath = values.projectPath?.[0];
    setInstructionError(undefined);
    setProjectError(undefined);
    setTargetError(undefined);

    if (!instructionValidation.isValid) {
      setInstructionError(instructionValidation.message);
      return;
    }
    if (values.targets.length === 0) {
      setTargetError("Choose at least one destination.");
      return;
    }
    if (values.scope === "project" && !projectPath) {
      setProjectError("Choose the project folder that should own this skill.");
      return;
    }

    setIsSubmitting(true);
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Opening Codex skill creator",
    });
    try {
      const request = await createSkillDraft({
        instruction: instructionValidation.instruction,
        scope: values.scope,
        targets: values.targets,
        projectPath,
      });
      toast.style = Toast.Style.Success;
      toast.title = "Request ready";
      await openAgentToolingRoute({ kind: "request", id: request.id });
      await popToRoot({ clearSearchBar: true });
    } catch (error: unknown) {
      toast.style = Toast.Style.Failure;
      toast.title = "Could not create the skill draft";
      toast.message = userMessageForError(error);
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <Form
      isLoading={isSubmitting}
      navigationTitle="Create Skill Draft"
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Create Draft with Codex"
            icon={Icon.Wand}
            onSubmit={submit}
          />
        </ActionPanel>
      }
    >
      <Form.Description text="Codex will use Agent Tooling's Skill Creator workflow. Nothing is installed until you review and approve the draft in the desktop app." />
      <Form.Description text="Codex is the only generator. Install destinations are optional targets for the portable skill after review; they do not invoke Claude or Gemini to create it." />
      <Form.TextArea
        id="instruction"
        title="Instruction"
        placeholder="Describe what the skill should do, when it should run, and what a good result looks like."
        error={instructionError}
        onChange={() => setInstructionError(undefined)}
        autoFocus
      />
      <Form.Separator />
      <Form.Dropdown
        id="scope"
        title="Scope"
        value={scope}
        onChange={(value) => setScope(value as SkillScope)}
      >
        <Form.Dropdown.Item
          value="global"
          title="Global"
          icon={Icon.ComputerChip}
        />
        <Form.Dropdown.Item
          value="project"
          title="Project"
          icon={Icon.Folder}
        />
      </Form.Dropdown>
      {scope === "project" ? (
        <Form.FilePicker
          id="projectPath"
          title="Project Folder"
          canChooseDirectories
          canChooseFiles={false}
          allowMultipleSelection={false}
          error={projectError}
          onChange={() => setProjectError(undefined)}
        />
      ) : null}
      <Form.TagPicker
        id="targets"
        title="Install after review"
        defaultValue={["codex"]}
        error={targetError}
        onChange={() => setTargetError(undefined)}
      >
        <Form.TagPicker.Item value="codex" title="Codex" icon={Icon.Terminal} />
        <Form.TagPicker.Item
          value="claude-code"
          title="Claude Code"
          icon={Icon.Code}
        />
        <Form.TagPicker.Item
          value="gemini"
          title="Gemini CLI"
          icon={Icon.Stars}
        />
      </Form.TagPicker>
    </Form>
  );
}
