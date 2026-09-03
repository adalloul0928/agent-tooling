import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import {
	closeAgentDeviceStrict,
	withTargetControllerOperation,
} from "./lane-controller.mjs";
import { withFileLock } from "./lane-lock.mjs";
import {
	laneHome,
	now,
	profile,
	repoRoot,
	runCaptured,
	simulatorControlLockPath,
} from "./lane-runtime-context.mjs";
import { readRegistry, targetResourceKey, withRegistryLock } from "./lane-state.mjs";

const maxSimulatorLanes = profile.simulators.maximum;
const simulatorNamePrefix = profile.simulators.namePrefix;
const simulatorDeviceType = profile.simulators.deviceType;
const maxIosRuntimeMajor = Number(
	process.env.IOS_SESSION_LANES_MAX_RUNTIME_MAJOR ?? profile.simulators.maximumRuntimeMajor,
);
const simulatorBootTimeoutMs = profile.simulators.bootTimeoutSeconds * 1000;
const simulatorControlTimeoutMs =
	maxSimulatorLanes * profile.simulators.bootTimeoutSeconds * 1000 + 60_000;
const physicalDeviceAliases = profile.physicalDevices;

export function ensureSimulator(registry, excludedKey = "") {
	const devices = readSimulatorDevices();
	for (const [udid, entry] of Object.entries(registry.resources.simulatorCooldown ?? {})) {
		if (Date.parse(entry.retryAfter) <= Date.now()) delete registry.resources.simulatorCooldown[udid];
	}
	const coolingDown = new Set(Object.keys(registry.resources.simulatorCooldown ?? {}));
	const quarantined = new Set(Object.keys(registry.resources.simulatorQuarantine ?? {}));
	const assignedSimulatorLanes = Object.values(registry.lanes).filter(
		(lane) => lane.key !== excludedKey && lane.target.kind === "simulator",
	);
	const assigned = new Set(assignedSimulatorLanes.map((lane) => lane.target.udid));
	if (assignedSimulatorLanes.length >= maxSimulatorLanes) {
		throw new Error(`All ${maxSimulatorLanes} ${profile.displayName} simulator lanes are assigned.`);
	}
	const reusable = selectReusableSimulator(devices, {
		assigned,
		coolingDown,
		quarantined,
	});
	if (reusable) return simulatorTarget(reusable);
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
	throw new Error(`All ${maxSimulatorLanes} ${profile.displayName} simulator lanes are assigned.`);
}

export function selectReusableSimulator(
	devices,
	{ assigned = new Set(), coolingDown = new Set(), quarantined = new Set() } = {},
) {
	const assignedUdids = new Set(assigned);
	const coolingDownUdids = new Set(coolingDown);
	const quarantinedUdids = new Set(quarantined);
	return (
		devices
			.filter(
				(device) =>
					managedSimulatorNumber(device.name) !== null &&
					(!device.deviceTypeIdentifier || device.deviceTypeIdentifier === simulatorDeviceType) &&
					iosRuntimeMajor(device.runtimeIdentifier) <= maxIosRuntimeMajor &&
					!quarantinedUdids.has(device.udid) &&
					!coolingDownUdids.has(device.udid) &&
					!assignedUdids.has(device.udid),
			)
			.sort((left, right) => {
				const numberDifference =
					managedSimulatorNumber(left.name) - managedSimulatorNumber(right.name);
				if (numberDifference !== 0) return numberDifference;
				const leftUdid = String(left.udid);
				const rightUdid = String(right.udid);
				return leftUdid < rightUdid ? -1 : leftUdid > rightUdid ? 1 : 0;
			})[0] ?? null
	);
}

export function managedSimulatorNumber(name) {
	const match = String(name).match(
		new RegExp(`^${escapeRegExp(simulatorNamePrefix)}([1-9][0-9]*)$`),
	);
	if (!match) return null;
	const number = Number(match[1]);
	return number <= maxSimulatorLanes ? number : null;
}

export async function cooldownAndReassignSimulator(key, lane, reason) {
	return markSimulatorHealth(key, lane, "cooldown", reason, { reassign: true });
}

