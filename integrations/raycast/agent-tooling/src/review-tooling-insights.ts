import { Toast, showToast } from "@raycast/api";
import {
  openAgentToolingRoute,
  userMessageForError,
} from "./lib/agent-tooling";

export default async function ReviewToolingInsightsCommand() {
  const toast = await showToast({
    style: Toast.Style.Animated,
    title: "Opening tooling insights",
  });
  try {
    await openAgentToolingRoute({ kind: "insights" });
    toast.style = Toast.Style.Success;
    toast.title = "Tooling insights opened";
  } catch (error: unknown) {
    toast.style = Toast.Style.Failure;
    toast.title = "Could not open tooling insights";
    toast.message = userMessageForError(error);
  }
}
