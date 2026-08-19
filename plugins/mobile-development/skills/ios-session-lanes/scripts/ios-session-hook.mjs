#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
	bootstrap,
	localBootstrapStatus,
	parseBootstrapOptions,
} from "./bootstrap-worktree.mjs";
import { getLane, sessionKey } from "./ios-session-lane.mjs";
import { isMainModule, projectMatch } from "./project-context.mjs";

const scriptsRoot = path.dirname(fileURLToPath(import.meta.url));

export function isLaneCommand(command) {
	return /\bios-session-lane\b/.test(command) || /ios-session-lane\.mjs/.test(command);
}

export function directIosReason(command) {
	if (isLaneCommand(command)) return "";
	if (/\bexpo\s+(?:start|run:ios)\b/.test(command)) {
		return "Direct Expo Metro or iOS commands bypass the session lane.";
	}
	if (/\bpnpm\b[^\n;&|]*(?:--dir\s+apps\/mobile|apps\/mobile)[^\n;&|]*\b(?:start(?::local)?|ios(?::device)?)\b/.test(command)) {
		return "Direct mobile Metro or iOS scripts bypass the session lane.";
	}
	if (/\bxcrun\s+simctl\s+(?:boot|shutdown|erase|delete|install|uninstall|launch|terminate|openurl)\b/.test(command)) {
		return "Direct simulator mutation bypasses the session lane's assigned UDID.";
	}
	if (/\bxcrun\s+devicectl\s+device\s+(?:install|process)\b/.test(command)) {
		return "Direct physical-device mutation bypasses the reserved device lane.";
	}
	if (/\bxcodebuild\b[^\n;&|]*(?:-destination|\btest\b)/.test(command)) {
		return "Direct Xcode simulator execution bypasses the lane's assigned destination.";
	}
	if (/\b(?:eas|eas-cli)\s+build\b[^\n;&|]*--profile\s+(?:development|development-device)\b/.test(command)) {
		return "This workflow never submits an EAS development build; native development builds are local.";
	}
	if (/\b(?:agent-device|argent|maestro)\b/.test(command)) {
		return "Device controllers must run through the lane's input-writer lease.";
	}
	if (/\b(?:pkill|kill(?:all))\b[^\n;&|]*(?:Simulator|Metro|expo|node)/i.test(command)) {
		return "Broad process termination can stop another session's simulator or Metro server.";
	}
	return "";
}

export function directBackendReason(command) {
	if (isLaneCommand(command)) return "";
	if (/\bsupabase\s+(?:start|stop)\b/.test(command)) {
		return "The local Supabase stack is shared and requires its owner lease.";
	}
	if (/\bsupabase\s+db\s+reset\b/.test(command)) {
		return "A shared local Supabase reset must not run from an ordinary app lane.";
	}
	if (/\bpnpm\b[^\n;&|]*--dir\s+apps\/backend[^\n;&|]*\b(?:start|stop|db:reset(?::bare)?)\b/.test(command)) {
		return "The local Supabase lifecycle is single-owner across all app lanes.";
	}
	return "";
}

export function directWorktreeReason(command) {
	if (/\bios-session-worktree\b/.test(command) || /create-worktree\.mjs/.test(command)) return "";
	if (/\bgit\s+worktree\s+add\b/.test(command)) {
		return "Raw worktree creation skips the mandatory EAS, Doppler, and dependency bootstrap.";
	}
	return "";
}

function parseClient(args) {
	const index = args.indexOf("--client");
	return index >= 0 ? args[index + 1] : "unknown";
}

function payloadSessionId(payload) {
	return String(payload.session_id ?? payload.thread_id ?? payload.conversation_id ?? "");
}

function laneCommand(client, sessionId, suffix = "") {
	return `ios-session-lane up --client ${client} --session-id ${sessionId}${suffix ? ` ${suffix}` : ""}`;
}

function deny(reason) {
	process.stdout.write(JSON.stringify({
		hookSpecificOutput: {
			hookEventName: "PreToolUse",
			permissionDecision: "deny",
			permissionDecisionReason: reason,
		},
	}));
}

function currentBranch(root) {
	const result = spawnSync("git", ["branch", "--show-current"], { cwd: root, encoding: "utf8" });
	return result.stdout.trim() || "detached";
}

function bootstrapForSession(root) {
	const options = { ...parseBootstrapOptions(["--quiet"]), projectRoot: root };
	const before = localBootstrapStatus(options);
	if (!before.ok) bootstrap(options);
	return { changed: !before.ok, status: localBootstrapStatus(options) };
}

function sessionContext(payload, client, root, bootstrapResult) {
	const sessionId = payloadSessionId(payload);
	if (!sessionId) return "";
	const bootstrapMessage = bootstrapResult.status.ok
		? `Worktree bootstrap is current (EAS mobile env and Doppler access; values hidden)${bootstrapResult.changed ? " and was repaired at session start" : ""}.`
		: `WORKTREE BOOTSTRAP REQUIRED: ${bootstrapResult.status.reasons.join("; ")}.`;
	return [
		`Branch: ${currentBranch(root)}`,
		bootstrapMessage,
		`PUMPD iOS lane identity: ${sessionKey(client, sessionId)}.`,
		"Default to a simulator lane. Ask before selecting the physical iPhone lane.",
		"When iOS or Metro is needed, do not run raw Expo, simulator mutation, or undirected device-controller commands.",
		`Start or reconnect: \`${laneCommand(client, sessionId)}\`. The native fingerprint selects a compatible installed or cached binary, otherwise a local Xcode build.`,
		`Status: \`ios-session-lane status --client ${client} --session-id ${sessionId}\` for the assigned Metro port and simulator UDID.`,
		`Input: \`ios-session-lane control --client ${client} --session-id ${sessionId} -- <agent-device args>\`. SimView is read-only; Maestro requires its lane lease.`,
		"Local Supabase is shared. Consume the running stack; only its registered owner may start, stop, or reset it.",
		"Physical lanes use Tailscale plus remote development Supabase. If the phone is unreachable, use the reported simulator fallback; never request an EAS development build.",
	].join("\n");
}

