#!/usr/bin/env node

import { randomBytes } from "node:crypto";
import path from "node:path";
import {
	assertSupportedProject,
	isMainModule,
} from "./project-context.mjs";
import { requireIdentifier, safeKey, sessionKey } from "./lane-identifiers.mjs";
import {
	applyRecordedLaneSelection,
	assertBackendChoice,
	assertBootstrap,
	assertControllerChoice,
	assertDarwin,
	assertExposureChoice,
	assertLaneSelection,
	assertSession,
	parseOptions,
	parseTarget,
	prepareTargetDefaults,
} from "./lane-policy.mjs";
import {
	backendAdopt,
	backendDown,
	backendReset,
	backendUp,
	backendWriterAcquire,
	backendWriterRelease,
	printBackend,
	redactBackendRegistry,
	resolveMetroEnvironment,
} from "./lane-backend.mjs";
import { withFileLock } from "./lane-lock.mjs";
import {
	closeAgentDeviceStrict,
	connectTarget,
	controllerAcquire,
	controllerRelease,
	runController,
	withTargetControllerOperation,
} from "./lane-controller.mjs";
import { ensureNativeBinary } from "./lane-native.mjs";
import {
	collectEvidence,
	failedCheckNames,
	writeEvidence,
} from "./lane-evidence.mjs";
import {
	ensureDirectoryLayout,
	evidenceRoot,
	hashText,
	laneHome,
	logsRoot,
	now,
	profile,
	repoRoot,
} from "./lane-runtime-context.mjs";
import {
	clearOwnedProcessRecord,
	metroProcessOwned,
	pruneDeadMetroMetadata,
	readRegistry,
	releaseLaneResources,
	updateLane,
	updateLaneIfPresent,
	withRegistryLock,
} from "./lane-state.mjs";
import {
	chooseMetroPort,
	ensureMetroStarted,
	laneRuntimeIsLive,
	resolveMetroEndpoint,
	stopLaneMetroAndWait,
} from "./lane-metro.mjs";
import {
	allocatePhysical,
	bootLaneSimulator,
	cooldownAndReassignSimulator,
	cooldownSimulatorWithoutReassignment,
	ensureSimulator,
	resolvePhysicalDevice,
} from "./lane-target.mjs";
const lifecycleLockTimeoutMs = 35 * 60 * 1000;

export { sessionKey } from "./lane-identifiers.mjs";
export { nativeCacheKey } from "./lane-native.mjs";
export { isPortAvailable } from "./lane-metro.mjs";
export {
	assertNoReservedControllerFlags,
	controllerAcquire,
	controllerRelease,
	runController,
} from "./lane-controller.mjs";
export { readRegistry } from "./lane-state.mjs";
export { classifySimulatorBootResult } from "./lane-target.mjs";
export {
	applyRecordedLaneSelection,
	lanePreset,
	laneSelectionIsConfirmed,
	normalizeBackendChoice,
	parseOptions,
	parseTarget,
} from "./lane-policy.mjs";
export {
	backendAdopt,
	backendDown,
	backendReset,
	backendUp,
	backendWriterAcquire,
	backendWriterRelease,
} from "./lane-backend.mjs";

export async function getLane(client, sessionId) {
	const registry = readRegistry();
	return registry.lanes[sessionKey(client, sessionId)] ?? null;
}

export async function up(options) {
	assertDarwin();
	assertSession(options);
	assertBootstrap();
	const key = sessionKey(options.client, options.sessionId);
	ensureDirectoryLayout();
	await reap({ deadOnly: true, excludeKey: key, quiet: true, staleAfterMinutes: 120 });
	return withFileLock(
		path.join(laneHome, `lifecycle-${safeKey(key)}.lock`),
		lifecycleLockTimeoutMs,
		() => upLocked(options, key),
	);
}

