#!/usr/bin/env node

import {
	chmodSync,
	closeSync,
	constants,
	cpSync,
	fstatSync,
	linkSync,
	lstatSync,
	mkdirSync,
	openSync,
	readFileSync,
	readdirSync,
	realpathSync,
	renameSync,
	rmSync,
	rmdirSync,
	writeFileSync,
} from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { isMainModule } from "./project-context.mjs";
import { withFileLock } from "./lane-lock.mjs";

const sourceScripts = path.dirname(fileURLToPath(import.meta.url));
const sourceSkill = path.resolve(sourceScripts, "..");
const marker = "agent-tooling-ios-session-lanes";
const runtimeOwner = "agent-tooling-ios-session-lanes-runtime";
const runtimeOwnerFile = ".agent-tooling-runtime-owner.json";
const runtimeOwnerVersion = 1;
const runtimeIntegrityVersion = 3;
const sourceRepository = path.resolve(sourceSkill, "../../../..");
const runtimeCommands = Object.freeze({
	"ios-session-bootstrap": "bootstrap-worktree.mjs",
	"ios-session-lane": "ios-session-lane.mjs",
	"ios-session-worktree": "create-worktree.mjs",
});
const legacyRequiredFiles = Object.freeze([
	"references/pumpd-project.json",
	"references/workflow.md",
	"scripts/bootstrap-worktree.mjs",
	"scripts/create-worktree.mjs",
	"scripts/install-runtime.mjs",
	"scripts/ios-session-hook.mjs",
	"scripts/ios-session-lane.mjs",
	"scripts/project-context.mjs",
]);
const legacyOptionalFiles = Object.freeze(["runtime-integrity.json"]);

function defaultRuntimeRoot() {
	return path.join(
		homedir(),
		"Library",
		"Application Support",
		"agent-tooling",
		"ios-session-lanes",
		"runtime",
	);
}

export function parseInstallOptions(args) {
	const options = {
		binDir: path.join(homedir(), ".local", "bin"),
		check: false,
		claudeSettingsFile: "",
		codexHooksFile: "",
		dryRun: false,
		help: false,
		migrateLegacyRuntime: false,
		removeManagedUserHooks: false,
		runtimeRoot: defaultRuntimeRoot(),
	};
	for (let index = 0; index < args.length; index += 1) {
		const arg = args[index];
		if (arg === "--help" || arg === "-h") options.help = true;
		else if (arg === "--check") options.check = true;
		else if (arg === "--dry-run") options.dryRun = true;
		else if (arg === "--migrate-legacy-runtime") options.migrateLegacyRuntime = true;
		else if (arg === "--remove-managed-user-hooks") options.removeManagedUserHooks = true;
		else if (arg === "--bin-dir") options.binDir = requireValue(args, ++index, arg);
		else if (arg === "--runtime-root") options.runtimeRoot = requireValue(args, ++index, arg);
		else if (arg === "--claude-settings-file") options.claudeSettingsFile = requireValue(args, ++index, arg);
		else if (arg === "--codex-hooks-file") options.codexHooksFile = requireValue(args, ++index, arg);
		else throw new Error(`Unknown installer option ${arg}.`);
	}
	return options;
}

function helpText() {
	return `Usage: install-runtime.mjs [options]

Installs the user-scoped iOS session-lane runtime and command wrappers.

Options:
  --check                          Verify the installed runtime without writing
  --bin-dir <path>                 Wrapper directory (default: ~/.local/bin)
  --runtime-root <path>            Runtime directory
  --claude-settings-file <path>    Install or remove managed Claude user hooks
  --codex-hooks-file <path>        Install or remove managed Codex user hooks
  --remove-managed-user-hooks      Remove only managed hooks from user settings
  --migrate-legacy-runtime         Explicitly back up and migrate the legacy default runtime
  --dry-run                        Resolve paths without writing files
  -h, --help                       Show this help
`;
}

function requireValue(args, index, option) {
	const value = args[index];
	if (!value || value.startsWith("--")) throw new Error(`${option} requires a value.`);
	return path.resolve(value);
}

function commandHook(command, extra = {}) {
	return {
		type: "command",
		command,
		...extra,
	};
}

function managedHook(hook) {
	return String(hook?.command ?? "").includes(marker);
}

function withoutManagedHooks(groups) {
	if (!Array.isArray(groups)) return [];
	return groups.flatMap((group) => {
		if (!Array.isArray(group?.hooks)) return [group];
		const hooks = group.hooks.filter((hook) => !managedHook(hook));
		return hooks.length > 0 ? [{ ...group, hooks }] : [];
	});
}

function managedHookClients(document) {
	const clients = new Set();
	for (const groups of Object.values(document?.hooks ?? {})) {
		if (!Array.isArray(groups)) continue;
		for (const group of groups) {
			if (!Array.isArray(group?.hooks)) continue;
			for (const hook of group.hooks) {
				if (!managedHook(hook)) continue;
				const match = String(hook.command ?? "").match(/(?:^|\s)--client\s+(claude|codex)(?=\s|$)/);
				clients.add(match?.[1] ?? "unknown");
			}
		}
	}
	return clients;
}

function replaceManagedEvent(hooks, event, groups) {
	hooks[event] = [...withoutManagedHooks(hooks[event]), ...groups];
}

export function mergeHooks(document, client, hookScript) {
	const result = structuredClone(document);
	result.hooks = result.hooks && typeof result.hooks === "object" ? result.hooks : {};
	const baseCommand = `node "${hookScript}"`;
	const start = `${baseCommand} start --client ${client} # ${marker}`;
	const pretool = `${baseCommand} pretool --client ${client} # ${marker}`;
	const heartbeat = `${baseCommand} heartbeat --client ${client} # ${marker}`;
	const end = `${baseCommand} end --client ${client} # ${marker}`;
	replaceManagedEvent(result.hooks, "SessionStart", [
		{
			matcher: "startup|resume|clear|compact",
			hooks: [
				commandHook(start, {
					statusMessage: "Checking worktree bootstrap and loading iOS lane context",
					timeout: 1800,
					...(client === "codex" ? { additionalContextLimit: 1400 } : {}),
				}),
			],
		},
	]);
	replaceManagedEvent(result.hooks, "UserPromptSubmit", [
		{
			hooks: [commandHook(heartbeat, { timeout: 5 })],
		},
	]);
	replaceManagedEvent(result.hooks, "PreToolUse", [
		{
			matcher: "Bash|Shell|exec_command|run_command|mcp__.*(?:[Ss]imview|[Ii]os[_-]?[Ss]imulator|[Aa]gent[_-]?[Dd]evice|[Mm]aestro|[Aa]rgent|[Xx]codebuild).*",
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
			hooks: [commandHook(end, { timeout: 3 })],
		},
	]);
	return result;
}