async function handleStart(payload, client, root) {
	try {
		return sessionContext(payload, client, root, bootstrapForSession(root));
	} catch (error) {
		const sessionId = payloadSessionId(payload);
		return [
			`PUMPD worktree bootstrap failed: ${error.message}`,
			`Repair separately with \`ios-session-bootstrap --project-root "${root}"\`.`,
			sessionId ? `Do not start iOS until bootstrap succeeds. Lane identity: ${sessionKey(client, sessionId)}.` : "",
		].filter(Boolean).join("\n");
	}
}

function shellCommand(payload) {
	return String(payload.tool_input?.command ?? payload.tool_input?.cmd ?? payload.input?.command ?? payload.input?.cmd ?? "");
}

function isShellTool(toolName) {
	return /(?:^|__)(?:Bash|Shell|exec_command|run_command)$/i.test(toolName);
}

async function handlePreTool(payload, client) {
	const sessionId = payloadSessionId(payload);
	if (!sessionId) return;
	const toolName = String(payload.tool_name ?? payload.tool ?? "");
	if (isShellTool(toolName)) {
		const command = shellCommand(payload);
		const reason = directIosReason(command) || directBackendReason(command) || directWorktreeReason(command);
		if (reason) {
			deny(`${reason} Use ${laneCommand(client, sessionId)} for iOS, or ios-session-lane backend-up --client ${client} --session-id ${sessionId} for the shared backend owner.`);
		}
		return;
	}

	const controllerTool = controllerForTool(toolName);
	if (!controllerTool) return;
	const lane = await getLane(client, sessionId);
	if (!lane) {
		deny(`Acquire the chat's iOS lane first with ${laneCommand(client, sessionId)}.`);
		return;
	}
	if (lane.target?.kind !== "simulator") {
		deny(`${controllerTool} simulator tools cannot control a physical lane.`);
		return;
	}
	const requestedUdid = requestedDeviceId(payload.tool_input ?? payload.input);
	if (/simview/i.test(toolName)) {
		if (/(?:connect_device|open_simview)/i.test(toolName) && requestedUdid !== lane.target.udid) {
			deny(`SimView must connect to this chat's assigned device ${lane.target.udid}.`);
			return;
		}
		if (!simViewToolIsReadOnly(toolName)) {
			deny("SimView is observation-only for PUMPD lanes. Use the lane's agent-device or Maestro input-writer adapter for mutations.");
		}
		return;
	}
	if (lane.controller?.controller !== controllerTool) {
		deny(`${controllerTool} does not own lane input. Run ios-session-lane controller-acquire --client ${client} --session-id ${sessionId} --controller ${controllerTool} --force-controller.`);
		return;
	}
	if (!requestedUdid || requestedUdid !== lane.target.udid) {
		deny(`${controllerTool} must explicitly target lane device ${lane.target.udid}.`);
	}
}

export function simViewToolIsReadOnly(toolName) {
	return /(?:connect_device|open_simview|list_devices|get_[a-z0-9_]+|observe_screen|take_screenshot|find_elements|search_elements|wait_for_element|inspect_point|add_annotation)$/i.test(toolName);
}

function controllerForTool(toolName) {
	if (/simview/i.test(toolName)) return "simview";
	if (/argent/i.test(toolName)) return "argent";
	if (/xcodebuild/i.test(toolName)) return "xcodebuildmcp";
	return "";
}

function requestedDeviceId(value) {
	if (!value || typeof value !== "object") return "";
	for (const key of ["deviceId", "device_id", "id", "simulatorId", "simulator_id", "udid"]) {
		if (typeof value[key] === "string") return value[key];
	}
	for (const nested of Object.values(value)) {
		const found = requestedDeviceId(nested);
		if (found) return found;
	}
	return "";
}

function handleEnd(payload, client, root) {
	const sessionId = payloadSessionId(payload);
	if (!sessionId) return;
	spawnSync(process.execPath, [
		path.join(scriptsRoot, "ios-session-lane.mjs"),
		"down", "--client", client, "--session-id", sessionId, "--quiet",
	], { cwd: root, stdio: "ignore", timeout: 25_000 });
}

async function readStdin() {
	let input = "";
	for await (const chunk of process.stdin) input += chunk;
	return input ? JSON.parse(input) : {};
}

async function main() {
	const action = process.argv[2];
	const client = parseClient(process.argv.slice(3));
	const payload = await readStdin();
	const rootHint = String(payload.cwd ?? payload.project_dir ?? process.cwd());
	const project = projectMatch(rootHint);
	if (!project.ok) return;
	if (action === "start") process.stdout.write(await handleStart(payload, client, project.root));
	else if (action === "pretool") await handlePreTool(payload, client);
	else if (action === "end") handleEnd(payload, client, project.root);
	else throw new Error(`Unknown hook action ${action}.`);
}

if (isMainModule(import.meta.url)) {
	main().catch((error) => {
		if (process.argv[2] === "pretool") {
			deny(`PUMPD lane guard could not validate this command: ${error.message}`);
		} else {
			console.error(`[ios-lane-hook] ${error.message}`);
		}
		process.exitCode = 1;
	});
}
