#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
	bootstrap,
	parseBootstrapOptions,
	writeManagedWorktreeAttestation,
} from "./bootstrap-worktree.mjs";
import {
	assertSupportedProject,
	isMainModule,
	projectContext,
} from "./project-context.mjs";

export function safeWorktreeName(value) {
	const normalized = String(value ?? "")
		.trim()
		.toLowerCase()
		.replace(/[^a-z0-9_-]+/g, "-")
		.replace(/^-+|-+$/g, "")
		.slice(0, 64);
	if (!normalized) throw new Error("A safe worktree name is required.");
	return normalized;
}

export function parseWorktreeOptions(args) {
	const profile = projectContext().profile;
	const options = {
		baseRef: profile.worktrees.defaultBase,
		baseRefSource: "default",
		client: "manual",
		destinationRoot: "",
		hook: false,
		name: "",
		projectRoot: "",
	};
	for (let index = 0; index < args.length; index += 1) {
		const arg = args[index];
		if (arg === "--") continue;
		if (arg === "--hook") options.hook = true;
		else if (arg === "--allow-stale-base") {
			throw new Error(
				"--allow-stale-base is no longer supported; managed worktrees require a freshly fetched, attested origin ref.",
			);
		} else if (arg === "--base-ref" || arg === "--base") {
			if (options.baseRefSource !== "default") {
				throw new Error("Specify exactly one of --base-ref or the deprecated --base alias.");
			}
			options.baseRef = validateOriginRemoteTrackingRef(requireValue(args, ++index, arg));
			options.baseRefSource = arg === "--base" ? "legacy-base" : "base-ref";
		} else if (arg === "--client")
			options.client = safeWorktreeName(requireValue(args, ++index, arg));
		else if (arg === "--name") options.name = safeWorktreeName(requireValue(args, ++index, arg));
		else if (arg === "--destination-root") options.destinationRoot = requireValue(args, ++index, arg);
		else if (arg === "--project-root") options.projectRoot = requireValue(args, ++index, arg);
		else throw new Error(`Unknown worktree option ${arg}.`);
	}
	options.baseRef = validateOriginRemoteTrackingRef(options.baseRef);
	return options;
}

function requireValue(args, index, option) {
	const value = args[index];
	if (!value || value.startsWith("--")) throw new Error(`${option} requires a value.`);
	return value;
}

async function readHookInput() {
	let input = "";
	for await (const chunk of process.stdin) input += chunk;
	if (!input) throw new Error("WorktreeCreate hook input was empty.");
	try {
		return JSON.parse(input);
	} catch {
		throw new Error("WorktreeCreate hook input was invalid JSON.");
	}
}

function run(command, args, cwd, { allowFailure = false, quiet = false } = {}) {
	const result = spawnSync(command, args, {
		cwd,
		encoding: "utf8",
		stdio: quiet ? "pipe" : ["ignore", 2, 2],
	});
	if (result.status !== 0 && !allowFailure) {
		const detail = quiet
			? (result.error?.message || result.stderr || result.stdout || "").trim()
			: result.error?.message || "";
		throw new Error(`${command} ${args.join(" ")} failed${detail ? `: ${detail}` : ""}.`);
	}
	return result;
}

export function validateOriginRemoteTrackingRef(value) {
	const requested = String(value ?? "");
	if (requested !== requested.trim() || requested.length > 255) {
		throw new Error("The worktree base must be a valid origin/<branch> remote-tracking ref.");
	}
	const match = requested.match(/^origin\/(.+)$/);
	if (!match) {
		throw new Error("The worktree base must be a valid origin/<branch> remote-tracking ref.");
	}
	const branch = match[1];
	const segments = branch.split("/");
	const valid =
		segments.length > 0 &&
		segments.every(
			(segment) =>
				/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(segment) &&
				segment !== "." &&
				segment !== ".." &&
				!segment.endsWith(".") &&
				!segment.toLowerCase().endsWith(".lock"),
		);
	if (!valid || branch.includes("..") || branch.includes("@{")) {
		throw new Error("The worktree base must be a valid origin/<branch> remote-tracking ref.");
	}
	return requested;
}

export function resolveRemoteBase(root, requestedBaseRef, execute = run) {
	const validatedRef = validateOriginRemoteTrackingRef(requestedBaseRef);
	const branch = validatedRef.slice("origin/".length);
	const fetch = execute(
		"git",
		[
			"fetch",
			"--no-tags",
			"origin",
			`+refs/heads/${branch}:refs/remotes/origin/${branch}`,
		],
		root,
		{ allowFailure: true, quiet: true },
	);
	if (fetch.status !== 0) {
		throw new Error(
			`Could not fetch ${validatedRef}; managed worktrees never use a stale integration base.`,
		);
	}
	const revision = `refs/remotes/origin/${branch}^{commit}`;
	const resolved = execute(
		"git",
		["rev-parse", "--verify", "--end-of-options", revision],
		root,
		{ allowFailure: true, quiet: true },
	);
	const resolvedBaseCommit = String(resolved.stdout ?? "").trim().toLowerCase();
	if (resolved.status !== 0 || !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(resolvedBaseCommit)) {
		throw new Error(`Could not resolve ${validatedRef} to an immutable commit.`);
	}
	return { requestedBaseRef: validatedRef, resolvedBaseCommit };
}

