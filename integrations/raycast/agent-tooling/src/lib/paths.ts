import path from "node:path";

export function isPathInside(parentPath: string, childPath: string): boolean {
  const relative = path.relative(parentPath, childPath);
  return (
    relative !== "" &&
    !relative.startsWith(`..${path.sep}`) &&
    relative !== ".." &&
    !path.isAbsolute(relative)
  );
}

export function normalizeFilePreference(value: unknown): string | undefined {
  if (typeof value === "string" && value.trim() !== "") return value;
  if (
    Array.isArray(value) &&
    value.length === 1 &&
    typeof value[0] === "string" &&
    value[0].trim() !== ""
  ) {
    return value[0];
  }
  return undefined;
}
