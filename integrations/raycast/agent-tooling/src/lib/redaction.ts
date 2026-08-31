import os from "node:os";

const SECRET_ASSIGNMENT =
  /\b(token|secret|password|api[-_]?key)\b\s*[:=]\s*[^\s,;]+/gi;
const LONG_CREDENTIAL = /\b(?:[A-Za-z0-9+/_-]{32,}={0,2}|[a-f0-9]{40,})\b/gi;
const USER_PATH = /\/(?:Users|home)\/[^\s:'"]+/g;

export function redactMessage(
  message: string,
  sensitiveValues: string[] = [],
): string {
  let value = message.replaceAll(os.homedir(), "~");
  for (const sensitive of sensitiveValues) {
    if (sensitive.length > 0) value = value.replaceAll(sensitive, "<redacted>");
  }
  value = value.replace(SECRET_ASSIGNMENT, "$1=<redacted>");
  value = value.replace(LONG_CREDENTIAL, "<redacted>");
  value = value.replace(USER_PATH, "<path>");
  value = value
    .replace(/[\r\n\t]+/g, " ")
    .replace(/\s{2,}/g, " ")
    .trim();
  return value.length > 240 ? `${value.slice(0, 237)}…` : value;
}