function capturedGit(root, args) {
	return run("git", args, root, { quiet: true }).stdout.trim();
}

export function branchName(client, name, discriminator = "") {
	const prefix = client === "claude" ? "claude" : client === "codex" ? "codex" : "agent";
	const suffix = discriminator ? `-${safeWorktreeName(discriminator).slice(0, 8)}` : "";
	return `${prefix}/${safeWorktreeName(name)}${suffix}`;
}

function mainCheckout(root) {
	const listing = capturedGit(root, ["worktree", "list", "--porcelain"]);
	const first = listing.match(/^worktree (.+)$/m)?.[1];
	if (!first) throw new Error("Could not determine the primary git worktree.");
	return path.resolve(first);
}

function uniqueBranch(root, client, name, discriminator) {
	const initial = branchName(client, name);
	for (let attempt = 0; attempt < 100; attempt += 1) {
		const hash = createHash("sha256")
			.update(`${discriminator || name}-${attempt}`)
			.digest("hex")
			.slice(0, 8);
		const candidate = attempt === 0 ? initial : branchName(client, name, hash);
		const exists = run(
			"git",
			["show-ref", "--verify", "--quiet", `refs/heads/${candidate}`],
			root,
			{ allowFailure: true, quiet: true },
		).status === 0;
		if (!exists) return candidate;
	}
	throw new Error(`Could not allocate a unique branch for ${client}/${name}.`);
}

function defaultDestinationRoot(root, profile) {
	const checkout = mainCheckout(root);
	const parentLevels = Number(profile.worktrees.parentLevels ?? 2);
	let parent = checkout;
	for (let level = 0; level < parentLevels; level += 1) parent = path.dirname(parent);
	return path.join(parent, profile.worktrees.directoryName);
}

function resolveWorktreePath(root, profile, options, discriminator) {
	const worktreesRoot = path.resolve(
		options.destinationRoot ||
			process.env.IOS_SESSION_LANES_WORKTREE_ROOT ||
			defaultDestinationRoot(root, profile),
	);
	mkdirSync(worktreesRoot, { recursive: true });
	const sessionSuffix = discriminator
		? `-${createHash("sha256").update(discriminator).digest("hex").slice(0, 8)}`
		: "";
	const directoryName = safeWorktreeName(`${options.name}-${options.client}${sessionSuffix}`);
	const destination = path.resolve(worktreesRoot, directoryName);
	if (path.dirname(destination) !== worktreesRoot) {
		throw new Error("Resolved worktree path escaped its managed directory.");
	}
	if (existsSync(destination)) throw new Error(`Worktree destination already exists: ${destination}.`);
	return destination;
}

export async function createWorktree(options, discriminator = "") {
	const context = assertSupportedProject(options.projectRoot || process.cwd());
	const root = context.root;
	const name = safeWorktreeName(options.name);
	const { requestedBaseRef, resolvedBaseCommit } = resolveRemoteBase(
		root,
		options.baseRef ?? options.base ?? context.profile.worktrees.defaultBase,
	);
	if (options.baseRefSource === "legacy-base") {
		process.stderr.write("[worktree] --base is deprecated; use --base-ref origin/<branch>.\n");
	}
	const destination = resolveWorktreePath(root, context.profile, options, discriminator);
	const branch = uniqueBranch(root, options.client, name, discriminator);
	run(
		"git",
		["worktree", "add", "--no-track", "-b", branch, destination, resolvedBaseCommit],
		root,
	);
	try {
		writeManagedWorktreeAttestation(
			{ projectRoot: destination },
			{ client: options.client, requestedBaseRef, resolvedBaseCommit },
		);
		await bootstrap({ ...parseBootstrapOptions(["--quiet"]), projectRoot: destination });
	} catch (error) {
		throw new Error(
			`Created and preserved ${destination} on ${branch}, but bootstrap failed: ${error.message}. ` +
				`Repair it with ios-session-bootstrap --project-root "${destination}".`,
		);
	}
	process.stderr.write(
		`[worktree] Ready ${destination} on ${branch} from ${requestedBaseRef} at ${resolvedBaseCommit}; bootstrap receipt verified.\n`,
	);
	return { branch, destination, requestedBaseRef, resolvedBaseCommit };
}

async function main() {
	const options = parseWorktreeOptions(process.argv.slice(2));
	let discriminator = "";
	if (options.hook) {
		const input = await readHookInput();
		options.name = safeWorktreeName(input.name);
		options.projectRoot = options.projectRoot || String(input.cwd ?? input.project_dir ?? "");
		discriminator = String(input.session_id ?? "");
	}
	if (!options.name) throw new Error("--name is required outside hook mode.");
	const result = await createWorktree(options, discriminator);
	process.stdout.write(`${result.destination}\n`);
}

if (isMainModule(import.meta.url)) {
	main().catch((error) => {
		console.error(`[worktree] ${error.message}`);
		process.exitCode = 1;
	});
}
