import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import {
	ensureDirectoryLayout,
	hashText,
	now,
	registryLockPath,
	registryPath,
	runtimeNamespaceIdentity,
} from "./lane-runtime-context.mjs";
import { withFileLock } from "./lane-lock.mjs";

const registryVersion = 5;

export function readRegistry() {
	ensureDirectoryLayout();
	if (!existsSync(registryPath)) return emptyRegistry();
	try {
		return normalizeRegistry(JSON.parse(readFileSync(registryPath, "utf8")));
	} catch (error) {
		throw new Error(`Invalid iOS lane registry at ${registryPath}: ${error.message}`);
	}
}

function normalizeRegistry(parsed) {
	const registry = emptyRegistry();
	if (
		parsed.namespace &&
		JSON.stringify(parsed.namespace) !== JSON.stringify(runtimeNamespaceIdentity)
	) {
		throw new Error("Registry namespace does not match this repository and mobile/backend profile.");
	}
	registry.backend = parsed.backend ?? null;
	if (registry.backend && !registry.backend.state) registry.backend.state = "running";
	registry.lanes = parsed.lanes ?? {};
	registry.resources = {
		...registry.resources,
		...(parsed.resources ?? {}),
		controllers: parsed.resources?.controllers ?? {},
		simulatorCooldown: parsed.resources?.simulatorCooldown ?? {},
		simulatorQuarantine: parsed.resources?.simulatorQuarantine ?? {},
	};
	for (const [key, lane] of Object.entries(registry.lanes)) {
		lane.backend = lane.backend === "remote" ? "preview" : lane.backend;
		lane.preset = lane.preset ?? "legacy";
		if (!lane.metro) {
			lane.metro = {
				cwd: lane.worktree,
				host: "127.0.0.1",
				nonce: randomBytes(16).toString("hex"),
				pid: lane.metroPid ?? null,
				port: lane.port,
				processStartedAt: null,
				startedAt: lane.createdAt,
				url: `http://127.0.0.1:${lane.port}`,
				worktreeHash: hashText(lane.worktree).slice(0, 16),
			};
		}
		if (!lane.target) {
			lane.target = {
				alias: lane.deviceName,
				kind: "simulator",
				name: lane.deviceName,
				udid: lane.udid,
			};
		}
		lane.key = lane.key ?? key;
	}
	return registry;
}

function emptyRegistry() {
	return {
		backend: null,
		lanes: {},
		namespace: runtimeNamespaceIdentity,
		resources: {
			backendWriter: null,
			controllers: {},
			simulatorCooldown: {},
			simulatorQuarantine: {},
		},
		version: registryVersion,
	};
}

export async function withRegistryLock(callback) {
	return withFileLock(registryLockPath, 60_000, async () => {
		const registry = readRegistry();
		registry.version = registryVersion;
		const result = await callback(registry);
		const temporaryPath = `${registryPath}.${process.pid}.tmp`;
		writeFileSync(temporaryPath, `${JSON.stringify(registry, null, 2)}\n`, {
			mode: 0o600,
		});
		renameSync(temporaryPath, registryPath);
		return result;
	});
}

export function pruneDeadMetroMetadata(registry) {
	for (const lane of Object.values(registry.lanes)) {
		if (lane.metro?.pid && !trackedProcessIsLive(lane.metro)) {
			lane.metro = clearOwnedProcessRecord(lane.metro);
		}
	}
}

export function isPidAlive(pid) {
	if (!Number.isInteger(pid) || pid <= 0) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return error.code === "EPERM";
	}
}

export function processStartedAt(pid) {
	return inspectProcessIdentity(pid)?.processStartedAt ?? null;
}

export function inspectProcessIdentity(pid, { includeEnvironment = false } = {}) {
	if (!Number.isInteger(pid) || pid <= 1 || !isPidAlive(pid)) return null;
	const before = readProcessCoreIdentity(pid);
	if (!before) return null;
	const processCwd = readProcessCwd(pid);
	const environmentCommand = includeEnvironment ? readProcessEnvironmentCommand(pid) : null;
	const after = readProcessCoreIdentity(pid);
	if (!after || !sameCoreProcessIdentity(before, after)) return null;
	return { ...before, environmentCommand, processCwd };
}

