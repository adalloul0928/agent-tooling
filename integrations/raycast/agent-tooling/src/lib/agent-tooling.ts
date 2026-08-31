import {
  Application,
  getApplications,
  getPreferenceValues,
  open,
} from "@raycast/api";
import { spawn } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access, lstat, realpath } from "node:fs/promises";
import path from "node:path";
import {
  CreateSkillDraftInput,
  decodeDoctorResponse,
  decodeRequestResponse,
  decodeSearchResponse,
  DoctorResponse,
  MAX_JSON_BYTES,
  RequestReference,
  SearchResponse,
} from "./contracts";
import { isPathInside, normalizeFilePreference } from "./paths";
import { redactMessage } from "./redaction";
import { AgentToolingRoute, routeURL } from "./routes";

export type { AgentToolingRoute } from "./routes";
export { routeURL } from "./routes";

export const AGENT_TOOLING_BUNDLE_ID = "com.arendalloul.agent-tooling";
const CLI_RELATIVE_PATH = path.join("Contents", "Helpers", "agent-tooling");
const MAX_ERROR_BYTES = 65_536;

interface ExtensionPreferences {
  cliPath?: unknown;
}

interface RunOptions {
  stdin?: string;
  timeoutMs?: number;
  acceptedExitCodes?: number[];
  signal?: AbortSignal;
  sensitiveValues?: string[];
}