async function upLocked(options, key) {
	let previousLane = readRegistry().lanes[key] ?? null;
	applyRecordedLaneSelection(options, previousLane);
	assertLaneSelection(options);
	const requestedTarget = parseTarget(options.target);
	prepareTargetDefaults(options, requestedTarget);
	assertBackendChoice(options.backend);
	assertExposureChoice(options.expose);
	assertControllerChoice(options.controller);
	let target = requestedTarget;
	let physicalFallback = null;
	if (requestedTarget.kind === "physical") {
		const physical = resolvePhysicalDevice(requestedTarget.alias);
		if (physical) target = physical;
		else {
			physicalFallback =
				`${requestedTarget.alias} is not locally reachable; using a simulator. ` +
				"No EAS physical-device build was requested or created.";
			console.warn(`[ios-lane] ${physicalFallback}`);
			target = { alias: "automatic", kind: "simulator" };
			options.expose = "local";
		}
	}
	if (
		previousLane &&
		!metroProcessOwned(previousLane) &&
		laneRuntimeIsLive(previousLane)
	) {
		await stopLaneMetroAndWait(previousLane);
		previousLane = readRegistry().lanes[key] ?? previousLane;
	}

	const registerLane = () => withRegistryLock(async (registry) => {
		pruneDeadMetroMetadata(registry);
		if (options.backend === "local" && registry.backend?.state && registry.backend.state !== "running") {
			throw new Error(
				`Shared Supabase is ${registry.backend.state}; wait for its owner operation to finish before attaching a lane.`,
			);
		}
		const existing = registry.lanes[key];
		if (existing) {
			if (path.resolve(existing.worktree) !== repoRoot) {
				throw new Error(
					`Session ${key} already owns a lane in ${existing.worktree}. Run down there before changing worktrees.`,
				);
			}
			const runtimeRunning = laneRuntimeIsLive(existing);
			if (existing.backend !== options.backend && runtimeRunning) {
				throw new Error(
					`Lane ${key} is already running with backend=${existing.backend}. Run down before switching backends.`,
				);
			}
			if (existing.exposure !== options.expose && runtimeRunning) {
				throw new Error(
					`Lane ${key} is already running with exposure=${existing.exposure}. Run down before switching exposure.`,
				);
			}
			const existingRequestedTarget = existing.requestedTarget ?? existing.target;
			if (
				existingRequestedTarget.kind !== requestedTarget.kind ||
				(requestedTarget.kind === "physical" &&
					existingRequestedTarget.alias !== requestedTarget.alias)
			) {
				throw new Error(
					`Lane ${key} already targets ${existing.requestedTarget?.kind ?? existing.target.kind}. Run down before changing targets.`,
				);
			}
			if (!runtimeRunning) {
				const nextTarget = allocateResolvedTarget(registry, target, existing);
				if (!sameResolvedTarget(existing.target, nextTarget)) {
					releaseLaneResources(registry, existing);
					existing.controller = null;
					existing.native = null;
					existing.render = null;
					existing.target = nextTarget;
				}
				existing.metro = stoppedMetroForRestart(existing.metro);
				existing.fallbackReason = physicalFallback;
				existing.requestedTarget = requestedTarget;
			}
			existing.backend = options.backend;
			existing.exposure = options.expose;
			existing.preset = options.preset;
			existing.updatedAt = now();
			return existing;
		}

		const port = await chooseMetroPort(registry, "", { exposure: options.expose });
		const allocatedTarget =
			target.kind === "physical" ? allocatePhysical(registry, target) : ensureSimulator(registry);
		const createdAt = now();
		const created = {
			backend: options.backend,
			client: options.client,
			controller: null,
			createdAt,
			evidenceFile: path.join(evidenceRoot, `${safeKey(key)}.json`),
			exposure: options.expose,
			fallbackReason: physicalFallback,
			key,
			logFile: path.join(logsRoot, `${safeKey(key)}.log`),
			metro: {
				cwd: repoRoot,
				host: null,
				nonce: randomBytes(16).toString("hex"),
				pid: null,
				port,
				processStartedAt: null,
				startedAt: null,
				url: null,
				worktreeHash: hashText(repoRoot).slice(0, 16),
			},
			native: null,
			preset: options.preset,
			requestedTarget,
			sessionId: options.sessionId,
			target: allocatedTarget,
			testRunId: `${safeKey(key)}-${randomBytes(4).toString("hex")}`,
			updatedAt: createdAt,
			worktree: repoRoot,
		};
		registry.lanes[key] = created;
		return created;
	});
	const transitionPlanned = Boolean(
		previousLane &&
		!laneRuntimeIsLive(previousLane) &&
		resolvedTargetWillChange(previousLane.target, target),
	);
	let lane;
	if (transitionPlanned) {
		lane = await withTargetControllerOperation(previousLane.target, async () => {
			const current = readRegistry().lanes[key];
			if (
				!current ||
				current.createdAt !== previousLane.createdAt ||
				!sameResolvedTarget(current.target, previousLane.target)
			) {
				throw new Error(`Lane ${key} changed before its target transition; retry up.`);
			}
			if (current.controller?.controller === "agent-device") {
				closeAgentDeviceStrict(current);
			}
			return registerLane();
		});
	} else {
		lane = await registerLane();
	}

	try {
		if (lane.target.kind === "simulator") {
			lane = await bootLaneSimulator(key, lane);
		}
		const environment = resolveMetroEnvironment(lane.backend);
		let native;
		try {
			({ lane, native } = await provisionNative(key, lane, environment, options));
		} catch (error) {
			if (error.code !== "PHYSICAL_NATIVE_BUILD_REQUIRED" || lane.target.kind !== "physical") {
				throw error;
			}
			const reason =
				`${lane.target.name} needs a compatible local physical-device binary. ` +
				"Physical installation is deferred until joint testing; using a simulator and no EAS build.";
			console.warn(`[ios-lane] ${reason}`);
			if (laneRuntimeIsLive(lane)) await stopLaneMetroAndWait(lane);
			lane = await fallbackPhysicalLaneToSimulator(key, lane, reason);
			options.expose = "local";
			lane = await bootLaneSimulator(key, lane);
			({ lane, native } = await provisionNative(key, lane, environment, options));
		}
		if (!native) throw new Error("Could not provision a compatible simulator binary.");
		lane = await updateLane(key, (current) => {
			current.native = native;
		});
		const metroEndpoint = resolveMetroEndpoint(lane.exposure);
		lane = await ensureMetroStarted(key, lane, environment, metroEndpoint);
		await controllerAcquire(
			{ ...options, controller: "agent-device", forceController: true, quiet: true },
			lane,
		);
		lane = await getLane(options.client, options.sessionId);
		await connectTarget(lane);
		lane = await getLane(options.client, options.sessionId);
		if (options.controller !== "agent-device") {
			await controllerAcquire({ ...options, forceController: true, quiet: true }, lane);
			lane = await getLane(options.client, options.sessionId);
		}
		lane = await updateLane(key, (current) => {
			delete current.lastError;
		});
		const evidence = await collectEvidence(lane, { refreshRender: false });
		writeEvidence(lane, evidence);
		if (evidence.status === "failed") {
			throw new Error(`Lane evidence failed: ${failedCheckNames(evidence).join(", ")}.`);
		}
		if (evidence.status === "pending") {
			console.warn("[ios-lane] Lane started, but physical-device joint validation remains pending.");
		}
		printLane(lane, options);
		return lane;
	} catch (error) {
		const cleanupError = await rollbackFailedStartup(key, lane, options);
		if (cleanupError) {
			throw new Error(`${error.message} Startup cleanup was incomplete: ${cleanupError.message}`);
		}
		throw error;
	}
}

