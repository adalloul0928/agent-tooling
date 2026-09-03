#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
	bootstrap,
	localBootstrapStatus,
	managedWorktreeAttestationStatus,
	parseBootstrapOptions,
} from "./bootstrap-worktree.mjs";
import { sessionKey } from "./lane-identifiers.mjs";
import { isMainModule, projectMatch } from "./project-context.mjs";

const scriptsRoot = path.dirname(fileURLToPath(import.meta.url));
const hookScriptPath = fileURLToPath(import.meta.url);
const laneScriptPath = path.join(scriptsRoot, "ios-session-lane.mjs");
const runtimeOwner = "agent-tooling-ios-session-lanes-runtime";
const runtimeOwnerFile = ".agent-tooling-runtime-owner.json";
const runtimeOwnerVersion = 1;
const runtimeIntegrityVersion = 3;

function normalizedShellText(command) {
	let result = "";
	let quote = "";
	let escaped = false;
	for (const character of String(command ?? "")) {
		if (escaped) {
			if (character !== "\n" && character !== "\r") result += character;
			escaped = false;
			continue;
		}
		if (character === "\\" && quote !== "'") {
			escaped = true;
			continue;
		}
		if (quote) {
			if (character === quote) quote = "";
			else result += character;
			continue;
		}
		if (character === "'" || character === '"') {
			quote = character;
			continue;
		}
		result += character;
	}
	if (escaped) result += "\\";
	return result;
}

export function isLaneCommand(command) {
	return sessionWrapperKinds(command).has("lane");
}

export function isWorktreeCommand(command) {
	return sessionWrapperKinds(command).has("worktree");
}

function scanShell(command) {
	let quote = "";
	let escaped = false;
	let substitution = false;
	let topLevelControl = false;
	for (let index = 0; index < command.length; index += 1) {
		const character = command[index];
		if (escaped) {
			escaped = false;
			continue;
		}
		if (character === "\\" && quote !== "'") {
			escaped = true;
			continue;
		}
		if (quote === "'") {
			if (character === "'") quote = "";
			continue;
		}
		if (character === "`" || (character === "$" && command[index + 1] === "(")) {
			substitution = true;
			continue;
		}
		if (!quote && (character === "<" || character === ">") && command[index + 1] === "(") {
			substitution = true;
			continue;
		}
		if (quote === '"') {
			if (character === '"') quote = "";
			continue;
		}
		if (character === "'" || character === '"') {
			quote = character;
			continue;
		}
		if (
			character === ";" ||
			character === "|" ||
			character === "&" ||
			character === "\n" ||
			character === "#" ||
			character === "<" ||
			character === ">"
		) {
			topLevelControl = true;
		}
	}
	return {
		invalid: Boolean(quote || escaped),
		substitution,
		topLevelControl,
	};
}

export function shellSubstitutionReason(command) {
	return scanShell(command).substitution
		? "Shell and process substitutions are not allowed in guarded PUMPD commands."
		: "";
}

export function shellDynamicExecutionReason(command) {
	const normalized = normalizedShellText(command);
	const protectedAssignments = normalized.matchAll(
		/\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:[^\s;&|]+\/)?(?:expo|xcrun|xcodebuild|eas|eas-cli|supabase|git|pnpm|npm|yarn|bun|maestro|argent|agent-device|ios-session-lane|ios-session-worktree)\b/gi,
	);
	for (const [, variable] of protectedAssignments) {
		const invocation = new RegExp(
			`(?:^|[;&|()\\n])\\s*(?:command\\s+|env\\s+)?\\$(?:${variable}\\b|\\{${variable}\\})`,
		);
		if (invocation.test(normalized)) {
			return "Protected PUMPD executables cannot be invoked through shell variables.";
		}
	}
	return "";
}

function shellWords(command) {
	const words = [];
	let current = "";
	let quote = "";
	let escaped = false;
	for (const character of command.trim()) {
		if (escaped) {
			if (character !== "\n" && character !== "\r") current += character;
			escaped = false;
			continue;
		}
		if (character === "\\" && quote !== "'") {
			escaped = true;
			continue;
		}
		if (quote) {
			if (character === quote) quote = "";
			else current += character;
			continue;
		}
		if (character === "'" || character === '"') {
			quote = character;
			continue;
		}
		if (/\s/.test(character)) {
			if (current) words.push(current);
			current = "";
		} else current += character;
	}
	if (current) words.push(current);
	return words;
}

