import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import {
	profile,
	repoRoot,
	runCaptured,
} from "./lane-runtime-context.mjs";
import { readRegistry } from "./lane-state.mjs";

export function assertBackendCompatible(
	detected,
	registeredBackend = readRegistry().backend,
	{ allowPersistedDrift = false } = {},
) {
	if (!detected.mountWorktree || !detected.compatibility) {
		throw new Error("Could not prove the running Supabase stack's source worktree.");
	}
	const current = backendContract(repoRoot);
	if (detected.compatibility.hash !== current.hash) {
		throw new Error(
			`Running Supabase is mounted from ${detected.mountWorktree} with a different backend contract. Coordinate with its owner; ordinary lane startup will not remount it.`,
		);
	}
	assertPersistedBackendContract(registeredBackend, detected.compatibility, {
		allowPersistedDrift,
	});
}

export function assertPersistedBackendContract(
	registeredBackend,
	liveContract,
	{ allowPersistedDrift = false } = {},
) {
	if (!registeredBackend || allowPersistedDrift) return liveContract;
	if (!registeredBackend.compatibility?.hash) {
		throw new Error(
			"The shared backend has no persisted start/reset contract; adopt or restart it before attaching lanes.",
		);
	}
	if (registeredBackend.compatibility.hash !== liveContract?.hash) {
		throw new Error(
			"The mounted backend contract changed after Supabase last started or reset; reset it before attaching lanes.",
		);
	}
	return liveContract;
}

export function backendContract(worktree) {
	const relativePaths = collectBackendContractPaths(worktree);
	const hash = createHash("sha256");
	for (const relative of relativePaths) {
		hash.update(relative);
		hash.update("\0");
		hash.update(readFileSync(path.join(worktree, relative)));
		hash.update("\0");
	}
	return { fileCount: relativePaths.length, hash: hash.digest("hex") };
}

function collectBackendContractPaths(worktree) {
	const result = runCaptured(
		"git",
		["ls-files", "--cached", "--others", "--exclude-standard", "--", ...profile.backend.contractPaths],
		worktree,
	);
	return [...new Set(result.stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean))]
		.filter((relative) => existsSync(path.join(worktree, relative)))
		.sort();
}
