import path from "node:path";
import { localBootstrapStatus } from "./bootstrap-worktree.mjs";
import {
	assertBackendCompatible,
	assertPersistedBackendContract,
	backendContract,
} from "./lane-backend-contract.mjs";
import {
	assertBackendDockerNetworkConfiguration,
	assertExpectedBackendNetwork,
	assertLoopbackBindings,
	assertManagedBackendOwnership,
	backendContainerAttestationsMatch,
	backendDockerNetwork,
	detectRunningBackend,
	ensureBackendDockerNetwork,
	parseBackendContainerInspection,
	verifyBackendLoopbackBindings,
	worktreeFromFunctionsMounts,
} from "./lane-backend-docker.mjs";
import {
	allowedDopplerConfigs,
	assertAllowedDopplerConfig,
	backendMediaPublishEnvironment,
	backendResetCommands,
	classifyBackendStatusResult,
	materializeBackendEnv,
	parseLocalDopplerReferences,
	readLocalSupabaseStatus,
	replaceFileFromPrivateStage,
	runBackendWithDoppler,
	runSensitiveCommand,
} from "./lane-backend-runtime.mjs";
import { requireIdentifier, sessionKey } from "./lane-identifiers.mjs";
import { withFileLock } from "./lane-lock.mjs";
import {
	backendOperationLockPath,
	ensureDirectoryLayout,
	now,
	profile,
	repoRoot,
} from "./lane-runtime-context.mjs";
import { readRegistry, withRegistryLock } from "./lane-state.mjs";

export {
	allowedDopplerConfigs,
	assertAllowedDopplerConfig,
	assertBackendCompatible,
	assertBackendDockerNetworkConfiguration,
	assertLoopbackBindings,
	assertPersistedBackendContract,
	backendContainerAttestationsMatch,
	backendContract,
	backendDockerNetwork,
	backendMediaPublishEnvironment,
	backendResetCommands,
	classifyBackendStatusResult,
	detectRunningBackend,
	materializeBackendEnv,
	parseBackendContainerInspection,
	parseLocalDopplerReferences,
	readLocalSupabaseStatus,
	replaceFileFromPrivateStage,
	verifyBackendLoopbackBindings,
	worktreeFromFunctionsMounts,
};

const operationTimeoutMs = 30 * 60 * 1000;

function assertSession(options) {
	requireIdentifier(options.client, "client");
	requireIdentifier(options.sessionId, "session id");
}

function assertBootstrap() {
	const status = localBootstrapStatus({ projectRoot: repoRoot });
	if (!status.ok) {
		throw new Error(
			`This worktree was not bootstrapped at creation time: ${status.reasons.join("; ")}. Run ios-session-bootstrap separately.`,
		);
	}
}

function assertManagedBackendOwner(backend, key, operation) {
	if (!backend?.managed) {
		throw new Error(`Refusing to ${operation} an externally managed shared Supabase stack.`);
	}
	if (backend.ownerKey !== key) {
		throw new Error(`Only ${backend.ownerKey} may ${operation} the shared Supabase stack.`);
	}
	if (!backend.mountWorktree || path.resolve(backend.mountWorktree) !== repoRoot) {
		throw new Error(
			`Run the backend ${operation} operation from its owner worktree: ${backend.mountWorktree ?? "unknown"}.`,
		);
	}
}

function assertNoOtherLocalConsumers(registry, key, operation) {
	const consumers = Object.values(registry.lanes).filter(
		(lane) => lane.backend === "local" && lane.key !== key,
	);
	if (consumers.length > 0) {
		throw new Error(
			`Shared ${operation} blocked while ${consumers.map((lane) => lane.key).join(", ")} consume local Supabase.`,
		);
	}
}

function assertBackendResetLease(registry, key) {
	assertManagedBackendOwner(registry.backend, key, "reset");
	if (registry.backend.state !== "running") {
		throw new Error(`Shared Supabase is ${registry.backend.state}; recover it before reset.`);
	}
	if (registry.resources.backendWriter?.ownerKey !== key) {
		throw new Error("Acquire the backend writer lease before reset.");
	}
	assertNoOtherLocalConsumers(registry, key, "reset");
}