export function removeManagedHooks(document) {
	const result = structuredClone(document);
	if (!result.hooks || typeof result.hooks !== "object") return result;
	for (const [event, groups] of Object.entries(result.hooks)) {
		if (!Array.isArray(groups)) continue;
		result.hooks[event] = withoutManagedHooks(groups);
		if (result.hooks[event].length === 0) delete result.hooks[event];
	}
	return result;
}

function wrapper(scriptPath) {
	const quoted = `'${scriptPath.replaceAll("'", `'\"'\"'`)}'`;
	return `#!/bin/sh\nexec node ${quoted} "$@"\n`;
}

function legacyWrapper(scriptPath) {
	return `#!/bin/sh\nexec node "${scriptPath.replaceAll('"', '\\"')}" "$@"\n`;
}

function wrapperDocuments(runtimeRoot, legacy = false) {
	const render = legacy ? legacyWrapper : wrapper;
	return Object.fromEntries(
		Object.entries(runtimeCommands).map(([name, script]) => [
			name,
			render(path.join(runtimeRoot, "scripts", script)),
		]),
	);
}

function hashText(value) {
	return createHash("sha256").update(value).digest("hex");
}

function hashFile(filePath) {
	return hashText(readFileSync(filePath));
}

function isSameOrAncestor(ancestor, candidate) {
	const relative = path.relative(path.resolve(ancestor), path.resolve(candidate));
	return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function lstatIfPresent(filePath) {
	try {
		return lstatSync(filePath);
	} catch (error) {
		if (error.code === "ENOENT") return null;
		throw error;
	}
}

function canonicalTargetPath(value, label) {
	const lexical = path.resolve(value);
	const targetMetadata = lstatIfPresent(lexical);
	if (targetMetadata?.isSymbolicLink()) {
		throw new Error(`Refusing symbolic-link ${label}: ${lexical}.`);
	}
	const suffix = [];
	let existingAncestor = lexical;
	while (!lstatIfPresent(existingAncestor)) {
		const parent = path.dirname(existingAncestor);
		if (parent === existingAncestor) throw new Error(`Cannot resolve ${label}: ${lexical}.`);
		suffix.unshift(path.basename(existingAncestor));
		existingAncestor = parent;
	}
	return path.resolve(realpathSync(existingAncestor), ...suffix);
}

function protectedRoots() {
	return [sourceRepository, sourceSkill, sourceScripts].map((root) => realpathSync(root));
}

export function assertSafeRuntimeRoot(value) {
	const runtimeRoot = canonicalTargetPath(value, "iOS lane runtime root");
	const filesystemRoot = path.parse(runtimeRoot).root;
	const home = realpathSync(homedir());
	if (
		runtimeRoot === filesystemRoot ||
		isSameOrAncestor(runtimeRoot, home) ||
		protectedRoots().some(
			(protectedRoot) =>
				isSameOrAncestor(runtimeRoot, protectedRoot) ||
				isSameOrAncestor(protectedRoot, runtimeRoot),
		)
	) {
		throw new Error(`Refusing unsafe iOS lane runtime root: ${runtimeRoot}.`);
	}
	return runtimeRoot;
}

function assertSafeBinDir(value, runtimeRoot) {
	const binDir = canonicalTargetPath(value, "iOS lane bin directory");
	const filesystemRoot = path.parse(binDir).root;
	const home = realpathSync(homedir());
	if (
		binDir === filesystemRoot ||
		isSameOrAncestor(binDir, home) ||
		isSameOrAncestor(binDir, runtimeRoot) ||
		isSameOrAncestor(runtimeRoot, binDir) ||
		protectedRoots().some(
			(protectedRoot) =>
				isSameOrAncestor(binDir, protectedRoot) ||
				isSameOrAncestor(protectedRoot, binDir),
		)
	) {
		throw new Error(`Refusing unsafe iOS lane bin directory: ${binDir}.`);
	}
	return binDir;
}

function runtimeOwnerDocument() {
	return {
		owner: runtimeOwner,
		version: runtimeOwnerVersion,
	};
}

function assertOwnedExistingRuntime(runtimeRoot) {
	const metadata = lstatIfPresent(runtimeRoot);
	if (!metadata) return null;
	if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
		throw new Error(`Refusing to replace non-directory iOS lane runtime root: ${runtimeRoot}.`);
	}
	const ownerPath = path.join(runtimeRoot, runtimeOwnerFile);
	const ownerMetadata = lstatIfPresent(ownerPath);
	if (!ownerMetadata) {
		throw new Error(
			`Refusing to replace unowned directory ${runtimeRoot}; the runtime ownership marker is absent. Remove or migrate the legacy runtime explicitly.`,
		);
	}
	if (!ownerMetadata.isFile() || ownerMetadata.isSymbolicLink()) {
		throw new Error(`Refusing to replace ${runtimeRoot}; its ownership marker is not a regular file.`);
	}
	try {
		const owner = JSON.parse(readFileSync(ownerPath, "utf8"));
		if (owner.owner !== runtimeOwner || owner.version !== runtimeOwnerVersion) {
			throw new Error("ownership marker mismatch");
		}
	} catch {
		throw new Error(`Refusing to replace ${runtimeRoot}; its runtime ownership marker is invalid.`);
	}
	const integrityPath = path.join(runtimeRoot, "runtime-integrity.json");
	const integrityMetadata = lstatIfPresent(integrityPath);
	if (!integrityMetadata?.isFile() || integrityMetadata.isSymbolicLink()) {
		throw new Error(`Refusing to replace ${runtimeRoot}; its integrity manifest is missing or unsafe.`);
	}
	let integrity;
	try {
		integrity = JSON.parse(readFileSync(integrityPath, "utf8"));
	} catch {
		throw new Error(`Refusing to replace ${runtimeRoot}; its integrity manifest is invalid.`);
	}
	const actualFiles = runtimeFileHashes(runtimeRoot);
	const actualTree = runtimeIntegrityTree(runtimeRoot);
	const expectedFiles = integrity.files;
	const sameInventory =
		expectedFiles &&
		typeof expectedFiles === "object" &&
		!Array.isArray(expectedFiles) &&
		Object.keys(actualFiles).length === Object.keys(expectedFiles).length &&
		Object.entries(actualFiles).every(([relative, digest]) => expectedFiles[relative] === digest);
	const hookPath = path.join(runtimeRoot, "scripts", "ios-session-hook.mjs");
	const lanePath = path.join(runtimeRoot, "scripts", "ios-session-lane.mjs");
	if (
		integrity.version !== runtimeIntegrityVersion ||
		path.resolve(integrity.runtimeRoot ?? "") !== runtimeRoot ||
		!sameInventory ||
		JSON.stringify(integrity.tree) !== JSON.stringify(actualTree) ||
		path.resolve(integrity.scripts?.hook?.path ?? "") !== hookPath ||
		integrity.scripts?.hook?.sha256 !== actualFiles["scripts/ios-session-hook.mjs"] ||
		path.resolve(integrity.scripts?.lane?.path ?? "") !== lanePath ||
		integrity.scripts?.lane?.sha256 !== actualFiles["scripts/ios-session-lane.mjs"]
	) {
		throw new Error(`Refusing to replace ${runtimeRoot}; its full integrity inventory failed.`);
	}
	return integrity;
}