function closingSubstitutionParen(command, openingIndex) {
	let depth = 1;
	let escaped = false;
	let quote = "";
	for (let index = openingIndex + 1; index < command.length; index += 1) {
		const character = command[index];
		if (escaped) {
			escaped = false;
			continue;
		}
		if (character === "\\" && quote !== "'") {
			escaped = true;
			continue;
		}
		if (quote) {
			if (character === quote) quote = "";
			continue;
		}
		if (character === "'" || character === '"') {
			quote = character;
			continue;
		}
		if (character === "$" && command[index + 1] === "(") {
			depth += 1;
			index += 1;
			continue;
		}
		if (character === ")") {
			depth -= 1;
			if (depth === 0) return index;
		}
	}
	return -1;
}

function closingBacktick(command, openingIndex) {
	let escaped = false;
	for (let index = openingIndex + 1; index < command.length; index += 1) {
		const character = command[index];
		if (escaped) {
			escaped = false;
			continue;
		}
		if (character === "\\") {
			escaped = true;
			continue;
		}
		if (character === "`") return index;
	}
	return -1;
}

function shellCommandSegments(command, collected = []) {
	let current = "";
	let escaped = false;
	let quote = "";
	function pushCurrent() {
		if (current.trim()) collected.push(current.trim());
		current = "";
	}
	for (let index = 0; index < command.length; index += 1) {
		const character = command[index];
		if (escaped) {
			current += character;
			escaped = false;
			continue;
		}
		if (character === "\\" && quote !== "'") {
			current += character;
			escaped = true;
			continue;
		}
		if (quote !== "'" && character === "$" && command[index + 1] === "(") {
			const closing = closingSubstitutionParen(command, index + 1);
			if (closing < 0) {
				current += command.slice(index);
				break;
			}
			shellCommandSegments(command.slice(index + 2, closing), collected);
			current += "__shell_substitution__";
			index = closing;
			continue;
		}
		if (quote !== "'" && character === "`") {
			const closing = closingBacktick(command, index);
			if (closing < 0) {
				current += command.slice(index);
				break;
			}
			shellCommandSegments(command.slice(index + 1, closing), collected);
			current += "__shell_substitution__";
			index = closing;
			continue;
		}
		if (quote) {
			current += character;
			if (character === quote) quote = "";
			continue;
		}
		if (character === "'" || character === '"') {
			quote = character;
			current += character;
			continue;
		}
		if (character === ";" || character === "|" || character === "&" || character === "\n" || character === "(" || character === ")") {
			pushCurrent();
			continue;
		}
		current += character;
	}
	pushCurrent();
	return collected;
}

function wrapperKindAt(words, start = 0) {
	let index = start;
	while (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[index] ?? "")) index += 1;
	while (["!", "if", "then", "elif", "while", "until", "do", "time"].includes(words[index])) {
		index += 1;
	}
	const executable = path.basename(words[index] ?? "");
	if (executable === "ios-session-lane") return "lane";
	if (executable === "ios-session-worktree") return "worktree";
	if (executable === "node") {
		const script = path.basename(words[index + 1] ?? "");
		if (script === "ios-session-lane.mjs") return "lane";
		if (script === "create-worktree.mjs") return "worktree";
	}
	if (executable === "command") {
		if (["-v", "-V"].includes(words[index + 1])) return "";
		while (words[index + 1]?.startsWith("-")) index += 1;
		return wrapperKindAt(words, index + 1);
	}
	if (["exec", "nohup"].includes(executable)) {
		while (words[index + 1]?.startsWith("-")) index += 1;
		return wrapperKindAt(words, index + 1);
	}
	if (executable === "env") {
		index += 1;
		while (words[index]?.startsWith("-") || /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[index] ?? "")) {
			index += 1;
		}
		return wrapperKindAt(words, index);
	}
	if (executable === "sudo") {
		index += 1;
		const optionsWithValues = new Set(["-C", "-D", "-g", "-h", "-p", "-R", "-r", "-T", "-t", "-u"]);
		while (words[index]?.startsWith("-")) {
			if (optionsWithValues.has(words[index])) index += 1;
			index += 1;
		}
		return wrapperKindAt(words, index);
	}
	if (["bash", "dash", "sh", "zsh"].includes(executable)) {
		const commandIndex = words.findIndex((word, wordIndex) => wordIndex > index && word === "-c");
		if (commandIndex >= 0 && words[commandIndex + 1]) {
			return [...sessionWrapperKinds(words[commandIndex + 1])][0] ?? "";
		}
	}
	if (executable === "eval" && words[index + 1]) {
		return [...sessionWrapperKinds(words.slice(index + 1).join(" "))][0] ?? "";
	}
	if (executable === "xargs") {
		index += 1;
		while (words[index]?.startsWith("-")) index += 1;
		return wrapperKindAt(words, index);
	}
	if (executable === "find") {
		const execIndex = words.findIndex((word) => word === "-exec" || word === "-execdir");
		if (execIndex >= 0) return wrapperKindAt(words, execIndex + 1);
	}
	return "";
}

