import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync } from "node:fs";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { requireIdentifier, safeKey, sessionKey } from "./lane-identifiers.mjs";
import { withFileLock } from "./lane-lock.mjs";
import { installedSimulatorAppPath } from "./lane-native.mjs";
import {
	controllerStateRoot,
	evidenceRoot,
	laneHome,
	now,
	profile,
	repoRoot,
	runCaptured,
	runInherited,
} from "./lane-runtime-context.mjs";
import {
	readRegistry,
	targetResourceKey,
	updateLane,
	withRegistryLock,
} from "./lane-state.mjs";

const appScheme = profile.mobile.scheme;
const appId = profile.mobile.appId;
const simulatorRenderTimeoutMs = profile.mobile.renderTimeoutSeconds * 1000;
const managedControllers = new Set(["agent-device", "argent", "maestro", "xcodebuildmcp"]);
const agentDeviceStartupLockPath = path.join(laneHome, "agent-device-startup.lock");
const controllerOperationTimeoutMs = 35 * 60 * 1000;

export function controllerOperationLockPath(target) {
	return path.join(
		laneHome,
		`controller-operation-${safeKey(targetResourceKey(target))}.lock`,
	);
}

export function withTargetControllerOperation(target, callback) {
	return withFileLock(
		controllerOperationLockPath(target),
		controllerOperationTimeoutMs,
		callback,
	);
}

function assertSession(options) {
	requireIdentifier(options.client, "client");
	requireIdentifier(options.sessionId, "session id");
}

function assertControllerChoice(controller) {
	if (!managedControllers.has(controller)) throw new Error(`Unknown controller ${controller}.`);
}

async function getLane(client, sessionId) {
	return readRegistry().lanes[sessionKey(client, sessionId)] ?? null;
}

export async function controllerAcquire(options, suppliedLane = null) {
	assertSession(options);
	assertControllerChoice(options.controller);
	const initialLane = suppliedLane ?? (await getLane(options.client, options.sessionId));
	if (!initialLane) throw new Error("Acquire an iOS lane before selecting a controller.");
	const expectedResource = targetResourceKey(initialLane.target);
	const lease = await withTargetControllerOperation(initialLane.target, async () => {
		const { lane: before, registry: beforeRegistry } = currentRegistryLaneOnExpectedTarget(
			initialLane.key,
			expectedResource,
			initialLane.createdAt,
		);
		const currentController = before.controller?.controller ?? null;
		if (
			currentController &&
			!laneWriterLeaseIsCurrent(beforeRegistry, before, currentController)
		) {
			throw new Error(
				`Controller ownership for ${initialLane.key} is inconsistent; refusing to switch or drive ${expectedResource}.`,
			);
		}
		if (
			currentController &&
			currentController !== options.controller &&
			!options.forceController
		) {
			throw new Error(
				`${initialLane.key} already uses ${currentController}. Release it or pass --force-controller to switch.`,
			);
		}
		if (currentController === "agent-device" && currentController !== options.controller) {
			closeAgentDeviceStrict(before);
		}
		return withRegistryLock(async (registry) => {
			const current = registry.lanes[initialLane.key];
			assertExpectedTarget(current, initialLane.key, expectedResource, initialLane.createdAt);
			const resource = targetResourceKey(current.target);
			const controller = current.controller?.controller ?? null;
			if (controller !== currentController) {
				throw new Error(`Controller ownership for ${initialLane.key} changed during transition; retry.`);
			}
			const existing = registry.resources.controllers[resource];
			if (existing && existing.ownerKey !== initialLane.key) {
				throw new Error(`${resource} input is owned by ${existing.ownerKey} through ${existing.controller}.`);
			}
			if (existing && existing.controller !== currentController) {
				throw new Error(`${resource} input changed from ${currentController ?? "unassigned"} to ${existing.controller}; retry the switch.`);
			}
			const value = {
				acquiredAt: now(),
				controller: options.controller,
				ownerKey: initialLane.key,
				resource,
			};
			registry.resources.controllers[resource] = value;
			current.controller = value;
			current.updatedAt = now();
			return value;
		});
	});
	if (!options.quiet) console.log(`${lease.controller} owns input for ${lease.resource}.`);
	return lease;
}