function runtimeFileHashes(root) {
	const hashes = {};
	function visit(directory) {
		for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) =>
			a.name.localeCompare(b.name),
		)) {
			const absolute = path.join(directory, entry.name);
			if (entry.isSymbolicLink()) {
				throw new Error(`Runtime source must not contain symlinks: ${absolute}.`);
			}
			if (entry.isDirectory()) visit(absolute);
			else if (entry.isFile()) {
				const relative = path.relative(root, absolute).split(path.sep).join("/");
				if (relative !== "runtime-integrity.json") hashes[relative] = hashFile(absolute);
			} else throw new Error(`Runtime source contains a non-regular entry: ${absolute}.`);
		}
	}
	visit(root);
	return hashes;
}

function assertManagedWrapperTargets(binDir, documents, integrity = null) {
	const resolvedBinDir = path.resolve(binDir);
	const binMetadata = lstatIfPresent(resolvedBinDir);
	if (binMetadata) {
		if (!binMetadata.isDirectory() || binMetadata.isSymbolicLink()) {
			throw new Error(`Refusing non-directory iOS lane bin path: ${resolvedBinDir}.`);
		}
	}
	for (const [name, document] of Object.entries(documents)) {
		const target = path.join(resolvedBinDir, name);
		if (
			integrity &&
			(path.resolve(integrity.wrappers?.[name]?.path ?? "") !== target ||
				integrity.wrappers?.[name]?.sha256 !== hashText(document) ||
				integrity.wrappers?.[name]?.mode !== 0o755)
		) {
			throw new Error(`Refusing to replace runtime with a mismatched ${name} integrity record.`);
		}
		const metadata = lstatIfPresent(target);
		if (!metadata) continue;
		if (!metadata.isFile() || metadata.isSymbolicLink()) {
			throw new Error(`Refusing to replace unmanaged iOS lane wrapper target: ${target}.`);
		}
		if ((metadata.mode & 0o7777) !== 0o755) {
			throw new Error(`Refusing to replace unmanaged iOS lane wrapper mode: ${target}.`);
		}
		const actual = readFileSync(target, "utf8");
		if (actual !== document) {
			throw new Error(`Refusing to replace unmanaged iOS lane wrapper: ${target}.`);
		}
	}
}

function assertLegacyRuntimeInventory(runtimeRoot) {
	const rootMetadata = lstatIfPresent(runtimeRoot);
	if (!rootMetadata?.isDirectory() || rootMetadata.isSymbolicLink()) {
		throw new Error(`Legacy runtime is missing or unsafe: ${runtimeRoot}.`);
	}
	const allowedFiles = new Set([...legacyRequiredFiles, ...legacyOptionalFiles]);
	const allowedDirectories = new Set(["references", "scripts"]);
	const foundFiles = new Set();
	function visit(directory) {
		for (const entry of readdirSync(directory, { withFileTypes: true })) {
			const absolute = path.join(directory, entry.name);
			const relative = path.relative(runtimeRoot, absolute).split(path.sep).join("/");
			if (entry.isSymbolicLink()) {
				throw new Error(`Legacy runtime contains a symbolic link: ${relative}.`);
			}
			if (entry.isDirectory()) {
				if (!allowedDirectories.has(relative)) {
					throw new Error(`Legacy runtime contains an unexpected directory: ${relative}.`);
				}
				visit(absolute);
			} else if (entry.isFile()) {
				if (!allowedFiles.has(relative)) {
					throw new Error(`Legacy runtime contains an unexpected file: ${relative}.`);
				}
				foundFiles.add(relative);
			} else {
				throw new Error(`Legacy runtime contains a non-regular entry: ${relative}.`);
			}
		}
	}
	visit(runtimeRoot);
	const missing = legacyRequiredFiles.filter((relative) => !foundFiles.has(relative));
	if (missing.length > 0) {
		throw new Error(`Legacy runtime is incomplete; missing ${missing.join(", ")}.`);
	}
	if (foundFiles.has("runtime-integrity.json")) {
		let integrity;
		try {
			integrity = JSON.parse(readFileSync(path.join(runtimeRoot, "runtime-integrity.json"), "utf8"));
		} catch {
			throw new Error("Legacy runtime integrity manifest is invalid.");
		}
		const hookPath = path.join(runtimeRoot, "scripts", "ios-session-hook.mjs");
		const lanePath = path.join(runtimeRoot, "scripts", "ios-session-lane.mjs");
		if (
			integrity.version !== 1 ||
			path.resolve(integrity.scripts?.hook?.path ?? "") !== hookPath ||
			path.resolve(integrity.scripts?.lane?.path ?? "") !== lanePath ||
			(integrity.scripts.hook.sha256 && integrity.scripts.hook.sha256 !== hashFile(hookPath)) ||
			(integrity.scripts.lane.sha256 && integrity.scripts.lane.sha256 !== hashFile(lanePath))
		) {
			throw new Error("Legacy runtime integrity manifest does not match the known v1 layout.");
		}
	}
}

function assertLegacyWrapperTargets(binDir, runtimeRoot) {
	const binMetadata = lstatIfPresent(binDir);
	if (!binMetadata?.isDirectory() || binMetadata.isSymbolicLink()) {
		throw new Error(`Legacy wrapper directory is missing or unsafe: ${binDir}.`);
	}
	const documents = wrapperDocuments(runtimeRoot, true);
	for (const [name, document] of Object.entries(documents)) {
		const target = path.join(binDir, name);
		const metadata = lstatIfPresent(target);
		if (!metadata?.isFile() || metadata.isSymbolicLink()) {
			throw new Error(`Legacy wrapper is missing or unsafe: ${target}.`);
		}
		if ((metadata.mode & 0o7777) !== 0o755) {
			throw new Error(`Legacy wrapper mode is not the known v1 mode: ${target}.`);
		}
		if (readFileSync(target, "utf8") !== document) {
			throw new Error(`Legacy wrapper does not exactly match the known v1 wrapper: ${target}.`);
		}
	}
	return documents;
}