function sessionWrapperKinds(command) {
	const kinds = new Set();
	for (const segment of shellCommandSegments(String(command ?? ""))) {
		const kind = wrapperKindAt(shellWords(segment));
		if (kind) kinds.add(kind);
	}
	return kinds;
}

function optionValues(words, option) {
	const values = [];
	for (let index = 0; index < words.length; index += 1) {
		if (words[index] === option && words[index + 1]) values.push(words[index + 1]);
		else if (words[index].startsWith(`${option}=`)) values.push(words[index].slice(option.length + 1));
	}
	return values;
}

export function laneWrapperReason(command, client, sessionId) {
	if (!isLaneCommand(command)) return "";
	const shell = scanShell(command);
	if (shell.substitution || shell.topLevelControl || shell.invalid) {
		return "The iOS lane wrapper must be the only top-level shell command.";
	}
	const words = shellWords(command);
	let executableIndex = -1;
	if (path.basename(words[0] ?? "") === "ios-session-lane") executableIndex = 0;
	else if (
		path.basename(words[0] ?? "") === "node" &&
		path.basename(words[1] ?? "") === "ios-session-lane.mjs"
	) executableIndex = 1;
	if (executableIndex < 0) return "The iOS lane wrapper invocation could not be validated.";
	if (words[executableIndex].endsWith(".mjs")) {
		if (executableIndex !== 1 || path.basename(words[0]) !== "node") {
			return "The iOS lane script must be invoked directly through Node.";
		}
	} else if (executableIndex !== 0) {
		return "The iOS lane wrapper must be invoked directly.";
	}
	const commandName = words[executableIndex + 1] ?? "help";
	if (commandName === "list") return "";
	if (!sessionId) return "The hook payload has no session identity for this lane command.";
	const clients = optionValues(words, "--client");
	const sessions = optionValues(words, "--session-id");
	if (clients.length !== 1 || clients[0] !== client) {
		return `The lane wrapper must use this hook client: ${client}.`;
	}
	if (sessions.length !== 1 || sessions[0] !== sessionId) {
		return "The lane wrapper must use this task's exact session id.";
	}
	return "";
}

function hashFile(filePath) {
	return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function generatedWrapper(scriptPath) {
	const quoted = `'${scriptPath.replaceAll("'", `'\"'\"'`)}'`;
	return `#!/bin/sh\nexec node ${quoted} "$@"\n`;
}

function runtimeRootFromGeneratedWrapper(wrapperPath) {
	try {
		const document = readFileSync(wrapperPath, "utf8");
		const prefix = "#!/bin/sh\nexec node '";
		const suffix = `' "$@"\n`;
		if (!document.startsWith(prefix) || !document.endsWith(suffix)) return "";
		const encodedScript = document.slice(prefix.length, -suffix.length);
		const scriptPath = encodedScript.replaceAll(`'"'"'`, "'");
		if (!path.isAbsolute(scriptPath) || generatedWrapper(scriptPath) !== document) return "";
		if (
			path.basename(scriptPath) !== "ios-session-lane.mjs" ||
			path.basename(path.dirname(scriptPath)) !== "scripts"
		) {
			return "";
		}
		return path.dirname(path.dirname(scriptPath));
	} catch {
		return "";
	}
}

function resolvedExecutable(value, cwd, environment) {
	if (!value) return "";
	if (value.includes(path.sep)) {
		const candidate = path.resolve(cwd, value);
		return existsSync(candidate) ? realpathSync(candidate) : "";
	}
	for (const directory of String(environment.PATH ?? "").split(path.delimiter)) {
		if (!directory) continue;
		const candidate = path.join(directory, value);
		if (existsSync(candidate)) return realpathSync(candidate);
	}
	return "";
}

function readRuntimeIntegrity(runtimeRoot) {
	const manifestPath = path.join(runtimeRoot, "runtime-integrity.json");
	if (!existsSync(manifestPath)) return null;
	try {
		return JSON.parse(readFileSync(manifestPath, "utf8"));
	} catch {
		return false;
	}
}

function runtimeFileHashes(root) {
	const hashes = {};
	function visit(directory) {
		for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) =>
			a.name.localeCompare(b.name),
		)) {
			const absolute = path.join(directory, entry.name);
			if (entry.isSymbolicLink()) throw new Error("runtime symlink");
			if (entry.isDirectory()) visit(absolute);
			else if (entry.isFile()) {
				const relative = path.relative(root, absolute).split(path.sep).join("/");
				if (relative !== "runtime-integrity.json") hashes[relative] = hashFile(absolute);
			}
		}
	}
	visit(root);
	return hashes;
}

