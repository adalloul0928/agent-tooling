import { Toast, showToast } from "@raycast/api";
import {
  openAgentToolingRoute,
  userMessageForError,
} from "./lib/agent-tooling";

export default async function OpenAgentToolingCommand() {
  try {
    await openAgentToolingRoute({ kind: "overview" });
  } catch (error: unknown) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not open Agent Tooling",
      message: userMessageForError(error),
    });
  }
}