function inspectExistingInstallation(options) {
	const documents = wrapperDocuments(options.runtimeRoot);
	const runtimeMetadata = lstatIfPresent(options.runtimeRoot);
	if (options.migrateLegacyRuntime) {
		if (
			path.resolve(options.runtimeRootInput) !== path.resolve(defaultRuntimeRoot()) ||
			options.runtimeRoot !== assertSafeRuntimeRoot(defaultRuntimeRoot())
		) {
			throw new Error("Legacy migration is allowed only at the exact default iOS lane runtime root.");
		}
		if (runtimeMetadata) {
			if (lstatIfPresent(path.join(options.runtimeRoot, runtimeOwnerFile))) {
				const validated = validatedRuntimeState(options.runtimeRoot, () =>
					assertOwnedExistingRuntime(options.runtimeRoot),
				);
				const integrity = validated.result;
				assertManagedWrapperTargets(options.binDir, documents, integrity);
				return {
					documents,
					integrity,
					migrationStatus: "already-current",
					runtimeExpectedState: validated.state,
				};
			}
			const validated = validatedRuntimeState(options.runtimeRoot, () => {
				assertLegacyRuntimeInventory(options.runtimeRoot);
				return null;
			});
			assertLegacyWrapperTargets(options.binDir, options.runtimeRoot);
			return {
				documents,
				integrity: null,
				migrationStatus: "migrated",
				runtimeExpectedState: validated.state,
			};
		}
		assertManagedWrapperTargets(options.binDir, documents);
		return {
			documents,
			integrity: null,
			migrationStatus: "no-legacy-runtime",
			runtimeExpectedState: { exists: false },
		};
	}
	const validated = validatedRuntimeState(options.runtimeRoot, () =>
		assertOwnedExistingRuntime(options.runtimeRoot),
	);
	const integrity = validated.result;
	assertManagedWrapperTargets(options.binDir, documents, integrity);
	return {
		documents,
		integrity,
		migrationStatus: null,
		runtimeExpectedState: validated.state,
	};
}

function uniqueSibling(target, purpose, token) {
	const candidate = path.join(path.dirname(target), `.${path.basename(target)}.${purpose}-${token}`);
	if (lstatIfPresent(candidate)) {
		throw new Error(`Refusing to reuse installer transaction path: ${candidate}.`);
	}
	return candidate;
}

function ensureDirectory(directory, transaction) {
	const missing = [];
	let cursor = directory;
	while (!lstatIfPresent(cursor)) {
		missing.unshift(cursor);
		const parent = path.dirname(cursor);
		if (parent === cursor) break;
		cursor = parent;
	}
	const existing = lstatIfPresent(cursor);
	if (!existing?.isDirectory() || existing.isSymbolicLink()) {
		throw new Error(`Installer parent is not a regular directory: ${cursor}.`);
	}
	mkdirSync(directory, { recursive: true, mode: 0o700 });
	transaction.createdDirectories.push(...missing);
}

function runtimeTreeSnapshot(root, { exclude = new Set() } = {}) {
	const entries = [];
	function visit(absolute, relative) {
		if (exclude.has(relative)) return;
		const metadata = lstatSync(absolute);
		if (metadata.isSymbolicLink()) {
			throw new Error(`Runtime tree contains a symbolic link: ${absolute}.`);
		}
		if (metadata.isDirectory()) {
			entries.push({
				mode: metadata.mode & 0o7777,
				path: relative,
				type: "directory",
			});
			for (const entry of readdirSync(absolute, { withFileTypes: true }).sort((a, b) =>
				a.name.localeCompare(b.name),
			)) {
				const childRelative = relative === "." ? entry.name : `${relative}/${entry.name}`;
				visit(path.join(absolute, entry.name), childRelative);
			}
			return;
		}
		if (metadata.isFile()) {
			entries.push({
				contents: readFileSync(absolute).toString("base64"),
				mode: metadata.mode & 0o7777,
				path: relative,
				type: "file",
			});
			return;
		}
		throw new Error(`Runtime tree contains a non-regular entry: ${absolute}.`);
	}
	visit(root, ".");
	return entries;
}

function runtimeIntegrityTree(root) {
	return runtimeTreeSnapshot(root, { exclude: new Set(["runtime-integrity.json"]) }).map(
		(entry) =>
			entry.type === "file"
				? {
						mode: entry.mode,
						path: entry.path,
						sha256: hashText(Buffer.from(entry.contents, "base64")),
						type: entry.type,
					}
				: entry,
	);
}

function sourcePayloadTree() {
	return [
		["references", path.join(sourceSkill, "references")],
		["scripts", sourceScripts],
	]
		.flatMap(([prefix, root]) =>
			runtimeTreeSnapshot(root).map((entry) => {
				const relative = entry.path === "." ? prefix : `${prefix}/${entry.path}`;
				return entry.type === "file"
					? {
							mode: entry.mode,
							path: relative,
							sha256: hashText(Buffer.from(entry.contents, "base64")),
							type: entry.type,
						}
					: { mode: entry.mode, path: relative, type: entry.type };
			}),
		)
		.sort((left, right) => left.path.localeCompare(right.path));
}

function expectedRuntimeTree(sourceTree) {
	const ownerDocument = `${JSON.stringify(runtimeOwnerDocument(), null, 2)}\n`;
	return [
		{ mode: 0o700, path: ".", type: "directory" },
		{
			mode: 0o600,
			path: runtimeOwnerFile,
			sha256: hashText(ownerDocument),
			type: "file",
		},
		...sourceTree,
	].sort((left, right) => left.path.localeCompare(right.path));
}

function installationCheckError(code, message, status = "drift") {
	const error = new Error(message);
	error.checkCode = code;
	error.checkStatus = status;
	return error;
}

function assertCheckOptions(options) {
	const incompatible = [
		["--dry-run", options.dryRun],
		["--migrate-legacy-runtime", options.migrateLegacyRuntime],
		["--remove-managed-user-hooks", options.removeManagedUserHooks],
		["--claude-settings-file", Boolean(options.claudeSettingsFile)],
		["--codex-hooks-file", Boolean(options.codexHooksFile)],
		["transactionPhaseHook", typeof options.transactionPhaseHook === "function"],
	]
		.filter(([, enabled]) => enabled)
		.map(([name]) => name);
	if (incompatible.length > 0) {
		throw installationCheckError(
			"incompatible-options",
			`--check cannot be combined with ${incompatible.join(", ")}.`,
			"error",
		);
	}
}

