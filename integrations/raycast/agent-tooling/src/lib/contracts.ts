export const AGENT_TOOLING_SCHEMA_VERSION = 1;
export const MAX_JSON_BYTES = 1_048_576;

export type ComponentKind = "skill" | "mcp-server" | "plugin";
export type SkillScope = "global" | "project";
export type SkillTarget = "codex" | "claude-code" | "gemini";

export interface SearchResult {
  id: string;
  kind: ComponentKind;
  name: string;
  description?: string;
  source?: string;
  scope?: string;
  targets: string[];
  status?: string;
}

export interface SearchResponse {
  schemaVersion: typeof AGENT_TOOLING_SCHEMA_VERSION;
  results: SearchResult[];
  totalResults: number;
  truncated: boolean;
}

export interface DoctorResponse {
  schemaVersion?: typeof AGENT_TOOLING_SCHEMA_VERSION;
  isHealthy: boolean;
  unavailableTargets: string[];
  observations: unknown[];
}

export interface RequestReference {
  id: string;
  state?: string;
}

export interface RequestResponse {
  schemaVersion: typeof AGENT_TOOLING_SCHEMA_VERSION;
  request: RequestReference;
}

export interface CreateSkillDraftInput {
  instruction: string;
  scope: SkillScope;
  targets: SkillTarget[];
  projectPath?: string;
}

export class ContractError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ContractError";
  }
}

export function parseBoundedJSON(
  output: string,
  maxBytes = MAX_JSON_BYTES,
): unknown {
  if (Buffer.byteLength(output, "utf8") > maxBytes) {
    throw new ContractError(
      "Agent Tooling returned more data than this extension can safely read.",
    );
  }

  try {
    return JSON.parse(output) as unknown;
  } catch {
    throw new ContractError("Agent Tooling returned malformed JSON.");
  }
}

export function decodeSearchResponse(output: string): SearchResponse {
  const value = parseBoundedJSON(output);
  const root = requireRecord(value, "search response");
  requireSchemaVersion(root);
  const results = requireArray(root.results, "search response results").map(
    (item, index) => decodeSearchResult(item, index),
  );
  if (results.length > 100) {
    throw new ContractError("The search response contains too many results.");
  }
  const totalResults = requireNonNegativeInteger(
    root.totalResults,
    "search result count",
  );
  if (typeof root.truncated !== "boolean") {
    throw new ContractError(
      "The search response is missing its truncation state.",
    );
  }
  if (
    totalResults < results.length ||
    root.truncated !== totalResults > results.length
  ) {
    throw new ContractError(
      "The search response has inconsistent result counts.",
    );
  }
  return {
    schemaVersion: AGENT_TOOLING_SCHEMA_VERSION,
    results,
    totalResults,
    truncated: root.truncated,
  };
}

export function decodeDoctorResponse(output: string): DoctorResponse {
  const value = parseBoundedJSON(output);
  const root = requireRecord(value, "doctor response");

  if (root.schemaVersion !== undefined) {
    requireSchemaVersion(root);
  }
  if (typeof root.isHealthy !== "boolean") {
    throw new ContractError(
      "The doctor response is missing its health status.",
    );
  }

  return {
    schemaVersion:
      root.schemaVersion === undefined
        ? undefined
        : AGENT_TOOLING_SCHEMA_VERSION,
    isHealthy: root.isHealthy,
    unavailableTargets: requireStringArray(
      root.unavailableTargets,
      "unavailable targets",
    ),
    observations: requireArray(root.observations, "doctor observations"),
  };
}

export function decodeRequestResponse(output: string): RequestResponse {
  const value = parseBoundedJSON(output);
  const root = requireRecord(value, "request response");
  requireSchemaVersion(root);
  const request = requireRecord(root.request, "request response request");
  const id = requireRequestID(request.id);

  return {
    schemaVersion: AGENT_TOOLING_SCHEMA_VERSION,
    request: {
      id,
      state: optionalShortString(request.state, "request state"),
    },
  };
}

function decodeSearchResult(value: unknown, index: number): SearchResult {
  const item = requireRecord(value, `search result ${index + 1}`);
  const kind = decodeKind(item.kind, index);
  return {
    id: requireSafeIdentifier(item.id, `search result ${index + 1} ID`),
    kind,
    name: requireShortString(item.name, `search result ${index + 1} name`),
    description: optionalShortString(
      item.description,
      `search result ${index + 1} description`,
      2_048,
    ),
    source: optionalShortString(
      item.source,
      `search result ${index + 1} source`,
    ),
    scope: optionalShortString(item.scope, `search result ${index + 1} scope`),
    targets:
      item.targets === undefined
        ? []
        : requireStringArray(
            item.targets,
            `search result ${index + 1} targets`,
          ),
    status: optionalShortString(
      item.status,
      `search result ${index + 1} status`,
    ),
  };
}

function decodeKind(value: unknown, index: number): ComponentKind {
  if (value === "skill" || value === "mcp-server" || value === "plugin") {
    return value;
  }
  throw new ContractError(
    `Search result ${index + 1} has an unsupported component kind.`,
  );
}

function requireSchemaVersion(record: Record<string, unknown>): void {
  if (record.schemaVersion !== AGENT_TOOLING_SCHEMA_VERSION) {
    throw new ContractError(
      `This extension supports Agent Tooling schema ${AGENT_TOOLING_SCHEMA_VERSION}; update the app and extension together.`,
    );
  }
}

function requireRecord(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new ContractError(`The ${label} must be a JSON object.`);
  }
  return value as Record<string, unknown>;
}

function requireArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new ContractError(`The ${label} must be an array.`);
  }
  if (value.length > 10_000) {
    throw new ContractError(`The ${label} contains too many items.`);
  }
  return value;
}

function requireNonNegativeInteger(value: unknown, label: string): number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0 ||
    value > 1_000_000
  ) {
    throw new ContractError(`The ${label} must be a non-negative integer.`);
  }
  return value;
}

function requireStringArray(value: unknown, label: string): string[] {
  return requireArray(value, label).map((item) =>
    requireShortString(item, label),
  );
}

function requireSafeIdentifier(value: unknown, label: string): string {
  const identifier = requireShortString(value, label, 256);
  if (!/^[A-Za-z0-9][A-Za-z0-9._:@+-]*$/.test(identifier)) {
    throw new ContractError(`The ${label} contains unsupported characters.`);
  }
  return identifier;
}

function requireRequestID(value: unknown): string {
  const identifier = requireShortString(value, "request ID", 36);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      identifier,
    )
  ) {
    throw new ContractError("The request ID is not a valid UUID.");
  }
  return identifier;
}

function requireShortString(
  value: unknown,
  label: string,
  maxLength = 512,
): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maxLength
  ) {
    throw new ContractError(
      `The ${label} must be a non-empty string no longer than ${maxLength} characters.`,
    );
  }
  return value;
}

function optionalShortString(
  value: unknown,
  label: string,
  maxLength = 512,
): string | undefined {
  if (value === undefined || value === null) return undefined;
  return requireShortString(value, label, maxLength);
}
