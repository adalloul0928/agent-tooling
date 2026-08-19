#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
	closeSync,
	cpSync,
	existsSync,
	mkdirSync,
	openSync,
	readFileSync,
	readdirSync,
	renameSync,
	rmSync,
	statSync,
	unlinkSync,
	writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import {
	envReferences,
	localBootstrapStatus,
} from "./bootstrap-worktree.mjs";
import {
	assertSupportedProject,
	isMainModule,
	projectContext,
} from "./project-context.mjs";

const context = projectContext();
const { backendRoot, mobileRoot, profile, root: repoRoot } = context;
const gitCommonDirectory = readGitCommonDirectory();
const repositoryHash = hashText(gitCommonDirectory).slice(0, 12);
const laneHome =
	process.env.IOS_SESSION_LANES_HOME ??
	path.join(
		homedir(),
		"Library",
		"Application Support",
		"agent-tooling",
		"ios-session-lanes",
		repositoryHash,
	);
const registryPath = path.join(laneHome, "registry.json");
const registryLockPath = path.join(laneHome, "registry.lock");
const simulatorControlLockPath = path.join(laneHome, "simulator-control.lock");
const logsRoot = path.join(laneHome, "logs");
const evidenceRoot = path.join(laneHome, "evidence");
const binaryRoot = path.join(laneHome, "binaries");
const deviceStateRoot = path.join(laneHome, "devices");
const controllerStateRoot = path.join(laneHome, "controllers");
const firstMetroPort = profile.metro.firstPort;
const lastMetroPort = profile.metro.lastPort;
const maxSimulatorLanes = profile.simulators.maximum;
const simulatorNamePrefix = profile.simulators.namePrefix;
const simulatorDeviceType = profile.simulators.deviceType;
const maxIosRuntimeMajor = Number(
	process.env.IOS_SESSION_LANES_MAX_RUNTIME_MAJOR ??
		profile.simulators.maximumRuntimeMajor,
);
const appId = profile.mobile.appId;
const appScheme = profile.mobile.scheme;
const cachedAppName = profile.mobile.cachedAppName;
const laneSelection = profile.laneSelection;
const registryVersion = 4;
const buildLockTimeoutMs = 30 * 60 * 1000;
const simulatorControlTimeoutMs = 10 * 60 * 1000;
const simulatorBootTimeoutMs = profile.simulators.bootTimeoutSeconds * 1000;
const metroReadyTimeoutMs = profile.metro.readyTimeoutSeconds * 1000;
const simulatorRenderTimeoutMs = profile.mobile.renderTimeoutSeconds * 1000;
const managedControllers = new Set([
	"agent-device",
	"argent",
	"maestro",
	"xcodebuildmcp",
]);
const physicalDeviceAliases = profile.physicalDevices;

export function sessionKey(client, sessionId) {
	return `${requireIdentifier(client, "client")}:${requireIdentifier(
		sessionId,
		"session id",
	)}`;
}

export function parseTarget(value) {
	if (value === "simulator") return { alias: "automatic", kind: "simulator" };
	const match = String(value ?? "").match(/^physical:([A-Za-z0-9._-]+)$/);
	if (!match || !physicalDeviceAliases[match[1]]) {
		throw new Error(
			`--target must be "simulator" or one of: ${Object.keys(
				physicalDeviceAliases,
			)
				.map((alias) => `physical:${alias}`)
				.join(", ")}.`,
		);
	}
	return { alias: match[1], kind: "physical" };
}

export function nativeCacheKey(fingerprint, xcodeVersion, architecture) {
	return hashText(`${fingerprint}\0${xcodeVersion}\0${architecture}`);
}

export function normalizeBackendChoice(value) {
	return value === "remote" ? "preview" : value;
}

export function lanePreset(name) {
	const preset = laneSelection.presets[name];
	if (!preset) {
		throw new Error(
			`Unknown lane preset ${name}. Choose one of: ${Object.keys(
				laneSelection.presets,
			).join(", ")}.`,
		);
	}
	return structuredClone(preset);
}

function requestedPreset(args) {
	const separator = args.indexOf("--");
	const searchable = separator >= 0 ? args.slice(0, separator) : args;
	const index = searchable.indexOf("--preset");
	if (index < 0) {
		return { explicit: false, name: laneSelection.defaultPreset };
	}
	return {
		explicit: true,
		name: requireValue(searchable, index + 1, "--preset"),
	};
}

export function parseOptions(args) {
	const selectedPreset = requestedPreset(args);
	const preset = lanePreset(selectedPreset.name);
	const options = {
		acknowledgeSharedReset: false,
		backend: preset.backend,
		backendExplicit: false,
		build: preset.build,
		client: process.env.IOS_SESSION_LANES_CLIENT ?? "",
		controller: preset.controller,
		controllerArgs: [],
		controllerExplicit: false,
		dopplerConfig:
			process.env.IOS_SESSION_LANES_DOPPLER_CONFIG ??
			profile.backend.dopplerConfig,
		expose: preset.expose,
		exposeExplicit: false,
		forceController: false,
		json: false,
		preset: selectedPreset.name,
		presetExplicit: selectedPreset.explicit,
		quiet: false,
		recordedSelection: false,
		sessionId: process.env.IOS_SESSION_LANES_SESSION_ID ?? "",
		staleAfterMinutes: 120,
		target: preset.target,
		targetExplicit: false,
		udid: "",
	};
	const positionals = [];

	for (let index = 0; index < args.length; index += 1) {
		const arg = args[index];
		if (arg === "--") {
			options.controllerArgs = args.slice(index + 1);
			break;
		}
		if (arg === "--build") options.build = true;
		else if (arg === "--json") options.json = true;
		else if (arg === "--quiet") options.quiet = true;
		else if (arg === "--force-controller") options.forceController = true;
		else if (arg === "--acknowledge-shared-reset")
			options.acknowledgeSharedReset = true;
		else if (arg === "--preset") index += 1;
		else if (arg === "--client") options.client = requireValue(args, ++index, arg);
		else if (arg === "--session-id")
			options.sessionId = requireValue(args, ++index, arg);
		else if (arg === "--backend") {
			options.backend = requireValue(args, ++index, arg);
			options.backendExplicit = true;
		} else if (arg === "--doppler-config")
			options.dopplerConfig = requireValue(args, ++index, arg);
		else if (arg === "--target") {
			options.target = requireValue(args, ++index, arg);
			options.targetExplicit = true;
		} else if (arg === "--udid") options.udid = requireValue(args, ++index, arg);
		else if (arg === "--controller") {
			options.controller = requireValue(args, ++index, arg);
			options.controllerExplicit = true;
		} else if (arg === "--expose") {
			options.expose = requireValue(args, ++index, arg);
			options.exposeExplicit = true;
		} else if (arg === "--stale-after-minutes")
			options.staleAfterMinutes = Number(requireValue(args, ++index, arg));
		else if (arg.startsWith("--")) throw new Error(`Unknown option ${arg}`);
		else positionals.push(arg);
	}
	options.backend = normalizeBackendChoice(options.backend);
	if (
		options.presetExplicit &&
		(options.targetExplicit || options.backendExplicit || options.exposeExplicit)
	) {
		throw new Error(
			"Do not combine --preset with --target, --backend, or --expose. " +
				"Choose a preset or provide all three custom choices.",
		);
	}
	if (
		!options.presetExplicit &&
		options.targetExplicit &&
		options.backendExplicit &&
		options.exposeExplicit
	) {
		options.preset = "custom";
	}

	return { command: positionals[0] ?? "help", options };
}

export async function getLane(client, sessionId) {
	const registry = readRegistry();
	return registry.lanes[sessionKey(client, sessionId)] ?? null;
}