function readInstalledWrapper(target) {
	let descriptor;
	try {
		descriptor = openSync(target, constants.O_RDONLY | constants.O_NOFOLLOW);
	} catch {
		throw installationCheckError(
			"wrapper-missing",
			`Installed wrapper is missing or unsafe: ${target}.`,
		);
	}
	try {
		const opened = fstatSync(descriptor);
		if (!opened.isFile()) {
			throw installationCheckError(
				"wrapper-missing",
				`Installed wrapper is not a regular file: ${target}.`,
			);
		}
		const contents = readFileSync(descriptor, "utf8");
		const afterRead = fstatSync(descriptor);
		const atPath = lstatIfPresent(target);
		if (
			!atPath?.isFile() ||
			atPath.isSymbolicLink() ||
			atPath.dev !== afterRead.dev ||
			atPath.ino !== afterRead.ino ||
			opened.dev !== afterRead.dev ||
			opened.ino !== afterRead.ino
		) {
			throw installationCheckError(
				"wrapper-changed",
				`Installed wrapper changed while it was being checked: ${target}.`,
			);
		}
		return { contents, metadata: afterRead };
	} finally {
		closeSync(descriptor);
	}
}

function assertExactInstalledWrappers(binDir, documents, integrity) {
	const expectedNames = Object.keys(documents).sort();
	const actualNames =
		integrity.wrappers &&
		typeof integrity.wrappers === "object" &&
		!Array.isArray(integrity.wrappers)
			? Object.keys(integrity.wrappers).sort()
			: [];
	if (JSON.stringify(actualNames) !== JSON.stringify(expectedNames)) {
		throw installationCheckError(
			"wrapper-manifest-drift",
			"Installed wrapper integrity records do not match the required command set.",
		);
	}
	const binMetadata = lstatIfPresent(binDir);
	if (!binMetadata?.isDirectory() || binMetadata.isSymbolicLink()) {
		throw installationCheckError(
			"wrapper-directory-missing",
			`Installed wrapper directory is missing or unsafe: ${binDir}.`,
		);
	}
	for (const [name, document] of Object.entries(documents)) {
		const target = path.join(binDir, name);
		const record = integrity.wrappers[name];
		if (
			path.resolve(record?.path ?? "") !== target ||
			record?.sha256 !== hashText(document) ||
			record?.mode !== 0o755
		) {
			throw installationCheckError(
				"wrapper-manifest-drift",
				`Installed wrapper integrity record is stale: ${name}.`,
			);
		}
		const { contents, metadata } = readInstalledWrapper(target);
		if ((metadata.mode & 0o7777) !== 0o755) {
			throw installationCheckError(
				"wrapper-mode-drift",
				`Installed wrapper mode must be 0755: ${target}.`,
			);
		}
		if (contents !== document) {
			throw installationCheckError(
				"wrapper-content-drift",
				`Installed wrapper content is stale: ${target}.`,
			);
		}
	}
}

function targetState(target, options = {}) {
	const normalizedOptions =
		typeof options === "boolean" ? { includeDigest: options } : options;
	const metadata = lstatIfPresent(target);
	if (!metadata) return { exists: false };
	let kind = "other";
	if (metadata.isSymbolicLink()) kind = "symlink";
	else if (metadata.isFile()) kind = "file";
	else if (metadata.isDirectory()) kind = "directory";
	return {
		...(normalizedOptions.includeDigest && kind === "file" ? { digest: hashFile(target) } : {}),
		...(normalizedOptions.includeTree && kind === "directory"
			? { tree: runtimeTreeSnapshot(target) }
			: {}),
		exists: true,
		kind,
		mode: metadata.mode & 0o7777,
	};
}

function verificationOptions(state) {
	return {
		includeDigest: state.digest !== undefined,
		includeTree: state.tree !== undefined,
	};
}

function targetStateMatches(expected, actual) {
	return (
		expected.exists === actual.exists &&
		(!expected.exists ||
			(expected.kind === actual.kind &&
				expected.mode === actual.mode &&
				(expected.digest === undefined || expected.digest === actual.digest) &&
				(expected.tree === undefined ||
					JSON.stringify(expected.tree) === JSON.stringify(actual.tree))))
	);
}

function targetMatchesExpected(target, expected) {
	try {
		return targetStateMatches(expected, targetState(target, verificationOptions(expected)));
	} catch {
		return false;
	}
}

function validatedRuntimeState(runtimeRoot, validate) {
	const before = targetState(runtimeRoot, { includeTree: true });
	const result = validate();
	const after = targetState(runtimeRoot, { includeTree: true });
	if (!targetStateMatches(before, after)) {
		throw new Error(`Runtime changed while its existing installation was being validated: ${runtimeRoot}.`);
	}
	return { result, state: after };
}

function restoreTreeSnapshot(target, tree) {
	const root = tree.find((entry) => entry.path === "." && entry.type === "directory");
	if (!root) throw new Error(`Cannot restore runtime tree without a root directory: ${target}.`);
	mkdirSync(target, { mode: 0o700 });
	const directories = tree.filter((entry) => entry.type === "directory" && entry.path !== ".");
	for (const entry of directories) {
		mkdirSync(path.join(target, ...entry.path.split("/")), { recursive: true, mode: 0o700 });
	}
	for (const entry of tree.filter((candidate) => candidate.type === "file")) {
		const destination = path.join(target, ...entry.path.split("/"));
		writeFileSync(destination, Buffer.from(entry.contents, "base64"), { mode: entry.mode });
		chmodSync(destination, entry.mode);
	}
	for (const entry of [...directories].reverse()) {
		chmodSync(path.join(target, ...entry.path.split("/")), entry.mode);
	}
	chmodSync(target, root.mode);
}

function restoreExpectedAsset(target, asset) {
	if (asset.expectedState.kind === "file" && asset.expectedContents !== undefined) {
		writeFileSync(target, asset.expectedContents, { mode: asset.expectedState.mode });
		chmodSync(target, asset.expectedState.mode);
		return;
	}
	if (asset.expectedState.kind === "directory" && asset.expectedState.tree !== undefined) {
		restoreTreeSnapshot(target, asset.expectedState.tree);
		return;
	}
	throw new Error(`Installer cannot reconstruct changed asset: ${asset.target}.`);
}

function retainAndReconstruct(transaction, asset, changedPath) {
	const retained = uniqueSibling(asset.target, "external-change", transaction.token);
	renameSync(changedPath, retained);
	transaction.retainedExternalChanges.push(retained);
	restoreExpectedAsset(changedPath, asset);
	return retained;
}

function assertTargetUnchanged(transaction, asset) {
	if (targetMatchesExpected(asset.target, asset.expectedState)) return;
	if (asset.expectedState.kind === "directory" && asset.expectedState.tree !== undefined) {
		if (lstatIfPresent(asset.target)) {
			retainAndReconstruct(transaction, asset, asset.target);
		} else {
			restoreExpectedAsset(asset.target, asset);
		}
	}
	throw new Error(`Installer target changed after staging: ${asset.target}.`);
}

