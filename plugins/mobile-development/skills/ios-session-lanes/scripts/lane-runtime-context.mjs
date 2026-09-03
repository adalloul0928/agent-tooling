import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { projectContext } from "./project-context.mjs";

export const context = projectContext();
export const { backendRoot, mobileRoot, profile, root: repoRoot } = context;

export function hashText(value) {
	return createHash("sha256").update(value).digest("hex");
}

function readOriginUrl() {
	const result = spawnSync("git", ["remote", "get-url", "origin"], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	if (result.status !== 0 || !result.stdout.trim()) {
		throw new Error("Could not determine the repository origin for the iOS lane namespace.");
	}
	return result.stdout.trim();
}

export function normalizeOriginUrl(value) {
	const input = String(value ?? "").trim();
	if (!input) throw new Error("A repository origin is required for the iOS lane namespace.");
	const scp = input.match(/^(?:[^@/\s]+@)?([^:/\s]+):(.+)$/);
	if (scp && !input.includes("://") && !/^[A-Za-z]:[\\/]/.test(input)) {
		return normalizeHostedOrigin(scp[1], scp[2]);
	}
	try {
		const parsed = new URL(input);
		if (parsed.protocol === "file:") {
			return `file:${path.resolve(decodeURIComponent(parsed.pathname))}`;
		}
		if (parsed.hostname) {
			return normalizeHostedOrigin(parsed.host, decodeURIComponent(parsed.pathname));
		}
	} catch {
		// Plain filesystem remotes are normalized below.
	}
	return `file:${path.resolve(repoRoot, input)}`;
}

function normalizeHostedOrigin(host, repositoryPath) {
	const normalizedPath = String(repositoryPath)
		.replace(/^\/+|\/+$/g, "")
		.replace(/\.git$/i, "")
		.toLowerCase();
	if (!normalizedPath) throw new Error("The repository origin has no repository path.");
	return `${String(host).toLowerCase()}/${normalizedPath}`;
}

export function namespaceIdentity(originUrl = readOriginUrl(), selectedProfile = profile) {
	return {
		backend: {
			config: selectedProfile.backend.config,
			dopplerProject: selectedProfile.backend.dopplerProject,
			root: selectedProfile.backend.root,
		},
		mobileAppId: selectedProfile.mobile.appId,
		origin: normalizeOriginUrl(originUrl),
		profileId: selectedProfile.id,
		schemaVersion: 1,
	};
}

export const runtimeNamespaceIdentity = Object.freeze(namespaceIdentity());
export const repositoryHash = hashText(JSON.stringify(runtimeNamespaceIdentity)).slice(0, 24);

function isSameOrAncestor(ancestor, candidate) {
	const relative = path.relative(ancestor, candidate);
	return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function realpathWithMissingSuffix(value) {
	let cursor = path.resolve(value);
	const missing = [];
	while (true) {
		try {
			return path.join(realpathSync(cursor), ...missing.reverse());
		} catch (error) {
			if (error.code !== "ENOENT") throw error;
			const parent = path.dirname(cursor);
			if (parent === cursor) throw error;
			missing.push(path.basename(cursor));
			cursor = parent;
		}
	}
}

export function resolveLaneHome(
	customValue,
	{
		home = homedir(),
		repository = repoRoot,
		defaultPath = path.join(
			homedir(),
			"Library",
			"Application Support",
			"agent-tooling",
			"ios-session-lanes",
			repositoryHash,
		),
	} = {},
) {
	const hasOverride = customValue !== undefined;
	const raw = hasOverride ? String(customValue).trim() : defaultPath;
	if (!raw) throw new Error("IOS_SESSION_LANES_HOME must not be empty.");
	if (hasOverride && !path.isAbsolute(raw)) {
		throw new Error("IOS_SESSION_LANES_HOME must be an absolute path.");
	}
	const resolved = realpathWithMissingSuffix(raw);
	const resolvedHome = realpathWithMissingSuffix(home);
	const resolvedRepository = realpathWithMissingSuffix(repository);
	const filesystemRoot = path.parse(resolved).root;
	if (
		resolved === filesystemRoot ||
		isSameOrAncestor(resolved, resolvedHome) ||
		isSameOrAncestor(resolved, resolvedRepository) ||
		isSameOrAncestor(resolvedRepository, resolved)
	) {
		throw new Error(`Refusing unsafe iOS lane home: ${resolved}.`);
	}
	return resolved;
}

export const laneHome = resolveLaneHome(process.env.IOS_SESSION_LANES_HOME);
export const registryPath = path.join(laneHome, "registry.json");
export const registryLockPath = path.join(laneHome, "registry.lock");
export const simulatorControlLockPath = path.join(laneHome, "simulator-control.lock");
export const backendOperationLockPath = path.join(laneHome, "backend-operation.lock");
export const tailscaleOperationLockPath = path.join(laneHome, "tailscale-operation.lock");
export const logsRoot = path.join(laneHome, "logs");
export const evidenceRoot = path.join(laneHome, "evidence");
export const binaryRoot = path.join(laneHome, "binaries");
export const deviceStateRoot = path.join(laneHome, "devices");
export const controllerStateRoot = path.join(laneHome, "controllers");

export function ensureDirectoryLayout() {
	for (const directory of [
		logsRoot,
		evidenceRoot,
		binaryRoot,
		deviceStateRoot,
		controllerStateRoot,
	]) {
		mkdirSync(directory, { recursive: true, mode: 0o700 });
	}
}

export function runCaptured(command, args, cwd = repoRoot, options = {}) {
	const result = spawnSync(command, args, {
		cwd,
		encoding: "utf8",
		maxBuffer: 20 * 1024 * 1024,
		...options,
	});
	if (result.status !== 0) {
		throw new Error(
			`${command} ${args.join(" ")} failed: ${(
				result.error?.message || result.stderr || result.stdout || `exit ${result.status}`
			).trim()}`,
		);
	}
	return result;
}

export function runInherited(command, args, cwd, environment = process.env) {
	const result = spawnSync(command, args, { cwd, env: environment, stdio: "inherit" });
	if (result.status !== 0) {
		throw new Error(`${command} ${args.join(" ")} failed with exit ${result.status}.`);
	}
}

export function runQuiet(command, args) {
	spawnSync(command, args, { cwd: repoRoot, stdio: "ignore" });
}

export function now() {
	return new Date().toISOString();
}