function runtimeIntegrityTree(root) {
	const entries = [];
	function visit(absolute, relative) {
		if (relative === "runtime-integrity.json") return;
		const metadata = lstatSync(absolute);
		if (metadata.isSymbolicLink()) throw new Error("runtime tree symlink");
		if (metadata.isDirectory()) {
			entries.push({ mode: metadata.mode & 0o7777, path: relative, type: "directory" });
			for (const entry of readdirSync(absolute, { withFileTypes: true }).sort((a, b) =>
				a.name.localeCompare(b.name),
			)) {
				visit(
					path.join(absolute, entry.name),
					relative === "." ? entry.name : `${relative}/${entry.name}`,
				);
			}
			return;
		}
		if (metadata.isFile()) {
			entries.push({
				mode: metadata.mode & 0o7777,
				path: relative,
				sha256: hashFile(absolute),
				type: "file",
			});
			return;
		}
		throw new Error("runtime tree special entry");
	}
	visit(root, ".");
	return entries;
}

function runtimePayloadHashes(root) {
	const hashes = {};
	function visit(directory) {
		for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) =>
			a.name.localeCompare(b.name),
		)) {
			const absolute = path.join(directory, entry.name);
			if (entry.isSymbolicLink()) throw new Error("runtime payload symlink");
			if (entry.isDirectory()) visit(absolute);
			else if (entry.isFile()) {
				const relative = path.relative(root, absolute).split(path.sep).join("/");
				hashes[relative] = hashFile(absolute);
			}
		}
	}
	for (const relative of ["references", "scripts"]) {
		visit(path.join(root, relative));
	}
	return hashes;
}

export function verifiedRuntimeIntegrity(runtimeRoot) {
	const resolvedRoot = path.resolve(runtimeRoot);
	const integrity = readRuntimeIntegrity(resolvedRoot);
	if (integrity === null) return null;
	try {
		const owner = JSON.parse(
			readFileSync(path.join(resolvedRoot, runtimeOwnerFile), "utf8"),
		);
		const actualFiles = runtimeFileHashes(resolvedRoot);
		const actualTree = runtimeIntegrityTree(resolvedRoot);
		if (
			!integrity ||
			integrity.version !== runtimeIntegrityVersion ||
			path.resolve(integrity.runtimeRoot ?? "") !== resolvedRoot ||
			owner.owner !== runtimeOwner ||
			owner.version !== runtimeOwnerVersion ||
			JSON.stringify(integrity.files) !== JSON.stringify(actualFiles) ||
			JSON.stringify(integrity.tree) !== JSON.stringify(actualTree) ||
			integrity.files?.["scripts/ios-session-hook.mjs"] !==
				hashFile(path.join(resolvedRoot, "scripts", "ios-session-hook.mjs")) ||
			integrity.files?.["scripts/ios-session-lane.mjs"] !==
				hashFile(path.join(resolvedRoot, "scripts", "ios-session-lane.mjs"))
		) {
			return false;
		}
	} catch {
		return false;
	}
	return integrity;
}