export function captureOwnedProcessRecord(
	pid,
	{
		expectedCommandParts = [],
		expectedCwd = null,
		metroNonce = null,
		metroWorktreeHash = null,
		processNonce = null,
		processRole = "process",
		signalScope = "group",
	} = {},
) {
	const includeEnvironment = Boolean(processNonce || processRole === "metro");
	const identity = inspectProcessIdentity(pid, { includeEnvironment });
	if (!identity) throw new Error(`Could not establish a stable identity for owned PID ${pid}.`);
	if (!identity.processCwd) {
		throw new Error(`Could not establish the working directory for owned PID ${pid}.`);
	}
	if (
		expectedCwd &&
		path.resolve(identity.processCwd) !== path.resolve(realpathSync(expectedCwd))
	) {
		throw new Error(`Owned PID ${pid} did not start in the expected working directory.`);
	}
	for (const part of expectedCommandParts) {
		if (!identity.processCommand.includes(String(part))) {
			throw new Error(`Owned PID ${pid} did not match its expected command.`);
		}
	}
	if (signalScope !== "group" && signalScope !== "individual") {
		throw new Error(`Unsupported signal scope ${signalScope}.`);
	}
	if (signalScope === "group" && identity.processGroupId !== pid) {
		throw new Error(`Owned PID ${pid} is not the leader of its dedicated process group.`);
	}
	if (!processNonce) {
		throw new Error(`Owned PID ${pid} is missing its random process identity token.`);
	}
	if (
		!environmentHasAssignment(
			identity.environmentCommand,
			"IOS_SESSION_LANE_PROCESS_NONCE",
			processNonce,
		)
	) {
		throw new Error(`Owned PID ${pid} did not expose its random process identity token.`);
	}
	if (processRole === "metro") {
		if (!metroNonce || !metroWorktreeHash) {
			throw new Error("Metro ownership requires its lane nonce and worktree hash.");
		}
		if (
			!environmentHasAssignment(identity.environmentCommand, "IOS_SESSION_LANE_NONCE", metroNonce) ||
			!environmentHasAssignment(
				identity.environmentCommand,
				"IOS_SESSION_LANE_WORKTREE_HASH",
				metroWorktreeHash,
			)
		) {
			throw new Error(`Owned Metro PID ${pid} did not expose its lane identity.`);
		}
	}
	return {
		metroNonce,
		metroWorktreeHash,
		pid,
		processCommand: identity.processCommand,
		processCwd: identity.processCwd,
		processExecutable: identity.processExecutable,
		processGroupId: identity.processGroupId,
		processNonce,
		processRole,
		processSessionId: identity.processSessionId,
		processStartedAt: identity.processStartedAt,
		signalScope,
	};
}

export function processIdentityMatches(processRecord, currentIdentity) {
	if (!processRecord || !currentIdentity) return false;
	if (
		!Number.isInteger(processRecord.pid) ||
		processRecord.pid <= 1 ||
		!Number.isInteger(processRecord.processGroupId) ||
		processRecord.processGroupId <= 1 ||
		!processRecord.processStartedAt ||
		!processRecord.processExecutable ||
		!processRecord.processCommand ||
		!processRecord.processCwd ||
		!processRecord.processNonce ||
		!processRecord.processRole ||
		processRecord.processSessionId === null ||
		processRecord.processSessionId === undefined ||
		!processRecord.signalScope
	) {
		return false;
	}
	if (
		!currentIdentity.processStartedAt ||
		!currentIdentity.processExecutable ||
		!currentIdentity.processCommand ||
		!currentIdentity.processCwd ||
		currentIdentity.processSessionId === null ||
		currentIdentity.processSessionId === undefined
	) {
		return false;
	}
	if (
		processRecord.pid !== currentIdentity.pid ||
		processRecord.processStartedAt !== currentIdentity.processStartedAt ||
		processRecord.processExecutable !== currentIdentity.processExecutable ||
		processRecord.processCommand !== currentIdentity.processCommand ||
		path.resolve(processRecord.processCwd) !== path.resolve(currentIdentity.processCwd ?? "") ||
		processRecord.processGroupId !== currentIdentity.processGroupId ||
		String(processRecord.processSessionId) !== String(currentIdentity.processSessionId)
	) {
		return false;
	}
	if (
		!environmentHasAssignment(
			currentIdentity.environmentCommand,
			"IOS_SESSION_LANE_PROCESS_NONCE",
			processRecord.processNonce,
		)
	) {
		return false;
	}
	if (
		processRecord.signalScope === "group" &&
		(processRecord.processGroupId !== processRecord.pid ||
			currentIdentity.processGroupId !== currentIdentity.pid)
	) {
		return false;
	}
	if (processRecord.signalScope !== "group" && processRecord.signalScope !== "individual") {
		return false;
	}
	if (processRecord.processRole === "metro") {
		return Boolean(
			processRecord.metroNonce &&
			processRecord.metroWorktreeHash &&
			environmentHasAssignment(
				currentIdentity.environmentCommand,
				"IOS_SESSION_LANE_NONCE",
				processRecord.metroNonce,
			) &&
			environmentHasAssignment(
				currentIdentity.environmentCommand,
				"IOS_SESSION_LANE_WORKTREE_HASH",
				processRecord.metroWorktreeHash,
			)
		);
	}
	return true;
}

