import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
	closeSync,
	existsSync,
	openSync,
	readFileSync,
	statSync,
} from "node:fs";
import { createServer } from "node:net";
import path from "node:path";
import {
	now,
	profile,
	repoRoot,
	runCaptured,
	tailscaleOperationLockPath,
} from "./lane-runtime-context.mjs";
import { withFileLock } from "./lane-lock.mjs";
import {
	captureOwnedProcessRecordOrCleanup,
	clearOwnedProcessRecord,
	inspectProcessIdentity,
	metroProcessOwned,
	ownedProcessRuntime,
	processGroupMemberIdentityMatches,
	stopOwnedMetroAndWait,
	stopOwnedProcessAndWait,
	trackedProcessIsLive,
	updateLane,
	withRegistryLock,
} from "./lane-state.mjs";

const firstMetroPort = profile.metro.firstPort;
const lastMetroPort = profile.metro.lastPort;
const metroReadyTimeoutMs = profile.metro.readyTimeoutSeconds * 1000;
const processStopTimeoutMs = 10_000;
const tailscaleStopTimeoutMs = 10_000;

export async function ensureMetroStarted(key, initialLane, environment, endpoint) {
	let lane = initialLane;
	if (metroProcessOwned(lane)) {
		await waitForMetroIdentity(lane, { requireTunnel: false });
		if (lane.exposure === "tailscale" && !ownedProcessRuntime(lane.metro.tailscale)) {
			lane = await startAndPersistTailscaleTunnel(key, lane);
		}
		await waitForMetroIdentity(lane);
		return lane;
	}

	for (let attempt = 0; attempt < 3; attempt += 1) {
		if (!(await isPortAvailable(lane.metro.port))) {
			lane = await reassignLanePort(key, lane);
		}
		const logOffset = existsSync(lane.logFile) ? statSync(lane.logFile).size : 0;
		try {
			const metro = await startMetro(lane, environment, endpoint);
			// Track the process in memory before persisting it. If the registry write
			// fails, the catch block still has the exact PID/start-time identity needed
			// to stop the process instead of orphaning a Metro server.
			lane = laneWithMetroProcess(lane, metro);
			lane = await updateLane(key, (current) => {
				current.metro = { ...current.metro, ...metro };
			});
			await waitForMetroIdentity(lane, { requireTunnel: false });
			if (lane.exposure === "tailscale") {
				lane = await startAndPersistTailscaleTunnel(key, lane);
				await waitForMetroIdentity(lane);
			}
			return lane;
		} catch (error) {
			const output = existsSync(lane.logFile)
				? readFileSync(lane.logFile).subarray(logOffset).toString("utf8")
				: "";
			await cleanupFailedMetroAttempt(lane);
			await clearMetroProcessMetadata(key, lane);
			if (
				!/EADDRINUSE|address already in use|TAILSCALE_SERVE_PORT_IN_USE/i.test(
					`${error.message}\n${output}`,
				)
			) {
				throw error;
			}
			lane = await reassignLanePort(key, lane);
		}
	}
	throw new Error("Metro could not claim a lane port after three collision-safe retries.");
}

export function laneWithMetroProcess(lane, metro) {
	return {
		...lane,
		metro: { ...lane.metro, ...metro },
	};
}

export function resolveMetroEndpoint(exposure) {
	if (exposure === "local") return { host: "127.0.0.1", scheme: "http" };
	const result = runCaptured("tailscale", ["status", "--json"]);
	let dnsName;
	try {
		dnsName = JSON.parse(result.stdout).Self?.DNSName?.replace(/\.$/, "");
	} catch {
		throw new Error("Tailscale returned invalid status JSON.");
	}
	if (!dnsName) throw new Error("Tailscale did not report this Mac's MagicDNS name.");
	return { host: dnsName, scheme: "https" };
}

export async function stopLaneMetroAndWait(lane) {
	const failures = [];
	if (lane.metro?.tailscale) {
		try {
			await disableTailscaleServe(lane);
		} catch (error) {
			failures.push(error.message);
		}
	}
	try {
		await stopOwnedMetroAndWait(lane, { timeoutMs: processStopTimeoutMs });
		assertNoOwnedMetroListener(lane);
		if (laneRuntimeIsLive(lane)) {
			throw new Error("an exact owned Metro or Tailscale process remained live after teardown");
		}
	} catch (error) {
		failures.push(error.message);
	}
	if (failures.length > 0) {
		throw new Error(`Could not fully stop lane runtime: ${failures.join("; ")}`);
	}
}