export async function cooldownSimulatorWithoutReassignment(key, lane, reason) {
	return markSimulatorHealth(key, lane, "cooldown", reason, { reassign: false });
}

function escapeRegExp(value) {
	return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
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

export function readSimulatorDevices() {
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
	const output = JSON.parse(runCaptured("xcrun", ["simctl", "list", "runtimes", "--json"]).stdout);
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

export async function bootLaneSimulator(key, initialLane) {
	let lane = initialLane;
	for (let attempt = 1; attempt <= maxSimulatorLanes; attempt += 1) {
		try {
			await withTargetControllerOperation(lane.target, async () => {
				const current = readRegistry().lanes[key];
				assertSameSimulator(current, lane.target, key, lane.createdAt);
				await withFileLock(simulatorControlLockPath, simulatorControlTimeoutMs, async () =>
					bootSimulator(current.target.udid),
				);
			});
			return lane;
		} catch (error) {
			if (error.code !== "SIMULATOR_DATA_MIGRATION_FAILED") throw error;
			const failedTarget = lane.target;
			const recoveryAction =
				attempt === maxSimulatorLanes
					? "Quarantining it without deleting or erasing it; no further simulator will be allocated."
					: "Quarantining it without deleting or erasing it and allocating another simulator.";
			console.warn(
				`[ios-lane] ${failedTarget.name} (${failedTarget.udid}) ended with Data Migration Failed. ` +
					recoveryAction,
			);
			if (attempt === maxSimulatorLanes) {
				await markSimulatorHealth(key, lane, "quarantine", "Data Migration Failed", {
					reassign: false,
				});
				break;
			}
			lane = await quarantineAndReassignSimulator(key, lane, "Data Migration Failed");
		}
	}
	throw new Error(
		`No healthy simulator was found after ${maxSimulatorLanes} terminal migration failures. ` +
			"The failed devices were preserved and quarantined for manual CoreSimulator diagnosis.",
	);
}

async function quarantineAndReassignSimulator(key, lane, reason) {
	return markSimulatorHealth(key, lane, "quarantine", reason, { reassign: true });
}

async function markSimulatorHealth(key, lane, kind, reason, { reassign }) {
	const failedTarget = lane.target;
	if (failedTarget?.kind !== "simulator" || !failedTarget.udid) {
		throw new Error(`Lane ${key} has no simulator to mark ${kind}.`);
	}
	return withTargetControllerOperation(failedTarget, async () => {
		const snapshot = await withRegistryLock(async (registry) => {
			const current = registry.lanes[key];
			assertSameSimulator(current, failedTarget, key, lane.createdAt);
			if (kind === "quarantine") {
				registry.resources.simulatorQuarantine[failedTarget.udid] = {
					name: failedTarget.name,
					quarantinedAt: now(),
					reason: String(reason).slice(0, 500),
					runtimeIdentifier: failedTarget.runtimeIdentifier,
				};
			} else {
				registry.resources.simulatorCooldown[failedTarget.udid] = {
					name: failedTarget.name,
					reason: String(reason).slice(0, 500),
					recordedAt: now(),
					retryAfter: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
					runtimeIdentifier: failedTarget.runtimeIdentifier,
				};
			}
			current.updatedAt = now();
			return structuredClone(current);
		});
		if (!reassign) return snapshot;
		if (snapshot.controller?.controller === "agent-device") {
			closeAgentDeviceStrict(snapshot);
		}

		let allocationError = null;
		const reassigned = await withRegistryLock(async (registry) => {
			const current = registry.lanes[key];
			assertSameSimulator(current, failedTarget, key, lane.createdAt);
			releaseTargetController(registry, current);
			current.controller = null;
			current.native = null;
			current.render = null;
			try {
				current.target = ensureSimulator(registry, key);
			} catch (error) {
				allocationError = error;
			}
			current.updatedAt = now();
			return current;
		});
		if (allocationError) throw allocationError;
		return reassigned;
	});
}

function assertSameSimulator(current, expectedTarget, key, expectedCreatedAt) {
	if (!current) throw new Error(`Lane ${key} was released.`);
	if (expectedCreatedAt && current.createdAt !== expectedCreatedAt) {
		throw new Error(`Lane ${key} was replaced while simulator recovery was waiting.`);
	}
	if (
		current.target?.kind !== "simulator" ||
		current.target.udid !== expectedTarget.udid
	) {
		throw new Error(`Lane ${key} changed simulator while health recovery was running.`);
	}
}

function releaseTargetController(registry, lane) {
	const resource = targetResourceKey(lane.target);
	if (registry.resources.controllers[resource]?.ownerKey === lane.key) {
		delete registry.resources.controllers[resource];
	}
}

export function classifySimulatorBootResult(result = {}) {
	const output = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
	if (/Data Migration Failed/i.test(output)) {
		return { code: "SIMULATOR_DATA_MIGRATION_FAILED", message: "Data Migration Failed" };
	}
	if (result.error?.code === "ETIMEDOUT" || result.signal === "SIGTERM") {
		return {
			code: "SIMULATOR_BOOT_TIMEOUT",
			message: "the current bootstatus probe timed out",
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
	const deadline = Date.now() + simulatorBootTimeoutMs;
	let lastFailure = null;
	while (Date.now() < deadline) {
		const result = spawnSync("xcrun", ["simctl", "bootstatus", udid, "-b"], {
			cwd: repoRoot,
			encoding: "utf8",
			timeout: Math.min(15_000, Math.max(1_000, deadline - Date.now())),
		});
		lastFailure = classifySimulatorBootResult(result);
		if (!lastFailure) return;
		if (
			lastFailure.code === "SIMULATOR_DATA_MIGRATION_FAILED" &&
			simulatorSpringBoardIsReachable(udid)
		) {
			console.warn(
				`[ios-lane] Simulator ${udid} reported ${lastFailure.message}, but SpringBoard is reachable; ` +
					"continuing to the rendered-app health check.",
			);
			return;
		}
		if (lastFailure.code === "SIMULATOR_DATA_MIGRATION_FAILED") break;
		if (lastFailure.code === "SIMULATOR_BOOT_FAILED") break;
	}
	const failure = lastFailure ?? {
		code: "SIMULATOR_BOOT_TIMEOUT",
		message: `bootstatus exceeded ${Math.round(simulatorBootTimeoutMs / 1000)} seconds`,
	};
	const error = new Error(`Simulator ${udid} did not finish booting: ${failure.message}.`);
	error.code = failure.code;
	throw error;
}

function simulatorSpringBoardIsReachable(udid) {
	const result = spawnSync(
		"xcrun",
		["simctl", "spawn", udid, "launchctl", "print", "system/com.apple.SpringBoard"],
		{ cwd: repoRoot, encoding: "utf8", timeout: 15_000 },
	);
	return result.status === 0;
}

export function resolvePhysicalDevice(alias) {
	const config = physicalDeviceAliases[alias];
	const outputPath = path.join(laneHome, `devicectl-${process.pid}.json`);
	try {
		const result = spawnSync(
			"xcrun",
			["devicectl", "list", "devices", "--timeout", "5", "--json-output", outputPath],
			{ cwd: repoRoot, encoding: "utf8", timeout: 15_000 },
		);
		if (result.status !== 0 || !existsSync(outputPath)) return null;
		const candidates = collectDeviceObjects(JSON.parse(readFileSync(outputPath, "utf8")));
		const device = candidates.find((candidate) => {
			const name = candidate.name ?? candidate.deviceName ?? candidate.properties?.name;
			return config.displayNames.includes(name);
		});
		if (!device) return null;
		const deviceId =
			device.identifier ?? device.udid ?? device.deviceIdentifier ?? device.hardwareProperties?.udid;
		if (!deviceId) return null;
		return {
			alias,
			deviceId,
			jointTestRequired: true,
			kind: "physical",
			name: device.name ?? device.deviceName ?? device.properties?.name ?? config.displayNames[0],
		};
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

export function allocatePhysical(registry, target) {
	const conflict = Object.values(registry.lanes).find(
		(lane) => lane.target.kind === "physical" && lane.target.alias === target.alias,
	);
	if (conflict) throw new Error(`${target.alias} is already assigned to ${conflict.key}.`);
	return target;
}