export async function backendUp(options) {
	if (process.platform !== "darwin") throw new Error(`${profile.displayName} local Supabase lanes require macOS.`);
	assertSession(options);
	assertBootstrap();
	ensureDirectoryLayout();
	const key = sessionKey(options.client, options.sessionId);
	const selectedConfig = assertAllowedDopplerConfig(options.dopplerConfig);
	return withFileLock(backendOperationLockPath, operationTimeoutMs, async () => {
		const registered = readRegistry().backend;
		const statusConfig = registered?.dopplerConfig
			? assertAllowedDopplerConfig(registered.dopplerConfig, selectedConfig)
			: selectedConfig;
		const currentStatus = readLocalSupabaseStatus({
			allowFailure: true,
			dopplerConfig: statusConfig,
		});
		if (currentStatus) {
			const detected = detectRunningBackend(registered);
			assertBackendCompatible(detected, registered);
			if (registered?.managed && detected.managed) {
				assertManagedBackendOwnership(registered, detected);
			}
			verifyBackendLoopbackBindings();
			materializeBackendEnv(currentStatus);
			await withRegistryLock(async (registry) => {
				if (!registry.backend) {
					registry.backend = {
						...detected,
						dopplerConfig: selectedConfig,
						state: "running",
					};
					return;
				}
				const backend = registry.backend;
				if (backend.managed && !detected.managed) {
					registry.backend = {
						...detected,
						dopplerConfig: statusConfig,
						managed: false,
						state: "running",
					};
					registry.resources.backendWriter = null;
					return;
				}
				if (backend.managed) {
					assertAllowedDopplerConfig(backend.dopplerConfig, selectedConfig);
					if (backend.state !== "running") {
						if (backend.ownerKey !== key || !options.acknowledgeStaleOwner) {
							throw new Error(
								`Shared Supabase is ${backend.state}; its owner must acknowledge recovery before it can be marked running.`,
							);
						}
						markBackendRunning(backend, detected);
					}
				} else {
					registry.backend = {
						...detected,
						dopplerConfig: statusConfig,
						managed: false,
						state: "running",
					};
				}
			});
			console.log(
				detected.managed
					? `Shared Supabase is already owned by ${detected.ownerKey}.`
					: `Shared Supabase is externally managed from ${detected.mountWorktree ?? "an unknown worktree"}; it was not remounted.`,
			);
			return detected;
		}

		const compatibility = backendContract(repoRoot);
		const owner = await withRegistryLock(async (registry) => {
			const existing = registry.backend;
			if (existing) {
				if (!existing.managed) {
					throw new Error("Shared Supabase has an external reservation that must be reconciled manually.");
				}
				if (path.resolve(existing.mountWorktree) !== repoRoot) {
					throw new Error(`Recover the shared backend from its mounted worktree: ${existing.mountWorktree}.`);
				}
				if (existing.ownerKey !== key && registry.lanes[existing.ownerKey]) {
					throw new Error(`Shared Supabase owner ${existing.ownerKey} still has a registered lane.`);
				}
				if (existing.ownerKey !== key && !options.acknowledgeStaleOwner) {
					throw new Error(
						`Shared Supabase is reserved by ${existing.ownerKey}. Adopt it with --acknowledge-stale-owner before restarting.`,
					);
				}
				assertAllowedDopplerConfig(existing.dopplerConfig, selectedConfig);
			}
			const value = {
				compatibility,
				createdAt: existing?.createdAt ?? now(),
				dopplerConfig: selectedConfig,
				managed: true,
				mountWorktree: repoRoot,
				ownerKey: key,
				state: "starting",
			};
			registry.backend = value;
			return value;
		});
		try {
			ensureBackendDockerNetwork();
			runBackendWithDoppler(selectedConfig, [
				"corepack",
				"pnpm",
				"--dir",
				profile.backend.root,
				"exec",
				"supabase",
				"start",
				"--network-id",
				backendDockerNetwork,
			]);
			const statusData = readLocalSupabaseStatus({ dopplerConfig: selectedConfig });
			const detected = detectRunningBackend(owner);
			assertBackendCompatible(detected, owner);
			assertExpectedBackendNetwork(detected);
			verifyBackendLoopbackBindings();
			materializeBackendEnv(statusData);
			await withRegistryLock(async (registry) => {
				if (registry.backend?.ownerKey === key) {
					markBackendRunning(registry.backend, detected);
				}
			});
			console.log(`Shared Supabase started by ${owner.ownerKey} from ${owner.mountWorktree}.`);
			return {
				...owner,
				compatibility: detected.compatibility,
				containerAttestation: detected.containerAttestation,
				state: "running",
			};
		} catch (error) {
			const observation = observeBackendAfterFailure(selectedConfig);
			await recordBackendRecovery(key, "start", error, observation);
			throw error;
		}
	});
}