function assertStageUnchanged(asset) {
	if (!targetMatchesExpected(asset.stage, asset.stageState)) {
		throw new Error(`Installer stage changed before promotion: ${asset.stage}.`);
	}
}

function assertBackupMatchesExpected(transaction, asset) {
	if (targetMatchesExpected(asset.backup, asset.expectedState)) return;
	if (
		asset.expectedContents !== undefined ||
		(asset.expectedState.kind === "directory" && asset.expectedState.tree !== undefined)
	) {
		retainAndReconstruct(transaction, asset, asset.backup);
	}
	throw new Error(`Installer target changed while being backed up: ${asset.target}.`);
}

function assertPromotedTargetUnchanged(asset) {
	if (!targetMatchesExpected(asset.target, asset.stageState)) {
		throw new Error(`Installer target changed after promotion: ${asset.target}.`);
	}
}

function assertTargetAbsentBeforePromotion(asset) {
	if (lstatIfPresent(asset.target)) {
		throw new Error(`Installer target changed before promotion: ${asset.target}.`);
	}
}

function addAsset(transaction, target, writeStage, options = {}) {
	if (transaction.targets.has(target)) throw new Error(`Duplicate installer target: ${target}.`);
	transaction.targets.add(target);
	ensureDirectory(path.dirname(target), transaction);
	const stage = uniqueSibling(target, "stage", transaction.token);
	const backup = uniqueSibling(
		target,
		options.retainBackup ? "legacy-backup" : "previous-install-backup",
		transaction.token,
	);
	const expectedState =
		options.expectedState ??
		targetState(target, {
			includeDigest: options.verifyDigest,
			includeTree: options.verifyTree,
		});
	let expectedContents = options.expectedContents;
	if (options.captureExpectedContents && expectedState.exists && expectedState.kind === "file") {
		expectedContents = readFileSync(target);
	}
	if (
		expectedContents !== undefined &&
		expectedState.digest !== undefined &&
		hashText(expectedContents) !== expectedState.digest
	) {
		throw new Error(`Installer target changed while its expected contents were captured: ${target}.`);
	}
	const asset = {
		backup,
		existed: expectedState.exists,
		expectedContents,
		expectedState,
		label: options.label ?? path.basename(target),
		promoted: false,
		retainBackup: Boolean(options.retainBackup),
		stage,
		target,
	};
	transaction.assets.push(asset);
	writeStage(stage);
	asset.stageState = targetState(stage, { includeDigest: true, includeTree: true });
	return asset;
}

function stageRuntime(stageRoot, options, documents) {
	mkdirSync(stageRoot, { mode: 0o700 });
	const scriptsTarget = path.join(stageRoot, "scripts");
	const referencesTarget = path.join(stageRoot, "references");
	cpSync(sourceScripts, scriptsTarget, { force: true, recursive: true });
	cpSync(path.join(sourceSkill, "references"), referencesTarget, {
		force: true,
		recursive: true,
	});
	writeFileSync(
		path.join(stageRoot, runtimeOwnerFile),
		`${JSON.stringify(runtimeOwnerDocument(), null, 2)}\n`,
		{ mode: 0o600 },
	);
	const integrity = {
		files: runtimeFileHashes(stageRoot),
		runtimeRoot: options.runtimeRoot,
		scripts: {
			hook: {
				path: path.join(options.runtimeRoot, "scripts", "ios-session-hook.mjs"),
				sha256: hashFile(path.join(scriptsTarget, "ios-session-hook.mjs")),
			},
			lane: {
				path: path.join(options.runtimeRoot, "scripts", "ios-session-lane.mjs"),
				sha256: hashFile(path.join(scriptsTarget, "ios-session-lane.mjs")),
			},
		},
		tree: runtimeIntegrityTree(stageRoot),
		version: runtimeIntegrityVersion,
		wrappers: Object.fromEntries(
			Object.entries(documents).map(([name, document]) => [
				name,
				{
					mode: 0o755,
					path: path.join(options.binDir, name),
					sha256: hashText(document),
				},
			]),
		),
	};
	writeFileSync(
		path.join(stageRoot, "runtime-integrity.json"),
		`${JSON.stringify(integrity, null, 2)}\n`,
		{ mode: 0o600 },
	);
}

function settingsPlans(options, hookScript) {
	const plans = new Map();
	for (const [client, filePath] of [
		["codex", options.codexHooksFile],
		["claude", options.claudeSettingsFile],
	]) {
		if (!filePath) continue;
		let plan = plans.get(filePath);
		if (!plan) {
			const metadata = lstatIfPresent(filePath);
			if (metadata && (!metadata.isFile() || metadata.isSymbolicLink())) {
				throw new Error(`Hook settings target is not a regular file: ${filePath}.`);
			}
			const original = metadata ? readFileSync(filePath, "utf8") : "";
			let document;
			try {
				document = original ? JSON.parse(original) : { hooks: {} };
			} catch {
				throw new Error(`Hook settings JSON is invalid: ${filePath}.`);
			}
			if (!options.removeManagedUserHooks) {
				const incompatibleClients = [...managedHookClients(document)].filter(
					(installedClient) => installedClient !== client,
				);
				if (incompatibleClients.length > 0) {
					throw new Error(
						`Hook settings file already contains managed hooks for a different client: ${filePath}.`,
					);
				}
			}
			plan = {
				document,
				existed: Boolean(metadata),
				expectedState: metadata
					? {
						digest: hashText(original),
						exists: true,
						kind: "file",
						mode: metadata.mode & 0o7777,
					}
					: { exists: false },
				filePath,
				original,
			};
			plans.set(filePath, plan);
		}
		plan.document = options.removeManagedUserHooks
			? removeManagedHooks(plan.document)
			: mergeHooks(plan.document, client, hookScript);
	}
	return [...plans.values()];
}