async function provisionNative(key, initialLane, environment, options) {
	let lane = initialLane;
	for (let attempt = 1; attempt <= profile.simulators.maximum; attempt += 1) {
		try {
			return await withTargetControllerOperation(lane.target, async () => {
				const current = readRegistry().lanes[key];
				if (
					!current ||
					current.createdAt !== lane.createdAt ||
					!sameResolvedTarget(current.target, lane.target)
				) {
					throw new Error(`Lane ${key} changed before native provisioning; retry up.`);
				}
				const native = await ensureNativeBinary(current, environment, options);
				return { lane: current, native };
			});
		} catch (error) {
			if (
				error.code === "NATIVE_SIMULATOR_UNRESPONSIVE" &&
				lane.target.kind === "simulator" &&
				attempt === profile.simulators.maximum
			) {
				await cooldownSimulatorWithoutReassignment(key, lane, error.message);
			}
			if (
				error.code !== "NATIVE_SIMULATOR_UNRESPONSIVE" ||
				lane.target.kind !== "simulator" ||
				attempt === profile.simulators.maximum
			) {
				throw error;
			}
			console.warn(
				`[ios-lane] ${lane.target.name} stopped responding during app installation; ` +
					"preserving it on a 15-minute cooldown and allocating another simulator.",
			);
			lane = await cooldownAndReassignSimulator(key, lane, error.message);
			lane = await bootLaneSimulator(key, lane);
		}
	}
	return { lane, native: null };
}