export function trustedLaneInvocationReason(
	command,
	{
		cwd = process.cwd(),
		environment = process.env,
		runtimeRoot = "",
	} = {},
) {
	if (!isLaneCommand(command)) return "";
	const words = shellWords(command);
	if (
		path.basename(words[0] ?? "") === "node" &&
		path.basename(words[1] ?? "") === "ios-session-lane.mjs"
	) {
		const localIntegrity = verifiedRuntimeIntegrity(path.resolve(scriptsRoot, ".."));
		if (localIntegrity === false) {
			return "The local iOS lane runtime failed its complete path and digest handshake.";
		}
		const requestedScript = resolvedExecutable(words[1], cwd, environment);
		if (!requestedScript || requestedScript !== realpathSync(laneScriptPath)) {
			return "The iOS lane script path is not the trusted companion to this hook.";
		}
		return "";
	}
	if (path.basename(words[0] ?? "") !== "ios-session-lane") {
		return "The iOS lane wrapper invocation could not be authenticated.";
	}
	const requestedWrapper = resolvedExecutable(words[0], cwd, environment);
	if (!requestedWrapper) return "The installed iOS lane wrapper could not be resolved.";
	const wrapperRuntimeRoot = runtimeRootFromGeneratedWrapper(requestedWrapper);
	if (!wrapperRuntimeRoot) {
		return "The installed iOS lane wrapper is not an exact generated runtime wrapper.";
	}
	if (runtimeRoot && path.resolve(runtimeRoot) !== path.resolve(wrapperRuntimeRoot)) {
		return "The installed iOS lane wrapper does not belong to the requested runtime root.";
	}
	const integrity = verifiedRuntimeIntegrity(wrapperRuntimeRoot);
	if (integrity === false) {
		return "The installed iOS lane runtime failed its complete path and digest handshake.";
	}
	if (!integrity) {
		return "The iOS lane wrapper has no installed runtime integrity handshake; invoke the trusted companion script directly.";
	}
	if (
		JSON.stringify(runtimePayloadHashes(path.resolve(scriptsRoot, ".."))) !==
		JSON.stringify(
			Object.fromEntries(
				Object.entries(integrity.files ?? {}).filter(
					([relative]) =>
						relative.startsWith("scripts/") || relative.startsWith("references/"),
				),
			),
		)
	) {
		return "The installed iOS lane runtime does not match this plugin's complete runtime revision.";
	}
	let expectedWrapper = "";
	try {
		expectedWrapper = realpathSync(integrity.wrappers?.["ios-session-lane"]?.path ?? "");
	} catch {
		return "The installed iOS lane wrapper is missing from its integrity handshake.";
	}
	if (
		!requestedWrapper ||
		requestedWrapper !== expectedWrapper ||
		integrity.wrappers["ios-session-lane"].sha256 !== hashFile(requestedWrapper) ||
		integrity.wrappers["ios-session-lane"].mode !== 0o755 ||
		(lstatSync(requestedWrapper).mode & 0o7777) !== 0o755
	) {
		return "The iOS lane wrapper path or digest does not match the installed runtime.";
	}
	return "";
}

function isWorkspaceDirectory(workingDirectory, projectRoot, relative) {
	if (!workingDirectory || !projectRoot) return false;
	return path.resolve(workingDirectory) === path.resolve(projectRoot, relative);
}

