import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const skillRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bundledProfilePath = path.join(skillRoot, "references", "pumpd-project.json");

export function bundledProfile() {
	return JSON.parse(readFileSync(bundledProfilePath, "utf8"));
}

export function resolveProjectRoot(cwd = process.cwd()) {
	const requested = process.env.IOS_SESSION_LANES_PROJECT_ROOT;
	if (requested) return path.resolve(requested);
	const result = spawnSync("git", ["rev-parse", "--show-toplevel"], {
		cwd,
		encoding: "utf8",
	});
	return result.status === 0 ? path.resolve(result.stdout.trim()) : path.resolve(cwd);
}

export function projectContext(cwd = process.cwd()) {
	const root = resolveProjectRoot(cwd);
	const profile = bundledProfile();
	return {
		backendRoot: path.join(root, profile.backend.root),
		mobileRoot: path.join(root, profile.mobile.root),
		profile,
		root,
	};
}

export function normalizeGitHubOrigin(value) {
	const input = String(value ?? "").trim();
	if (!input) return "";
	let parsed;
	try {
		const scpMatch = input.match(/^git@github\.com:([^/?#]+)\/([^/?#]+?)(?:\.git)?\/?$/i);
		parsed = scpMatch
			? { hostname: "github.com", pathname: `/${scpMatch[1]}/${scpMatch[2]}` }
			: new URL(input);
	} catch {
		return "";
	}
	if (String(parsed.hostname).toLowerCase() !== "github.com") return "";
	const parts = String(parsed.pathname)
		.replace(/\/+$/, "")
		.replace(/\.git$/i, "")
		.split("/")
		.filter(Boolean);
	if (parts.length !== 2 || parts.some((part) => !/^[A-Za-z0-9_.-]+$/.test(part))) {
		return "";
	}
	return `github.com/${parts[0].toLowerCase()}/${parts[1].toLowerCase()}`;
}

export function projectMatch(cwd = process.cwd()) {
	const context = projectContext(cwd);
	const missingPaths = context.profile.match.requiredPaths.filter(
		(relative) => !existsSync(path.join(context.root, relative)),
	);
	const origin = spawnSync("git", ["remote", "get-url", "origin"], {
		cwd: context.root,
		encoding: "utf8",
	});
	const originUrl = origin.status === 0 ? origin.stdout.trim() : "";
	const normalizedOrigin = normalizeGitHubOrigin(originUrl);
	const originMatches =
		normalizedOrigin === context.profile.match.canonicalGitHubOrigin.toLowerCase();
	return {
		...context,
		missingPaths,
		ok: missingPaths.length === 0 && originMatches,
		normalizedOrigin,
		originUrl,
	};
}

export function assertSupportedProject(cwd = process.cwd()) {
	const result = projectMatch(cwd);
	if (!result.ok) {
		throw new Error(
			`iOS session lanes only run in a registered ${result.profile.displayName} worktree. ` +
				`Origin was ${result.originUrl || "unavailable"}; missing paths: ${result.missingPaths.join(", ") || "none"}.`,
		);
	}
	return result;
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