async function fallbackPhysicalLaneToSimulator(key, lane, reason) {
	return withTargetControllerOperation(lane.target, async () => {
		const before = readRegistry().lanes[key];
		if (
			!before ||
			before.createdAt !== lane.createdAt ||
			!sameResolvedTarget(before.target, lane.target)
		) {
			throw new Error(`Lane ${key} changed before its physical-device fallback.`);
		}
		if (laneRuntimeIsLive(before)) {
			throw new Error(`Lane ${key} cannot change its resolved target while its runtime is live.`);
		}
		if (before.controller?.controller === "agent-device") closeAgentDeviceStrict(before);
		return withRegistryLock(async (registry) => {
			const current = registry.lanes[key];
			if (
				!current ||
				current.createdAt !== lane.createdAt ||
				!sameResolvedTarget(current.target, lane.target)
			) {
				throw new Error(`Lane ${key} changed during its physical-device fallback.`);
			}
			if (laneRuntimeIsLive(current)) {
				throw new Error(`Lane ${key} became live during its physical-device fallback.`);
			}
			releaseLaneResources(registry, current);
			current.controller = null;
			current.exposure = "local";
			current.fallbackReason = reason;
			current.native = null;
			current.render = null;
			current.target = ensureSimulator(registry);
			current.metro = stoppedMetroForRestart(current.metro);
			current.updatedAt = now();
			return current;
		});
	});
}

async function rollbackFailedStartup(key, lane, options) {
	const current = readRegistry().lanes[key];
	if (!current || current.createdAt !== lane.createdAt) return null;
	try {
		await withTargetControllerOperation(current.target, async () => {
			const before = readRegistry().lanes[key];
			if (!before || before.createdAt !== current.createdAt) return;
			if (!sameResolvedTarget(before.target, current.target)) {
				throw new Error(`Lane ${key} changed target while startup cleanup was running.`);
			}
			await stopLaneMetroAndWait(before);
			if (laneRuntimeIsLive(before)) {
				throw new Error("an owned Metro or Tailscale process is still live");
			}
			if (before.controller?.controller === "agent-device") closeAgentDeviceStrict(before);
			await withRegistryLock(async (registry) => {
				const registered = registry.lanes[key];
				if (!registered || registered.createdAt !== current.createdAt) return;
				if (!sameResolvedTarget(registered.target, current.target)) {
					throw new Error(`Lane ${key} changed target during startup cleanup.`);
				}
				if (laneRuntimeIsLive(registered)) {
					throw new Error(`Lane ${key} became live while startup cleanup was running.`);
				}
				releaseLaneResources(registry, registered);
				delete registry.lanes[key];
			});
		});
		return null;
	} catch (cleanupError) {
		await updateLaneIfPresent(key, (registered) => {
			registered.lastError = `${options.client}:${options.sessionId}: ${cleanupError.message}`;
		});
		return cleanupError;
	}
}

function allocateResolvedTarget(registry, desiredTarget, existing) {
	if (desiredTarget.kind === "simulator") {
		return existing?.target.kind === "simulator"
			? existing.target
			: ensureSimulator(registry);
	}
	const conflict = Object.values(registry.lanes).find(
		(lane) =>
			lane.key !== existing?.key &&
			lane.target.kind === "physical" &&
			lane.target.alias === desiredTarget.alias,
	);
	if (conflict) throw new Error(`${desiredTarget.alias} is already assigned to ${conflict.key}.`);
	return desiredTarget;
}