export function processOwnershipStatus(processRecord) {
	if (!processRecord?.pid) return "absent";
	if (!isPidAlive(processRecord.pid)) return "exited";
	const current = inspectProcessIdentity(processRecord.pid, {
		includeEnvironment: Boolean(processRecord.processNonce || processRecord.processRole === "metro"),
	});
	if (!current) return isPidAlive(processRecord.pid) ? "mismatch" : "exited";
	if (String(current.processState).startsWith("Z")) return "exited";
	return processIdentityMatches(processRecord, current) ? "owned" : "mismatch";
}

export function ownedProcess(processRecord) {
	return processOwnershipStatus(processRecord) === "owned";
}

export function ownedProcessRuntime(processRecord) {
	if (ownedProcess(processRecord)) return true;
	if (processRecord?.signalScope === "group") {
		return inspectOwnedProcessGroup(processRecord).status === "owned";
	}
	return false;
}

export function trackedProcessIsLive(processRecord) {
	if (processRecord?.signalScope === "group") {
		const group = inspectOwnedProcessGroup(processRecord);
		return group.status !== "empty";
	}
	const status = processOwnershipStatus(processRecord);
	return status === "owned" || status === "mismatch";
}

export function metroProcessOwned(lane) {
	return ownedProcessRuntime(lane.metro);
}

export function stopOwnedProcess(processRecord) {
	return signalOwnedProcess(processRecord, "SIGTERM");
}

function signalOwnedProcess(processRecord, signal) {
	if (processRecord?.signalScope === "group") {
		return signalOwnedProcessGroup(processRecord, signal);
	}
	const status = processOwnershipStatus(processRecord);
	if (status === "absent" || status === "exited") return false;
	if (status !== "owned") throw processIdentityMismatchError(processRecord);
	const current = inspectProcessIdentity(processRecord.pid, {
		includeEnvironment: Boolean(processRecord.processNonce || processRecord.processRole === "metro"),
	});
	if (!processIdentityMatches(processRecord, current)) {
		throw processIdentityMismatchError(processRecord);
	}
	const target = processSignalTarget(processRecord, current);
	if (target === null) throw processIdentityMismatchError(processRecord);
	try {
		process.kill(target, signal);
		return true;
	} catch (error) {
		if (error.code === "ESRCH" && !isPidAlive(processRecord.pid)) return false;
		throw new Error(`Could not signal exactly owned PID ${processRecord.pid}: ${error.message}`);
	}
}

export function processSignalTarget(processRecord, currentIdentity) {
	if (!processIdentityMatches(processRecord, currentIdentity)) return null;
	if (processRecord.signalScope === "individual") return processRecord.pid;
	if (
		processRecord.signalScope !== "group" ||
		processRecord.pid <= 1 ||
		processRecord.processGroupId !== processRecord.pid ||
		currentIdentity.processGroupId !== currentIdentity.pid
	) {
		return null;
	}
	return -processRecord.processGroupId;
}

