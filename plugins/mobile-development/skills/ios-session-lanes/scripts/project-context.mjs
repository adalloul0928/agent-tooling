import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const skillRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bundledProfilePath = path.join(skillRoot, "references", "pumpd-project.json");
const maximumGitOutputBytes = 64 * 1024;

export function bundledProfile() {
	return normalizeProjectProfile(
		JSON.parse(readFileSync(bundledProfilePath, "utf8")),
	);
}

export function normalizeProjectProfile(value) {
	if (!isRecord(value) || value.schemaVersion !== 2) {
		throw new Error("The iOS session project profile must use schemaVersion 2.");
	}
	if (typeof value.id !== "string" || value.id.trim() === "") {
		throw new Error("The iOS session project profile must have an id.");
	}
	if (!isRecord(value.match) || !isRecord(value.match.repository)) {
		throw new Error("The iOS session project profile must declare a repository identity.");
	}
	const repository = normalizeExpectedRepository(value.match.repository);
	if (!Array.isArray(value.match.requiredPaths) || value.match.requiredPaths.length === 0) {
		throw new Error("The iOS session project profile must declare required paths.");
	}
	const requiredPaths = value.match.requiredPaths.map((relative) => {
		if (
			typeof relative !== "string" ||
			relative === "" ||
			/[\u0000-\u001F\u007F]/u.test(relative) ||
			relative.includes("\\") ||
			path.posix.isAbsolute(relative) ||
			path.posix.normalize(relative) !== relative ||
			relative.split("/").some((component) => component === ".." || component === ".")
		) {
			throw new Error("The iOS session project profile contains an unsafe required path.");
		}
		return relative;
	});
	return {
		...value,
		match: {
			...value.match,
			repository,
			requiredPaths,
		},
	};
}

export function normalizeRepositoryRemote(value) {
	if (typeof value !== "string") return null;
	if (/[\u0000-\u001F\u007F\\]/u.test(value)) return null;
	const remote = value.trim();
	if (
		remote === "" ||
		/%[0-9A-F]{2}/iu.test(remote) ||
		/(?:^|\/)\.{1,2}(?:\/|$)/u.test(remote)
	) {
		return null;
	}

	let host;
	let repositoryPath;
	if (/^(?:https|ssh):\/\//iu.test(remote)) {
		let parsed;
		try {
			parsed = new URL(remote);
		} catch {
			return null;
		}
		if (parsed.search || parsed.hash || parsed.hostname !== "github.com") return null;
		if (parsed.protocol === "https:") {
			if (parsed.username || parsed.password || parsed.port) return null;
		} else if (parsed.protocol === "ssh:") {
			if (parsed.username !== "git" || parsed.password || !["", "22"].includes(parsed.port)) {
				return null;
			}
		} else return null;
		host = parsed.hostname;
		repositoryPath = parsed.pathname.replace(/^\//u, "");
	} else {
		const scp = remote.match(/^git@([^:]+):(.+)$/u);
		if (!scp || scp[1].toLowerCase() !== "github.com") return null;
		host = scp[1].toLowerCase();
		repositoryPath = scp[2];
	}

	const components = repositoryPath.replace(/\/$/u, "").split("/");
	if (components.length !== 2) return null;
	const owner = normalizeGitHubOwner(components[0]);
	const repositoryWithoutSuffix = components[1].replace(/\.git$/iu, "");
	const repo = normalizeGitHubRepository(repositoryWithoutSuffix);
	if (!owner || !repo) return null;
	return repositoryIdentity(host, owner, repo);
}

export function resolveProjectRoot(cwd) {
	const explicitRoot = typeof cwd === "string" && cwd.trim() !== "";
	const requested = explicitRoot
		? cwd
		: process.env.IOS_SESSION_LANES_PROJECT_ROOT || process.cwd();
	const result = spawnSync("git", ["rev-parse", "--show-toplevel"], {
		cwd: requested,
		encoding: "utf8",
		maxBuffer: maximumGitOutputBytes,
		stdio: ["ignore", "pipe", "ignore"],
	});
	const output = result.status === 0 ? result.stdout.trim() : "";
	if (!output || output.includes("\n")) {
		throw new Error("not_git_worktree");
	}
	try {
		return realpathSync(output);
	} catch {
		throw new Error("not_git_worktree");
	}
}

export function projectContext(cwd) {
	const root = resolveProjectRoot(cwd);
	const profile = bundledProfile();
	return {
		backendRoot: path.join(root, profile.backend.root),
		mobileRoot: path.join(root, profile.mobile.root),
		profile,
		root,
	};
}

export function readRemoteIdentity(root, remote = "origin") {
	if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u.test(remote)) {
		return { identity: null, reason: "origin_unavailable" };
	}
	const result = spawnSync("git", ["remote", "get-url", "--all", remote], {
		cwd: root,
		encoding: "utf8",
		maxBuffer: maximumGitOutputBytes,
		stdio: ["ignore", "pipe", "ignore"],
	});
	if (result.status !== 0) {
		return { identity: null, reason: "origin_unavailable" };
	}
	const urls = result.stdout.split(/\r?\n/u).filter((line) => line !== "");
	if (urls.length !== 1) {
		return {
			identity: null,
			reason: urls.length > 1 ? "origin_ambiguous" : "origin_unavailable",
		};
	}
	const identity = normalizeRepositoryRemote(urls[0]);
	return identity
		? { identity, reason: null }
		: { identity: null, reason: "origin_unrecognized" };
}