export function directIosReason(command, context = {}) {
	const guarded = normalizedShellText(command);
	if (/\bexpo\b[^\n;&|]*\b(?:start|run:ios)\b/.test(guarded)) {
		return "Direct Expo Metro or iOS commands bypass the session lane.";
	}
	const mobileScript = "(?:start(?::local)?|ios(?::device)?)";
	const packageRunner = "(?:corepack\\s+)?(?:pnpm|npm|yarn|bun)";
	const mobilePath = "(?:[^\\s\"']*/)?apps/mobile/?";
	if (
		new RegExp(`\\b${packageRunner}\\b[^\\n;&|]*(?:-C|--dir|--prefix|--cwd)(?:=|\\s+)${mobilePath}[^\\n;&|]*\\b(?:run\\s+)?${mobileScript}\\b`).test(guarded) ||
		new RegExp(`\\b${packageRunner}\\b[^\\n;&|]*(?:--filter|-F)(?:=|\\s+)[^\\n;&|]*mobile[^\\n;&|]*\\b(?:run\\s+)?${mobileScript}\\b`).test(guarded) ||
		new RegExp(`\\b(?:cd|pushd)\\s+${mobilePath}\\s*(?:&&|;)\\s*${packageRunner}\\s+(?:run\\s+)?${mobileScript}\\b`).test(guarded) ||
		(isWorkspaceDirectory(context.workingDirectory, context.projectRoot, "apps/mobile") &&
			new RegExp(`^\\s*${packageRunner}\\s+(?:run\\s+)?${mobileScript}\\b`).test(guarded))
	) {
		return "Direct mobile Metro or iOS scripts bypass the session lane.";
	}
	if (/\bxcrun\b[^\n;&|]*\bsimctl\b[^\n;&|]*\b(?:boot|shutdown|erase|delete|install|uninstall|launch|terminate|openurl)\b/.test(guarded)) {
		return "Direct simulator mutation bypasses the session lane's assigned UDID.";
	}
	if (/\bxcrun\b[^\n;&|]*\bdevicectl\b[^\n;&|]*\bdevice\b[^\n;&|]*\b(?:install|process)\b/.test(guarded)) {
		return "Direct physical-device mutation bypasses the reserved device lane.";
	}
	if (/\bxcodebuild\b[^\n;&|]*(?:-destination|\btest\b)/.test(guarded)) {
		return "Direct Xcode simulator execution bypasses the lane's assigned destination.";
	}
	if (/\b(?:eas|eas-cli)\b[^\n;&|]*\bbuild\b[^\n;&|]*--profile(?:=|\s+)(?:development|development-device)\b/.test(guarded)) {
		return "This workflow never submits an EAS development build; native development builds are local.";
	}
	if (/(?:^|[;&|\n])\s*(?:agent-device|argent|maestro)\b/.test(guarded)) {
		return "Device controllers must run through the lane's input-writer lease.";
	}
	if (/\b(?:pkill|kill(?:all))\b[^\n;&|]*(?:Simulator|Metro|expo|node)/i.test(guarded)) {
		return "Broad process termination can stop another session's simulator or Metro server.";
	}
	return "";
}

export function directBackendReason(command, context = {}) {
	const guarded = normalizedShellText(command);
	if (/\bsupabase\b[^\n;&|]*\b(?:start|stop)\b/.test(guarded)) {
		return "The local Supabase stack is shared and requires its owner lease.";
	}
	if (/\bsupabase\b[^\n;&|]*\bdb\b[^\n;&|]*\breset\b/.test(guarded)) {
		return "A shared local Supabase reset must not run from an ordinary app lane.";
	}
	const backendScript = "(?:start|stop|db:reset(?::bare)?)";
	const packageRunner = "(?:corepack\\s+)?(?:pnpm|npm|yarn|bun)";
	const backendPath = "(?:[^\\s\"']*/)?apps/backend/?";
	if (
		new RegExp(`\\b${packageRunner}\\b[^\\n;&|]*(?:-C|--dir|--prefix|--cwd)(?:=|\\s+)${backendPath}[^\\n;&|]*\\b(?:run\\s+)?${backendScript}\\b`).test(guarded) ||
		new RegExp(`\\b${packageRunner}\\b[^\\n;&|]*(?:--filter|-F)(?:=|\\s+)[^\\n;&|]*backend[^\\n;&|]*\\b(?:run\\s+)?${backendScript}\\b`).test(guarded) ||
		new RegExp(`\\b(?:cd|pushd)\\s+${backendPath}\\s*(?:&&|;)\\s*${packageRunner}\\s+(?:run\\s+)?${backendScript}\\b`).test(guarded) ||
		(isWorkspaceDirectory(context.workingDirectory, context.projectRoot, "apps/backend") &&
			new RegExp(`^\\s*${packageRunner}\\s+(?:run\\s+)?${backendScript}\\b`).test(guarded))
	) {
		return "The local Supabase lifecycle is single-owner across all app lanes.";
	}
	return "";
}