export function processGroupMemberIdentityMatches(processRecord, currentIdentity) {
	if (
		!verifiableOwnedProcessGroupRecord(processRecord) ||
		!currentIdentity ||
		!Number.isInteger(currentIdentity.pid) ||
		currentIdentity.pid <= 1 ||
		currentIdentity.processGroupId !== processRecord.processGroupId ||
		String(currentIdentity.processSessionId) !== String(processRecord.processSessionId) ||
		!currentIdentity.processCwd ||
		path.resolve(currentIdentity.processCwd) !== path.resolve(processRecord.processCwd) ||
		!environmentHasAssignment(
			currentIdentity.environmentCommand,
			"IOS_SESSION_LANE_PROCESS_NONCE",
			processRecord.processNonce,
		)
	) {
		return false;
	}
	if (
		processRecord.processRole === "metro" &&
		(!processRecord.metroNonce ||
			!processRecord.metroWorktreeHash ||
			!environmentHasAssignment(
				currentIdentity.environmentCommand,
				"IOS_SESSION_LANE_NONCE",
				processRecord.metroNonce,
			) ||
			!environmentHasAssignment(
				currentIdentity.environmentCommand,
				"IOS_SESSION_LANE_WORKTREE_HASH",
				processRecord.metroWorktreeHash,
			))
	) {
		return false;
	}
	return currentIdentity.pid !== processRecord.pid || processIdentityMatches(processRecord, currentIdentity);
}

export function inspectOwnedProcessGroup(processRecord) {
	if (!verifiableOwnedProcessGroupRecord(processRecord)) {
		return { members: [], reason: "the persisted group identity is incomplete", status: "mismatch" };
	}
	return inspectStableProcessGroup(processRecord.processGroupId, (identity) =>
		processGroupMemberIdentityMatches(processRecord, identity),
	);
}

function signalOwnedProcessGroup(processRecord, signal) {
	const snapshot = inspectOwnedProcessGroup(processRecord);
	if (snapshot.status === "empty") return false;
	if (snapshot.status !== "owned") throw processGroupIdentityMismatchError(processRecord, snapshot);
	try {
		process.kill(-processRecord.processGroupId, signal);
		return true;
	} catch (error) {
		if (error.code === "ESRCH" && inspectOwnedProcessGroup(processRecord).status === "empty") {
			return false;
		}
		throw new Error(
			`Could not signal exactly owned process group ${processRecord.processGroupId}: ${error.message}`,
		);
	}
}

async function stopOwnedProcessGroupAndWait(processRecord, { timeoutMs }) {
	let snapshot = inspectOwnedProcessGroup(processRecord);
	if (snapshot.status === "empty") return false;
	if (snapshot.status !== "owned") throw processGroupIdentityMismatchError(processRecord, snapshot);
	signalOwnedProcessGroup(processRecord, "SIGTERM");
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		snapshot = inspectOwnedProcessGroup(processRecord);
		if (snapshot.status === "empty") return true;
		if (snapshot.status !== "owned") throw processGroupIdentityMismatchError(processRecord, snapshot);
		await delay(50);
	}
	signalOwnedProcessGroup(processRecord, "SIGKILL");
	const killDeadline = Date.now() + Math.min(2_000, Math.max(250, timeoutMs));
	while (Date.now() < killDeadline) {
		snapshot = inspectOwnedProcessGroup(processRecord);
		if (snapshot.status === "empty") return true;
		if (snapshot.status !== "owned") throw processGroupIdentityMismatchError(processRecord, snapshot);
		await delay(25);
	}
	snapshot = inspectOwnedProcessGroup(processRecord);
	if (snapshot.status !== "owned") {
		if (snapshot.status === "empty") return true;
		throw processGroupIdentityMismatchError(processRecord, snapshot);
	}
	throw new Error(
		`Exactly owned process group ${processRecord.processGroupId} retained active members after SIGKILL.`,
	);
}

export async function captureOwnedProcessRecordOrCleanup(
	child,
	captureOptions,
	{ attempts = 20, cleanupTimeoutMs = 5_000, retryDelayMs = 50 } = {},
) {
	let lastError = null;
	for (let attempt = 0; attempt < attempts; attempt += 1) {
		try {
			return captureOwnedProcessRecord(child.pid, captureOptions);
		} catch (error) {
			lastError = error;
			if (attempt + 1 < attempts) await delay(retryDelayMs);
		}
	}
	try {
		await cleanupSpawnedProcessGroup(child, captureOptions, { timeoutMs: cleanupTimeoutMs });
	} catch (cleanupError) {
		throw new Error(
			`Spawned process identity could not be captured (${lastError?.message ?? "unknown error"}); exact child/group cleanup failed: ${cleanupError.message}`,
		);
	}
	throw new Error(
		`Spawned process identity could not be captured (${lastError?.message ?? "unknown error"}); the exact spawned child/group was stopped.`,
	);
}