function resolvedTargetWillChange(currentTarget, desiredTarget) {
	if (desiredTarget.kind === "simulator") return currentTarget.kind !== "simulator";
	return !sameResolvedTarget(currentTarget, desiredTarget);
}

export function sameResolvedTarget(left, right) {
	if (!left || !right) return false;
	if (left?.kind !== right?.kind) return false;
	return left.kind === "simulator"
		? left.udid === right.udid
		: left.alias === right.alias && left.deviceId === right.deviceId;
}

function stoppedMetroForRestart(metro) {
	return clearOwnedProcessRecord({
		...metro,
		host: null,
		nonce: randomBytes(16).toString("hex"),
		startedAt: null,
		tailscale: null,
		url: null,
	});
}

export async function down(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	ensureDirectoryLayout();
	return withFileLock(
		path.join(laneHome, `lifecycle-${safeKey(key)}.lock`),
		lifecycleLockTimeoutMs,
		() => downLocked(options, key),
	);
}

async function downLocked(options, key) {
	const lane = await getLane(options.client, options.sessionId);

	if (!lane) {
		if (!options.quiet) console.log(`No iOS lane is registered for ${key}.`);
		return null;
	}

	await withTargetControllerOperation(lane.target, async () => {
		const before = readRegistry().lanes[key];
		if (!before) return;
		if (
			before.createdAt !== lane.createdAt ||
			!sameResolvedTarget(before.target, lane.target)
		) {
			throw new Error(`Lane ${key} changed while it was being released; retry down.`);
		}
		await stopLaneMetroAndWait(before);
		if (laneRuntimeIsLive(before)) {
			throw new Error(`Lane ${key} runtime is still live; its leases were preserved.`);
		}
		if (before.controller?.controller === "agent-device") closeAgentDeviceStrict(before);
		await withRegistryLock(async (registry) => {
			const current = registry.lanes[key];
			if (!current) return;
			if (
				current.createdAt !== lane.createdAt ||
				!sameResolvedTarget(current.target, lane.target)
			) {
				throw new Error(`Lane ${key} changed during release; retry down.`);
			}
			releaseLaneResources(registry, current);
			delete registry.lanes[key];
		});
	});
	if (!options.quiet) console.log(`Released ${describeLane(lane)}.`);
	return lane;
}

export async function list(options = {}) {
	const registry = readRegistry();
	pruneDeadMetroMetadata(registry);
	const lanes = Object.values(registry.lanes);
	if (options.json) {
		console.log(
			JSON.stringify(
				{
					backend: redactBackendRegistry(registry.backend),
					lanes,
					simulatorCooldown: registry.resources.simulatorCooldown,
					simulatorQuarantine: registry.resources.simulatorQuarantine,
					version: registry.version,
				},
				null,
				2,
			),
		);
		return lanes;
	}
	if (lanes.length === 0) {
		console.log(`No ${profile.displayName} iOS lanes are registered.`);
	}
	for (const lane of lanes) console.log(describeLane(lane));
	printBackend(registry.backend);
	const quarantined = Object.keys(registry.resources.simulatorQuarantine).length;
	const coolingDown = Object.keys(registry.resources.simulatorCooldown).length;
	if (coolingDown > 0) {
		console.log(`${coolingDown} simulator(s) are on a temporary non-destructive cooldown.`);
	}
	if (quarantined > 0) {
		console.log(
			`${quarantined} simulator(s) quarantined after terminal boot failure; none were deleted or erased.`,
		);
	}
	return lanes;
}

export async function status(options) {
	assertSession(options);
	const lane = await getLane(options.client, options.sessionId);
	if (!lane) {
		console.log(`No iOS lane is registered for ${sessionKey(options.client, options.sessionId)}.`);
		return null;
	}
	if (options.json) console.log(JSON.stringify(lane, null, 2));
	else console.log(describeLane(lane));
	return lane;
}