export function projectMatch(cwd) {
	const profile = bundledProfile();
	let root;
	try {
		root = resolveProjectRoot(cwd);
	} catch {
		return failedMatch(profile, "not_git_worktree");
	}
	const context = {
		backendRoot: path.join(root, profile.backend.root),
		mobileRoot: path.join(root, profile.mobile.root),
		profile,
		root,
	};
	const missingPaths = profile.match.requiredPaths.filter(
		(relative) => !existsSync(path.join(root, relative)),
	);
	const remote = readRemoteIdentity(root, profile.match.repository.remote);
	const expectedIdentity = repositoryIdentity(
		profile.match.repository.host,
		profile.match.repository.owner,
		profile.match.repository.repo,
	);
	const repositoryMatches = remote.identity?.key === expectedIdentity.key;
	const reason = remote.reason
		? remote.reason
		: !repositoryMatches
			? "origin_mismatch"
			: missingPaths.length > 0
				? "required_paths_missing"
				: null;
	return {
		...context,
		missingPaths,
		ok: reason === null,
		reason,
		repositoryIdentity: remote.identity?.key ?? null,
	};
}

export function assertSupportedProject(cwd) {
	const result = projectMatch(cwd);
	if (!result.ok) {
		throw new Error(
			`iOS session lanes only run in a registered ${result.profile.displayName} worktree. ` +
				`Repository check: ${result.reason}; normalized identity: ${result.repositoryIdentity || "unavailable"}; ` +
				`missing paths: ${result.missingPaths.join(", ") || "none"}.`,
		);
	}
	return result;
}

function failedMatch(profile, reason) {
	return {
		backendRoot: null,
		missingPaths: [],
		mobileRoot: null,
		ok: false,
		profile,
		reason,
		repositoryIdentity: null,
		root: null,
	};
}

function normalizeExpectedRepository(value) {
	if (value.remote !== "origin") {
		throw new Error("The iOS session project profile must use the origin remote.");
	}
	if (typeof value.host !== "string" || value.host.toLowerCase() !== "github.com") {
		throw new Error("The iOS session project profile must use github.com.");
	}
	const owner = normalizeGitHubOwner(value.owner);
	const repo = normalizeGitHubRepository(value.repo);
	if (!owner || !repo || /\.git$/iu.test(value.repo)) {
		throw new Error("The iOS session project profile has an invalid owner or repository.");
	}
	return { host: "github.com", owner, remote: "origin", repo };
}

function normalizeGitHubOwner(value) {
	if (typeof value !== "string" || !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/u.test(value)) {
		return null;
	}
	if (value.endsWith("-") || value.includes("--")) return null;
	return value.toLowerCase();
}

function normalizeGitHubRepository(value) {
	if (
		typeof value !== "string" ||
		value === "." ||
		value === ".." ||
		!/^[A-Za-z0-9._-]{1,100}$/u.test(value)
	) {
		return null;
	}
	return value.toLowerCase();
}

function repositoryIdentity(host, owner, repo) {
	return {
		host,
		key: `${host}/${owner}/${repo}`,
		owner,
		repo,
	};
}

function isRecord(value) {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function isMainModule(moduleUrl) {
	if (!process.argv[1]) return false;
	try {
		return (
			realpathSync(path.resolve(process.argv[1])) ===
			realpathSync(fileURLToPath(moduleUrl))
		);
	} catch {
		return path.resolve(process.argv[1]) === fileURLToPath(moduleUrl);
	}
}

export { bundledProfilePath, skillRoot };