export async function controllerRelease(options) {
	assertSession(options);
	const key = sessionKey(options.client, options.sessionId);
	const initialLane = await getLane(options.client, options.sessionId);
	if (!initialLane) {
		if (!options.quiet) console.log("No controller lease held.");
		return null;
	}
	const expectedResource = targetResourceKey(initialLane.target);
	const released = await withTargetControllerOperation(initialLane.target, async () => {
		const { lane: before, registry: beforeRegistry } = currentRegistryLaneOnExpectedTarget(
			key,
			expectedResource,
			initialLane.createdAt,
		);
		if (!before.controller) {
			const staleLease = beforeRegistry.resources.controllers[expectedResource];
			if (!staleLease || staleLease.ownerKey !== key) return null;
			if (staleLease.controller === "agent-device") closeAgentDeviceStrict(before);
			return withRegistryLock(async (registry) => {
				const lane = registry.lanes[key];
				assertExpectedTarget(lane, key, expectedResource, initialLane.createdAt);
				const currentLease = registry.resources.controllers[expectedResource];
				if (
					lane.controller ||
					currentLease?.ownerKey !== key ||
					currentLease?.controller !== staleLease.controller
				) {
					throw new Error(`Controller ownership for ${key} changed during stale lease cleanup; retry.`);
				}
				delete registry.resources.controllers[expectedResource];
				lane.updatedAt = now();
				return expectedResource;
			});
		}
		if (!laneWriterLeaseIsCurrent(beforeRegistry, before, before.controller.controller)) {
			throw new Error(
				`Controller ownership for ${key} is inconsistent; refusing to release ${expectedResource}.`,
			);
		}
		if (before.controller.controller === "agent-device") closeAgentDeviceStrict(before);
		return withRegistryLock(async (registry) => {
			const lane = registry.lanes[key];
			assertExpectedTarget(lane, key, expectedResource, initialLane.createdAt);
			if (lane.controller?.controller !== before.controller.controller) {
				throw new Error(`Controller ownership for ${key} changed during release; retry.`);
			}
			const resource = lane.controller.resource;
			const currentLease = registry.resources.controllers[resource];
			if (
				resource !== expectedResource ||
				currentLease?.ownerKey !== key ||
				currentLease?.controller !== before.controller.controller
			) {
				throw new Error(`Controller ownership for ${key} changed during release; retry.`);
			}
			delete registry.resources.controllers[resource];
			lane.controller = null;
			lane.updatedAt = now();
			return resource;
		});
	});
	if (!options.quiet) console.log(released ? `Released input for ${released}.` : "No controller lease held.");
	return released;
}

export async function runController(options, kind = "agent-device") {
	assertSession(options);
	const lane = await getLane(options.client, options.sessionId);
	if (!lane) throw new Error("Acquire an iOS lane before running a controller.");
	return withLaneWriterOperation(lane, kind, (current) => {
		if (kind === "agent-device") return runAgentDevice(current, options.controllerArgs);
		if (kind === "maestro") return runMaestro(current, options.controllerArgs);
		throw new Error(`${kind} is used through its MCP tools after acquiring the lane lease.`);
	});
}

function assertExpectedTarget(lane, key, expectedResource, expectedCreatedAt = null) {
	if (!lane) throw new Error(`Lane ${key} was released.`);
	if (expectedCreatedAt && lane.createdAt !== expectedCreatedAt) {
		throw new Error(`Lane ${key} was replaced while its controller operation was waiting; retry.`);
	}
	const currentResource = targetResourceKey(lane.target);
	if (currentResource !== expectedResource) {
		throw new Error(
			`Lane ${key} changed target from ${expectedResource} to ${currentResource}; retry the controller operation.`,
		);
	}
}

export function laneWriterLeaseIsCurrent(registry, lane, controller) {
	if (!lane?.target || !lane?.controller) return false;
	const resource = targetResourceKey(lane.target);
	const lease = registry?.resources?.controllers?.[resource];
	return Boolean(
		lane.controller.controller === controller &&
		lane.controller.resource === resource &&
		lane.controller.ownerKey === lane.key &&
		lease?.controller === controller &&
		lease?.ownerKey === lane.key &&
		lease?.resource === resource,
	);
}

function currentRegistryLaneOnExpectedTarget(key, expectedResource, expectedCreatedAt) {
	const registry = readRegistry();
	const lane = registry.lanes[key];
	assertExpectedTarget(lane, key, expectedResource, expectedCreatedAt);
	return { lane, registry };
}