export async function backendDown(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	await withFileLock(backendOperationLockPath, operationTimeoutMs, async () => {
		const snapshot = readRegistry().backend;
		assertManagedBackendOwner(snapshot, key, "stop");
		const dopplerConfig = assertAllowedDopplerConfig(snapshot.dopplerConfig);
		const statusData = readLocalSupabaseStatus({
			allowFailure: true,
			dopplerConfig,
		});
		if (!statusData) {
			await withRegistryLock(async (registry) => {
				assertManagedBackendOwner(registry.backend, key, "stop");
				assertNoOtherLocalConsumers(registry, key, "stop");
				registry.backend = null;
				registry.resources.backendWriter = null;
			});
			return;
		}
		const detected = detectRunningBackend(snapshot);
		assertBackendCompatible(detected, snapshot, { allowPersistedDrift: true });
		assertManagedBackendOwnership(snapshot, detected);
		verifyBackendLoopbackBindings();
		await withRegistryLock(async (registry) => {
			const backend = registry.backend;
			assertManagedBackendOwner(backend, key, "stop");
			assertNoOtherLocalConsumers(registry, key, "stop");
			if (!backendContainerAttestationsMatch(
				backend.containerAttestation,
				snapshot.containerAttestation,
			)) {
				throw new Error("The shared backend lease changed while stop was being prepared.");
			}
			backend.state = "stopping";
		});
		try {
			runBackendWithDoppler(dopplerConfig, [
				"corepack",
				"pnpm",
				"--dir",
				profile.backend.root,
				"exec",
				"supabase",
				"stop",
				"--network-id",
				backendDockerNetwork,
			]);
			if (readLocalSupabaseStatus({ allowFailure: true, dopplerConfig })) {
				throw new Error("Supabase stop returned, but the shared stack is still running.");
			}
			await withRegistryLock(async (registry) => {
				if (registry.backend?.ownerKey === key) registry.backend = null;
				registry.resources.backendWriter = null;
			});
		} catch (error) {
			const observation = observeBackendAfterFailure(dopplerConfig);
			if (observation.observedRunning === false) {
				await withRegistryLock(async (registry) => {
					if (registry.backend?.ownerKey === key) registry.backend = null;
					registry.resources.backendWriter = null;
				});
				return;
			}
			await recordBackendRecovery(key, "stop", error, observation);
			throw error;
		}
	});
	console.log("Shared Supabase stopped and its owner lease was released.");
}

export async function backendAdopt(options) {
	assertSession(options);
	if (!options.acknowledgeStaleOwner) {
		throw new Error("Backend adoption requires --acknowledge-stale-owner.");
	}
	const key = sessionKey(options.client, options.sessionId);
	const adopted = await withFileLock(backendOperationLockPath, operationTimeoutMs, async () => {
		const registered = readRegistry().backend;
		if (!registered?.managed) throw new Error("No managed shared Supabase owner can be adopted.");
		const dopplerConfig = assertAllowedDopplerConfig(registered.dopplerConfig);
		const statusData = readLocalSupabaseStatus({
			allowFailure: true,
			dopplerConfig,
		});
		let detected = null;
		if (statusData) {
			detected = detectRunningBackend(registered);
			assertBackendCompatible(detected, registered, {
				allowPersistedDrift: !registered.compatibility?.hash,
			});
			if (!detected.managed) throw new Error("The running Supabase stack does not match the stale managed mount lease.");
			assertExpectedBackendNetwork(detected);
			verifyBackendLoopbackBindings();
		}
		return withRegistryLock(async (registry) => {
			const backend = registry.backend;
			if (!backend?.managed) throw new Error("No managed shared Supabase owner can be adopted.");
			if (
				backend.ownerKey !== registered.ownerKey ||
				backend.createdAt !== registered.createdAt
			) {
				throw new Error("The shared Supabase lease changed while adoption was being prepared.");
			}
			if (registry.lanes[backend.ownerKey]) throw new Error(`Shared Supabase owner ${backend.ownerKey} still has a registered lane.`);
			if (path.resolve(backend.mountWorktree) !== repoRoot) {
				throw new Error(`Adoption must run from the mounted worktree: ${backend.mountWorktree}.`);
			}
			assertAllowedDopplerConfig(backend.dopplerConfig);
			const currentContract = backendContract(repoRoot);
			if (
				backend.compatibility?.hash &&
				backend.compatibility.hash !== currentContract.hash
			) {
				throw new Error("The mounted worktree backend contract changed; review it before adopting the stale owner.");
			}
			backend.ownerKey = key;
			backend.adoptedAt = now();
			if (statusData) markBackendRunning(backend, detected);
			else {
				clearBackendRecovery(backend);
				delete backend.containerAttestation;
				backend.state = "stopped";
			}
			if (registry.resources.backendWriter && !registry.lanes[registry.resources.backendWriter.ownerKey]) {
				registry.resources.backendWriter = null;
			}
			return backend;
		});
	});
	console.log(`Shared Supabase ownership adopted by ${key}.`);
	return adopted;
}

