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
import { SkillProvider, SkillScope, SkillTarget } from "./lib/contracts";
import {
  DEFAULT_SKILL_PROVIDER,
  isSkillProvider,
  SKILL_PROVIDERS,
  skillProviderTitle,
  validateSkillInstruction,
} from "./lib/skill-request";

interface CreateSkillFormValues {
  instruction: string;
  provider: SkillProvider;
  scope: SkillScope;
  targets: SkillTarget[];
  projectPath?: string[];
}

const PROVIDER_ICONS: Record<SkillProvider, Icon> = {
  codex: Icon.Terminal,
  claude: Icon.Code,
};

export default function CreateSkillDraftCommand() {
  const [provider, setProvider] = useState<SkillProvider>(
    DEFAULT_SKILL_PROVIDER,
  );
  const [scope, setScope] = useState<SkillScope>("global");
  const [instructionError, setInstructionError] = useState<string>();
  const [projectError, setProjectError] = useState<string>();
  const [targetError, setTargetError] = useState<string>();
  const [isSubmitting, setIsSubmitting] = useState(false);
  const providerTitle = skillProviderTitle(provider);

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
      title: `Opening ${skillProviderTitle(values.provider)} skill creator`,
    });
    try {
      const request = await createSkillDraft({
        instruction: instructionValidation.instruction,
        provider: values.provider,
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
            title={`Create Draft with ${providerTitle}`}
            icon={Icon.Wand}
            onSubmit={submit}
          />
        </ActionPanel>
      }
    >
      <Form.Description
        text={`${providerTitle} will use Agent Tooling's Skill Creator workflow. Nothing is installed until you review and approve the draft in the desktop app.`}
      />
      <Form.Description text="Only the assistant you choose writes the draft. Install destinations are optional targets for the portable skill after review; picking one does not ask that app to write it." />
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
        id="provider"
        title="Assistant"
        info="Skill creation runs in your signed-in local Claude Code or Codex."
        value={provider}
        onChange={(value) => {
          if (isSkillProvider(value)) setProvider(value);
        }}
      >
        {SKILL_PROVIDERS.map((value) => (
          <Form.Dropdown.Item
            key={value}
            value={value}
            title={skillProviderTitle(value)}
            icon={PROVIDER_ICONS[value]}
          />
        ))}
      </Form.Dropdown>
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