export function laneRuntimeIsLive(lane) {
	return trackedProcessIsLive(lane.metro) || trackedProcessIsLive(lane.metro?.tailscale);
}

export async function waitForMetroIdentity(lane, { requireTunnel = true } = {}) {
	const startedAt = Date.now();
	const localStatusUrl = `http://127.0.0.1:${lane.metro.port}/status`;
	while (Date.now() - startedAt < metroReadyTimeoutMs) {
		if (!metroProcessOwned(lane)) {
			throw new Error(`Metro exited during startup. Check ${lane.logFile}.`);
		}
		const localReady = await metroStatusReady(localStatusUrl);
		const commandReady = metroCommandMatchesLane(lane) && metroListenerOwned(lane);
		let tunnelReady = true;
		if (requireTunnel && lane.exposure === "tailscale") {
			tunnelReady =
				ownedProcessRuntime(lane.metro.tailscale) &&
				(await metroStatusReady(`${lane.metro.url}/status`));
		}
		if (localReady && commandReady && tunnelReady) return;
		await sleep(500);
	}
	const endpoint =
		requireTunnel && lane.exposure === "tailscale"
			? `${lane.metro.url}/status`
			: localStatusUrl;
	throw new Error(
		`Owned Metro process did not become ready at ${endpoint} for ${lane.worktree}.`,
	);
}

export async function metroIdentityCheck(lane) {
	try {
		await waitForMetroIdentity(lane);
		return {
			detail: `port ${lane.metro.port}`,
			name: "metro-identity",
			ok: true,
			status: "pass",
		};
	} catch (error) {
		return {
			detail: error.message,
			name: "metro-identity",
			ok: false,
			status: "fail",
		};
	}
}

export function tailscaleServeOffArgs(port) {
	return ["serve", `--https=${port}`, "--yes", "off"];
}

export function tailscaleServeStartArgs(port) {
	return ["serve", `--https=${port}`, `http://127.0.0.1:${port}`];
}

export function tailscaleStatusHasHttpsPort(status, port) {
	return tailscaleServeMappings(status).get(Number(port))?.https === true;
}

export function tailscaleServePorts(status) {
	return new Set(tailscaleServeMappings(status).keys());
}

export function tailscaleServeMappingMatchesLane(status, lane) {
	const record = lane?.metro?.tailscale;
	const port = Number(lane?.metro?.port);
	const expectedProxy = `http://127.0.0.1:${port}`;
	if (
		!record ||
		!Number.isInteger(port) ||
		record.serveHttpsPort !== port ||
		record.serveProxyUrl !== expectedProxy
	) {
		return false;
	}
	return exactTailscaleMappingMatches(tailscaleServeMappings(status).get(port), expectedProxy);
}

function tailscaleServeMappings(status) {
	const mappings = new Map();
	const mappingFor = (port) => {
		if (!mappings.has(port)) {
			mappings.set(port, { handlers: [], https: false });
		}
		return mappings.get(port);
	};
	const visit = (value) => {
		if (Array.isArray(value)) {
			for (const child of value) visit(child);
			return;
		}
		if (!value || typeof value !== "object") return;
		if (value.TCP && typeof value.TCP === "object" && !Array.isArray(value.TCP)) {
			for (const [key, configuration] of Object.entries(value.TCP)) {
				const port = numericPort(key);
				if (port === null || !configuration || typeof configuration !== "object") continue;
				const mapping = mappingFor(port);
				if (configuration.HTTPS === true) mapping.https = true;
			}
		}
		if (value.Web && typeof value.Web === "object" && !Array.isArray(value.Web)) {
			for (const [endpoint, configuration] of Object.entries(value.Web)) {
				const port = endpointPort(endpoint);
				if (port === null || !configuration || typeof configuration !== "object") continue;
				const mapping = mappingFor(port);
				const handlers = configuration.Handlers;
				if (!handlers || typeof handlers !== "object" || Array.isArray(handlers)) continue;
				for (const [handlerPath, handler] of Object.entries(handlers)) {
					mapping.handlers.push({
						path: handlerPath,
						proxy:
							handler && typeof handler === "object" && typeof handler.Proxy === "string"
								? handler.Proxy
								: null,
					});
				}
			}
		}
		if (value.endpoints && typeof value.endpoints === "object" && !Array.isArray(value.endpoints)) {
			for (const endpoint of Object.keys(value.endpoints)) {
				const port = numericPort(String(endpoint).match(/^tcp:([0-9]+)$/)?.[1] ?? "");
				if (port !== null) mappingFor(port);
			}
		}
		for (const child of Object.values(value)) visit(child);
	};
	visit(status);
	return mappings;
}