async function withLaneWriterOperation(initialLane, controller, callback) {
	assertControllerChoice(controller);
	const expectedResource = targetResourceKey(initialLane.target);
	return withTargetControllerOperation(initialLane.target, async () => {
		const registry = readRegistry();
		const current = registry.lanes[initialLane.key];
		assertExpectedTarget(current, initialLane.key, expectedResource, initialLane.createdAt);
		if (!laneWriterLeaseIsCurrent(registry, current, controller)) {
			throw new Error(
				`${controller} cannot control ${expectedResource} without the current lane writer lease.`,
			);
		}
		return callback(structuredClone(current));
	});
}

export async function connectTarget(lane) {
	if (lane.target.kind === "simulator") return connectSimulator(lane);
	return withLaneWriterOperation(lane, "agent-device", (current) =>
		runAgentDevice(current, ["open", developmentClientUrl(current)]),
	);
}

async function connectSimulator(lane) {
	try {
		await verifyFreshRenderedSimulatorApp(lane);
	} catch (error) {
		error.code = "SIMULATOR_RENDER_FAILED";
		throw error;
	}
}

export async function verifyFreshRenderedSimulatorApp(lane) {
	return withLaneWriterOperation(lane, "agent-device", verifyFreshRenderedSimulatorAppLocked);
}

async function verifyFreshRenderedSimulatorAppLocked(lane) {
	if (lane.target.kind !== "simulator") {
		throw new Error("Rendered simulator proof requires a simulator lane.");
	}
	let reloads = 0;
	let manualConnections = 0;
	let renderedObservations = 0;
	let metroLogOffset = 0;
	let snapshot = "";
	await withFileLock(agentDeviceStartupLockPath, 5 * 60 * 1000, async () => {
		if (!installedSimulatorAppPath(lane.target.udid)) {
			throw new Error(`Could not launch ${lane.target.name}; its compatible local binary is missing.`);
		}
		metroLogOffset = existsSync(lane.logFile) ? statSync(lane.logFile).size : 0;
		terminateSimulatorApp(lane);
		agentDeviceCaptured(lane, ["open", developmentClientUrl(lane)]);
	});
	const deadline = Date.now() + simulatorRenderTimeoutMs;
	let freshMetroBundle = false;
	while (Date.now() < deadline) {
		freshMetroBundle ||= metroLogHasMainBundleSince(lane.logFile, metroLogOffset);
		snapshot = agentDeviceCaptured(lane, ["snapshot", "-i"]);
		if (/\[alert\] "Open in .*PUMPD Development.*\?"/.test(snapshot) && /\[button\] "Open"/.test(snapshot)) {
			pressSnapshotElement(lane, snapshot, /\[button\] "Open"/);
			continue;
		}
		if (/Error loading app/i.test(snapshot) && /\[button\] "OK"/.test(snapshot)) {
			pressSnapshotElement(lane, snapshot, /\[button\] "OK"/);
			continue;
		}
		if (/problem loading the project|failed to load app|request.*timed out/i.test(snapshot)) {
			if (reloads >= 2) break;
			reloads += 1;
			pressSnapshotElement(lane, snapshot, /\[button\] "Reload"/);
			continue;
		}
		if (manualConnections < 2) {
			const action = manualUrlAction(snapshot, lane.metro.url);
			if (action?.kind === "enter") {
				pressSnapshotLine(lane, action.line);
				continue;
			}
			if (action?.kind === "focus") {
				pressSnapshotLine(lane, action.line);
				agentDeviceCaptured(lane, ["type", lane.metro.url]);
				continue;
			}
			if (action?.kind === "connect") {
				manualConnections += 1;
				pressSnapshotLine(lane, action.line);
				await delay(2_000);
				continue;
			}
		}
		if (/DEVELOPMENT SERVERS/.test(snapshot)) {
			const selected = pressDevelopmentServerIfPresent(lane, snapshot);
			if (selected) continue;
		}
		if (/\[button\] "Continue"/.test(snapshot)) {
			pressSnapshotElement(lane, snapshot, /\[button\] "Continue"/);
			continue;
		}
		if ((/Runtime version:|CUSTOM MENU ITEMS/.test(snapshot) && /\[button\] "Close"/.test(snapshot))) {
			pressSnapshotElement(lane, snapshot, /\[button\] "Close"/);
			continue;
		}
		if (snapshotLooksRendered(snapshot)) {
			if (!freshMetroBundle) {
				await delay(1_000);
				continue;
			}
			renderedObservations += 1;
			if (renderedObservations >= 2) break;
			await delay(2_000);
			continue;
		}
		renderedObservations = 0;
		await delay(1_500);
	}
	if (!snapshotLooksRendered(snapshot)) {
		throw new Error(`The assigned simulator did not reach a rendered PUMPD screen.\n${snapshot}`);
	}
	if (!freshMetroBundle) {
		throw new Error(
			`The assigned simulator rendered PUMPD, but its dedicated Metro did not log a fresh main-bundle connection after launch.`,
		);
	}
	await delay(750);
	const screenshot = path.join(evidenceRoot, `${safeKey(lane.key)}-render.png`);
	rmSync(screenshot, { force: true });
	agentDeviceCaptured(lane, ["screenshot", screenshot]);
	const screenshotIdentity = renderScreenshotIdentity(screenshot);
	if (!screenshotIdentity) throw new Error("agent-device did not produce a non-empty render screenshot.");
	const verifiedAt = now();
	const render = {
		controller: "agent-device",
		metroConnectionVerifiedAt: verifiedAt,
		screenshot,
		...screenshotIdentity,
		verifiedAt,
	};
	await updateLane(lane.key, (current) => {
		assertExpectedTarget(current, lane.key, targetResourceKey(lane.target), lane.createdAt);
		if (current.controller?.controller !== "agent-device") {
			throw new Error(
				`Lane ${lane.key} lost its agent-device writer lease before render proof was saved.`,
			);
		}
		current.render = render;
	});
	return render;
}

