import { Toast, showToast } from "@raycast/api";
import {
  openAgentToolingRoute,
  userMessageForError,
} from "./lib/agent-tooling";

export default async function ReviewSyncCommand() {
  const toast = await showToast({
    style: Toast.Style.Animated,
    title: "Opening sync review",
  });
  try {
    await openAgentToolingRoute({ kind: "sync" });
    toast.style = Toast.Style.Success;
    toast.title = "Sync review opened";
  } catch (error: unknown) {
    toast.style = Toast.Style.Failure;
    toast.title = "Could not open the sync review";
    toast.message = userMessageForError(error);
  }
}