function exactTailscaleMappingMatches(mapping, proxyUrl) {
	return Boolean(
		mapping?.https === true &&
		mapping.handlers.length === 1 &&
		mapping.handlers[0].path === "/" &&
		mapping.handlers[0].proxy === proxyUrl,
	);
}

function numericPort(value) {
	if (!/^[0-9]+$/.test(String(value))) return null;
	const port = Number(value);
	return Number.isInteger(port) && port > 0 && port <= 65_535 ? port : null;
}

function endpointPort(value) {
	const text = String(value);
	return numericPort(text) ?? numericPort(text.match(/:([0-9]+)$/)?.[1] ?? "");
}

export function isPortAvailable(port) {
	return Promise.all([
		canBindPort(port, "127.0.0.1"),
		canBindPort(port, "::1"),
	]).then((results) => results.every(Boolean));
}

export async function chooseMetroPort(
	registry,
	excludedKey = "",
	{ exposure = "local", isAvailable = isPortAvailable, tailscaleStatus = null } = {},
) {
	const assigned = new Set(
		Object.values(registry.lanes)
			.filter((lane) => lane.key !== excludedKey)
			.map((lane) => lane.metro.port),
	);
	const servePorts =
		exposure === "tailscale"
			? tailscaleServePorts(tailscaleStatus ?? readTailscaleServeStatus())
			: new Set();
	for (let port = firstMetroPort; port <= lastMetroPort; port += 1) {
		if (!assigned.has(port) && !servePorts.has(port) && (await isAvailable(port))) return port;
	}
	throw new Error(`No free Metro port is available in ${firstMetroPort}-${lastMetroPort}.`);
}

async function reassignLanePort(key, lane) {
	return withRegistryLock(async (registry) => {
		const current = registry.lanes[key];
		if (!current) throw new Error(`Lane ${key} was released.`);
		current.metro.port = await chooseMetroPort(registry, key, {
			exposure: current.exposure,
		});
		current.metro.nonce = randomBytes(16).toString("hex");
		current.updatedAt = now();
		return current;
	});
}

async function clearMetroProcessMetadata(key, lane) {
	await updateLane(key, (current) => {
		if (current.metro.pid !== lane.metro.pid) return;
		current.metro = clearOwnedProcessRecord({
			...current.metro,
			host: null,
			startedAt: null,
			tailscale: null,
			url: null,
		});
	});
}

async function startMetro(lane, environment, endpoint) {
	const logDescriptor = openSync(lane.logFile, "a", 0o600);
	const processNonce = randomBytes(16).toString("hex");
	const devServerUrl = `${endpoint.scheme}://${formatUrlHost(endpoint.host)}:${lane.metro.port}`;
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
			"--localhost",
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
				IOS_SESSION_LANE_PROCESS_NONCE: processNonce,
				IOS_SESSION_LANE_WORKTREE_HASH: lane.metro.worktreeHash,
				NODE_OPTIONS: withNodeOption(environment.NODE_OPTIONS, "--dns-result-order=ipv4first"),
				REACT_NATIVE_PACKAGER_HOSTNAME: endpoint.host,
			},
			stdio: ["ignore", logDescriptor, logDescriptor],
		},
	);
	child.unref();
	closeSync(logDescriptor);
	let processRecord;
	try {
		processRecord = await captureOwnedProcessRecordOrCleanup(child, {
			expectedCommandParts: [profile.mobile.root, "expo", "start", String(lane.metro.port)],
			expectedCwd: lane.worktree,
			metroNonce: lane.metro.nonce,
			metroWorktreeHash: lane.metro.worktreeHash,
			processNonce,
			processRole: "metro",
		});
	} catch (error) {
		throw new Error(`Metro started, but its full process identity could not be verified. ${error.message}`);
	}
	return {
		host: endpoint.host,
		...processRecord,
		startedAt: now(),
		tailscale: null,
		url: devServerUrl,
	};
}