export function directWorktreeReason(command) {
	const guarded = normalizedShellText(command);
	if (/\bgit\b[^\n;&|]*\bworktree\s+add\b/.test(guarded)) {
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

function shellQuote(value) {
	return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

function laneCommand(client, sessionId, suffix = "") {
	return `node ${shellQuote(laneScriptPath)} up --client ${shellQuote(client)} --session-id ${shellQuote(sessionId)}${suffix ? ` ${suffix}` : ""}`;
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

async function bootstrapForSession(root) {
	const options = { ...parseBootstrapOptions(["--quiet"]), projectRoot: root };
	const before = localBootstrapStatus(options);
	if (before.ok) return { changed: false, status: before };
	const attestation = managedWorktreeAttestationStatus(options);
	if (!attestation.ok) {
		return {
			attestation,
			changed: false,
			skippedAutomaticBootstrap: true,
			status: before,
		};
	}
	await bootstrap(options);
	return {
		attestation,
		changed: true,
		skippedAutomaticBootstrap: false,
		status: localBootstrapStatus(options),
	};
}

function sessionContext(payload, client, root, bootstrapResult) {
	const sessionId = payloadSessionId(payload);
	if (!sessionId) return "";
	const bootstrapMessage = bootstrapResult.status.ok
		? `Worktree bootstrap is current (EAS mobile env and Doppler access; values hidden)${bootstrapResult.changed ? " and was repaired at session start from its managed-worktree attestation" : ""}.`
		: `WORKTREE BOOTSTRAP REQUIRED: ${bootstrapResult.status.reasons.join("; ")}. SessionStart did not run pnpm, EAS, or Doppler because ${bootstrapResult.attestation?.reason ?? "the worktree is not attested as managed"}. Run the explicit bootstrap command before iOS work.`;
	return [
		`Branch: ${currentBranch(root)}`,
		bootstrapMessage,
		`PUMPD iOS lane identity: ${sessionKey(client, sessionId)}.`,
		`Before first launch, check \`ios-session-lane status --client ${client} --session-id ${sessionId}\`. Reconnect without asking if it exists.`,
		"If no lane exists and the user did not already specify the choices, ask once: Simulator + Local (Recommended), Simulator + Preview, or Physical iPhone (Preview + Tailscale). Allow a custom answer.",
		"Preset mapping: simulator-local, simulator-preview, iphone-preview. Custom lanes must explicitly set target, backend, and exposure; simulator-preview-tailscale is also available.",
		"When iOS or Metro is needed, do not run raw Expo, simulator mutation, or undirected device-controller commands.",
		`After confirmation, start with \`${laneCommand(client, sessionId, "--preset <preset>")}\`. The native fingerprint selects a compatible installed or cached binary, otherwise a local Xcode build.`,
		`Status: \`ios-session-lane status --client ${client} --session-id ${sessionId}\` for the assigned Metro port and simulator UDID.`,
		`Input: \`ios-session-lane control --client ${client} --session-id ${sessionId} -- <agent-device args>\`. SimView is read-only; Maestro requires its lane lease.`,
		"Local Supabase is shared. Consume the running stack; only its registered owner may start, stop, or reset it.",
		"Physical lanes use Tailscale plus Preview Supabase. If the phone is unreachable, use the reported simulator fallback; never request an EAS development build.",
	].join("\n");
}

async function handleStart(payload, client, root) {
	try {
		return sessionContext(payload, client, root, await bootstrapForSession(root));
	} catch (error) {
		const sessionId = payloadSessionId(payload);
		return [
			`PUMPD worktree bootstrap check or repair failed: ${error.message}`,
			`Repair separately with \`node ${shellQuote(path.join(scriptsRoot, "bootstrap-worktree.mjs"))} --project-root ${shellQuote(root)}\`.`,
			sessionId ? `Do not start iOS until bootstrap succeeds. Lane identity: ${sessionKey(client, sessionId)}.` : "",
		].filter(Boolean).join("\n");
	}
}

function shellCommand(payload) {
	const input = payload.tool_input ?? payload.input ?? {};
	if (typeof input === "string") return input;
	return String(input.command ?? input.cmd ?? input.code ?? input.source ?? "");
}

function isShellTool(toolName) {
	return /(?:^|__|\.)(?:Bash|Shell|exec|exec_command|run_command)$/i.test(toolName);
}

function commandWorkingDirectory(payload, root) {
	const input = payload.tool_input ?? payload.input ?? {};
	const requested =
		input && typeof input === "object"
			? input.workdir ?? input.cwd ?? payload.cwd ?? payload.project_dir
			: payload.cwd ?? payload.project_dir;
	return path.resolve(root, String(requested || root));
}

async function getLaneForProject(client, sessionId, root) {
	process.env.IOS_SESSION_LANES_PROJECT_ROOT = root;
	const { getLane } = await import("./ios-session-lane.mjs");
	return getLane(client, sessionId);
}

async function handleHeartbeat(payload, client, root) {
	const sessionId = payloadSessionId(payload);
	if (!sessionId) return;
	process.env.IOS_SESSION_LANES_PROJECT_ROOT = root;
	const { heartbeat } = await import("./ios-session-lane.mjs");
	await heartbeat({ client, sessionId });
}

async function handlePreTool(payload, client, root) {
	const sessionId = payloadSessionId(payload);
	const toolName = String(payload.tool_name ?? payload.tool ?? "");
	if (isShellTool(toolName)) {
		const command = shellCommand(payload);
		const commandContext = {
			projectRoot: root,
			workingDirectory: commandWorkingDirectory(payload, root),
		};
		const wrapperReason = laneWrapperReason(command, client, sessionId);
		const trustReason = wrapperReason
			? ""
			: trustedLaneInvocationReason(command, {
				cwd: commandContext.workingDirectory,
				environment: process.env,
			});
		const guardedReason =
			wrapperReason ||
			trustReason ||
			shellDynamicExecutionReason(command) ||
			directIosReason(command, commandContext) ||
			directBackendReason(command, commandContext) ||
			directWorktreeReason(command);
		const reason =
			(guardedReason && shellSubstitutionReason(command)) || guardedReason;
		if (reason) {
			const recovery = sessionId
				? `Check this session's lane status, ask the user for a lane preset if none exists, then use ${laneCommand(client, sessionId, "--preset <preset>")} for iOS. Use ios-session-lane backend-up --client ${client} --session-id ${sessionId} only for the shared backend owner.`
				: "The hook payload had no session identity, so guarded PUMPD operations fail closed.";
			deny(`${reason} ${recovery}`);
		}
		return;
	}

	const controllerTool = controllerForTool(toolName);
	if (!controllerTool) return;
	if (!sessionId) {
		deny("The hook payload had no session identity, so PUMPD device tools fail closed.");
		return;
	}
	const lane = await getLaneForProject(client, sessionId, root);
	if (!lane) {
		deny(`No lane exists. Ask the user to choose simulator-local, simulator-preview, iphone-preview, or custom settings, then run ${laneCommand(client, sessionId, "--preset <preset>")}.`);
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
	if (/ios[_-]?simulator/i.test(toolName)) {
		if (!iosSimulatorToolIsReadOnly(toolName)) {
			deny("The raw iOS Simulator MCP is observation-only for PUMPD lanes. Use the lane controller adapter for input, app installation, and launch.");
			return;
		}
		if (!requestedUdid || requestedUdid !== lane.target.udid) {
			deny(`The iOS Simulator MCP must explicitly observe lane device ${lane.target.udid}.`);
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

export function iosSimulatorToolIsReadOnly(toolName) {
	return /(?:ui_describe_all|ui_describe_point|ui_find_element|ui_view|screenshot)$/i.test(
		toolName,
	);
}

function controllerForTool(toolName) {
	if (/simview/i.test(toolName)) return "simview";
	if (/ios[_-]?simulator/i.test(toolName)) return "ios-simulator";
	if (/agent[_-]?device/i.test(toolName)) return "agent-device";
	if (/maestro/i.test(toolName)) return "maestro";
	if (/argent/i.test(toolName)) return "argent";
	if (/xcodebuild/i.test(toolName)) return "xcodebuildmcp";
	return "";
}

export function requestedDeviceId(value) {
	const acceptedKeys = new Set([
		"deviceId",
		"device_id",
		"simulatorId",
		"simulator_id",
		"udid",
	]);
	const identifiers = new Set();
	const visited = new WeakSet();
	function visit(candidate) {
		if (!candidate || typeof candidate !== "object" || visited.has(candidate)) return;
		visited.add(candidate);
		for (const [key, nested] of Object.entries(candidate)) {
			if (acceptedKeys.has(key) && typeof nested === "string" && nested.trim()) {
				identifiers.add(nested.trim());
			} else if (nested && typeof nested === "object") {
				visit(nested);
			}
		}
	}
	visit(value);
	return identifiers.size === 1 ? [...identifiers][0] : "";
}

function handleEnd(payload, client, root) {
	const sessionId = payloadSessionId(payload);
	if (!sessionId) return;
	const child = spawn(process.execPath, [
		path.join(scriptsRoot, "ios-session-lane.mjs"),
		"down", "--client", client, "--session-id", sessionId, "--quiet",
	], { cwd: root, detached: true, stdio: "ignore" });
	child.unref();
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
	else if (action === "heartbeat") await handleHeartbeat(payload, client, project.root);
	else if (action === "pretool") await handlePreTool(payload, client, project.root);
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
