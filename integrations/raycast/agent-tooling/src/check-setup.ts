import { Toast, showHUD, showToast } from "@raycast/api";
import {
  checkAgentToolingSetup,
  userMessageForError,
} from "./lib/agent-tooling";

export default async function CheckSetupCommand() {
  try {
    const report = await checkAgentToolingSetup();
    if (report.isHealthy) {
      await showHUD("Agent setup looks good");
      return;
    }

    const count = report.unavailableTargets.length;
    const noun = count === 1 ? "target needs" : "targets need";
    await showToast({
      style: Toast.Style.Failure,
      title: `${count} ${noun} attention`,
      message: report.unavailableTargets.join(", "),
    });
  } catch (error: unknown) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Setup check failed",
      message: userMessageForError(error),
    });
  }
}