async function startTailscaleTunnel(lane) {
	return withFileLock(tailscaleOperationLockPath, 60_000, () =>
		startTailscaleTunnelLocked(lane),
	);
}

async function startTailscaleTunnelLocked(lane) {
	const serveProxyUrl = `http://127.0.0.1:${lane.metro.port}`;
	const initialStatus = readTailscaleServeStatus();
	if (tailscaleServePorts(initialStatus).has(lane.metro.port)) {
		throw new Error(
			`TAILSCALE_SERVE_PORT_IN_USE: HTTPS port ${lane.metro.port} already has a machine-global Tailscale Serve mapping; refusing to overwrite it.`,
		);
	}
	const logDescriptor = openSync(lane.logFile, "a", 0o600);
	const processNonce = randomBytes(16).toString("hex");
	const child = spawn(
		"tailscale",
		tailscaleServeStartArgs(lane.metro.port),
		{
			cwd: repoRoot,
			detached: true,
			env: { ...process.env, IOS_SESSION_LANE_PROCESS_NONCE: processNonce },
			stdio: ["ignore", logDescriptor, logDescriptor],
		},
	);
	child.unref();
	closeSync(logDescriptor);
	let processRecord;
	try {
		processRecord = await captureOwnedProcessRecordOrCleanup(child, {
			expectedCommandParts: ["tailscale", "serve", `--https=${lane.metro.port}`],
			expectedCwd: lane.worktree,
			processNonce,
			processRole: "tailscale",
		});
	} catch (error) {
		let configurationState = "";
		try {
			if (tailscaleServePorts(readTailscaleServeStatus()).has(lane.metro.port)) {
				configurationState =
					" A Serve mapping now exists on the reserved port and was left untouched because exact process ownership was not captured.";
			}
		} catch (statusError) {
			configurationState = ` Serve mapping state could not be re-read: ${statusError.message}`;
		}
		throw new Error(
			`Tailscale Serve started, but its full process identity could not be verified. ${error.message}` +
				configurationState,
		);
	}
	const record = {
		...processRecord,
		serveHttpsPort: lane.metro.port,
		serveProxyUrl,
		startedAt: now(),
	};
	try {
		await sleep(250);
		if (!ownedProcessRuntime(record)) {
			throw new Error(`Tailscale Serve exited during startup. Check ${lane.logFile}.`);
		}
		const trackedLane = { ...lane, metro: { ...lane.metro, tailscale: record } };
		if (!tailscaleServeMappingMatchesLane(readTailscaleServeStatus(), trackedLane)) {
			throw new Error(
				`Tailscale Serve did not create the exact reserved HTTPS mapping for port ${lane.metro.port}.`,
			);
		}
		return record;
	} catch (error) {
		const cleanupFailures = [];
		const trackedLane = { ...lane, metro: { ...lane.metro, tailscale: record } };
		try {
			await disableTailscaleServeLocked(trackedLane);
		} catch (cleanupError) {
			cleanupFailures.push(cleanupError.message);
		}
		try {
			await stopOwnedProcessAndWait(record, { timeoutMs: processStopTimeoutMs });
		} catch (cleanupError) {
			cleanupFailures.push(cleanupError.message);
		}
		if (cleanupFailures.length > 0) {
			throw new Error(`${error.message} Tailscale cleanup was incomplete: ${cleanupFailures.join("; ")}`);
		}
		throw error;
	}
}