export function manualUrlAction(snapshot, url) {
	const lines = snapshot.split("\n");
	const field = lines.find((line) => /\[text-field\].*\[editable\]/.test(line));
	if (field) {
		const connect = lines.find(
			(line) => /\[button\] "Connect"/.test(line) && !/\[disabled\]/.test(line),
		);
		if (field.includes(`"${url}"`) && connect) return { kind: "connect", line: connect };
		if (!/\[text-field\] ".+"/.test(field)) return { kind: "focus", line: field };
		return null;
	}
	const enter = lines.find((line) => /\[button\] "Enter URL manually"/.test(line));
	return enter ? { kind: "enter", line: enter } : null;
}

export function snapshotLooksRendered(snapshot) {
	return Boolean(
		/^@[^ ]+ \[application\] "PUMPD"(?:\s|$)/m.test(snapshot) &&
		!/\[alert\]|SpringBoard|Home Screen|Development Build|DEVELOPMENT SERVERS|Error loading app|problem loading the project|failed to load app|request.*timed out|Loading PUMPD|SplashScreenLogo/i.test(snapshot) &&
		/^Snapshot: [1-9][0-9]* visible nodes/m.test(snapshot) &&
		/\[(?:text|button|cell|scroll-area)\]/.test(snapshot),
	);
}

export function metroLogShowsMainBundle(logText) {
	const mainModule = `${profile.mobile.root.replace(/\\/g, "/")}/index.js`;
	return String(logText)
		.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "")
		.split(/\r?\n/)
		.some((line) => line.includes("iOS Bundled") && line.includes(mainModule));
}

function metroLogHasMainBundleSince(logFile, offset) {
	try {
		const contents = readFileSync(logFile);
		if (contents.length <= offset) return false;
		return metroLogShowsMainBundle(contents.subarray(offset).toString("utf8"));
	} catch {
		return false;
	}
}

export function renderScreenshotIdentity(screenshot) {
	try {
		const stat = statSync(screenshot);
		if (!stat.isFile() || stat.size <= 0) return null;
		return {
			screenshotBytes: stat.size,
			screenshotModifiedAt: stat.mtime.toISOString(),
			screenshotSha256: createHash("sha256").update(readFileSync(screenshot)).digest("hex"),
		};
	} catch {
		return null;
	}
}

export function renderEvidenceMatchesScreenshot(render) {
	const current = renderScreenshotIdentity(render?.screenshot);
	return Boolean(
		current &&
		render?.screenshotBytes === current.screenshotBytes &&
		render?.screenshotModifiedAt === current.screenshotModifiedAt &&
		render?.screenshotSha256 === current.screenshotSha256,
	);
}

function pressDevelopmentServerIfPresent(lane, snapshot) {
	const line = snapshot
		.split("\n")
		.find(
			(entry) =>
				/\[(?:button|cell)\]/.test(entry) &&
				entry.includes("PUMPD Development") &&
				entry.includes(lane.metro.url),
		);
	if (!line) return false;
	pressSnapshotLine(lane, line);
	return true;
}

function pressSnapshotElement(lane, snapshot, pattern) {
	const line = snapshot.split("\n").find((entry) => pattern.test(entry));
	pressSnapshotLine(lane, line, pattern);
}

