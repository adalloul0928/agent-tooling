#!/usr/bin/env node

import {
	chmodSync,
	copyFileSync,
	cpSync,
	existsSync,
	mkdirSync,
	readFileSync,
	renameSync,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMainModule } from "./project-context.mjs";

const sourceScripts = path.dirname(fileURLToPath(import.meta.url));
const sourceSkill = path.resolve(sourceScripts, "..");
const marker = "agent-tooling-ios-session-lanes";

export function parseInstallOptions(args) {
	const options = {
		binDir: path.join(homedir(), ".local", "bin"),
		claudeSettingsFile: "",
		codexHooksFile: "",
		dryRun: false,
		runtimeRoot: path.join(
			homedir(),
			"Library",
			"Application Support",
			"agent-tooling",
			"ios-session-lanes",
			"runtime",
		),
	};
	for (let index = 0; index < args.length; index += 1) {
		const arg = args[index];
		if (arg === "--dry-run") options.dryRun = true;
		else if (arg === "--bin-dir") options.binDir = requireValue(args, ++index, arg);
		else if (arg === "--runtime-root") options.runtimeRoot = requireValue(args, ++index, arg);
		else if (arg === "--claude-settings-file") options.claudeSettingsFile = requireValue(args, ++index, arg);
		else if (arg === "--codex-hooks-file") options.codexHooksFile = requireValue(args, ++index, arg);
		else throw new Error(`Unknown installer option ${arg}.`);
	}
	return options;
}

function requireValue(args, index, option) {
	const value = args[index];
	if (!value || value.startsWith("--")) throw new Error(`${option} requires a value.`);
	return path.resolve(value);
}

function readJson(filePath, fallback) {
	if (!existsSync(filePath)) return structuredClone(fallback);
	return JSON.parse(readFileSync(filePath, "utf8"));
}

function atomicJsonWrite(filePath, value) {
	mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
	if (existsSync(filePath)) {
		const backupPath = `${filePath}.before-ios-session-lanes.json`;
		if (!existsSync(backupPath)) copyFileSync(filePath, backupPath);
		chmodSync(backupPath, 0o600);
	}
	const temporary = `${filePath}.${process.pid}.tmp`;
	writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
	renameSync(temporary, filePath);
}

function commandHook(command, extra = {}) {
	return {
		type: "command",
		command,
		...extra,
	};
}

function managedGroup(group) {
	return group?.hooks?.some((hook) => String(hook.command ?? "").includes(marker));
}

function replaceManagedEvent(hooks, event, groups) {
	const existing = Array.isArray(hooks[event]) ? hooks[event] : [];
	hooks[event] = [...existing.filter((group) => !managedGroup(group)), ...groups];
}

export function mergeHooks(document, client, hookScript) {
	const result = structuredClone(document);
	result.hooks = result.hooks && typeof result.hooks === "object" ? result.hooks : {};
	const baseCommand = `node "${hookScript}"`;
	const start = `${baseCommand} start --client ${client} # ${marker}`;
	const pretool = `${baseCommand} pretool --client ${client} # ${marker}`;
	const end = `${baseCommand} end --client ${client} # ${marker}`;
	replaceManagedEvent(result.hooks, "SessionStart", [
		{
			matcher: "startup|resume|clear|compact",
			hooks: [
				commandHook(start, {
					statusMessage: "Bootstrapping worktree and loading iOS lane context",
					timeout: 1800,
					...(client === "codex" ? { additionalContextLimit: 1400 } : {}),
				}),
			],
		},
	]);
	replaceManagedEvent(result.hooks, "PreToolUse", [
		{
			matcher: "Bash|Shell|exec_command|mcp__.*(?:[Ss]imview|[Aa]rgent|[Xx]codebuild).*",
			hooks: [
				commandHook(pretool, {
					statusMessage: "Checking iOS lane ownership",
					timeout: 15,
				}),
			],
		},
	]);
	replaceManagedEvent(result.hooks, "SessionEnd", [
		{
			hooks: [commandHook(end, { timeout: 30 })],
		},
	]);
	return result;
}

function wrapper(scriptPath) {
	return `#!/bin/sh\nexec node "${scriptPath.replaceAll('"', '\\"')}" "$@"\n`;
}

function installRuntime(options) {
	const runtimeRoot = path.resolve(options.runtimeRoot);
	const scriptsTarget = path.join(runtimeRoot, "scripts");
	const referencesTarget = path.join(runtimeRoot, "references");
	mkdirSync(runtimeRoot, { recursive: true, mode: 0o700 });
	cpSync(sourceScripts, scriptsTarget, { force: true, recursive: true });
	cpSync(path.join(sourceSkill, "references"), referencesTarget, {
		force: true,
		recursive: true,
	});
	mkdirSync(options.binDir, { recursive: true, mode: 0o700 });
	const commands = {
		"ios-session-bootstrap": "bootstrap-worktree.mjs",
		"ios-session-lane": "ios-session-lane.mjs",
		"ios-session-worktree": "create-worktree.mjs",
	};
	for (const [name, script] of Object.entries(commands)) {
		const target = path.join(options.binDir, name);
		writeFileSync(target, wrapper(path.join(scriptsTarget, script)), { mode: 0o755 });
		chmodSync(target, 0o755);
	}
	return { runtimeRoot, scriptsTarget };
}

export function install(options) {
	const hookScript = path.join(path.resolve(options.runtimeRoot), "scripts", "ios-session-hook.mjs");
	if (options.dryRun) {
		return {
			binDir: path.resolve(options.binDir),
			claudeSettingsFile: options.claudeSettingsFile || null,
			codexHooksFile: options.codexHooksFile || null,
			hookScript,
			runtimeRoot: path.resolve(options.runtimeRoot),
		};
	}
	const runtime = installRuntime(options);
	if (options.codexHooksFile) {
		const current = readJson(options.codexHooksFile, { hooks: {} });
		atomicJsonWrite(
			options.codexHooksFile,
			mergeHooks(current, "codex", hookScript),
		);
	}
	if (options.claudeSettingsFile) {
		const current = readJson(options.claudeSettingsFile, { hooks: {} });
		atomicJsonWrite(
			options.claudeSettingsFile,
			mergeHooks(current, "claude", hookScript),
		);
	}
	return {
		binDir: path.resolve(options.binDir),
		claudeSettingsFile: options.claudeSettingsFile || null,
		codexHooksFile: options.codexHooksFile || null,
		runtimeRoot: runtime.runtimeRoot,
	};
}

function main() {
	const result = install(parseInstallOptions(process.argv.slice(2)));
	process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (isMainModule(import.meta.url)) {
	try {
		main();
	} catch (error) {
		console.error(`[ios-session-lanes-install] ${error.message}`);
		process.exitCode = 1;
	}
}