export async function doctor(options, { quiet = false } = {}) {
	assertSession(options);
	const lane = await getLane(options.client, options.sessionId);
	if (!lane) throw new Error(`No lane exists for ${sessionKey(options.client, options.sessionId)}.`);
	const evidence = await collectEvidence(lane);
	writeEvidence(lane, evidence);
	if (!quiet) {
		if (options.json) console.log(JSON.stringify(evidence, null, 2));
		else {
			console.log(`${evidence.status.toUpperCase()}: ${describeLane(lane)}`);
			for (const check of evidence.checks) {
				console.log(`  ${check.status.toUpperCase()} ${check.name}: ${check.detail}`);
			}
			console.log(`Evidence: ${lane.evidenceFile}`);
		}
	}
	return evidence;
}

export async function reap(options = {}) {
	if (!Number.isFinite(options.staleAfterMinutes) || options.staleAfterMinutes < 0) {
		throw new Error("--stale-after-minutes must be a non-negative number.");
	}
	const cutoff = Date.now() - options.staleAfterMinutes * 60_000;
	const candidates = Object.values(readRegistry().lanes).filter(
		(lane) => laneEligibleForReap(lane, { cutoff, excludeKey: options.excludeKey }),
	);
	const removed = [];
	for (const candidate of candidates) {
		try {
			await withFileLock(
				path.join(laneHome, `lifecycle-${safeKey(candidate.key)}.lock`),
				1_000,
				async () => {
				const current = readRegistry().lanes[candidate.key];
				if (
					!current ||
					current.createdAt !== candidate.createdAt ||
					!laneEligibleForReap(current, { cutoff, excludeKey: options.excludeKey })
				) return;
				await withTargetControllerOperation(current.target, async () => {
					const before = readRegistry().lanes[candidate.key];
					if (
						!before ||
						before.createdAt !== candidate.createdAt ||
						!sameResolvedTarget(before.target, current.target) ||
						!laneEligibleForReap(before, { cutoff, excludeKey: options.excludeKey })
					) return;
					if (before.controller?.controller === "agent-device") closeAgentDeviceStrict(before);
					await withRegistryLock(async (registry) => {
						const lane = registry.lanes[candidate.key];
						if (
							!lane ||
							lane.createdAt !== candidate.createdAt ||
							!sameResolvedTarget(lane.target, current.target) ||
							!laneEligibleForReap(lane, { cutoff, excludeKey: options.excludeKey })
						) return;
						releaseLaneResources(registry, lane);
						delete registry.lanes[candidate.key];
						removed.push(lane);
					});
				});
				},
			);
		} catch (error) {
			if (!/Timed out acquiring/.test(error.message)) throw error;
		}
	}
	if (!options.quiet) {
		console.log(`Reaped ${removed.length} stale dead iOS lane metadata entr${removed.length === 1 ? "y" : "ies"}.`);
	}
	return removed;
}

export function laneEligibleForReap(
	lane,
	{ cutoff, excludeKey = "" },
	isLive = laneRuntimeIsLive,
) {
	return Boolean(
		lane &&
		lane.key !== excludeKey &&
		Date.parse(lane.updatedAt) <= cutoff &&
		!isLive(lane),
	);
}

export async function heartbeat(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	return updateLaneIfPresent(key, (lane) => {
		lane.lastHeartbeatAt = now();
	});
}

export async function simulatorRecheck(options = {}) {
	const udid = requireIdentifier(options.udid, "simulator UDID");
	const removed = await withRegistryLock(async (registry) => {
		const entry =
			registry.resources.simulatorQuarantine[udid] ??
			registry.resources.simulatorCooldown[udid] ??
			null;
		delete registry.resources.simulatorQuarantine[udid];
		delete registry.resources.simulatorCooldown[udid];
		return entry;
	});
	if (!options.quiet) {
		console.log(
			removed
				? `Simulator ${udid} is eligible for a fresh health check; it was not erased or recreated.`
				: `Simulator ${udid} had no quarantine or cooldown marker.`,
		);
	}
	return removed;
}