function pressSnapshotLine(lane, line, description = "the selected element") {
	const reference = line?.match(/^(@[^ ]+)/)?.[1];
	if (!reference) throw new Error(`Could not resolve an agent-device element reference for ${description}.`);
	agentDeviceCaptured(lane, ["press", reference, "--settle"]);
}

function agentDeviceCaptured(lane, commandArgs) {
	const stateDirectory = path.join(controllerStateRoot, safeKey(lane.key), "agent-device");
	mkdirSync(stateDirectory, { recursive: true, mode: 0o700 });
	const args = [...commandArgs];
	appendFlag(args, "--platform", "ios");
	appendFlag(args, "--udid", agentDeviceTarget(lane));
	appendFlag(args, "--session", safeKey(lane.key));
	const result = runCaptured(
		"corepack",
		["pnpm", "dlx", `agent-device@${profile.controllers.agentDeviceVersion}`, ...args],
		repoRoot,
		{
			env: { ...process.env, AGENT_DEVICE_STATE_DIR: stateDirectory },
			timeout: 2 * 60 * 1000,
		},
	);
	return `${result.stdout ?? ""}${result.stderr ?? ""}`;
}

function developmentClientUrl(lane) {
	return `${appScheme}://expo-development-client/?url=${encodeURIComponent(lane.metro.url)}&disableOnboarding=1`;
}

function runAgentDevice(lane, providedArgs) {
	const stateDirectory = path.join(controllerStateRoot, safeKey(lane.key), "agent-device");
	mkdirSync(stateDirectory, { recursive: true, mode: 0o700 });
	let args = [...providedArgs];
	if (args.length === 0) args = ["snapshot", "-i"];
	assertNoReservedControllerFlags(args, ["--platform", "--device", "--udid", "--session", "-d"]);
	appendFlag(args, "--platform", "ios");
	appendFlag(args, "--udid", agentDeviceTarget(lane));
	appendFlag(args, "--session", safeKey(lane.key));
	runInherited(
		"corepack",
		["pnpm", "dlx", `agent-device@${profile.controllers.agentDeviceVersion}`, ...args],
		repoRoot,
		{ ...process.env, AGENT_DEVICE_STATE_DIR: stateDirectory },
	);
}

export function agentDeviceTarget(lane) {
	const target = lane.target.kind === "physical" ? lane.target.deviceId : lane.target.udid;
	if (!target) throw new Error(`Lane ${lane.key ?? "target"} is missing its agent-device identifier.`);
	return target;
}

export function closeAgentDeviceStrict(lane) {
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

export function closeAgentDeviceBestEffort(lane, quiet = false) {
	try {
		closeAgentDeviceStrict(lane);
	} catch (error) {
		if (!quiet) {
			console.warn(`[ios-lane] Could not close the stale agent-device session for ${lane.key}: ${error.message}`);
		}
	}
}

export function simulatorAppTerminationSucceeded(result = {}) {
	if (result.status === 0) return true;
	if (result.error) return false;
	const output = `${result.stderr ?? ""}\n${result.stdout ?? ""}`;
	return /found nothing to terminate|application is not running|no such process/i.test(output);
}

function terminateSimulatorApp(lane) {
	const result = spawnSync("xcrun", ["simctl", "terminate", lane.target.udid, appId], {
		cwd: repoRoot,
		encoding: "utf8",
		timeout: 30_000,
	});
	if (simulatorAppTerminationSucceeded(result)) return;
	const detail = (
		result.error?.message ||
		result.stderr ||
		result.stdout ||
		`exit ${result.status ?? "unknown"}`
	).trim();
	throw new Error(
		`Could not terminate ${appId} on assigned simulator ${lane.target.udid} before fresh render proof: ${detail}`,
	);
}

function runMaestro(lane, providedArgs) {
	if (providedArgs.length === 0) throw new Error("Maestro requires arguments after --.");
	if (lane.target.kind !== "simulator") {
		throw new Error("This lane's Maestro adapter is simulator-only until the joint physical-device test.");
	}
	const args = [...providedArgs];
	assertNoReservedControllerFlags(args, ["--udid", "--device"]);
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

export function assertNoReservedControllerFlags(args, flags) {
	const reserved = new Set(flags);
	const conflict = args.find((arg) => {
		if (reserved.has(arg)) return true;
		return [...reserved].some((flag) => flag.startsWith("--") && arg.startsWith(`${flag}=`));
	});
	if (conflict) {
		throw new Error(`${conflict} is owned by the iOS lane and cannot be supplied after --.`);
	}
}