export async function backendWriterAcquire(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	const lease = await withRegistryLock(async (registry) => {
		const lane = registry.lanes[key];
		if (!lane || lane.backend !== "local") throw new Error("A local-backend iOS lane is required for the backend writer lease.");
		if (registry.backend?.state !== "running") {
			throw new Error(`Shared Supabase is ${registry.backend?.state ?? "unregistered"}; writer acquisition is blocked.`);
		}
		const existing = registry.resources.backendWriter;
		if (existing && existing.ownerKey !== key) throw new Error(`Shared backend data writes are owned by ${existing.ownerKey}.`);
		const value = { acquiredAt: now(), ownerKey: key, testRunId: lane.testRunId };
		registry.resources.backendWriter = value;
		return value;
	});
	console.log(`Backend writer lease: ${lease.ownerKey} (${lease.testRunId}).`);
	return lease;
}

export async function backendWriterRelease(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	const released = await withRegistryLock(async (registry) => {
		if (registry.resources.backendWriter?.ownerKey !== key) return false;
		registry.resources.backendWriter = null;
		return true;
	});
	console.log(released ? "Backend writer lease released." : "No backend writer lease held.");
	return released;
}

export function refreshResetBackendAttestation(backend, detected, expectedLease) {
	if (!backend?.managed || backend.state !== "resetting") {
		throw new Error(
			"The shared backend is no longer the managed reset lease.",
		);
	}
	if (
		!expectedLease?.managed ||
		backend.ownerKey !== expectedLease.ownerKey ||
		backend.createdAt !== expectedLease.createdAt
	) {
		throw new Error("The shared backend owner lease changed during reset.");
	}
	const registeredMount = resolvedBackendMount(backend.mountWorktree);
	const expectedMount = resolvedBackendMount(expectedLease.mountWorktree);
	const detectedMount = resolvedBackendMount(detected?.mountWorktree);
	if (!registeredMount || registeredMount !== expectedMount) {
		throw new Error("The shared backend owner worktree changed during reset.");
	}
	if (
		!detected?.managed ||
		detected.ownerKey !== expectedLease.ownerKey ||
		detectedMount !== registeredMount
	) {
		throw new Error(
			"The reset Supabase stack does not match the registered owner lane and worktree mount.",
		);
	}
	backend.compatibility = detected.compatibility;
	backend.containerAttestation = detected.containerAttestation;
	return backend;
}

function resolvedBackendMount(value) {
	return typeof value === "string" && value
		? path.resolve(value)
		: null;
}

export async function backendReset(options) {
	assertSession(options);
	if (!options.acknowledgeSharedReset) throw new Error("Shared reset requires --acknowledge-shared-reset.");
	const key = sessionKey(options.client, options.sessionId);
	await withFileLock(backendOperationLockPath, operationTimeoutMs, async () => {
		const snapshot = readRegistry();
		assertBackendResetLease(snapshot, key);
		const dopplerConfig = assertAllowedDopplerConfig(
			snapshot.backend.dopplerConfig,
			options.dopplerConfig,
		);
		const statusData = readLocalSupabaseStatus({
			allowFailure: true,
			dopplerConfig,
		});
		if (!statusData) throw new Error("Shared Supabase is not running; reset was not started.");
		const detectedBeforeReset = detectRunningBackend(snapshot.backend);
		assertBackendCompatible(detectedBeforeReset, snapshot.backend, {
			allowPersistedDrift: true,
		});
		assertManagedBackendOwnership(snapshot.backend, detectedBeforeReset);
		verifyBackendLoopbackBindings();
		await withRegistryLock(async (registry) => {
			assertBackendResetLease(registry, key);
			if (!backendContainerAttestationsMatch(
				registry.backend.containerAttestation,
				snapshot.backend.containerAttestation,
			)) {
				throw new Error("The shared backend lease changed while reset was being prepared.");
			}
			registry.backend.state = "resetting";
		});
		try {
			const [resetCommand, mediaPublishCommand] = backendResetCommands();
			runBackendWithDoppler(dopplerConfig, resetCommand);
			const refreshedStatus = readLocalSupabaseStatus({ dopplerConfig });
			const registeredAfterReset = readRegistry().backend;
			const detected = detectRunningBackend(registeredAfterReset);
			assertBackendCompatible(detected, null);
			assertExpectedBackendNetwork(detected);
			verifyBackendLoopbackBindings();
			await withRegistryLock(async (registry) => {
				refreshResetBackendAttestation(
					registry.backend,
					detected,
					snapshot.backend,
				);
			});
			runSensitiveCommand(
				mediaPublishCommand[0],
				mediaPublishCommand.slice(1),
				backendMediaPublishEnvironment(refreshedStatus),
			);
			materializeBackendEnv(refreshedStatus);
			await withRegistryLock(async (registry) => {
				const backend = registry.backend;
				if (
					backend?.ownerKey !== key ||
					backend.state !== "resetting" ||
					!backendContainerAttestationsMatch(
						backend.containerAttestation,
						detected.containerAttestation,
					)
				) {
					throw new Error(
						"The shared backend lease changed while reset media was being published.",
					);
				}
				markBackendRunning(backend, detected);
			});
		} catch (error) {
			const observation = observeBackendAfterFailure(dopplerConfig);
			await recordBackendRecovery(key, "reset", error, observation);
			throw error;
		}
	});
	console.log("Shared Supabase reset completed, including catalog media publishing.");
}