function stageInstallation(options, hookScript, inspection) {
	const token = `${Date.now()}-${process.pid}-${randomBytes(6).toString("hex")}`;
	const transaction = {
		assets: [],
		backedUp: [],
		createdDirectories: [],
		migrationStatus: inspection.migrationStatus,
		promoted: [],
		failedInstallRecoveries: [],
		retainedExternalChanges: [],
		stageRecoveries: [],
		targets: new Set(),
		token,
	};
	const retainLegacy = inspection.migrationStatus === "migrated";
	try {
		transaction.runtimeAsset = addAsset(
			transaction,
			options.runtimeRoot,
			(stage) => stageRuntime(stage, options, inspection.documents),
			{
				expectedState: inspection.runtimeExpectedState,
				label: "runtime",
				retainBackup: retainLegacy,
			},
		);
		transaction.wrapperAssets = {};
		for (const [name, document] of Object.entries(inspection.documents)) {
			transaction.wrapperAssets[name] = addAsset(
				transaction,
				path.join(options.binDir, name),
				(stage) => writeFileSync(stage, document, { mode: 0o755 }),
				{
					captureExpectedContents: true,
					label: name,
					retainBackup: retainLegacy,
					verifyDigest: true,
				},
			);
		}
		for (const plan of settingsPlans(options, hookScript)) {
			if (plan.existed) {
				const pristineBackup = `${plan.filePath}.before-ios-session-lanes.json`;
				if (!lstatIfPresent(pristineBackup)) {
					addAsset(
						transaction,
						pristineBackup,
						(stage) => writeFileSync(stage, plan.original, { mode: 0o600 }),
						{
							expectedState: { exists: false },
							label: `${path.basename(plan.filePath)} pristine backup`,
						},
					);
				}
			}
			addAsset(
				transaction,
				plan.filePath,
				(stage) => writeFileSync(stage, `${JSON.stringify(plan.document, null, 2)}\n`, { mode: 0o600 }),
				{
					expectedContents: plan.original,
					expectedState: plan.expectedState,
					label: `${path.basename(plan.filePath)} hooks`,
				},
			);
		}
		return transaction;
	} catch (error) {
		let cleanupError = null;
		try {
			cleanupTransactionStages(transaction);
		} catch (failure) {
			cleanupError = failure;
		}
		cleanupCreatedDirectories(transaction);
		if (cleanupError) {
			throw new AggregateError(
				[error, cleanupError],
				"Installation staging failed and its recovery move was incomplete.",
			);
		}
		if (transaction.stageRecoveries.length > 0) {
			throw new Error(
				`${error.message} Staged recovery copies were retained at: ${transaction.stageRecoveries.join(", ")}.`,
				{ cause: error },
			);
		}
		throw error;
	}
}

function cleanupTransactionStages(transaction) {
	const failures = [];
	for (const asset of transaction.assets) {
		let retained = "";
		try {
			retained = uniqueSibling(asset.target, "abandoned-stage", transaction.token);
			renameSync(asset.stage, retained);
			transaction.stageRecoveries.push(retained);
		} catch (error) {
			if (error.code === "ENOENT") continue;
			transaction.stageRecoveries.push(retained || asset.stage);
			failures.push(error);
		}
	}
	if (failures.length > 0) {
		throw new AggregateError(failures, "Installer could not retain every staged recovery copy.");
	}
}

function cleanupCreatedDirectories(transaction) {
	for (const directory of [...transaction.createdDirectories].reverse()) {
		try {
			rmdirSync(directory);
		} catch {
			// A committed target or a pre-existing concurrent entry keeps this directory in place.
		}
	}
}

function retainExternalChange(transaction, asset) {
	const retained = uniqueSibling(asset.target, "external-change", transaction.token);
	renameSync(asset.target, retained);
	transaction.retainedExternalChanges.push(retained);
	return retained;
}

function retainFailedInstall(transaction, asset) {
	const retained = uniqueSibling(asset.target, "failed-install", transaction.token);
	renameSync(asset.target, retained);
	transaction.failedInstallRecoveries.push(retained);
	return retained;
}

function assertBackupUnchangedBeforeCompletion(transaction, asset) {
	if (targetMatchesExpected(asset.backup, asset.expectedState)) return;
	if (
		asset.expectedContents === undefined &&
		(asset.expectedState.kind !== "directory" || asset.expectedState.tree === undefined)
	) {
		throw new Error(`Installer backup changed before transaction completion: ${asset.backup}.`);
	}
	retainAndReconstruct(transaction, asset, asset.backup);
	throw new Error(`Installer backup changed before transaction completion: ${asset.backup}.`);
}

function rollbackTransaction(transaction) {
	const failures = [];
	for (const asset of [...transaction.promoted].reverse()) {
		try {
			if (!lstatIfPresent(asset.target)) continue;
			retainFailedInstall(transaction, asset);
		} catch (error) {
			failures.push(error);
		}
	}
	for (const asset of [...transaction.backedUp].reverse()) {
		try {
			if (lstatIfPresent(asset.target)) {
				retainExternalChange(transaction, asset);
			}
			renameSync(asset.backup, asset.target);
		} catch (error) {
			failures.push(error);
		}
	}
	try {
		cleanupTransactionStages(transaction);
	} catch (error) {
		failures.push(error);
	}
	cleanupCreatedDirectories(transaction);
	if (failures.length > 0) {
		throw new AggregateError(failures, "Installer rollback failed; transaction backups were retained.");
	}
}

function commitTransaction(transaction, options) {
	try {
		options.transactionPhaseHook?.("staged");
		for (const asset of transaction.assets) {
			assertTargetUnchanged(transaction, asset);
			if (!asset.existed) continue;
			renameSync(asset.target, asset.backup);
			transaction.backedUp.push(asset);
			assertBackupMatchesExpected(transaction, asset);
		}
		options.transactionPhaseHook?.("backed-up");
		for (const asset of transaction.assets) {
			assertStageUnchanged(asset);
			assertTargetAbsentBeforePromotion(asset);
			if (asset.stageState.kind === "file") {
				const stageMetadata = lstatSync(asset.stage);
				linkSync(asset.stage, asset.target);
				const targetMetadata = lstatSync(asset.target);
				if (
					stageMetadata.dev !== targetMetadata.dev ||
					stageMetadata.ino !== targetMetadata.ino ||
					!targetMatchesExpected(asset.target, asset.stageState)
				) {
					throw new Error(`Installer file promotion identity changed: ${asset.target}.`);
				}
			} else {
				renameSync(asset.stage, asset.target);
			}
			asset.promoted = true;
			transaction.promoted.push(asset);
			if (asset.stageState.kind === "file") rmSync(asset.stage);
			options.transactionPhaseHook?.(`promoted:${asset.label}`);
		}
		options.transactionPhaseHook?.("promoted");
		for (const asset of transaction.promoted) assertPromotedTargetUnchanged(asset);
		for (const asset of transaction.backedUp) {
			assertBackupUnchangedBeforeCompletion(transaction, asset);
		}
	} catch (error) {
		try {
			rollbackTransaction(transaction);
		} catch (rollbackError) {
			throw new AggregateError([error, rollbackError], "Installation failed and rollback was incomplete.");
		}
		const recoveryPaths = [
			...transaction.retainedExternalChanges,
			...transaction.failedInstallRecoveries,
			...transaction.stageRecoveries,
		];
		if (recoveryPaths.length > 0) {
			throw new Error(
				`${error.message} Recovery copies were retained at: ${recoveryPaths.join(", ")}.`,
				{ cause: error },
			);
		}
		throw error;
	}
	cleanupCreatedDirectories(transaction);
}