async function startAndPersistTailscaleTunnel(key, lane) {
	const tailscale = await startTailscaleTunnel(lane);
	const trackedLane = {
		...lane,
		metro: { ...lane.metro, tailscale },
	};
	try {
		return await updateLane(key, (current) => {
			current.metro.tailscale = tailscale;
		});
	} catch (error) {
		const cleanupFailures = [];
		try {
			await disableTailscaleServe(trackedLane);
		} catch (cleanupError) {
			cleanupFailures.push(cleanupError.message);
		}
		try {
			await stopOwnedProcessAndWait(tailscale, { timeoutMs: processStopTimeoutMs });
		} catch (cleanupError) {
			cleanupFailures.push(cleanupError.message);
		}
		if (cleanupFailures.length > 0) {
			throw new Error(
				`${error.message} Tailscale registry persistence failed and cleanup was incomplete: ${cleanupFailures.join("; ")}`,
			);
		}
		throw error;
	}
}

async function cleanupFailedMetroAttempt(lane) {
	try {
		await stopLaneMetroAndWait(lane);
	} catch (error) {
		throw new Error(`Metro startup failed and cleanup was incomplete: ${error.message}`);
	}
}

async function disableTailscaleServe(lane) {
	return withFileLock(tailscaleOperationLockPath, 60_000, () =>
		disableTailscaleServeLocked(lane),
	);
}

async function disableTailscaleServeLocked(lane) {
	const status = readTailscaleServeStatus();
	if (!tailscaleServePorts(status).has(lane.metro.port)) return;
	if (!tailscaleServeMappingMatchesLane(status, lane)) {
		throw new Error(
			`Refusing to disable Tailscale Serve port ${lane.metro.port}: the machine-global mapping is not the exact mapping recorded for this lane.`,
		);
	}
	if (!ownedProcessRuntime(lane.metro.tailscale)) {
		throw new Error(
			`Refusing to disable Tailscale Serve port ${lane.metro.port}: its exact recorded process group is not owned and live.`,
		);
	}
	await turnOffTailscaleServePort(lane);
}

async function turnOffTailscaleServePort(lane) {
	const port = lane.metro.port;
	const freshStatus = readTailscaleServeStatus();
	if (!tailscaleServeMappingMatchesLane(freshStatus, lane)) {
		throw new Error(
			`Refusing to disable Tailscale Serve port ${port}: its exact mapping changed immediately before teardown.`,
		);
	}
	if (!ownedProcessRuntime(lane.metro.tailscale)) {
		throw new Error(
			`Refusing to disable Tailscale Serve port ${port}: exact process ownership changed immediately before teardown.`,
		);
	}
	const result = spawnSync("tailscale", tailscaleServeOffArgs(port), {
		cwd: repoRoot,
		encoding: "utf8",
		timeout: tailscaleStopTimeoutMs,
	});
	if (result.status !== 0) {
		throw new Error(
			`tailscale ${tailscaleServeOffArgs(port).join(" ")} failed: ${(
				result.error?.message || result.stderr || result.stdout || `exit ${result.status}`
			).trim()}`,
		);
	}
	const deadline = Date.now() + tailscaleStopTimeoutMs;
	while (Date.now() < deadline) {
		if (!tailscaleServeUsesPort(port)) return;
		await sleep(250);
	}
	throw new Error(`Tailscale Serve still reports HTTPS port ${port} after teardown.`);
}

function tailscaleServeUsesPort(port) {
	return tailscaleStatusHasHttpsPort(readTailscaleServeStatus(), port);
}

function readTailscaleServeStatus() {
	const statusResult = spawnSync("tailscale", ["serve", "status", "--json"], {
		cwd: repoRoot,
		encoding: "utf8",
		maxBuffer: 20 * 1024 * 1024,
		timeout: 5_000,
	});
	let status = {};
	if (statusResult.status !== 0) {
		const detail = `${statusResult.stderr ?? ""}\n${statusResult.stdout ?? ""}`;
		if (!/no serve config|not configured|no configuration/i.test(detail)) {
			throw new Error(
				`Could not inspect machine-global Tailscale Serve status: ${detail.trim() || `exit ${statusResult.status}`}.`,
			);
		}
	} else {
		status = parseTailscaleObject(statusResult.stdout, "status");
	}
	const configurationResult = spawnSync(
		"tailscale",
		["serve", "get-config", "--all", "-"],
		{
			cwd: repoRoot,
			encoding: "utf8",
			maxBuffer: 20 * 1024 * 1024,
			timeout: 5_000,
		},
	);
	if (configurationResult.status !== 0) {
		const detail = `${configurationResult.stderr ?? ""}\n${configurationResult.stdout ?? ""}`;
		throw new Error(
			`Could not inspect all Tailscale Serve service configurations: ${detail.trim() || `exit ${configurationResult.status}`}.`,
		);
	}
	return {
		machineStatus: status,
		servicesConfiguration: parseTailscaleObject(configurationResult.stdout, "service configuration"),
	};
}