export async function cleanupSpawnedProcessGroup(
	child,
	{
		expectedCwd,
		metroNonce = null,
		metroWorktreeHash = null,
		processNonce,
		processRole = "process",
	} = {},
	{ timeoutMs = 5_000 } = {},
) {
	if (!child?.pid || child.pid <= 1 || !expectedCwd || !processNonce) {
		throw new Error("The spawned child/group identity is incomplete.");
	}
	const descriptor = {
		expectedCwd: path.resolve(realpathSync(expectedCwd)),
		metroNonce,
		metroWorktreeHash,
		processGroupId: child.pid,
		processNonce,
		processRole,
	};
	let snapshot = inspectSpawnedProcessGroup(descriptor);
	if (snapshot.status === "mismatch") {
		if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
		await delay(50);
		snapshot = inspectSpawnedProcessGroup(descriptor);
		if (snapshot.status === "mismatch") {
			throw new Error(
				`Refusing a group signal for spawned PGID ${child.pid}: ${snapshot.reason ?? "a member identity changed"}.`,
			);
		}
	}
	if (snapshot.status === "empty") return false;
	signalSpawnedProcessGroup(descriptor, "SIGTERM");
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		snapshot = inspectSpawnedProcessGroup(descriptor);
		if (snapshot.status === "empty") return true;
		if (snapshot.status === "mismatch") {
			throw new Error(`Spawned PGID ${child.pid} changed identity during cleanup.`);
		}
		await delay(50);
	}
	signalSpawnedProcessGroup(descriptor, "SIGKILL");
	const killDeadline = Date.now() + Math.min(2_000, Math.max(250, timeoutMs));
	while (Date.now() < killDeadline) {
		snapshot = inspectSpawnedProcessGroup(descriptor);
		if (snapshot.status === "empty") return true;
		if (snapshot.status === "mismatch") {
			throw new Error(`Spawned PGID ${child.pid} changed identity during cleanup.`);
		}
		await delay(25);
	}
	throw new Error(`Spawned PGID ${child.pid} retained active members after SIGKILL.`);
}

function signalSpawnedProcessGroup(descriptor, signal) {
	const snapshot = inspectSpawnedProcessGroup(descriptor);
	if (snapshot.status === "empty") return false;
	if (snapshot.status !== "owned") {
		throw new Error(
			`Refusing a group signal for spawned PGID ${descriptor.processGroupId}: ${snapshot.reason ?? "a member identity changed"}.`,
		);
	}
	try {
		process.kill(-descriptor.processGroupId, signal);
		return true;
	} catch (error) {
		if (error.code === "ESRCH" && inspectSpawnedProcessGroup(descriptor).status === "empty") {
			return false;
		}
		throw error;
	}
}

function inspectSpawnedProcessGroup(descriptor) {
	if (
		!Number.isInteger(descriptor.processGroupId) ||
		descriptor.processGroupId <= 1 ||
		!descriptor.expectedCwd ||
		!descriptor.processNonce
	) {
		return { members: [], reason: "the spawned group identity is incomplete", status: "mismatch" };
	}
	const snapshot = inspectStableProcessGroup(descriptor.processGroupId, (identity) => {
		if (
			!identity.processCwd ||
			path.resolve(identity.processCwd) !== descriptor.expectedCwd ||
			!environmentHasAssignment(
				identity.environmentCommand,
				"IOS_SESSION_LANE_PROCESS_NONCE",
				descriptor.processNonce,
			)
		) {
			return false;
		}
		if (descriptor.processRole !== "metro") return true;
		return Boolean(
			descriptor.metroNonce &&
			descriptor.metroWorktreeHash &&
			environmentHasAssignment(
				identity.environmentCommand,
				"IOS_SESSION_LANE_NONCE",
				descriptor.metroNonce,
			) &&
			environmentHasAssignment(
				identity.environmentCommand,
				"IOS_SESSION_LANE_WORKTREE_HASH",
				descriptor.metroWorktreeHash,
			)
		);
	});
	if (
		snapshot.status === "owned" &&
		new Set(snapshot.members.map((member) => String(member.processSessionId))).size !== 1
	) {
		return {
			members: snapshot.members,
			reason: "spawned process-group members did not share one session identity",
			status: "mismatch",
		};
	}
	return snapshot;
}