function recoveryBackupReport(transaction) {
	return transaction.backedUp.map((asset) => ({
		label: asset.label,
		path: asset.backup,
		target: asset.target,
	}));
}

function migrationReport(transaction) {
	if (!transaction.migrationStatus) return null;
	if (transaction.migrationStatus !== "migrated") {
		return { status: transaction.migrationStatus };
	}
	return {
		runtimeBackup: transaction.runtimeAsset.backup,
		status: "migrated",
		wrapperBackups: Object.fromEntries(
			Object.entries(transaction.wrapperAssets).map(([name, asset]) => [name, asset.backup]),
		),
	};
}

export function checkInstallation(options) {
	assertCheckOptions(options);
	try {
		const runtimeRoot = assertSafeRuntimeRoot(path.resolve(options.runtimeRoot));
		const binDir = assertSafeBinDir(options.binDir, runtimeRoot);
		if (!lstatIfPresent(runtimeRoot)) {
			throw installationCheckError(
				"runtime-missing",
				`Installed iOS lane runtime is missing: ${runtimeRoot}.`,
			);
		}
		const sourceBefore = sourcePayloadTree();
		let validated;
		try {
			validated = validatedRuntimeState(runtimeRoot, () =>
				assertOwnedExistingRuntime(runtimeRoot),
			);
		} catch (error) {
			if (error.checkStatus) throw error;
			throw installationCheckError("runtime-integrity-drift", error.message);
		}
		const integrity = validated.result;
		if (!integrity) {
			throw installationCheckError(
				"runtime-missing",
				`Installed iOS lane runtime is missing: ${runtimeRoot}.`,
			);
		}
		const integrityMetadata = lstatIfPresent(path.join(runtimeRoot, "runtime-integrity.json"));
		if ((integrityMetadata?.mode & 0o7777) !== 0o600) {
			throw installationCheckError(
				"runtime-integrity-mode-drift",
				"Installed runtime integrity manifest mode must be 0600.",
			);
		}
		const documents = wrapperDocuments(runtimeRoot);
		assertExactInstalledWrappers(binDir, documents, integrity);
		const installedTree = [...integrity.tree].sort((left, right) =>
			left.path.localeCompare(right.path),
		);
		if (JSON.stringify(installedTree) !== JSON.stringify(expectedRuntimeTree(sourceBefore))) {
			throw installationCheckError(
				"source-revision-drift",
				"Installed runtime does not exactly match the current plugin revision.",
			);
		}
		const sourceAfter = sourcePayloadTree();
		if (JSON.stringify(sourceBefore) !== JSON.stringify(sourceAfter)) {
			throw installationCheckError(
				"source-changed",
				"Plugin scripts or references changed while the installation was being checked.",
			);
		}
		if (!targetMatchesExpected(runtimeRoot, validated.state)) {
			throw installationCheckError(
				"runtime-changed",
				"Installed runtime changed while it was being checked.",
			);
		}
		assertExactInstalledWrappers(binDir, documents, integrity);
		return {
			binDir,
			integrityVersion: runtimeIntegrityVersion,
			runtimeRoot,
			status: "ok",
			wrappers: Object.keys(documents).length,
		};
	} catch (error) {
		if (error.checkStatus) throw error;
		throw installationCheckError("check-failed", error.message);
	}
}

export async function install(options) {
	if (options.check) return checkInstallation(options);
	const runtimeRootInput = path.resolve(options.runtimeRoot);
	const runtimeRoot = assertSafeRuntimeRoot(runtimeRootInput);
	const binDir = assertSafeBinDir(options.binDir, runtimeRoot);
	const normalizedOptions = {
		...options,
		binDir,
		claudeSettingsFile: options.claudeSettingsFile
			? canonicalTargetPath(options.claudeSettingsFile, "Claude settings file")
			: "",
		codexHooksFile: options.codexHooksFile
			? canonicalTargetPath(options.codexHooksFile, "Codex hooks file")
			: "",
		runtimeRoot,
		runtimeRootInput,
	};
	if (
		normalizedOptions.claudeSettingsFile &&
		normalizedOptions.codexHooksFile &&
		normalizedOptions.claudeSettingsFile === normalizedOptions.codexHooksFile
	) {
		throw new Error(
			"Claude settings and Codex hooks must use different files; their hook schemas are client-specific.",
		);
	}
	const hookScript = path.join(runtimeRoot, "scripts", "ios-session-hook.mjs");
	if (options.migrateLegacyRuntime && runtimeRootInput !== path.resolve(defaultRuntimeRoot())) {
		throw new Error("Legacy migration is allowed only at the exact default iOS lane runtime root.");
	}
	if (options.dryRun) {
		return {
			binDir,
			claudeSettingsFile: normalizedOptions.claudeSettingsFile || null,
			codexHooksFile: normalizedOptions.codexHooksFile || null,
			hookScript,
			legacyMigration: options.migrateLegacyRuntime ? { status: "dry-run" } : null,
			recoveryBackups: [],
			runtimeRoot,
		};
	}
	return withFileLock(
		`${runtimeRoot}.installer.lock`,
		5 * 60 * 1000,
		() => installLocked(normalizedOptions, hookScript),
	);
}

function installLocked(options, hookScript) {
	const inspection = inspectExistingInstallation(options);
	const transaction = stageInstallation(options, hookScript, inspection);
	commitTransaction(transaction, options);
	return {
		binDir: options.binDir,
		claudeSettingsFile: options.claudeSettingsFile || null,
		codexHooksFile: options.codexHooksFile || null,
		legacyMigration: migrationReport(transaction),
		recoveryBackups: recoveryBackupReport(transaction),
		runtimeRoot: options.runtimeRoot,
	};
}

async function main() {
	const options = parseInstallOptions(process.argv.slice(2));
	if (options.help) {
		if (options.check) assertCheckOptions(options);
		process.stdout.write(helpText());
		return;
	}
	const result = options.check ? checkInstallation(options) : await install(options);
	process.stdout.write(`${JSON.stringify(result, null, options.check ? 0 : 2)}\n`);
}

if (isMainModule(import.meta.url)) {
	try {
		await main();
	} catch (error) {
		if (process.argv.slice(2).includes("--check")) {
			process.stderr.write(
				`${JSON.stringify({
					code: error.checkCode ?? "invalid-check",
					message: error.message,
					status: error.checkStatus ?? "error",
				})}\n`,
			);
		} else console.error(`[ios-session-lanes-install] ${error.message}`);
		process.exitCode = 1;
	}
}