function describeLane(lane) {
	const target =
		lane.target.kind === "simulator"
			? `${lane.target.name} (${lane.target.udid})`
			: `${lane.target.alias} (${lane.target.deviceId})`;
	return `${lane.key} [${lane.preset ?? "custom"}; ${lane.backend}/${lane.exposure}] -> Metro ${lane.metro.url ?? `:${lane.metro.port}`} (pid ${
		lane.metro.pid ?? "stopped"
	}), ${target}, ${lane.native?.decision ?? "native unchecked"}, ${lane.worktree}`;
}

function printLane(lane, options) {
	if (options.quiet) return;
	if (options.json) console.log(JSON.stringify(lane, null, 2));
	else {
		console.log(`Ready: ${describeLane(lane)}`);
		console.log(`Metro log: ${lane.logFile}`);
		console.log(`Evidence: ${lane.evidenceFile}`);
		console.log(`Controller: ${lane.controller.controller}`);
		console.log(`Test run id: ${lane.testRunId}`);
		if (lane.target.kind === "simulator") console.log(`SimView device id: ${lane.target.udid}`);
	}
}

function printHelp() {
	console.log(`Usage:
  ios-session-lane up --client <claude|codex> --session-id <id> --preset <simulator-local|simulator-preview|simulator-preview-tailscale|iphone-preview>
  ios-session-lane up --client <claude|codex> --session-id <id> --target <target> --backend <local|preview> --expose <local|tailscale>
  ios-session-lane status|doctor --client <client> --session-id <id> [--json]
  ios-session-lane list [--json]
  ios-session-lane down --client <client> --session-id <id>
  ios-session-lane reap [--stale-after-minutes 120] [--dead-only]
  ios-session-lane simulator-recheck --udid <simulator-udid>
  ios-session-lane controller-acquire --client <client> --session-id <id> --controller <agent-device|argent|maestro|xcodebuildmcp> [--force-controller]
  ios-session-lane controller-release --client <client> --session-id <id>
  ios-session-lane control --client <client> --session-id <id> -- <agent-device args>
  ios-session-lane maestro --client <client> --session-id <id> -- <maestro args>
  ios-session-lane backend-up|backend-down --client <client> --session-id <id>
  ios-session-lane backend-adopt --client <client> --session-id <id>
  ios-session-lane backend-writer-acquire|backend-writer-release --client <client> --session-id <id>
  ios-session-lane backend-reset --client <client> --session-id <id> --acknowledge-shared-reset

Simulator lanes automatically reuse a fingerprint-compatible local .app or create one
with Xcode. Physical lanes use hosted Preview Supabase and Tailscale. They never
request an EAS development build; physical-device execution requires joint testing.`);
}

async function main() {
	const { command, options } = parseOptions(process.argv.slice(2));
	if (command !== "help" && command !== "--help") {
		assertSupportedProject(repoRoot);
	}
	if (command === "up") await up(options);
	else if (command === "down") await down(options);
	else if (command === "list") await list(options);
	else if (command === "status") await status(options);
	else if (command === "doctor") {
		const evidence = await doctor(options);
		if (!evidence.passed) process.exitCode = 1;
	} else if (command === "reap") await reap(options);
	else if (command === "simulator-recheck") await simulatorRecheck(options);
	else if (command === "controller-acquire") await controllerAcquire(options);
	else if (command === "controller-release") await controllerRelease(options);
	else if (command === "control") await runController(options, "agent-device");
	else if (command === "maestro") await runController(options, "maestro");
	else if (command === "backend-up") await backendUp(options);
	else if (command === "backend-down") await backendDown(options);
	else if (command === "backend-adopt") await backendAdopt(options);
	else if (command === "backend-writer-acquire") await backendWriterAcquire(options);
	else if (command === "backend-writer-release") await backendWriterRelease(options);
	else if (command === "backend-reset") await backendReset(options);
	else if (command === "help" || command === "--help") printHelp();
	else throw new Error(`Unknown command ${command}. Run ios-session-lane help.`);
}

if (isMainModule(import.meta.url)) {
	main().catch((error) => {
		console.error(`[ios-lane] ${error.message}`);
		process.exitCode = 1;
	});
}