function inspectStableProcessGroup(processGroupId, memberMatches) {
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const before = readActiveProcessGroupMembers(processGroupId);
		if (!before) {
			return { members: [], reason: "process-group enumeration failed", status: "mismatch" };
		}
		if (before.length === 0) return { members: [], status: "empty" };
		const identities = [];
		let raced = false;
		for (const member of before) {
			const identity = inspectProcessIdentity(member.pid, { includeEnvironment: true });
			if (!identity || identity.processGroupId !== processGroupId) {
				raced = true;
				break;
			}
			if (!memberMatches(identity)) {
				return {
					members: identities,
					reason: `PID ${member.pid} did not match the exact group identity`,
					status: "mismatch",
				};
			}
			identities.push(identity);
		}
		if (raced) continue;
		const after = readActiveProcessGroupMembers(processGroupId);
		if (!after) {
			return { members: [], reason: "process-group enumeration failed", status: "mismatch" };
		}
		if (samePidSet(before, after)) return { members: identities, status: "owned" };
	}
	return { members: [], reason: "process-group membership did not stabilize", status: "mismatch" };
}

function readActiveProcessGroupMembers(processGroupId) {
	const result = spawnSync("ps", ["-axo", "pid=,pgid=,state="], {
		encoding: "utf8",
		maxBuffer: 4 * 1024 * 1024,
	});
	if (result.status !== 0) return null;
	return result.stdout
		.split(/\r?\n/)
		.map((line) => line.match(/^\s*([0-9]+)\s+([0-9]+)\s+(\S+)/))
		.filter(Boolean)
		.map((match) => ({ pid: Number(match[1]), processGroupId: Number(match[2]), state: match[3] }))
		.filter(
			(member) =>
				member.processGroupId === processGroupId && !String(member.state).startsWith("Z"),
		)
		.sort((left, right) => left.pid - right.pid);
}

function samePidSet(left, right) {
	return (
		left.length === right.length && left.every((member, index) => member.pid === right[index].pid)
	);
}

function verifiableOwnedProcessGroupRecord(processRecord) {
	return Boolean(
		processRecord &&
		processRecord.signalScope === "group" &&
		Number.isInteger(processRecord.pid) &&
		processRecord.pid > 1 &&
		processRecord.processGroupId === processRecord.pid &&
		processRecord.processStartedAt &&
		processRecord.processExecutable &&
		processRecord.processCommand &&
		processRecord.processCwd &&
		processRecord.processNonce &&
		processRecord.processRole &&
		processRecord.processSessionId !== null &&
		processRecord.processSessionId !== undefined
	);
}

function processGroupIdentityMismatchError(processRecord, snapshot) {
	return new Error(
		`Refusing to signal process group ${processRecord?.processGroupId ?? "unknown"}: ${snapshot?.reason ?? "a member no longer matches its exact lane identity"}.`,
	);
}

export async function stopOwnedProcessAndWait(processRecord, { timeoutMs = 5_000 } = {}) {
	if (processRecord?.signalScope === "group") {
		return stopOwnedProcessGroupAndWait(processRecord, { timeoutMs });
	}
	const initialStatus = processOwnershipStatus(processRecord);
	if (initialStatus === "absent" || initialStatus === "exited") return false;
	if (initialStatus !== "owned") throw processIdentityMismatchError(processRecord);
	signalOwnedProcess(processRecord, "SIGTERM");
	const deadline = Date.now() + timeoutMs;
	let status = processOwnershipStatus(processRecord);
	while (status === "owned" && Date.now() < deadline) {
		await delay(50);
		status = processOwnershipStatus(processRecord);
	}
	if (status === "mismatch") throw processIdentityMismatchError(processRecord);
	if (status === "owned") {
		signalOwnedProcess(processRecord, "SIGKILL");
		const killDeadline = Date.now() + Math.min(2_000, Math.max(250, timeoutMs));
		while (status === "owned" && Date.now() < killDeadline) {
			await delay(25);
			status = processOwnershipStatus(processRecord);
		}
	}
	if (status === "mismatch") throw processIdentityMismatchError(processRecord);
	if (status !== "exited" && status !== "absent") {
		throw new Error(`Exactly owned PID ${processRecord.pid} remained live after SIGKILL.`);
	}
	return true;
}

export function stopOwnedMetro(lane) {
	stopOwnedProcess(lane.metro?.tailscale);
	stopOwnedProcess(lane.metro);
}