function parseTailscaleObject(output, label) {
	try {
		const parsed = JSON.parse(output || "{}");
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			throw new Error(`${label} was not an object`);
		}
		return parsed;
	} catch {
		throw new Error(`Tailscale Serve returned invalid ${label} JSON.`);
	}
}

async function metroStatusReady(url) {
	try {
		const response = await fetch(url, { signal: AbortSignal.timeout(2_000) });
		const body = await response.text();
		return response.ok && body.includes("packager-status:running");
	} catch {
		return false;
	}
}

function canBindPort(port, host) {
	return new Promise((resolvePort) => {
		const server = createServer();
		server.unref();
		server.once("error", () => resolvePort(false));
		server.listen(port, host, () => server.close(() => resolvePort(true)));
	});
}

function formatUrlHost(host) {
	return String(host).includes(":") && !String(host).startsWith("[") ? `[${host}]` : host;
}

function withNodeOption(existing, required) {
	const values = String(existing ?? "").split(/\s+/).filter(Boolean);
	if (!values.includes(required)) values.push(required);
	return values.join(" ");
}

function metroCommandMatchesLane(lane) {
	if (!metroProcessOwned(lane)) return false;
	const command = lane.metro.processCommand ?? "";
	return (
		/(?:expo|corepack|pnpm)/.test(command) &&
		command.includes(String(lane.metro.port)) &&
		path.resolve(lane.metro.processCwd ?? "") === path.resolve(lane.worktree)
	);
}

function metroListenerOwned(lane) {
	const result = spawnSync(
		"lsof",
		["-nP", `-iTCP:${lane.metro.port}`, "-sTCP:LISTEN", "-Fp"],
		{ encoding: "utf8" },
	);
	if (result.status !== 0) return false;
	const listenerPids = result.stdout
		.split(/\r?\n/)
		.filter((line) => /^p[0-9]+$/.test(line))
		.map((line) => Number(line.slice(1)));
	return listenerPids.some((pid) => {
		const identity = inspectProcessIdentity(pid, { includeEnvironment: true });
		return processGroupMemberIdentityMatches(lane.metro, identity);
	});
}

export function assertNoOwnedMetroListener(lane) {
	const result = spawnSync(
		"lsof",
		["-nP", `-iTCP:${lane.metro.port}`, "-sTCP:LISTEN", "-Fp"],
		{ encoding: "utf8" },
	);
	if (result.status === 1 && !result.error) return;
	if (result.status !== 0) {
		throw new Error(
			`Could not verify Metro listener teardown on port ${lane.metro.port}: ${result.error?.message || result.stderr || `exit ${result.status}`}.`,
		);
	}
	const listenerPids = result.stdout
		.split(/\r?\n/)
		.filter((line) => /^p[0-9]+$/.test(line))
		.map((line) => Number(line.slice(1)));
	for (const pid of listenerPids) {
		const identity = inspectProcessIdentity(pid, { includeEnvironment: true });
		if (!identity) {
			const refreshed = spawnSync(
				"lsof",
				["-nP", `-iTCP:${lane.metro.port}`, "-sTCP:LISTEN", "-Fp"],
				{ encoding: "utf8" },
			);
			if (refreshed.status === 0 && refreshed.stdout.split(/\r?\n/).includes(`p${pid}`)) {
				throw new Error(`Metro listener PID ${pid} could not be identity-verified during teardown.`);
			}
			continue;
		}
		if (identity.processGroupId !== lane.metro.processGroupId) continue;
		if (!processGroupMemberIdentityMatches(lane.metro, identity)) {
			throw new Error(
				`A listener on port ${lane.metro.port} reused Metro PGID ${lane.metro.processGroupId} without its exact lane identity.`,
			);
		}
		throw new Error(
			`Exactly owned Metro PGID ${lane.metro.processGroupId} still listens on port ${lane.metro.port}.`,
		);
	}
}

function sleep(milliseconds) {
	return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}