export function resolveMetroEnvironment(backend) {
	const environment = { ...process.env, APP_VARIANT: "development" };
	if (backend === "preview") {
		environment.EXPO_PUBLIC_USE_LOCAL_SUPABASE = "false";
		return environment;
	}
	const registered = readRegistry().backend;
	if (registered?.state !== "running") {
		throw new Error(`Shared local Supabase is ${registered?.state ?? "unregistered"}; recover its owner state before attaching a lane.`);
	}
	const dopplerConfig = assertAllowedDopplerConfig(
		registered.dopplerConfig ?? profile.backend.dopplerConfig,
	);
	const statusData = readLocalSupabaseStatus({ dopplerConfig });
	const detected = detectRunningBackend(registered);
	assertBackendCompatible(detected, registered);
	if (registered.managed) assertManagedBackendOwnership(registered, detected);
	verifyBackendLoopbackBindings();
	const publishableKey = statusData.PUBLISHABLE_KEY ?? statusData.ANON_KEY;
	if (!statusData.API_URL || !publishableKey) {
		throw new Error("Local Supabase status did not include its API URL and publishable key.");
	}
	materializeBackendEnv(statusData);
	return {
		...environment,
		EXPO_PUBLIC_LOCAL_SUPABASE_KEY: publishableKey,
		EXPO_PUBLIC_LOCAL_SUPABASE_URL: statusData.API_URL,
		EXPO_PUBLIC_USE_LOCAL_SUPABASE: "true",
	};
}

function markBackendRunning(backend, detected) {
	backend.compatibility = detected.compatibility;
	backend.containerAttestation = detected.containerAttestation;
	backend.state = "running";
	clearBackendRecovery(backend);
}

function clearBackendRecovery(backend) {
	delete backend.lastError;
	delete backend.recovery;
	delete backend.recoveryRequired;
}

function observeBackendAfterFailure(dopplerConfig) {
	try {
		return {
			observedRunning: Boolean(
				readLocalSupabaseStatus({ allowFailure: true, dopplerConfig }),
			),
			probeError: null,
		};
	} catch (error) {
		return { observedRunning: null, probeError: error.message };
	}
}

async function recordBackendRecovery(ownerKey, operation, error, observation) {
	await withRegistryLock(async (registry) => {
		const backend = registry.backend;
		if (!backend || backend.ownerKey !== ownerKey) return;
		backend.lastError = String(error?.message ?? error).slice(0, 500);
		backend.recovery = {
			failedAt: now(),
			observedRunning: observation.observedRunning,
			operation,
			...(observation.probeError
				? { probeError: String(observation.probeError).slice(0, 500) }
				: {}),
		};
		backend.recoveryRequired = true;
		backend.state = "recovery-required";
	});
}

export function redactBackendRegistry(backend) {
	if (!backend) return null;
	return {
		compatibility: backend.compatibility,
		createdAt: backend.createdAt,
		managed: backend.managed,
		mountWorktree: backend.mountWorktree,
		ownerKey: backend.ownerKey,
		state: backend.state ?? "running",
	};
}

export function printBackend(backend) {
	if (!backend) {
		console.log("Shared Supabase owner: stopped or not yet detected.");
		return;
	}
	console.log(
		backend.managed
			? `Shared Supabase owner: ${backend.ownerKey} (${backend.mountWorktree}; ${backend.state ?? "running"}).`
			: `Shared Supabase owner: external (${backend.mountWorktree ?? "mount unknown"}).`,
	);
}