export async function stopOwnedMetroAndWait(lane, options) {
	const failures = [];
	let tailscaleStopped = false;
	let metroStopped = false;
	try {
		tailscaleStopped = await stopOwnedProcessAndWait(lane.metro?.tailscale, options);
	} catch (error) {
		failures.push(error.message);
	}
	try {
		metroStopped = await stopOwnedProcessAndWait(lane.metro, options);
	} catch (error) {
		failures.push(error.message);
	}
	if (failures.length > 0) throw new Error(failures.join("; "));
	return { metroStopped, tailscaleStopped };
}

export function clearOwnedProcessRecord(record = {}) {
	return {
		...record,
		metroNonce: null,
		metroWorktreeHash: null,
		pid: null,
		processCommand: null,
		processCwd: null,
		processExecutable: null,
		processGroupId: null,
		processNonce: null,
		processRole: null,
		processSessionId: null,
		processStartedAt: null,
		serveHttpsPort: null,
		serveProxyUrl: null,
		signalScope: null,
	};
}

function readProcessCoreIdentity(pid) {
	const result = spawnSync(
		"ps",
		[
			"-ww",
			"-p",
			String(pid),
			"-o",
			"pid=,pgid=,sess=,state=,lstart=,comm=,command=",
		],
		{ encoding: "utf8", maxBuffer: 1024 * 1024 },
	);
	if (result.status !== 0) return null;
	const fields = result.stdout.trim().split(/\s+/);
	if (fields.length < 11) return null;
	const outputPid = Number(fields[0]);
	const processGroupId = Number(fields[1]);
	if (outputPid !== pid || !Number.isInteger(processGroupId)) return null;
	return {
		pid: outputPid,
		processCommand: fields.slice(10).join(" "),
		processExecutable: fields[9],
		processGroupId,
		processSessionId: fields[2],
		processStartedAt: fields.slice(4, 9).join(" "),
		processState: fields[3],
	};
}

function readProcessCwd(pid) {
	const result = spawnSync("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], {
		encoding: "utf8",
		maxBuffer: 1024 * 1024,
	});
	if (result.status !== 0) return null;
	const cwd = result.stdout
		.split(/\r?\n/)
		.find((line) => line.startsWith("n"))
		?.slice(1);
	return cwd ? path.resolve(cwd) : null;
}

function readProcessEnvironmentCommand(pid) {
	const result = spawnSync("ps", ["eww", "-p", String(pid), "-o", "command="], {
		encoding: "utf8",
		maxBuffer: 20 * 1024 * 1024,
	});
	return result.status === 0 ? result.stdout : null;
}

function sameCoreProcessIdentity(left, right) {
	return Boolean(
		left &&
		right &&
		left.pid === right.pid &&
		left.processStartedAt === right.processStartedAt &&
		left.processExecutable === right.processExecutable &&
		left.processCommand === right.processCommand &&
		left.processGroupId === right.processGroupId &&
		String(left.processSessionId) === String(right.processSessionId),
	);
}

function environmentHasAssignment(environmentCommand, name, value) {
	if (!environmentCommand || !name || value === null || value === undefined) return false;
	const escapedName = String(name).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	const escapedValue = String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	return new RegExp(`(?:^|\\s)${escapedName}=${escapedValue}(?:\\s|$)`).test(environmentCommand);
}

function processIdentityMismatchError(processRecord) {
	return new Error(
		`Refusing to signal PID ${processRecord?.pid ?? "unknown"}: its executable, command, cwd, process group/session, or lane identity changed.`,
	);
}

export async function updateLane(key, callback) {
	return withRegistryLock(async (registry) => {
		const current = registry.lanes[key];
		if (!current) throw new Error(`Lane ${key} was released.`);
		callback(current);
		current.updatedAt = now();
		return current;
	});
}

export async function updateLaneIfPresent(key, callback) {
	return withRegistryLock(async (registry) => {
		const current = registry.lanes[key];
		if (current) {
			callback(current);
			current.updatedAt = now();
		}
		return current ?? null;
	});
}

export function releaseLaneResources(registry, lane) {
	if (
		lane.controller?.resource &&
		registry.resources.controllers[lane.controller.resource]?.ownerKey === lane.key
	) {
		delete registry.resources.controllers[lane.controller.resource];
	}
	if (registry.resources.backendWriter?.ownerKey === lane.key) {
		registry.resources.backendWriter = null;
	}
}

export function targetResourceKey(target) {
	return target.kind === "simulator" ? `simulator:${target.udid}` : `physical:${target.alias}`;
}