interface ProcessOutput {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export type AgentToolingFailureCode =
  | "app-not-found"
  | "helper-not-found"
  | "helper-invalid"
  | "command-failed"
  | "timeout"
  | "cancelled"
  | "output-too-large";

export class AgentToolingFailure extends Error {
  constructor(
    readonly code: AgentToolingFailureCode,
    message: string,
  ) {
    super(message);
    this.name = "AgentToolingFailure";
  }
}

export async function searchAgentTooling(
  query: string,
  signal?: AbortSignal,
): Promise<SearchResponse> {
  const output = await runAgentTooling(
    ["search", "--query", query, "--limit", "100", "--json"],
    {
      timeoutMs: 15_000,
      signal,
    },
  );
  return decodeSearchResponse(output.stdout);
}

export async function checkAgentToolingSetup(): Promise<DoctorResponse> {
  const output = await runAgentTooling(["doctor"], {
    timeoutMs: 30_000,
    acceptedExitCodes: [0, 2],
  });
  return decodeDoctorResponse(output.stdout);
}

export async function createSkillDraft(
  input: CreateSkillDraftInput,
): Promise<RequestReference> {
  const args = [
    "request",
    "create-skill",
    "--provider",
    "codex",
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

  const output = await runAgentTooling(args, {
    stdin: input.instruction,
    timeoutMs: 120_000,
    sensitiveValues: [input.instruction],
  });
  return decodeRequestResponse(output.stdout).request;
}

export async function openAgentToolingRoute(
  route: AgentToolingRoute,
): Promise<void> {
  const app = await findAgentToolingApplication();
  await open(routeURL(route), app);
}

export function userMessageForError(error: unknown): string {
  if (error instanceof AgentToolingFailure || error instanceof Error)
    return redactMessage(error.message);
  return "Agent Tooling could not complete the request.";
}

async function runAgentTooling(
  args: string[],
  options: RunOptions = {},
): Promise<ProcessOutput> {
  if (options.signal?.aborted) {
    throw new AgentToolingFailure(
      "cancelled",
      "The Agent Tooling request was cancelled.",
    );
  }
  const executable = await resolveCLIPath();
  if (options.signal?.aborted) {
    throw new AgentToolingFailure(
      "cancelled",
      "The Agent Tooling request was cancelled.",
    );
  }
  return await runExecutable(executable, args, options);
}

export async function findAgentToolingApplication(): Promise<Application> {
  const applications = (await getApplications()).filter(
    (application) => application.bundleId === AGENT_TOOLING_BUNDLE_ID,
  );
  const app = applications.sort(
    (left, right) => applicationPreference(left) - applicationPreference(right),
  )[0];
  if (!app) {
    throw new AgentToolingFailure(
      "app-not-found",
      "Agent Tooling is not installed. Install the desktop app before using this extension.",
    );
  }
  return app;
}

async function resolveCLIPath(): Promise<string> {
  const preferences = getPreferenceValues<ExtensionPreferences>();
  const override = normalizeFilePreference(preferences.cliPath);
  if (override) return await validateExecutable(override, undefined);

  const app = await findAgentToolingApplication();
  return await validateExecutable(
    path.join(app.path, CLI_RELATIVE_PATH),
    app.path,
  );
}

async function validateExecutable(
  candidatePath: string,
  containingAppPath: string | undefined,
): Promise<string> {
  let resolvedPath: string;
  try {
    resolvedPath = await realpath(candidatePath);
    const metadata = await lstat(resolvedPath);
    if (!metadata.isFile()) throw new Error("not a regular file");
    await access(resolvedPath, fsConstants.X_OK);
  } catch {
    const code = containingAppPath ? "helper-not-found" : "helper-invalid";
    const message = containingAppPath
      ? "The installed Agent Tooling app does not include its CLI helper. Update or reinstall the app."
      : "The configured CLI helper is missing or is not executable.";
    throw new AgentToolingFailure(code, message);
  }

  if (containingAppPath) {
    const resolvedAppPath = await realpath(containingAppPath);
    if (!isPathInside(resolvedAppPath, resolvedPath)) {
      throw new AgentToolingFailure(
        "helper-invalid",
        "The Agent Tooling helper resolves outside the signed app bundle.",
      );
    }
  }
  return resolvedPath;
}

function runExecutable(
  executable: string,
  args: string[],
  options: RunOptions,
): Promise<ProcessOutput> {
  if (options.signal?.aborted) {
    return Promise.reject(
      new AgentToolingFailure(
        "cancelled",
        "The Agent Tooling request was cancelled.",
      ),
    );
  }
  const timeoutMs = options.timeoutMs ?? 30_000;
  const acceptedExitCodes = options.acceptedExitCodes ?? [0];

  return new Promise((resolve, reject) => {
    let stdoutSize = 0;
    let stderrSize = 0;
    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];
    let completed = false;
    const timers: { timeout?: NodeJS.Timeout } = {};

    const child = spawn(executable, args, {
      detached: true,
      shell: false,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      env: { ...process.env, NO_COLOR: "1" },
    });

    const finish = (callback: () => void) => {
      if (completed) return;
      completed = true;
      if (timers.timeout) clearTimeout(timers.timeout);
      options.signal?.removeEventListener("abort", onAbort);
      callback();
    };

    const signalProcessGroup = (signal: NodeJS.Signals) => {
      if (child.exitCode !== null || child.signalCode !== null) return;
      try {
        if (child.pid !== undefined) process.kill(-child.pid, signal);
        else child.kill(signal);
      } catch {
        child.kill(signal);
      }
    };

    const terminate = () => {
      signalProcessGroup("SIGTERM");
      const forceKill = setTimeout(() => signalProcessGroup("SIGKILL"), 500);
      forceKill.unref();
    };

    const rejectForOutput = () => {
      terminate();
      finish(() =>
        reject(
          new AgentToolingFailure(
            "output-too-large",
            "Agent Tooling returned more data than this extension accepts.",
          ),
        ),
      );
    };

    child.stdout.on("data", (chunk: Buffer) => {
      stdoutSize += chunk.length;
      if (stdoutSize > MAX_JSON_BYTES) return rejectForOutput();
      stdoutChunks.push(chunk);
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderrSize += chunk.length;
      if (stderrSize > MAX_ERROR_BYTES) return rejectForOutput();
      stderrChunks.push(chunk);
    });
    child.stdin.on("error", (error: NodeJS.ErrnoException) => {
      if (error.code === "EPIPE") return;
      terminate();
      finish(() =>
        reject(
          new AgentToolingFailure(
            "command-failed",
            `Agent Tooling could not receive the request: ${redactMessage(error.message, options.sensitiveValues)}`,
          ),
        ),
      );
    });

    child.on("error", (error) => {
      finish(() =>
        reject(
          new AgentToolingFailure(
            "command-failed",
            `Agent Tooling could not start: ${redactMessage(error.message, options.sensitiveValues)}`,
          ),
        ),
      );
    });

    child.on("close", (code) => {
      finish(() => {
        const exitCode = code ?? -1;
        const stdout = Buffer.concat(stdoutChunks).toString("utf8");
        const stderr = Buffer.concat(stderrChunks).toString("utf8");
        if (!acceptedExitCodes.includes(exitCode)) {
          const detail = redactMessage(stderr, options.sensitiveValues);
          const suffix = detail ? ` ${detail}` : "";
          reject(
            new AgentToolingFailure(
              "command-failed",
              `Agent Tooling could not complete the request.${suffix}`,
            ),
          );
          return;
        }
        resolve({ stdout, stderr, exitCode });
      });
    });

    const onAbort = () => {
      terminate();
      finish(() =>
        reject(
          new AgentToolingFailure(
            "cancelled",
            "The Agent Tooling request was cancelled.",
          ),
        ),
      );
    };
    timers.timeout = setTimeout(() => {
      terminate();
      finish(() =>
        reject(
          new AgentToolingFailure(
            "timeout",
            "Agent Tooling did not respond before the timeout.",
          ),
        ),
      );
    }, timeoutMs);
    options.signal?.addEventListener("abort", onAbort, { once: true });
    if (options.signal?.aborted) {
      onAbort();
      return;
    }

    if (options.stdin !== undefined) child.stdin.end(options.stdin, "utf8");
    else child.stdin.end();
  });
}

function applicationPreference(application: Application): number {
  if (application.path.startsWith("/Applications/")) return 0;
  if (application.path.includes("/Applications/")) return 1;
  return 2;
}
