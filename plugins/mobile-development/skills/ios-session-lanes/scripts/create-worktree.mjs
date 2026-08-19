#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { bootstrap, parseBootstrapOptions } from "./bootstrap-worktree.mjs";
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
		base: profile.worktrees.defaultBase,
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
		else if (arg === "--base") options.base = requireValue(args, ++index, arg);
		else if (arg === "--client") options.client = safeWorktreeName(requireValue(args, ++index, arg));
		else if (arg === "--name") options.name = safeWorktreeName(requireValue(args, ++index, arg));
		else if (arg === "--destination-root") options.destinationRoot = requireValue(args, ++index, arg);
		else if (arg === "--project-root") options.projectRoot = requireValue(args, ++index, arg);
		else throw new Error(`Unknown worktree option ${arg}.`);
	}
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
	const exists = run("git", ["show-ref", "--verify", "--quiet", `refs/heads/${initial}`], root, {
		allowFailure: true,
		quiet: true,
	}).status === 0;
	if (!exists) return initial;
	const hash = createHash("sha256")
		.update(discriminator || `${name}-${Date.now()}`)
		.digest("hex")
		.slice(0, 8);
	return branchName(client, name, hash);
}

function defaultDestinationRoot(root, profile) {
	const checkout = mainCheckout(root);
	const parentLevels = Number(profile.worktrees.parentLevels ?? 2);
	let parent = checkout;
	for (let level = 0; level < parentLevels; level += 1) parent = path.dirname(parent);
	return path.join(parent, profile.worktrees.directoryName);
}

function resolveWorktreePath(root, profile, options) {
	const worktreesRoot = path.resolve(
		options.destinationRoot ||
			process.env.IOS_SESSION_LANES_WORKTREE_ROOT ||
			defaultDestinationRoot(root, profile),
	);
	mkdirSync(worktreesRoot, { recursive: true });
	const destination = path.resolve(worktreesRoot, safeWorktreeName(options.name));
	if (path.dirname(destination) !== worktreesRoot) {
		throw new Error("Resolved worktree path escaped its managed directory.");
	}
	if (existsSync(destination)) throw new Error(`Worktree destination already exists: ${destination}.`);
	return destination;
}

function refreshBase(root, base) {
	if (!base.startsWith("origin/")) return;
	const branch = base.slice("origin/".length);
	const result = run("git", ["fetch", "origin", branch], root, {
		allowFailure: true,
		quiet: true,
	});
	if (result.status !== 0) {
		process.stderr.write(`[worktree] Could not refresh ${base}; using the existing local ref.\n`);
	}
}

export function createWorktree(options, discriminator = "") {
	const context = assertSupportedProject(options.projectRoot || process.cwd());
	const root = context.root;
	const name = safeWorktreeName(options.name);
	refreshBase(root, options.base);
	const destination = resolveWorktreePath(root, context.profile, options);
	const branch = uniqueBranch(root, options.client, name, discriminator);
	run("git", ["worktree", "add", "--no-track", "-b", branch, destination, options.base], root);
	try {
		bootstrap({ ...parseBootstrapOptions(["--quiet"]), projectRoot: destination });
	} catch (error) {
		throw new Error(
			`Created and preserved ${destination} on ${branch}, but bootstrap failed: ${error.message}. ` +
				`Repair it with ios-session-bootstrap --project-root "${destination}".`,
		);
	}
	process.stderr.write(`[worktree] Ready ${destination} on ${branch}; bootstrap receipt verified.\n`);
	return { branch, destination };
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
	const result = createWorktree(options, discriminator);
	process.stdout.write(`${result.destination}\n`);
}

if (isMainModule(import.meta.url)) {
	main().catch((error) => {
		console.error(`[worktree] ${error.message}`);
		process.exitCode = 1;
	});
}