export async function up(options) {
	assertDarwin();
	assertSession(options);
	assertBootstrap();
	const key = sessionKey(options.client, options.sessionId);
	applyRecordedLaneSelection(options, readRegistry().lanes[key]);
	assertLaneSelection(options);
	const requestedTarget = parseTarget(options.target);
	prepareTargetDefaults(options, requestedTarget);
	assertBackendChoice(options.backend);
	assertExposureChoice(options.expose);
	assertControllerChoice(options.controller);
	ensureDirectoryLayout();
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

	let lane = await withRegistryLock(async (registry) => {
		pruneDeadMetroMetadata(registry);
		const existing = registry.lanes[key];
		if (existing) {
			if (path.resolve(existing.worktree) !== repoRoot) {
				throw new Error(
					`Session ${key} already owns a lane in ${existing.worktree}. Run down there before changing worktrees.`,
				);
			}
			const metroRunning = metroProcessOwned(existing);
			if (existing.backend !== options.backend && metroRunning) {
				throw new Error(
					`Lane ${key} is already running with backend=${existing.backend}. Run down before switching backends.`,
				);
			}
			if (existing.exposure !== options.expose && metroRunning) {
				throw new Error(
					`Lane ${key} is already running with exposure=${existing.exposure}. Run down before switching exposure.`,
				);
			}
			if (
				existing.requestedTarget?.kind !== requestedTarget.kind ||
				(requestedTarget.kind === "physical" &&
					existing.requestedTarget?.alias !== requestedTarget.alias)
			) {
				throw new Error(
					`Lane ${key} already targets ${existing.requestedTarget?.kind ?? existing.target.kind}. Run down before changing targets.`,
				);
			}
			existing.backend = options.backend;
			existing.exposure = options.expose;
			existing.preset = options.preset;
			existing.updatedAt = now();
			return existing;
		}

		const port = await chooseMetroPort(registry);
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

	try {
		if (lane.target.kind === "simulator") {
			lane = await bootLaneSimulator(key, lane);
		}
		const metroHost = resolveMetroHost(lane.exposure);
		const environment = resolveMetroEnvironment(lane.backend);
		if (!metroProcessOwned(lane)) {
			if (!(await isPortAvailable(lane.metro.port))) {
				lane = await reassignLanePort(key, lane);
			}
			const metro = await startMetro(lane, environment, metroHost);
			lane = await updateLane(key, (current) => {
				current.metro = { ...current.metro, ...metro };
			});
		}
		await waitForMetroIdentity(lane);
		const native = await ensureNativeBinary(lane, environment, options);
		lane = await updateLane(key, (current) => {
			current.native = native;
		});
		await controllerAcquire({ ...options, quiet: true }, lane);
		lane = await getLane(options.client, options.sessionId);
		await connectTarget(lane);
		lane = await getLane(options.client, options.sessionId);
		const evidence = await collectEvidence(lane);
		writeEvidence(lane, evidence);
		if (!evidence.passed) {
			throw new Error(`Lane evidence failed: ${failedCheckNames(evidence).join(", ")}.`);
		}
		lane = await updateLane(key, (current) => {
			delete current.lastError;
		});
		printLane(lane, options);
		return lane;
	} catch (error) {
		if (
			lane.target.kind === "simulator" &&
			error.code === "SIMULATOR_UNREACHABLE" &&
			(options.simulatorRetries ?? 0) < maxSimulatorLanes - 1
		) {
			console.warn(
				`[ios-lane] ${lane.target.name} could not render PUMPD. ` +
					"Quarantining it without deleting or erasing it and retrying with another simulator.",
			);
			await quarantineAndReassignSimulator(key, lane, error.message);
			return up({
				...options,
				simulatorRetries: (options.simulatorRetries ?? 0) + 1,
			});
		}
		await updateLaneIfPresent(key, (current) => {
			current.lastError = error.message;
		});
		throw error;
	}
}

export async function down(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	const lane = await getLane(options.client, options.sessionId);

	if (!lane) {
		if (!options.quiet) console.log(`No iOS lane is registered for ${key}.`);
		return null;
	}

	closeAgentDeviceBestEffort(lane, options.quiet);
	stopOwnedMetro(lane);
	await withRegistryLock(async (registry) => {
		const current = registry.lanes[key];
		if (!current) return;
		if (current.createdAt !== lane.createdAt) {
			throw new Error(`Lane ${key} changed while it was being released; retry down.`);
		}
		releaseLaneResources(registry, current);
		delete registry.lanes[key];
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
			console.log(`${evidence.passed ? "PASS" : "FAIL"}: ${describeLane(lane)}`);
			for (const check of evidence.checks) {
				console.log(`  ${check.ok ? "PASS" : "FAIL"} ${check.name}: ${check.detail}`);
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
		(lane) => !metroProcessOwned(lane) && Date.parse(lane.updatedAt) <= cutoff,
	);
	for (const lane of candidates) closeAgentDeviceBestEffort(lane, options.quiet);
	const removed = await withRegistryLock(async (registry) => {
		const stale = [];
		for (const candidate of candidates) {
			const lane = registry.lanes[candidate.key];
			if (!lane || lane.createdAt !== candidate.createdAt) continue;
			if (metroProcessOwned(lane) || Date.parse(lane.updatedAt) > cutoff) continue;
			releaseLaneResources(registry, lane);
			delete registry.lanes[candidate.key];
			stale.push(lane);
		}
		return stale;
	});
	if (!options.quiet) console.log(`Reaped ${removed.length} stale iOS lane(s).`);
	return removed;
}

export async function simulatorRecheck(options = {}) {
	const udid = requireIdentifier(options.udid, "simulator UDID");
	const removed = await withRegistryLock(async (registry) => {
		const entry = registry.resources.simulatorQuarantine[udid] ?? null;
		delete registry.resources.simulatorQuarantine[udid];
		return entry;
	});
	if (!options.quiet) {
		console.log(
			removed
				? `Simulator ${udid} is eligible for a fresh health check; it was not erased or recreated.`
				: `Simulator ${udid} was not quarantined.`,
		);
	}
	return removed;
}

export async function controllerAcquire(options, suppliedLane = null) {
	assertSession(options);
	assertControllerChoice(options.controller);
	const lane =
		suppliedLane ?? (await getLane(options.client, options.sessionId));
	if (!lane) throw new Error("Acquire an iOS lane before selecting a controller.");
	const resource = targetResourceKey(lane.target);
	const priorController = lane.controller?.controller ?? null;
	if (
		priorController &&
		priorController !== options.controller &&
		!options.forceController
	) {
		throw new Error(
			`${lane.key} already uses ${priorController}. Release it or pass --force-controller to switch.`,
		);
	}
	if (priorController === "agent-device" && priorController !== options.controller) {
		closeAgentDevice(lane);
	}
	const lease = await withRegistryLock(async (registry) => {
		const current = registry.lanes[lane.key];
		if (!current) throw new Error(`Lane ${lane.key} was released.`);
		const existing = registry.resources.controllers[resource];
		if (existing && existing.ownerKey !== lane.key) {
			throw new Error(
				`${resource} input is owned by ${existing.ownerKey} through ${existing.controller}.`,
			);
		}
		if (existing && existing.controller !== priorController) {
			throw new Error(
				`${resource} input changed from ${priorController ?? "unassigned"} to ${existing.controller}; retry the switch.`,
			);
		}
		const value = {
			acquiredAt: now(),
			controller: options.controller,
			ownerKey: lane.key,
			resource,
		};
		registry.resources.controllers[resource] = value;
		current.controller = value;
		current.updatedAt = now();
		return value;
	});
	if (!options.quiet) console.log(`${lease.controller} owns input for ${lease.resource}.`);
	return lease;
}

export async function controllerRelease(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	const currentLane = await getLane(options.client, options.sessionId);
	if (currentLane?.controller?.controller === "agent-device") {
		closeAgentDevice(currentLane);
	}
	const released = await withRegistryLock(async (registry) => {
		const lane = registry.lanes[key];
		if (!lane?.controller) return null;
		if (lane.controller.controller !== currentLane?.controller?.controller) {
			throw new Error(`Lane ${key} input ownership changed while it was being released.`);
		}
		const resource = lane.controller.resource;
		if (registry.resources.controllers[resource]?.ownerKey === key) {
			delete registry.resources.controllers[resource];
		}
		lane.controller = null;
		lane.updatedAt = now();
		return resource;
	});
	if (!options.quiet) console.log(released ? `Released input for ${released}.` : "No controller lease held.");
	return released;
}

export async function runController(options, kind = "agent-device") {
	assertSession(options);
	const lane = await getLane(options.client, options.sessionId);
	if (!lane) throw new Error("Acquire an iOS lane before running a controller.");
	if (lane.controller?.controller !== kind) {
		throw new Error(
			`${kind} does not own this lane. Run controller-acquire --controller ${kind}${
				lane.controller ? " --force-controller" : ""
			}.`,
		);
	}
	if (kind === "agent-device") return runAgentDevice(lane, options.controllerArgs);
	if (kind === "maestro") return runMaestro(lane, options.controllerArgs);
	throw new Error(`${kind} is used through its MCP tools after acquiring the lane lease.`);
}

export async function backendUp(options) {
	assertDarwin();
	assertSession(options);
	assertBootstrap();
	ensureDirectoryLayout();
	const currentStatus = readLocalSupabaseStatus({ allowFailure: true });
	if (currentStatus) {
		const detected = detectRunningBackend();
		assertBackendCompatible(detected);
		materializeBackendEnv(currentStatus);
		await withRegistryLock(async (registry) => {
			if (!registry.backend) registry.backend = detected;
		});
		console.log(
			detected.managed
				? `Shared Supabase is already owned by ${detected.ownerKey}.`
				: `Shared Supabase is externally managed from ${detected.mountWorktree ?? "an unknown worktree"}; it was not remounted.`,
		);
		return detected;
	}

	const key = sessionKey(options.client, options.sessionId);
	const compatibility = backendContract(repoRoot);
	const owner = await withRegistryLock(async (registry) => {
		if (registry.backend) {
			throw new Error(`Shared Supabase is reserved by ${registry.backend.ownerKey ?? "an external owner"}.`);
		}
		const value = {
			compatibility,
			createdAt: now(),
			dopplerConfig: options.dopplerConfig,
			managed: true,
			mountWorktree: repoRoot,
			ownerKey: key,
		};
		registry.backend = value;
		return value;
	});

	try {
		const secretNames = availableBackendSecretNames(options.dopplerConfig);
		runInherited(
			"doppler",
			[
				"--silent",
				"run",
				"--project",
				profile.backend.dopplerProject,
				"--config",
				options.dopplerConfig,
				"--no-fallback",
				"--only-secrets",
				secretNames.join(","),
				"--",
				"corepack",
				"pnpm",
				"--dir",
				profile.backend.root,
				"exec",
				"supabase",
				"start",
			],
			repoRoot,
		);
		const statusData = readLocalSupabaseStatus();
		materializeBackendEnv(statusData);
		console.log(`Shared Supabase started by ${owner.ownerKey} from ${owner.mountWorktree}.`);
		return owner;
	} catch (error) {
		await withRegistryLock(async (registry) => {
			if (registry.backend?.ownerKey === key) registry.backend = null;
		});
		throw error;
	}
}

export async function backendDown(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	const backend = readRegistry().backend;
	if (!backend?.managed) {
		throw new Error("Refusing to stop an externally managed shared Supabase stack.");
	}
	if (backend.ownerKey !== key) {
		throw new Error(`Only ${backend.ownerKey} may stop the shared Supabase stack.`);
	}
	if (path.resolve(backend.mountWorktree) !== repoRoot) {
		throw new Error(`Run backend-down from its owner worktree: ${backend.mountWorktree}.`);
	}
	runInherited(
		"corepack",
		["pnpm", "--dir", profile.backend.root, "exec", "supabase", "stop"],
		repoRoot,
	);
	await withRegistryLock(async (registry) => {
		registry.backend = null;
		registry.resources.backendWriter = null;
	});
	console.log("Shared Supabase stopped and its owner lease was released.");
}

export async function backendWriterAcquire(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	const lease = await withRegistryLock(async (registry) => {
		const lane = registry.lanes[key];
		if (!lane || lane.backend !== "local") {
			throw new Error("A local-backend iOS lane is required for the backend writer lease.");
		}
		const existing = registry.resources.backendWriter;
		if (existing && existing.ownerKey !== key) {
			throw new Error(`Shared backend data writes are owned by ${existing.ownerKey}.`);
		}
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

export async function backendReset(options) {
	assertSession(options);
	if (!options.acknowledgeSharedReset) {
		throw new Error("Shared reset requires --acknowledge-shared-reset.");
	}
	const key = sessionKey(options.client, options.sessionId);
	const registry = readRegistry();
	if (!registry.backend?.managed || registry.backend.ownerKey !== key) {
		throw new Error("Only the managed shared-backend owner may reset it.");
	}
	if (path.resolve(registry.backend.mountWorktree) !== repoRoot) {
		throw new Error(`Run backend-reset from its owner worktree: ${registry.backend.mountWorktree}.`);
	}
	if (registry.resources.backendWriter?.ownerKey !== key) {
		throw new Error("Acquire the backend writer lease before reset.");
	}
	const otherConsumers = Object.values(registry.lanes).filter(
		(lane) => lane.backend === "local" && lane.key !== key,
	);
	if (otherConsumers.length > 0) {
		throw new Error(
			`Shared reset blocked while ${otherConsumers.map((lane) => lane.key).join(", ")} consume local Supabase.`,
		);
	}
	runInherited(
		"corepack",
		["pnpm", "--dir", profile.backend.root, "db:reset"],
		repoRoot,
	);
	console.log("Shared Supabase reset completed through the repo wrapper, including catalog media.");
}

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
	registry.backend = parsed.backend ?? null;
	registry.lanes = parsed.lanes ?? {};
	registry.resources = {
		...registry.resources,
		...(parsed.resources ?? {}),
		controllers: parsed.resources?.controllers ?? {},
		simulatorQuarantine: parsed.resources?.simulatorQuarantine ?? {},
	};
	for (const [key, lane] of Object.entries(registry.lanes)) {
		lane.backend = normalizeBackendChoice(lane.backend);
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
		resources: {
			backendWriter: null,
			controllers: {},
			simulatorQuarantine: {},
		},
		version: registryVersion,
	};
}

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

function prepareTargetDefaults(options, target) {
	if (target.kind !== "physical") return;
	if (options.backendExplicit && options.backend !== "preview") {
		throw new Error("Physical lanes must use --backend preview; local Supabase is never exposed.");
	}
	if (options.exposeExplicit && options.expose !== "tailscale") {
		throw new Error("Physical lanes must use --expose tailscale.");
	}
	options.backend = "preview";
	options.expose = "tailscale";
}

function assertBackendChoice(backend) {
	if (backend !== "local" && backend !== "preview") {
		throw new Error('--backend must be either "local" or "preview".');
	}
}

export function laneSelectionIsConfirmed(options) {
	return Boolean(
		options.presetExplicit ||
		options.recordedSelection ||
		(options.targetExplicit && options.backendExplicit && options.exposeExplicit)
	);
}

export function applyRecordedLaneSelection(options, lane) {
	if (laneSelectionIsConfirmed(options) || !lane) return false;
	const requestedTarget = lane.requestedTarget ?? lane.target;
	options.target =
		requestedTarget.kind === "physical"
			? `physical:${requestedTarget.alias}`
			: "simulator";
	options.backend = normalizeBackendChoice(lane.backend);
	options.expose = lane.exposure;
	options.preset = lane.preset ?? "legacy";
	options.recordedSelection = true;
	return true;
}

function assertLaneSelection(options) {
	if (laneSelectionIsConfirmed(options)) return;
	throw new Error(
		"Lane choices were not confirmed. Ask the user to choose a lane preset, then pass " +
			`--preset <name>. Recommended: ${laneSelection.defaultPreset}.`,
	);
}

function assertExposureChoice(expose) {
	if (expose !== "local" && expose !== "tailscale") {
		throw new Error('--expose must be either "local" or "tailscale".');
	}
}

function assertControllerChoice(controller) {
	if (!managedControllers.has(controller)) {
		throw new Error(`Unknown controller ${controller}.`);
	}
}

function assertDarwin() {
	if (process.platform !== "darwin") {
		throw new Error(
			`${profile.displayName} iOS lanes require macOS with Xcode installed.`,
		);
	}
}

function requireIdentifier(value, label) {
	if (!value || !/^[A-Za-z0-9._:-]+$/.test(value)) {
		throw new Error(`A safe ${label} is required.`);
	}
	return value;
}

function requireValue(args, index, option) {
	const value = args[index];
	if (!value || value.startsWith("--")) throw new Error(`${option} requires a value.`);
	return value;
}

function ensureDirectoryLayout() {
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

async function withRegistryLock(callback) {
	return withFileLock(registryLockPath, 5_000, async () => {
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

async function withFileLock(lockPath, timeoutMs, callback) {
	ensureDirectoryLayout();
	let descriptor;
	const startedAt = Date.now();
	while (descriptor === undefined && Date.now() - startedAt < timeoutMs) {
		try {
			descriptor = openSync(lockPath, "wx", 0o600);
			writeFileSync(descriptor, `${process.pid}\n`);
		} catch (error) {
			if (error.code !== "EEXIST") throw error;
			try {
				const ownerPid = Number(readFileSync(lockPath, "utf8").trim());
				if (!isPidAlive(ownerPid)) {
					unlinkSync(lockPath);
					continue;
				}
			} catch {
				continue;
			}
			await sleep(50);
		}
	}
	if (descriptor === undefined) throw new Error(`Timed out acquiring ${lockPath}.`);
	try {
		return await callback();
	} finally {
		closeSync(descriptor);
		rmSync(lockPath, { force: true });
	}
}

function pruneDeadMetroMetadata(registry) {
	for (const lane of Object.values(registry.lanes)) {
		if (lane.metro?.pid && !metroProcessOwned(lane)) {
			lane.metro.pid = null;
			lane.metro.processStartedAt = null;
		}
	}
}

function isPidAlive(pid) {
	if (!Number.isInteger(pid) || pid <= 0) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return error.code === "EPERM";
	}
}

function processStartedAt(pid) {
	if (!isPidAlive(pid)) return null;
	const result = spawnSync("ps", ["-p", String(pid), "-o", "lstart="], {
		encoding: "utf8",
	});
	return result.status === 0 ? result.stdout.trim() || null : null;
}

function metroProcessOwned(lane) {
	const pid = lane.metro?.pid;
	if (!isPidAlive(pid)) return false;
	const expected = lane.metro.processStartedAt;
	return Boolean(expected && processStartedAt(pid) === expected);
}

function stopOwnedMetro(lane) {
	if (!metroProcessOwned(lane)) return;
	try {
		process.kill(-lane.metro.pid, "SIGTERM");
	} catch {
		try {
			process.kill(lane.metro.pid, "SIGTERM");
		} catch {
			// The owned process exited between validation and signaling.
		}
	}
}

async function chooseMetroPort(registry, excludedKey = "") {
	const assigned = new Set(
		Object.values(registry.lanes)
			.filter((lane) => lane.key !== excludedKey)
			.map((lane) => lane.metro.port),
	);
	for (let port = firstMetroPort; port <= lastMetroPort; port += 1) {
		if (!assigned.has(port) && (await isPortAvailable(port))) return port;
	}
	throw new Error(`No free Metro port is available in ${firstMetroPort}-${lastMetroPort}.`);
}

function isPortAvailable(port) {
	return new Promise((resolvePort) => {
		const server = createServer();
		server.unref();
		server.once("error", () => resolvePort(false));
		server.listen(port, "0.0.0.0", () => server.close(() => resolvePort(true)));
	});
}

async function reassignLanePort(key, lane) {
	return withRegistryLock(async (registry) => {
		const current = registry.lanes[key];
		if (!current) throw new Error(`Lane ${key} was released.`);
		current.metro.port = await chooseMetroPort(registry, key);
		current.metro.nonce = randomBytes(16).toString("hex");
		current.updatedAt = now();
		return current;
	});
}

function ensureSimulator(registry) {
	const devices = readSimulatorDevices();
	const quarantined = new Set(
		Object.keys(registry.resources.simulatorQuarantine ?? {}),
	);
	const assigned = new Set(
		Object.values(registry.lanes)
			.filter((lane) => lane.target.kind === "simulator")
			.map((lane) => lane.target.udid),
	);
	for (const device of devices) {
		if (
			device.name.startsWith(simulatorNamePrefix) &&
			iosRuntimeMajor(device.runtimeIdentifier) <= maxIosRuntimeMajor &&
			!quarantined.has(device.udid) &&
			!assigned.has(device.udid)
		) {
			return simulatorTarget(device);
		}
	}

	for (let number = 1; number <= maxSimulatorLanes; number += 1) {
		const name = `${simulatorNamePrefix}${number}`;
		if (devices.some((device) => device.name === name)) continue;
		const runtime = newestIosRuntime();
		const result = runCaptured("xcrun", [
			"simctl",
			"create",
			name,
			simulatorDeviceType,
			runtime.identifier,
		]);
		return simulatorTarget({
			name,
			runtimeIdentifier: runtime.identifier,
			state: "Shutdown",
			udid: result.stdout.trim(),
		});
	}
	throw new Error(
		`All ${maxSimulatorLanes} ${profile.displayName} simulator lanes are assigned.`,
	);
}

function simulatorTarget(device) {
	return {
		alias: device.name.toLowerCase().replace(/\s+/g, "-"),
		kind: "simulator",
		name: device.name,
		runtimeIdentifier: device.runtimeIdentifier,
		udid: device.udid,
	};
}

function readSimulatorDevices() {
	const output = JSON.parse(
		runCaptured("xcrun", ["simctl", "list", "devices", "--json"], repoRoot, {
			timeout: 30_000,
		}).stdout,
	);
	return Object.entries(output.devices)
		.flatMap(([runtimeIdentifier, devices]) =>
			devices.map((device) => ({ ...device, runtimeIdentifier })),
		)
		.filter((device) => device.isAvailable !== false);
}

function newestIosRuntime() {
	const output = JSON.parse(
		runCaptured("xcrun", ["simctl", "list", "runtimes", "--json"]).stdout,
	);
	const runtimes = output.runtimes
		.filter(
			(runtime) =>
				runtime.isAvailable &&
				runtime.identifier.includes("CoreSimulator.SimRuntime.iOS-") &&
				iosRuntimeMajor(runtime.identifier) <= maxIosRuntimeMajor,
		)
		.sort((left, right) => compareVersions(right.version, left.version));
	if (!runtimes[0]) {
		throw new Error(`No iOS Simulator runtime at or below major ${maxIosRuntimeMajor} is available.`);
	}
	return runtimes[0];
}

function iosRuntimeMajor(identifier) {
	const match = identifier.match(/\.iOS-(\d+)(?:-|$)/);
	return match ? Number(match[1]) : Number.POSITIVE_INFINITY;
}

function compareVersions(left, right) {
	const leftParts = left.split(".").map(Number);
	const rightParts = right.split(".").map(Number);
	for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
		const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0);
		if (difference !== 0) return difference;
	}
	return 0;
}

async function bootLaneSimulator(key, initialLane) {
	let lane = initialLane;
	for (let attempt = 1; attempt <= maxSimulatorLanes; attempt += 1) {
		try {
			await withSimulatorControl(async () => bootSimulator(lane.target.udid));
			return lane;
		} catch (error) {
			if (error.code !== "SIMULATOR_DATA_MIGRATION_FAILED") throw error;
			const failedTarget = lane.target;
			console.warn(
				`[ios-lane] ${failedTarget.name} (${failedTarget.udid}) ended with Data Migration Failed. ` +
					"Quarantining it without deleting or erasing it and allocating another simulator.",
			);
			lane = await quarantineAndReassignSimulator(
				key,
				lane,
				"Data Migration Failed",
			);
		}
	}
	throw new Error(
		`No healthy simulator was found after ${maxSimulatorLanes} terminal migration failures. ` +
			"The failed devices were preserved and quarantined for manual CoreSimulator diagnosis.",
	);
}

async function quarantineAndReassignSimulator(key, lane, reason) {
	const failedTarget = lane.target;
	if (lane.controller?.controller === "agent-device") {
		closeAgentDeviceBestEffort(lane, true);
	}
	return withRegistryLock(async (registry) => {
		const current = registry.lanes[key];
		if (!current) throw new Error(`Lane ${key} was released.`);
		registry.resources.simulatorQuarantine[failedTarget.udid] = {
			name: failedTarget.name,
			quarantinedAt: now(),
			reason: String(reason).slice(0, 500),
			runtimeIdentifier: failedTarget.runtimeIdentifier,
		};
		releaseLaneResources(registry, current);
		current.controller = null;
		current.native = null;
		current.target = ensureSimulator(registry);
		current.updatedAt = now();
		return current;
	});
}

export function classifySimulatorBootResult(result = {}) {
	const output = [result.stdout, result.stderr]
		.filter(Boolean)
		.join("\n")
		.trim();
	if (/Data Migration Failed/i.test(output)) {
		return {
			code: "SIMULATOR_DATA_MIGRATION_FAILED",
			message: "Data Migration Failed",
		};
	}
	if (result.error?.code === "ETIMEDOUT" || result.signal === "SIGTERM") {
		return {
			code: "SIMULATOR_BOOT_TIMEOUT",
			message: `bootstatus exceeded ${Math.round(simulatorBootTimeoutMs / 1000)} seconds`,
		};
	}
	if (result.status !== 0) {
		return {
			code: "SIMULATOR_BOOT_FAILED",
			message: output || result.error?.message || `bootstatus exited ${result.status}`,
		};
	}
	return null;
}

function bootSimulator(udid) {
	const existing = readSimulatorDevices().find((device) => device.udid === udid);
	if (existing?.state !== "Booted") {
		spawnSync("xcrun", ["simctl", "boot", udid], {
			cwd: repoRoot,
			stdio: "ignore",
			timeout: 30_000,
		});
	}
	const result = spawnSync("xcrun", ["simctl", "bootstatus", udid, "-b"], {
		cwd: repoRoot,
		encoding: "utf8",
		timeout: simulatorBootTimeoutMs,
	});
	const failure = classifySimulatorBootResult(result);
	if (failure) {
		if (
			failure.code === "SIMULATOR_DATA_MIGRATION_FAILED" &&
			simulatorSpringBoardIsReachable(udid)
		) {
			console.warn(
				`[ios-lane] Simulator ${udid} reported Data Migration Failed, ` +
					"but SpringBoard is reachable; continuing to the rendered-app health check.",
			);
			return;
		}
		const error = new Error(`Simulator ${udid} did not finish booting: ${failure.message}.`);
		error.code = failure.code;
		throw error;
	}
}

function simulatorSpringBoardIsReachable(udid) {
	const result = spawnSync(
		"xcrun",
		["simctl", "spawn", udid, "launchctl", "print", "system/com.apple.SpringBoard"],
		{ cwd: repoRoot, encoding: "utf8", timeout: 30_000 },
	);
	return result.status === 0;
}

function resolvePhysicalDevice(alias) {
	const config = physicalDeviceAliases[alias];
	const outputPath = path.join(laneHome, `devicectl-${process.pid}.json`);
	try {
		const result = spawnSync(
			"xcrun",
			["devicectl", "list", "devices", "--timeout", "5", "--json-output", outputPath],
			{ cwd: repoRoot, encoding: "utf8", timeout: 15_000 },
		);
		if (result.status !== 0 || !existsSync(outputPath)) return null;
		const payload = JSON.parse(readFileSync(outputPath, "utf8"));
		const candidates = collectDeviceObjects(payload);
		const device = candidates.find((candidate) => {
			const name = candidate.name ?? candidate.deviceName ?? candidate.properties?.name;
			return config.displayNames.includes(name);
		});
		if (!device) return null;
		const deviceId =
			device.identifier ?? device.udid ?? device.deviceIdentifier ?? device.hardwareProperties?.udid;
		if (!deviceId) return null;
		return { alias, deviceId, jointTestRequired: true, kind: "physical", name: config.displayNames[0] };
	} catch {
		return null;
	} finally {
		rmSync(outputPath, { force: true });
	}
}

function collectDeviceObjects(value, output = []) {
	if (Array.isArray(value)) {
		for (const item of value) collectDeviceObjects(item, output);
	} else if (value && typeof value === "object") {
		if (value.identifier || value.udid || value.deviceIdentifier) output.push(value);
		for (const child of Object.values(value)) collectDeviceObjects(child, output);
	}
	return output;
}

function allocatePhysical(registry, target) {
	const conflict = Object.values(registry.lanes).find(
		(lane) => lane.target.kind === "physical" && lane.target.alias === target.alias,
	);
	if (conflict) throw new Error(`${target.alias} is already assigned to ${conflict.key}.`);
	return target;
}

function resolveMetroHost(exposure) {
	if (exposure === "local") return "127.0.0.1";
	const result = runCaptured("tailscale", ["ip", "-4"]);
	const address = result.stdout
		.split(/\r?\n/)
		.map((line) => line.trim())
		.find((line) => /^100\./.test(line));
	if (!address) throw new Error("Tailscale did not report a tailnet IPv4 address.");
	return address;
}

function resolveMetroEnvironment(backend) {
	const environment = { ...process.env, APP_VARIANT: "development" };
	if (backend === "preview") {
		environment.EXPO_PUBLIC_USE_LOCAL_SUPABASE = "false";
		return environment;
	}
	const statusData = readLocalSupabaseStatus();
	const detected = detectRunningBackend();
	assertBackendCompatible(detected);
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

function readLocalSupabaseStatus({ allowFailure = false } = {}) {
	const result = spawnSync(
		"corepack",
		[
			"pnpm",
			"--dir",
			profile.backend.root,
			"exec",
			"supabase",
			"status",
			"-o",
			"json",
		],
		{ cwd: repoRoot, encoding: "utf8", maxBuffer: 10 * 1024 * 1024 },
	);
	if (result.status !== 0) {
		if (allowFailure) return null;
		throw new Error(
			"Shared local Supabase is not running. One session must use ios:lane backend-up; ordinary lanes only consume it.",
		);
	}
	try {
		return JSON.parse(result.stdout);
	} catch {
		throw new Error("Supabase status returned invalid JSON.");
	}
}

function materializeBackendEnv(statusData) {
	const publishableKey = statusData.PUBLISHABLE_KEY ?? statusData.ANON_KEY ?? "";
	const secretKey = statusData.SECRET_KEY ?? statusData.SERVICE_ROLE_KEY ?? "";
	if (!statusData.API_URL || !publishableKey || !secretKey) return;
	writeFileSync(
		path.join(backendRoot, ".env"),
		[
			`SUPABASE_URL=${statusData.API_URL}`,
			`SUPABASE_PUBLISHABLE_KEY=${publishableKey}`,
			`SUPABASE_SECRET_KEY=${secretKey}`,
			"",
		].join("\n"),
		{ mode: 0o600 },
	);
}

async function startMetro(lane, environment, host) {
	const logDescriptor = openSync(lane.logFile, "a", 0o600);
	const devServerUrl = `http://${host}:${lane.metro.port}`;
	const child = spawn(
		"corepack",
		[
			"pnpm",
			"--dir",
			profile.mobile.root,
			"exec",
			"expo",
			"start",
			"--dev-client",
			"--host",
			"lan",
			"--port",
			String(lane.metro.port),
		],
		{
			cwd: repoRoot,
			detached: true,
			env: {
				...environment,
				EXPO_PACKAGER_PROXY_URL: devServerUrl,
				IOS_SESSION_LANE_NONCE: lane.metro.nonce,
				IOS_SESSION_LANE_WORKTREE_HASH: lane.metro.worktreeHash,
				REACT_NATIVE_PACKAGER_HOSTNAME: host,
			},
			stdio: ["ignore", logDescriptor, logDescriptor],
		},
	);
	child.unref();
	closeSync(logDescriptor);
	let processIdentity = null;
	for (let attempt = 0; attempt < 20 && !processIdentity; attempt += 1) {
		processIdentity = processStartedAt(child.pid);
		if (!processIdentity) await sleep(50);
	}
	if (!processIdentity) {
		try {
			process.kill(-child.pid, "SIGTERM");
		} catch {
			child.kill("SIGTERM");
		}
		throw new Error("Metro started, but its PID/start-time identity could not be verified.");
	}
	return {
		host,
		pid: child.pid,
		processStartedAt: processIdentity,
		startedAt: now(),
		url: devServerUrl,
	};
}

async function waitForMetroIdentity(lane) {
	const startedAt = Date.now();
	const statusUrl = `http://127.0.0.1:${lane.metro.port}/status`;
	while (Date.now() - startedAt < metroReadyTimeoutMs) {
		if (!metroProcessOwned(lane)) {
			throw new Error(`Metro exited during startup. Check ${lane.logFile}.`);
		}
		try {
			const statusResponse = await fetch(statusUrl);
			const statusBody = await statusResponse.text();
			if (
				statusResponse.ok &&
				statusBody.includes("packager-status:running") &&
				metroCommandMatchesLane(lane)
			) {
				return;
			}
		} catch {
			// Metro is still warming up.
		}
		await sleep(500);
	}
	throw new Error(
		`Owned Metro process did not become ready at ${statusUrl} for ${lane.worktree}.`,
	);
}

function metroCommandMatchesLane(lane) {
	const result = spawnSync(
		"ps",
		["-p", String(lane.metro.pid), "-o", "command="],
		{ encoding: "utf8" },
	);
	if (result.status !== 0) return false;
	const command = result.stdout.trim();
	return (
		/(?:expo|corepack|pnpm)/.test(command) &&
		command.includes(String(lane.metro.port))
	);
}

async function ensureNativeBinary(lane, environment, options) {
	const identity = nativeIdentity();
	if (lane.target.kind === "physical") {
		return ensurePhysicalBinary(lane, environment, options, identity);
	}
	return ensureSimulatorBinary(lane, environment, options, identity);
}

function nativeIdentity() {
	const result = runCaptured(
		"corepack",
		[
			"pnpm",
			"--dir",
			profile.mobile.root,
			"exec",
			"fingerprint",
			"fingerprint:generate",
			"--platform",
			"ios",
		],
		repoRoot,
		{ env: { ...process.env, APP_VARIANT: "development" } },
	);
	let fingerprint;
	try {
		fingerprint = JSON.parse(result.stdout).hash;
	} catch {
		throw new Error("Expo native fingerprint output was invalid.");
	}
	if (!fingerprint) throw new Error("Expo native fingerprint did not include a hash.");
	const xcodeVersion = runCaptured("xcodebuild", ["-version"]).stdout.trim();
	return {
		cacheKey: nativeCacheKey(fingerprint, xcodeVersion, process.arch),
		fingerprint,
		xcodeVersion,
	};
}

async function ensureSimulatorBinary(lane, environment, options, identity) {
	const marker = readDeviceMarker(lane.target.udid);
	if (
		!options.build &&
		marker?.fingerprint === identity.fingerprint &&
		installedSimulatorAppPath(lane.target.udid)
	) {
		return { ...identity, decision: "reuse-installed", verifiedAt: now() };
	}

	const cache = readBinaryCache(identity.cacheKey);
	if (!options.build && cache) {
		installCachedSimulatorApp(lane.target.udid, cache.appPath);
		writeDeviceMarker(lane.target.udid, identity);
		return {
			...identity,
			cachePath: cache.appPath,
			decision: "reuse-cache",
			verifiedAt: now(),
		};
	}

	return withNativeBuildLock(identity.cacheKey, async () => {
		const refreshedCache = !options.build && readBinaryCache(identity.cacheKey);
		if (refreshedCache) {
			installCachedSimulatorApp(lane.target.udid, refreshedCache.appPath);
			writeDeviceMarker(lane.target.udid, identity);
			return {
				...identity,
				cachePath: refreshedCache.appPath,
				decision: "reuse-cache-after-wait",
				verifiedAt: now(),
			};
		}
		buildIosApp(lane, environment);
		const installedPath = installedSimulatorAppPath(lane.target.udid);
		if (!installedPath) throw new Error("Local iOS build completed but its app was not installed.");
		const cachedPath = cacheSimulatorApp(installedPath, identity);
		writeDeviceMarker(lane.target.udid, identity);
		return {
			...identity,
			cachePath: cachedPath,
			decision: options.build ? "force-local-build" : "local-build-native-miss",
			verifiedAt: now(),
		};
	});
}

async function ensurePhysicalBinary(lane, environment, options, identity) {
	const marker = readDeviceMarker(`physical-${lane.target.alias}`);
	if (!options.build && marker?.fingerprint === identity.fingerprint) {
		return { ...identity, decision: "reuse-physical-install", verifiedAt: now() };
	}
	// This is always a local Xcode build. The workflow never requests an EAS
	// development build for a physical phone.
	buildIosApp(lane, environment);
	writeDeviceMarker(`physical-${lane.target.alias}`, identity);
	return {
		...identity,
		decision: options.build ? "force-local-physical-build" : "local-physical-build-native-miss",
		verifiedAt: now(),
	};
}

async function withNativeBuildLock(cacheKey, callback) {
	const lockPath = path.join(laneHome, `native-build-${cacheKey}.lock`);
	return withFileLock(lockPath, buildLockTimeoutMs, callback);
}

function buildIosApp(lane, environment) {
	runInherited(
		"corepack",
		[
			"pnpm",
			"--dir",
			profile.mobile.root,
			"exec",
			"expo",
			"run:ios",
			"--device",
			lane.target.kind === "simulator" ? lane.target.udid : lane.target.deviceId,
			"--no-bundler",
		],
		repoRoot,
		environment,
	);
}

function installedSimulatorAppPath(udid) {
	const result = spawnSync(
		"xcrun",
		["simctl", "get_app_container", udid, appId, "app"],
		{ cwd: repoRoot, encoding: "utf8", timeout: 3 * 60 * 1000 },
	);
	return result.status === 0 ? result.stdout.trim() || null : null;
}

function readBinaryCache(cacheKey) {
	const directory = path.join(binaryRoot, cacheKey);
	const manifestPath = path.join(directory, "manifest.json");
	const appPath = path.join(directory, cachedAppName);
	if (!existsSync(manifestPath) || !existsSync(appPath)) return null;
	try {
		const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
		if (manifest.appId !== appId || manifest.cacheKey !== cacheKey) return null;
		validateAppBundle(appPath);
		return { appPath, manifest };
	} catch {
		return null;
	}
}

function cacheSimulatorApp(sourcePath, identity) {
	validateAppBundle(sourcePath);
	const directory = path.join(binaryRoot, identity.cacheKey);
	const temporary = `${directory}.${process.pid}.tmp`;
	rmSync(temporary, { force: true, recursive: true });
	mkdirSync(temporary, { recursive: true, mode: 0o700 });
	const appPath = path.join(temporary, cachedAppName);
	cpSync(sourcePath, appPath, { recursive: true });
	writeFileSync(
		path.join(temporary, "manifest.json"),
		`${JSON.stringify(
			{
				appId,
				architecture: process.arch,
				builtAt: now(),
				cacheKey: identity.cacheKey,
				fingerprint: identity.fingerprint,
				xcodeVersion: identity.xcodeVersion,
			},
			null,
			2,
		)}\n`,
		{ mode: 0o600 },
	);
	rmSync(directory, { force: true, recursive: true });
	renameSync(temporary, directory);
	return path.join(directory, cachedAppName);
}

function validateAppBundle(appPath) {
	const plistPath = path.join(appPath, "Info.plist");
	if (!existsSync(plistPath)) throw new Error(`Cached app has no Info.plist: ${appPath}.`);
	const bundleId = runCaptured("plutil", ["-extract", "CFBundleIdentifier", "raw", "-o", "-", plistPath]).stdout.trim();
	if (bundleId !== appId) throw new Error(`Cached app bundle id ${bundleId} did not match ${appId}.`);
}

function installCachedSimulatorApp(udid, appPath) {
	validateAppBundle(appPath);
	const result = spawnSync("xcrun", ["simctl", "install", udid, appPath], {
		cwd: repoRoot,
		encoding: "utf8",
		timeout: 5 * 60 * 1000,
	});
	if (result.status !== 0 && !installedSimulatorAppPath(udid)) {
		throw new Error(
			`xcrun simctl install ${udid} failed: ${(
				result.error?.message ||
				result.stderr ||
				result.stdout ||
				`exit ${result.status}`
			).trim()}`,
		);
	}
}

function deviceMarkerPath(deviceKey) {
	return path.join(deviceStateRoot, `${safeKey(deviceKey)}.json`);
}

function readDeviceMarker(deviceKey) {
	const markerPath = deviceMarkerPath(deviceKey);
	if (!existsSync(markerPath)) return null;
	try {
		return JSON.parse(readFileSync(markerPath, "utf8"));
	} catch {
		return null;
	}
}

function writeDeviceMarker(deviceKey, identity) {
	writeFileSync(
		deviceMarkerPath(deviceKey),
		`${JSON.stringify({ ...identity, installedAt: now() }, null, 2)}\n`,
		{ mode: 0o600 },
	);
}

async function connectTarget(lane) {
	if (lane.target.kind === "simulator") return connectSimulator(lane);
	return runAgentDevice(lane, ["open", developmentClientUrl(lane)]);
}

async function connectSimulator(lane) {
	if (!installedSimulatorAppPath(lane.target.udid)) {
		throw new Error(
			`Could not launch ${lane.target.name}; its compatible local binary is missing.`,
		);
	}
	try {
		await verifyRenderedSimulatorApp(lane);
	} catch (error) {
		error.code =
			/failed to open|daemon request timed out|ETIMEDOUT|simulator device failed/i.test(
				error.message,
			)
				? "SIMULATOR_UNREACHABLE"
				: "SIMULATOR_RENDER_FAILED";
		throw error;
	}
}

async function verifyRenderedSimulatorApp(lane) {
	const deadline = Date.now() + simulatorRenderTimeoutMs;
	let reloads = 0;
	let renderedObservations = 0;
	let snapshot = "";
	agentDeviceCaptured(lane, ["open", developmentClientUrl(lane)]);
	while (Date.now() < deadline) {
		snapshot = agentDeviceCaptured(lane, ["snapshot", "-i"]);
		if (
			/\[alert\] "Open in .*PUMPD Development.*\?"/.test(snapshot) &&
			/\[button\] "Open"/.test(snapshot)
		) {
			pressSnapshotElement(lane, snapshot, /\[button\] "Open"/);
			continue;
		}
		if (/DEVELOPMENT SERVERS/.test(snapshot)) {
			pressSnapshotElement(lane, snapshot, /PUMPD Development/);
			continue;
		}
		if (/problem loading the project|request timed out/i.test(snapshot)) {
			if (reloads >= 2) break;
			reloads += 1;
			pressSnapshotElement(lane, snapshot, /\[button\] "Reload"/);
			continue;
		}
		if (/\[button\] "Continue"/.test(snapshot)) {
			pressSnapshotElement(lane, snapshot, /\[button\] "Continue"/);
			continue;
		}
		if (
			(/Runtime version:|CUSTOM MENU ITEMS/.test(snapshot) &&
				/\[button\] "Close"/.test(snapshot))
		) {
			pressSnapshotElement(lane, snapshot, /\[button\] "Close"/);
			continue;
		}
		if (
			!/(Loading PUMPD|SplashScreenLogo)/i.test(snapshot) &&
			/^Snapshot: [1-9][0-9]* visible nodes/m.test(snapshot) &&
			/\[(?:text|button|cell|scroll-area)\]/.test(snapshot)
		) {
			renderedObservations += 1;
			if (renderedObservations >= 2) break;
			await delay(2_000);
			continue;
		}
		renderedObservations = 0;
		await delay(1_500);
	}
	if (
		/DEVELOPMENT SERVERS|problem loading the project|request timed out|Loading PUMPD|SplashScreenLogo/i.test(
			snapshot,
		) ||
		!/^Snapshot: [1-9][0-9]* visible nodes/m.test(snapshot) ||
		!/\[(?:text|button|cell|scroll-area)\]/.test(snapshot)
	) {
		throw new Error(`The assigned simulator did not reach a rendered PUMPD screen.\n${snapshot}`);
	}
	await delay(750);
	const screenshot = path.join(evidenceRoot, `${safeKey(lane.key)}-render.png`);
	agentDeviceCaptured(lane, ["screenshot", screenshot]);
	await updateLane(lane.key, (current) => {
		current.render = {
			controller: "agent-device",
			screenshot,
			verifiedAt: now(),
		};
	});
}

function pressSnapshotElement(lane, snapshot, pattern) {
	const line = snapshot.split("\n").find((entry) => pattern.test(entry));
	const reference = line?.match(/^(@[^ ]+)/)?.[1];
	if (!reference) {
		throw new Error(`Could not resolve an agent-device element reference for ${pattern}.`);
	}
	agentDeviceCaptured(lane, ["press", reference, "--settle"]);
}

function agentDeviceCaptured(lane, commandArgs) {
	const stateDirectory = path.join(controllerStateRoot, safeKey(lane.key), "agent-device");
	mkdirSync(stateDirectory, { recursive: true, mode: 0o700 });
	const args = [...commandArgs];
	appendFlag(args, "--platform", "ios");
	appendFlag(args, "--device", lane.target.name);
	appendFlag(args, "--session", safeKey(lane.key));
	const result = runCaptured(
		"corepack",
		[
			"pnpm",
			"dlx",
			`agent-device@${profile.controllers.agentDeviceVersion}`,
			...args,
		],
		repoRoot,
		{
			env: { ...process.env, AGENT_DEVICE_STATE_DIR: stateDirectory },
			timeout: 2 * 60 * 1000,
		},
	);
	return `${result.stdout ?? ""}${result.stderr ?? ""}`;
}

function developmentClientUrl(lane) {
	return `${appScheme}://expo-development-client/?url=${encodeURIComponent(
		lane.metro.url,
	)}&disableOnboarding=1`;
}

function runAgentDevice(lane, providedArgs) {
	const stateDirectory = path.join(controllerStateRoot, safeKey(lane.key), "agent-device");
	mkdirSync(stateDirectory, { recursive: true, mode: 0o700 });
	let args = [...providedArgs];
	if (args.length === 0) args = ["snapshot", "-i"];
	appendFlag(args, "--platform", "ios");
	appendFlag(args, "--device", lane.target.name);
	appendFlag(args, "--session", safeKey(lane.key));
	runAgentDeviceCommand(args, stateDirectory);
}
function runAgentDeviceCommand(args, stateDirectory) {
	runInherited(
		"corepack",
		[
			"pnpm",
			"dlx",
			`agent-device@${profile.controllers.agentDeviceVersion}`,
			...args,
		],
		repoRoot,
		{
			...process.env,
			AGENT_DEVICE_STATE_DIR: stateDirectory,
		},
	);
}

function closeAgentDevice(lane) {
	const stateDirectory = path.join(controllerStateRoot, safeKey(lane.key), "agent-device");
	if (!existsSync(stateDirectory)) return;
	const result = spawnSync(
		"corepack",
		[
			"pnpm",
			"dlx",
			`agent-device@${profile.controllers.agentDeviceVersion}`,
			"daemon",
			"stop",
			"--clean",
		],
		{
			cwd: repoRoot,
			env: { ...process.env, AGENT_DEVICE_STATE_DIR: stateDirectory },
			encoding: "utf8",
			timeout: 15_000,
		},
	);
	if (result.status !== 0) {
		const detail = (result.error?.message || result.stderr || result.stdout || "unknown error").trim();
		throw new Error(`Could not release agent-device for ${lane.key}: ${detail}`);
	}
}

function closeAgentDeviceBestEffort(lane, quiet = false) {
	try {
		closeAgentDevice(lane);
	} catch (error) {
		if (!quiet) {
			console.warn(
				`[ios-lane] Could not close the stale agent-device session for ${lane.key}: ${error.message}`,
			);
		}
	}
}

function runMaestro(lane, providedArgs) {
	if (providedArgs.length === 0) throw new Error("Maestro requires arguments after --.");
	if (lane.target.kind !== "simulator") {
		throw new Error("This lane's Maestro adapter is simulator-only until the joint physical-device test.");
	}
	const args = [...providedArgs];
	appendFlag(args, "--udid", lane.target.udid);
	const binary = process.env.MAESTRO_BIN ?? path.join(process.env.HOME ?? "", ".maestro/bin/maestro");
	runInherited(binary, args, repoRoot, {
		...process.env,
		MAESTRO_DEVICE_UDID: lane.target.udid,
		PUMPD_TEST_RUN_ID: lane.testRunId,
	});
}

function appendFlag(args, flag, value) {
	if (args.includes(flag) || args.some((arg) => arg.startsWith(`${flag}=`))) return;
	args.push(flag, value);
}

async function withSimulatorControl(callback) {
	return withFileLock(simulatorControlLockPath, simulatorControlTimeoutMs, callback);
}

async function updateLane(key, callback) {
	return withRegistryLock(async (registry) => {
		const current = registry.lanes[key];
		if (!current) throw new Error(`Lane ${key} was released.`);
		callback(current);
		current.updatedAt = now();
		return current;
	});
}

async function updateLaneIfPresent(key, callback) {
	return withRegistryLock(async (registry) => {
		const current = registry.lanes[key];
		if (current) {
			callback(current);
			current.updatedAt = now();
		}
		return current ?? null;
	});
}

function releaseLaneResources(registry, lane) {
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

function targetResourceKey(target) {
	return target.kind === "simulator" ? `simulator:${target.udid}` : `physical:${target.alias}`;
}

async function collectEvidence(lane) {
	const checks = [];
	const bootstrap = localBootstrapStatus({ projectRoot: repoRoot });
	checks.push(check("bootstrap", bootstrap.ok, bootstrap.ok ? "receipt current" : bootstrap.reasons.join("; ")));
	checks.push(check("worktree", path.resolve(lane.worktree) === repoRoot, lane.worktree));
	checks.push(check("metro-process", metroProcessOwned(lane), `pid ${lane.metro.pid ?? "none"}`));
	checks.push(await metroIdentityCheck(lane));
	if (lane.target.kind === "simulator") {
		const device = readSimulatorDevices().find((item) => item.udid === lane.target.udid);
		checks.push(check("simulator-booted", device?.state === "Booted", device?.state ?? "missing"));
		checks.push(
			check(
				"app-installed",
				Boolean(installedSimulatorAppPath(lane.target.udid)),
				appId,
			),
		);
		const marker = readDeviceMarker(lane.target.udid);
		checks.push(
			check(
				"native-fingerprint",
				Boolean(lane.native?.fingerprint && marker?.fingerprint === lane.native.fingerprint),
				lane.native?.decision ?? "missing",
			),
		);
		checks.push(
			check(
				"rendered-app",
				Boolean(lane.render?.verifiedAt && existsSync(lane.render?.screenshot)),
				lane.render?.screenshot ?? "not verified",
			),
		);
	} else {
		checks.push(check("physical-reserved", true, "joint device validation remains pending"));
	}
	if (lane.backend === "local") {
		const running = readLocalSupabaseStatus({ allowFailure: true });
		let compatible = false;
		let detail = "not running";
		if (running) {
			try {
				const detected = detectRunningBackend();
				assertBackendCompatible(detected);
				compatible = true;
				detail = detected.mountWorktree ?? "mount unknown";
			} catch (error) {
				detail = error.message;
			}
		}
		checks.push(check("shared-backend", compatible, detail));
	} else checks.push(check("preview-backend", true, "EAS Preview development environment"));
	const registry = readRegistry();
	const lease = registry.resources.controllers[targetResourceKey(lane.target)];
	checks.push(
		check(
			"controller-writer",
			lease?.ownerKey === lane.key && lease?.controller === lane.controller?.controller,
			lease ? `${lease.controller}:${lease.ownerKey}` : "missing",
		),
	);
	return {
		checks,
		generatedAt: now(),
		lane: {
			backend: lane.backend,
			client: lane.client,
			controller: lane.controller?.controller ?? null,
			key: lane.key,
			metroPort: lane.metro.port,
			nativeDecision: lane.native?.decision ?? null,
			target: lane.target,
			testRunId: lane.testRunId,
			worktree: lane.worktree,
		},
		passed: checks.every((item) => item.ok),
		physicalJointTestPending: lane.target.kind === "physical",
		version: 1,
	};
}

async function metroIdentityCheck(lane) {
	try {
		await waitForMetroIdentity(lane);
		return check("metro-identity", true, `port ${lane.metro.port}`);
	} catch (error) {
		return check("metro-identity", false, error.message);
	}
}

function check(name, ok, detail) {
	return { detail: String(detail), name, ok: Boolean(ok) };
}

function writeEvidence(lane, evidence) {
	writeFileSync(lane.evidenceFile, `${JSON.stringify(evidence, null, 2)}\n`, {
		mode: 0o600,
	});
}

function failedCheckNames(evidence) {
	return evidence.checks.filter((item) => !item.ok).map((item) => item.name);
}

function backendProjectId() {
	const match = readFileSync(path.join(backendRoot, "supabase/config.toml"), "utf8").match(
		/^project_id\s*=\s*"([^"]+)"/m,
	);
	if (!match) throw new Error("Supabase config has no root project_id.");
	return match[1];
}

function detectRunningBackend() {
	const container = `supabase_edge_runtime_${backendProjectId()}`;
	const result = spawnSync("docker", ["inspect", "--format", "{{json .Mounts}}", container], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	let mountWorktree = null;
	if (result.status === 0) {
		try {
			const mounts = JSON.parse(result.stdout);
			const backendFunctionsSuffix =
				`/${profile.backend.root}/supabase/functions`;
			const functionsMount = mounts.find((mount) =>
				String(mount.Destination).endsWith(backendFunctionsSuffix),
			);
			const source = functionsMount?.Source?.replace(/^\/host_mnt/, "");
			if (source && source.endsWith(backendFunctionsSuffix)) {
				mountWorktree = source.slice(0, -backendFunctionsSuffix.length);
			}
		} catch {
			// Mount remains unknown; compatibility check below fails safely.
		}
	}
	const existing = readRegistry().backend;
	return {
		compatibility: mountWorktree && existsSync(mountWorktree) ? backendContract(mountWorktree) : null,
		createdAt: existing?.createdAt ?? now(),
		managed: Boolean(existing?.managed && existing.mountWorktree === mountWorktree),
		mountWorktree,
		ownerKey: existing?.ownerKey ?? null,
	};
}

function assertBackendCompatible(detected) {
	if (!detected.mountWorktree || !detected.compatibility) {
		throw new Error("Could not prove the running Supabase stack's source worktree.");
	}
	const current = backendContract(repoRoot);
	if (detected.compatibility.hash !== current.hash) {
		throw new Error(
			`Running Supabase is mounted from ${detected.mountWorktree} with a different backend contract. Coordinate with its owner; ordinary lane startup will not remount it.`,
		);
	}
}

function backendContract(worktree) {
	const relativePaths = collectBackendContractPaths(worktree);
	const hash = createHash("sha256");
	for (const relative of relativePaths) {
		hash.update(relative);
		hash.update("\0");
		hash.update(readFileSync(path.join(worktree, relative)));
		hash.update("\0");
	}
	return {
		fileCount: relativePaths.length,
		hash: hash.digest("hex"),
	};
}

function collectBackendContractPaths(worktree) {
	const roots = profile.backend.contractPaths;
	const files = [];
	for (const relative of roots) {
		const absolute = path.join(worktree, relative);
		if (!existsSync(absolute)) continue;
		if (statSync(absolute).isDirectory()) collectFiles(absolute, worktree, files);
		else files.push(relative);
	}
	return files.sort();
}

function collectFiles(directory, worktree, output) {
	for (const entry of readdirSync(directory, { withFileTypes: true })) {
		const absolute = path.join(directory, entry.name);
		if (entry.isDirectory()) collectFiles(absolute, worktree, output);
		else if (entry.isFile()) output.push(path.relative(worktree, absolute));
	}
}

function availableBackendSecretNames(config) {
	const output = runCaptured("doppler", [
		"secrets",
		"--only-names",
		"--json",
		"--project",
		profile.backend.dopplerProject,
		"--config",
		config,
	]).stdout;
	let names;
	try {
		names = new Set(Object.keys(JSON.parse(output)));
	} catch {
		throw new Error("Doppler returned invalid names-only JSON.");
	}
	const referenced = envReferences(path.join(backendRoot, "supabase/config.toml"));
	const available = referenced.filter((name) => names.has(name));
	if (available.length === 0) throw new Error("No Supabase config secret names are available in Doppler.");
	return available;
}

function redactBackendRegistry(backend) {
	if (!backend) return null;
	return {
		compatibility: backend.compatibility,
		createdAt: backend.createdAt,
		managed: backend.managed,
		mountWorktree: backend.mountWorktree,
		ownerKey: backend.ownerKey,
	};
}

function readGitCommonDirectory() {
	const result = spawnSync("git", ["rev-parse", "--git-common-dir"], {
		cwd: repoRoot,
		encoding: "utf8",
	});
	if (result.status !== 0) throw new Error("Could not determine the shared git directory.");
	return path.resolve(repoRoot, result.stdout.trim());
}

function runCaptured(command, args, cwd = repoRoot, options = {}) {
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

function runInherited(command, args, cwd, environment = process.env) {
	const result = spawnSync(command, args, { cwd, env: environment, stdio: "inherit" });
	if (result.status !== 0) {
		throw new Error(`${command} ${args.join(" ")} failed with exit ${result.status}.`);
	}
}

function runQuiet(command, args) {
	spawnSync(command, args, { cwd: repoRoot, stdio: "ignore" });
}

function hashText(value) {
	return createHash("sha256").update(value).digest("hex");
}

function safeKey(key) {
	return key.replace(/[^A-Za-z0-9._-]/g, "-");
}

function now() {
	return new Date().toISOString();
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

function printBackend(backend) {
	if (!backend) {
		console.log("Shared Supabase owner: stopped or not yet detected.");
		return;
	}
	console.log(
		backend.managed
			? `Shared Supabase owner: ${backend.ownerKey} (${backend.mountWorktree}).`
			: `Shared Supabase owner: external (${backend.mountWorktree ?? "mount unknown"}).`,
	);
}

function sleep(milliseconds) {
	return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}

function printHelp() {
	console.log(`Usage:
  ios-session-lane up --client <claude|codex> --session-id <id> --preset <simulator-local|simulator-preview|simulator-preview-tailscale|iphone-preview>
  ios-session-lane up --client <claude|codex> --session-id <id> --target <target> --backend <local|preview> --expose <local|tailscale>
  ios-session-lane status|doctor --client <client> --session-id <id> [--json]
  ios-session-lane list [--json]
  ios-session-lane down --client <client> --session-id <id>
  ios-session-lane reap [--stale-after-minutes 120]
  ios-session-lane simulator-recheck --udid <simulator-udid>
  ios-session-lane controller-acquire --client <client> --session-id <id> --controller <agent-device|argent|maestro|xcodebuildmcp> [--force-controller]
  ios-session-lane controller-release --client <client> --session-id <id>
  ios-session-lane control --client <client> --session-id <id> -- <agent-device args>
  ios-session-lane maestro --client <client> --session-id <id> -- <maestro args>
  ios-session-lane backend-up|backend-down --client <client> --session-id <id>
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
