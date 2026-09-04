import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
	mkdirSync,
	mkdtempSync,
	readFileSync,
	readdirSync,
	realpathSync,
	rmSync,
	statSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { createServer } from "node:net";
import path from "node:path";
import test from "node:test";
import {
	allowedDopplerConfigs,
	assertAllowedDopplerConfig,
	assertBackendDockerNetworkConfiguration,
	assertLoopbackBindings,
	assertPersistedBackendContract,
	backendContainerAttestationsMatch,
	backendDockerNetwork,
	backendMediaPublishEnvironment,
	backendResetCommands,
	classifyBackendStatusResult,
	parseBackendContainerInspection,
	parseLocalDopplerReferences,
	refreshResetBackendAttestation,
	replaceFileFromPrivateStage,
	worktreeFromFunctionsMounts,
} from "../scripts/lane-backend.mjs";
import {
	laneWriterLeaseIsCurrent,
	metroLogShowsMainBundle,
	renderEvidenceMatchesScreenshot,
	renderScreenshotIdentity,
	simulatorAppTerminationSucceeded,
	snapshotLooksRendered,
	withTargetControllerOperation,
} from "../scripts/lane-controller.mjs";
import { safeKey } from "../scripts/lane-identifiers.mjs";
import { withFileLock } from "../scripts/lane-lock.mjs";
import {
	appBundleContentDigest,
	parsePhysicalAppIdentity,
	samePhysicalAppIdentity,
} from "../scripts/lane-native.mjs";
import { assertNoOwnedMetroListener } from "../scripts/lane-metro.mjs";
import { parseOptions } from "../scripts/lane-policy.mjs";
import {
	namespaceIdentity,
	normalizeOriginUrl,
	resolveLaneHome,
} from "../scripts/lane-runtime-context.mjs";
import {
	captureOwnedProcessRecord,
	captureOwnedProcessRecordOrCleanup,
	inspectOwnedProcessGroup,
	inspectProcessIdentity,
	isPidAlive,
	metroProcessOwned,
	ownedProcess,
	processSignalTarget,
	pruneDeadMetroMetadata,
	stopOwnedProcessAndWait,
} from "../scripts/lane-state.mjs";
import {
	managedSimulatorNumber,
	selectReusableSimulator,
} from "../scripts/lane-target.mjs";

function processGroupLeaderScript(port) {
	const childScript = `
		const { createServer } = require("node:net");
		process.on("SIGTERM", () => {});
		createServer(() => {}).listen(${port}, "127.0.0.1");
		setInterval(() => {}, 1000);
	`;
	return `
		const { spawn } = require("node:child_process");
		spawn(process.execPath, ["-e", ${JSON.stringify(childScript)}], { stdio: "ignore" });
		process.on("SIGTERM", () => process.exit(0));
		setInterval(() => {}, 1000);
	`;
}

function unusedLoopbackPort() {
	return new Promise((resolve, reject) => {
		const server = createServer();
		server.once("error", reject);
		server.listen(0, "127.0.0.1", () => {
			const address = server.address();
			server.close((error) => {
				if (error) reject(error);
				else resolve(address.port);
			});
		});
	});
}

function loopbackPortHasListener(port) {
	const result = spawnSync("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-Fp"], {
		encoding: "utf8",
	});
	return result.status === 0 && /^p[0-9]+$/m.test(result.stdout);
}

async function waitFor(predicate, timeoutMs = 5_000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return;
		await new Promise((resolve) => setTimeout(resolve, 25));
	}
	throw new Error("Timed out waiting for the synthetic process fixture.");
}

test("runtime namespace is clone-stable across common Git origin spellings", () => {
	const origins = [
		"git@github.com:Avad-Technologies/PUMPD-Mobile-App.git",
		"https://github.com/avad-technologies/pumpd-mobile-app.git",
		"ssh://git@github.com/avad-technologies/pumpd-mobile-app",
	];
	assert.deepEqual(
		origins.map(normalizeOriginUrl),
		Array(3).fill("github.com/avad-technologies/pumpd-mobile-app"),
	);
	assert.deepEqual(namespaceIdentity(origins[0]), namespaceIdentity(origins[1]));
});

test("custom lane homes reject protected paths and accept a safe absolute temp path", () => {
	const protectedRoot = mkdtempSync(path.join(tmpdir(), "ios-lane-home-protected-"));
	const safeRoot = mkdtempSync(path.join(tmpdir(), "ios-lane-home-safe-"));
	const home = path.join(protectedRoot, "home");
	const repository = path.join(protectedRoot, "source", "repository");
	const linkedRepository = path.join(safeRoot, "repository-link");
	mkdirSync(home, { recursive: true });
	mkdirSync(repository, { recursive: true });
	symlinkSync(repository, linkedRepository);
	const options = { home, repository };
	try {
		assert.throws(() => resolveLaneHome("", options), /must not be empty/);
		assert.throws(() => resolveLaneHome("relative/lane-home", options), /absolute path/);
		assert.throws(() => resolveLaneHome(path.parse(safeRoot).root, options), /unsafe/);
		assert.throws(() => resolveLaneHome(home, options), /unsafe/);
		assert.throws(() => resolveLaneHome(repository, options), /unsafe/);
		assert.throws(() => resolveLaneHome(path.join(repository, "runtime"), options), /unsafe/);
		assert.throws(() => resolveLaneHome(protectedRoot, options), /unsafe/);
		assert.throws(() => resolveLaneHome(linkedRepository, options), /unsafe/);

		const safeLaneHome = path.join(safeRoot, "nested", "runtime");
		assert.equal(
			resolveLaneHome(safeLaneHome, options),
			path.join(realpathSync(safeRoot), "nested", "runtime"),
		);
	} finally {
		rmSync(protectedRoot, { force: true, recursive: true });
		rmSync(safeRoot, { force: true, recursive: true });
	}
});

test("filesystem-safe keys remain collision-resistant after sanitizing", () => {
	assert.notEqual(safeKey("codex:a:b"), safeKey("codex:a-b"));
	assert.match(safeKey("codex:a:b"), /^codex-a-b-[a-f0-9]{16}$/);
});

test("concurrent stale-lock reclaimers never overlap callbacks", async () => {
	const directory = mkdtempSync(path.join(tmpdir(), "ios-lane-stale-race-"));
	const lockPath = path.join(directory, "shared.lock");
	mkdirSync(lockPath);
	writeFileSync(
		path.join(lockPath, "owner.json"),
		JSON.stringify({ pid: 2_147_483_647, processStartedAt: "dead", token: "stale-token" }),
	);
	let active = 0;
	let maximum = 0;
	try {
		await Promise.all(
			Array.from({ length: 12 }, () =>
				withFileLock(lockPath, 5_000, async () => {
					active += 1;
					maximum = Math.max(maximum, active);
					await new Promise((resolve) => setTimeout(resolve, 10));
					active -= 1;
				}),
			),
		);
		assert.equal(maximum, 1);
		assert.equal(
			readdirSync(directory).filter((entry) => entry.startsWith("shared.lock.stale-")).length,
			1,
		);
	} finally {
		rmSync(directory, { force: true, recursive: true });
	}
});

test("owned process shutdown waits for every exact process-group member", async () => {
	const workingDirectory = mkdtempSync(path.join(tmpdir(), "ios-lane-owned-process-"));
	const metroNonce = "test-metro-nonce";
	const metroWorktreeHash = "test-worktree-hash";
	const processNonce = "test-process-nonce";
	const port = await unusedLoopbackPort();
	const child = spawn(process.execPath, ["-e", processGroupLeaderScript(port)], {
		cwd: workingDirectory,
		detached: true,
		env: {
			...process.env,
			IOS_SESSION_LANE_NONCE: metroNonce,
			IOS_SESSION_LANE_PROCESS_NONCE: processNonce,
			IOS_SESSION_LANE_WORKTREE_HASH: metroWorktreeHash,
		},
		stdio: "ignore",
	});
	child.unref();
	let record = null;
	try {
		for (let attempt = 0; attempt < 40 && !record; attempt += 1) {
			try {
				record = captureOwnedProcessRecord(child.pid, {
					expectedCommandParts: ["setInterval", String(port)],
					expectedCwd: workingDirectory,
					metroNonce,
					metroWorktreeHash,
					processNonce,
					processRole: "metro",
				});
			} catch {
				await new Promise((resolve) => setTimeout(resolve, 25));
			}
		}
		assert.ok(record);
		await waitFor(() => inspectOwnedProcessGroup(record).members.length >= 2);
		await waitFor(() => loopbackPortHasListener(port));
		assert.throws(
			() => assertNoOwnedMetroListener({ metro: { ...record, port } }),
			/still listens/,
		);
		assert.equal(ownedProcess(record), true);
		assert.equal(ownedProcess({ ...record, metroNonce: "wrong-lane" }), false);
		const current = inspectProcessIdentity(child.pid, { includeEnvironment: true });
		assert.ok(current);
		assert.equal(processSignalTarget(record, current), -child.pid);
		assert.equal(
			processSignalTarget({ ...record, processGroupId: child.pid + 1 }, current),
			null,
		);
		assert.equal(
			processSignalTarget({ ...record, signalScope: "individual" }, current),
			child.pid,
		);

		const mismatched = { ...record, processCommand: `${record.processCommand} --different` };
		await assert.rejects(
			stopOwnedProcessAndWait(mismatched, { timeoutMs: 250 }),
			/Refusing to signal (?:PID|process group)/,
		);
		assert.equal(ownedProcess(record), true);
		child.kill("SIGTERM");
		await waitFor(
			() => !ownedProcess(record) && inspectOwnedProcessGroup(record).status === "owned",
		);
		const registry = { lanes: { fixture: { metro: { ...record } } } };
		pruneDeadMetroMetadata(registry);
		assert.equal(registry.lanes.fixture.metro.pid, record.pid);
		assert.equal(metroProcessOwned(registry.lanes.fixture), true);
		assert.equal(await stopOwnedProcessAndWait(record, { timeoutMs: 250 }), true);
		assert.equal(ownedProcess(record), false);
		assert.equal(inspectOwnedProcessGroup(record).status, "empty");
		assert.equal(loopbackPortHasListener(port), false);
		assert.doesNotThrow(() => assertNoOwnedMetroListener({ metro: { ...record, port } }));
		pruneDeadMetroMetadata(registry);
		assert.equal(registry.lanes.fixture.metro.pid, null);
	} finally {
		if (record && inspectOwnedProcessGroup(record).status !== "empty") {
			await stopOwnedProcessAndWait(record, { timeoutMs: 2_000 });
		} else if (!record) {
			try {
				process.kill(-child.pid, "SIGKILL");
			} catch {}
		}
		rmSync(workingDirectory, { force: true, recursive: true });
	}
});

test("spawn identity capture failure stops the exact child and surviving group members", async () => {
	for (let iteration = 0; iteration < 6; iteration += 1) {
		const workingDirectory = mkdtempSync(path.join(tmpdir(), "ios-lane-capture-cleanup-"));
		const metroNonce = `capture-failure-metro-nonce-${iteration}`;
		const metroWorktreeHash = `capture-failure-worktree-hash-${iteration}`;
		const processNonce = `capture-failure-process-nonce-${iteration}`;
		const port = await unusedLoopbackPort();
		const child = spawn(process.execPath, ["-e", processGroupLeaderScript(port)], {
			cwd: workingDirectory,
			detached: true,
			env: {
				...process.env,
				IOS_SESSION_LANE_NONCE: metroNonce,
				IOS_SESSION_LANE_PROCESS_NONCE: processNonce,
				IOS_SESSION_LANE_WORKTREE_HASH: metroWorktreeHash,
			},
			stdio: "ignore",
		});
		child.unref();
		try {
			await waitFor(() => loopbackPortHasListener(port));
			await assert.rejects(
				captureOwnedProcessRecordOrCleanup(
					child,
					{
						expectedCommandParts: ["command-part-that-is-not-present"],
						expectedCwd: workingDirectory,
						metroNonce,
						metroWorktreeHash,
						processNonce,
						processRole: "metro",
					},
					{ attempts: 1, cleanupTimeoutMs: 250 },
				),
				/the exact spawned child\/group was stopped/,
			);
			await waitFor(() => !isPidAlive(child.pid) && !loopbackPortHasListener(port));
		} finally {
			try {
				process.kill(-child.pid, "SIGKILL");
			} catch {}
			rmSync(workingDirectory, { force: true, recursive: true });
		}
	}
});

test("Metro and Tailscale startup both route capture failures through exact cleanup", () => {
	const source = readFileSync(new URL("../scripts/lane-metro.mjs", import.meta.url), "utf8");
	assert.equal(
		Array.from(source.matchAll(/await captureOwnedProcessRecordOrCleanup\(child,/g)).length,
		2,
	);
});

test("simulator bundle digest covers every regular file and rejects unsafe entries", () => {
	const appPath = mkdtempSync(path.join(tmpdir(), "ios-lane-app-"));
	try {
		writeFileSync(path.join(appPath, "Info.plist"), "plist-one");
		writeFileSync(path.join(appPath, "PUMPD"), "binary-one");
		mkdirSync(path.join(appPath, "Frameworks", "Example.framework"), { recursive: true });
		mkdirSync(path.join(appPath, "PlugIns", "Widget.appex"), { recursive: true });
		mkdirSync(path.join(appPath, "Resources"), { recursive: true });
		writeFileSync(path.join(appPath, "Frameworks", "Example.framework", "Example"), "framework-one");
		writeFileSync(path.join(appPath, "PlugIns", "Widget.appex", "Widget"), "extension-one");
		const resource = path.join(appPath, "Resources", "asset.bin");
		writeFileSync(resource, "resource-one");
		const initial = appBundleContentDigest(appPath, "PUMPD");
		writeFileSync(resource, "resource-two");
		assert.notEqual(appBundleContentDigest(appPath, "PUMPD"), initial);
		writeFileSync(resource, "resource-one");
		assert.equal(appBundleContentDigest(appPath, "PUMPD"), initial);
		writeFileSync(path.join(appPath, "Frameworks", "Example.framework", "Example"), "framework-two");
		assert.notEqual(appBundleContentDigest(appPath, "PUMPD"), initial);
		writeFileSync(path.join(appPath, "Frameworks", "Example.framework", "Example"), "framework-one");
		symlinkSync(resource, path.join(appPath, "Resources", "linked-asset"));
		assert.throws(() => appBundleContentDigest(appPath, "PUMPD"), /symbolic link/);
		rmSync(path.join(appPath, "Resources", "linked-asset"));
		const fifo = path.join(appPath, "Resources", "named-pipe");
		const fifoResult = spawnSync("mkfifo", [fifo]);
		assert.equal(fifoResult.status, 0);
		assert.throws(() => appBundleContentDigest(appPath, "PUMPD"), /non-regular file/);
		assert.throws(() => appBundleContentDigest(appPath, "../PUMPD"), /Invalid app executable/);
	} finally {
		rmSync(appPath, { force: true, recursive: true });
	}
});

test("render proof requires the PUMPD application and an unchanged non-empty screenshot", () => {
	assert.equal(
		snapshotLooksRendered(
			'Snapshot: 3 visible nodes\n@e1 [application] "PUMPD"\n@e2 [text] "Today"',
		),
		true,
	);
	assert.equal(
		snapshotLooksRendered(
			'Snapshot: 3 visible nodes\n@e1 [application] "SpringBoard"\n@e2 [text] "PUMPD"',
		),
		false,
	);
	assert.equal(
		metroLogShowsMainBundle("iOS Bundled 433ms apps/mobile/index.js (1 module)"),
		true,
	);
	assert.equal(
		metroLogShowsMainBundle("iOS Bundled 20ms node_modules/example/index.js (1 module)"),
		false,
	);
	assert.equal(
		snapshotLooksRendered(
			'Snapshot: 3 visible nodes\n@e1 [application] "PUMPD"\n@e2 [alert] "Permission"',
		),
		false,
	);
	const directory = mkdtempSync(path.join(tmpdir(), "ios-lane-render-"));
	const screenshot = path.join(directory, "render.png");
	try {
		writeFileSync(screenshot, "image-one");
		const render = { screenshot, ...renderScreenshotIdentity(screenshot) };
		assert.equal(renderEvidenceMatchesScreenshot(render), true);
		writeFileSync(screenshot, "image-two");
		assert.equal(renderEvidenceMatchesScreenshot(render), false);
	} finally {
		rmSync(directory, { force: true, recursive: true });
	}
});

test("controller writer validation requires matching lane and resource leases", () => {
	const target = { kind: "simulator", udid: "SIM-LEASE" };
	const lease = {
		controller: "agent-device",
		ownerKey: "codex:test",
		resource: "simulator:SIM-LEASE",
	};
	const lane = { controller: lease, key: "codex:test", target };
	const registry = {
		resources: { controllers: { "simulator:SIM-LEASE": lease } },
	};
	assert.equal(laneWriterLeaseIsCurrent(registry, lane, "agent-device"), true);
	assert.equal(laneWriterLeaseIsCurrent(registry, lane, "maestro"), false);
	assert.equal(
		laneWriterLeaseIsCurrent(
			{
				resources: {
					controllers: {
						"simulator:SIM-LEASE": { ...lease, ownerKey: "claude:other" },
					},
				},
			},
			lane,
			"agent-device",
		),
		false,
	);
});

test("target controller operations serialize writers for the same target", async () => {
	const target = {
		kind: "simulator",
		udid: `SIM-LOCK-${process.pid}-${Date.now()}`,
	};
	let active = 0;
	let maximum = 0;
	await Promise.all(
		Array.from({ length: 4 }, () =>
			withTargetControllerOperation(target, async () => {
				active += 1;
				maximum = Math.max(maximum, active);
				await new Promise((resolve) => setTimeout(resolve, 10));
				active -= 1;
			}),
		),
	);
	assert.equal(maximum, 1);
});

test("simulator app termination accepts only success or an exact already-stopped result", () => {
	assert.equal(simulatorAppTerminationSucceeded({ status: 0 }), true);
	assert.equal(
		simulatorAppTerminationSucceeded({
			status: 3,
			stderr: "The operation couldn't be completed. found nothing to terminate",
		}),
		true,
	);
	assert.equal(
		simulatorAppTerminationSucceeded({
			error: Object.assign(new Error("timed out"), { code: "ETIMEDOUT" }),
			status: null,
		}),
		false,
	);
	assert.equal(simulatorAppTerminationSucceeded({ status: 1, stderr: "device unavailable" }), false);
});

test("physical app identity is parsed only from devicectl result apps", () => {
	const bundleIdentifier = "com.avadworkout.pumpdmobileapp.development";
	assert.equal(
		parsePhysicalAppIdentity(
			{
				info: { arguments: ["--bundle-id", bundleIdentifier] },
				result: { apps: [] },
			},
			bundleIdentifier,
		),
		null,
	);
	const payload = {
		result: {
			apps: [
				{
					bundleIdentifier,
					bundleVersion: "42",
					url: "file:///private/var/containers/Bundle/Application/ONE/PUMPD.app/",
					version: "1.2.3",
				},
			],
		},
	};
	const identity = parsePhysicalAppIdentity(payload, bundleIdentifier);
	assert.deepEqual(identity, {
		bundleIdentifier,
		bundleVersion: "42",
		url: "file:///private/var/containers/Bundle/Application/ONE/PUMPD.app/",
		version: "1.2.3",
	});
	assert.equal(samePhysicalAppIdentity(identity, { ...identity }), true);
	assert.equal(
		samePhysicalAppIdentity(identity, {
			...identity,
			url: "file:///private/var/containers/Bundle/Application/TWO/PUMPD.app/",
		}),
		false,
	);
	assert.equal(
		samePhysicalAppIdentity(
			{ ...identity, deviceId: "DEVICE-ONE" },
			{ ...identity, deviceId: "DEVICE-TWO" },
		),
		false,
	);
	assert.equal(
		parsePhysicalAppIdentity(
			{ result: { apps: [...payload.result.apps, ...payload.result.apps] } },
			bundleIdentifier,
		),
		null,
	);
});

test("backend bindings and Doppler configs fail closed", () => {
	const safe = [{ container: "supabase_kong_test", containerPort: "8000/tcp", hostIp: "127.0.0.1", hostPort: "54321" }];
	assert.deepEqual(assertLoopbackBindings(safe), safe);
	assert.throws(
		() => assertLoopbackBindings([{ ...safe[0], hostIp: "0.0.0.0" }]),
		/non-loopback/,
	);
	assert.throws(() => assertLoopbackBindings([]), /Could not prove/);
	assert.deepEqual(allowedDopplerConfigs(), ["dev_personal"]);
	assert.equal(assertAllowedDopplerConfig("dev_personal"), "dev_personal");
	assert.throws(() => assertAllowedDopplerConfig("prd"), /not approved/);
});

test("backend mount discovery accepts portable container paths but validates the host suffix", () => {
	assert.equal(
		worktreeFromFunctionsMounts([
			{
				Destination: "/home/deno/functions/",
				Source: "/host_mnt/Users/example/pumpd/apps/backend/supabase/functions/",
			},
		]),
		"/Users/example/pumpd",
	);
	assert.equal(
		worktreeFromFunctionsMounts([
			{
				Destination: "/Users/example/other/apps/backend/supabase/functions",
				Source: "/run/desktop/mnt/host/Users/example/other/apps/backend/supabase/functions",
			},
		]),
		"/Users/example/other",
	);
	assert.equal(
		worktreeFromFunctionsMounts([
			{
				Destination: "/home/deno/functions",
				Source: "/Users/example/pumpd/unrelated/functions",
			},
		]),
		null,
	);
});

test("backend container attestation is parsed from one coherent Docker inspection", () => {
	assert.deepEqual(
		parseBackendContainerInspection(
			JSON.stringify({
				Created: "2026-09-03T10:00:00Z",
				Id: "sha256:container",
				Mounts: [{ Destination: "/home/deno/functions", Source: "/source" }],
				NetworkSettings: {
					Networks: { secondary: {}, "pumpd-network": {} },
				},
			}),
		),
		{
			createdAt: "2026-09-03T10:00:00Z",
			id: "sha256:container",
			mounts: [{ Destination: "/home/deno/functions", Source: "/source" }],
			networks: ["pumpd-network", "secondary"],
		},
	);
	assert.throws(
		() => parseBackendContainerInspection('{"Id":"sha256:container"}'),
		/incomplete/,
	);
});

test("Doppler validation parses every local reference and excludes remote blocks", () => {
	const references = parseLocalDopplerReferences(`
project_id = "pumpd"
[auth.sms.twilio_verify]
auth_token = "env(LOCAL_AUTH_TOKEN)"
[edge_runtime.secrets]
OPENAI_API_KEY = "env(OPENAI_API_KEY)"
mixed = "env(local_mixed_case)" # env(COMMENTED_OUT)
[remotes.preview]
ignored = "env(REMOTE_ROOT_SECRET)"
[remotes.preview.edge_runtime.secrets]
OPENAI_API_KEY = "env(REMOTE_OPENAI_KEY)"
[functions.health]
verify_jwt = false
`);
	assert.deepEqual(references, {
		all: ["LOCAL_AUTH_TOKEN", "OPENAI_API_KEY", "local_mixed_case"],
		edgeRuntime: ["OPENAI_API_KEY", "local_mixed_case"],
	});
});

test("backend status only reports stopped when Docker proves no project containers remain", () => {
	assert.deepEqual(
		classifyBackendStatusResult({ status: 0, stdout: '{"API_URL":"http://127.0.0.1:54321"}' }),
		{
			data: { API_URL: "http://127.0.0.1:54321" },
			state: "running",
		},
	);
	assert.deepEqual(classifyBackendStatusResult({ status: 1, stdout: "" }, []), {
		data: null,
		state: "stopped",
	});
	assert.throws(
		() =>
			classifyBackendStatusResult(
				{ status: 1, stdout: "" },
				[{ id: "container", name: "supabase_db_pumpd", state: "running" }],
			),
		/Ownership was preserved/,
	);
	assert.throws(
		() => classifyBackendStatusResult({ status: 0, stdout: "not-json" }),
		/invalid JSON/,
	);
});

test("backend network reuse requires a bridge with loopback-only default bindings", () => {
	const safeNetwork = {
		Driver: "bridge",
		Options: { "com.docker.network.bridge.host_binding_ipv4": "127.0.0.1" },
	};
	assert.equal(assertBackendDockerNetworkConfiguration(safeNetwork), safeNetwork);
	assert.throws(
		() => assertBackendDockerNetworkConfiguration({ ...safeNetwork, Options: {} }),
		/loopback-only/,
	);
	assert.throws(
		() => assertBackendDockerNetworkConfiguration({ ...safeNetwork, Driver: "overlay" }),
		/loopback-only/,
	);
});

test("managed backend attestation binds destructive operations to the exact container", () => {
	const recorded = {
		containerCreatedAt: "2026-09-03T10:00:00Z",
		containerId: "sha256:one",
		dockerNetworks: ["secondary", "pumpd"],
		projectId: "pumpd",
		schemaVersion: 1,
	};
	assert.equal(
		backendContainerAttestationsMatch(recorded, {
			...recorded,
			dockerNetworks: ["pumpd", "secondary"],
		}),
		true,
	);
	assert.equal(
		backendContainerAttestationsMatch(recorded, {
			...recorded,
			containerId: "sha256:replacement",
		}),
		false,
	);
	assert.equal(backendContainerAttestationsMatch(recorded, null), false);
});

test("post-reset attestation accepts replacement containers only for the same owner mount", () => {
	const ownerMount = path.join(tmpdir(), "pumpd-reset-owner");
	const expectedLease = {
		createdAt: "2026-09-03T09:00:00Z",
		managed: true,
		mountWorktree: ownerMount,
		ownerKey: "codex:reset-owner",
	};
	const replacementAttestation = {
		containerCreatedAt: "2026-09-03T10:05:00Z",
		containerId: "sha256:replacement",
		dockerNetworks: [backendDockerNetwork],
		projectId: "pumpd",
		schemaVersion: 1,
	};
	const detected = {
		compatibility: { fileCount: 4, hash: "fresh-contract" },
		containerAttestation: replacementAttestation,
		managed: true,
		mountWorktree: ownerMount,
		ownerKey: expectedLease.ownerKey,
	};
	const resettingBackend = () => ({
		...expectedLease,
		compatibility: { fileCount: 4, hash: "old-contract" },
		containerAttestation: {
			...replacementAttestation,
			containerCreatedAt: "2026-09-03T09:00:00Z",
			containerId: "sha256:before-reset",
		},
		state: "resetting",
	});

	const refreshed = refreshResetBackendAttestation(
		resettingBackend(),
		detected,
		expectedLease,
	);
	assert.equal(refreshed.state, "resetting");
	assert.deepEqual(refreshed.compatibility, detected.compatibility);
	assert.deepEqual(refreshed.containerAttestation, replacementAttestation);

	assert.throws(
		() =>
			refreshResetBackendAttestation(
				resettingBackend(),
				{ ...detected, managed: false },
				expectedLease,
			),
		/does not match the registered owner lane and worktree mount/,
	);
	assert.throws(
		() =>
			refreshResetBackendAttestation(
				resettingBackend(),
				{ ...detected, mountWorktree: `${ownerMount}-other` },
				expectedLease,
			),
		/does not match the registered owner lane and worktree mount/,
	);
	assert.throws(
		() =>
			refreshResetBackendAttestation(
				{ ...resettingBackend(), ownerKey: "codex:other" },
				detected,
				expectedLease,
			),
		/owner lease changed during reset/,
	);
});

test("backend compatibility compares the live contract with the persisted start/reset hash", () => {
	const live = { fileCount: 4, hash: "live-hash" };
	assert.equal(
		assertPersistedBackendContract({ compatibility: { hash: "live-hash" } }, live),
		live,
	);
	assert.throws(
		() => assertPersistedBackendContract({ compatibility: { hash: "old-hash" } }, live),
		/changed after Supabase last started or reset/,
	);
	assert.throws(
		() => assertPersistedBackendContract({ compatibility: null }, live),
		/no persisted start\/reset contract/,
	);
	assert.equal(
		assertPersistedBackendContract(
			{ compatibility: { hash: "old-hash" } },
			live,
			{ allowPersistedDrift: true },
		),
		live,
	);
});

test("backend reset preserves the custom network and publishes media without a bare status call", () => {
	const [reset, publishMedia] = backendResetCommands("pumpd-test-network");
	assert.deepEqual(reset.slice(-5), [
		"supabase",
		"db",
		"reset",
		"--network-id",
		"pumpd-test-network",
	]);
	assert.deepEqual(publishMedia.slice(-3), ["apps/catalog", "run", "media:publish"]);
	assert.equal(publishMedia.includes("status"), false);
	const environment = backendMediaPublishEnvironment(
		{
			API_URL: "http://127.0.0.1:54321",
			SERVICE_ROLE_KEY: "private-service-role",
		},
		{ PATH: "/test/bin" },
	);
	assert.deepEqual(environment, {
		PATH: "/test/bin",
		SUPABASE_SERVICE_ROLE_KEY: "private-service-role",
		SUPABASE_URL: "http://127.0.0.1:54321",
	});
	assert.equal(reset.includes("private-service-role"), false);
	assert.equal(publishMedia.includes("private-service-role"), false);
	assert.throws(
		() => backendMediaPublishEnvironment({ API_URL: "http://127.0.0.1:54321" }),
		/secret\/service-role key/,
	);
});

test("backend environment replacement stages secrets privately and leaves no worktree temp file", () => {
	const directory = mkdtempSync(path.join(tmpdir(), "ios-lane-backend-env-"));
	const worktreeDirectory = path.join(directory, "worktree");
	const stagingDirectory = path.join(directory, "private-stage");
	const destination = path.join(worktreeDirectory, ".env");
	mkdirSync(worktreeDirectory);
	writeFileSync(destination, "OLD=value\n", { mode: 0o600 });
	try {
		replaceFileFromPrivateStage(destination, "SECRET=new-value\n", {
			stagingDirectory,
		});
		assert.equal(readFileSync(destination, "utf8"), "SECRET=new-value\n");
		assert.equal(statSync(destination).mode & 0o777, 0o600);
		assert.equal(statSync(stagingDirectory).mode & 0o777, 0o700);
		assert.deepEqual(readdirSync(worktreeDirectory), [".env"]);
		assert.deepEqual(readdirSync(stagingDirectory), []);
	} finally {
		rmSync(directory, { force: true, recursive: true });
	}
});

test("CLI defaults to dead-only reaping and gates physical native builds", () => {
	const defaults = parseOptions(["reap"]).options;
	assert.equal(defaults.deadOnly, true);
	assert.equal(defaults.acknowledgePhysicalBuild, false);
	assert.equal(defaults.acknowledgeStaleOwner, false);
	const acknowledged = parseOptions([
		"up",
		"--acknowledge-physical-build",
		"--acknowledge-stale-owner",
	]).options;
	assert.equal(acknowledged.acknowledgePhysicalBuild, true);
	assert.equal(acknowledged.acknowledgeStaleOwner, true);
});

test("simulator pool names never allocate beyond the configured maximum", () => {
	assert.equal(managedSimulatorNumber("PUMPD Agent Lane 1"), 1);
	assert.equal(managedSimulatorNumber("PUMPD Agent Lane 6"), 6);
	assert.equal(managedSimulatorNumber("PUMPD Agent Lane 7"), null);
	assert.equal(managedSimulatorNumber("PUMPD Agent Lane 06"), null);
});

test("simulator reuse deterministically selects the lowest eligible lane number", () => {
	const runtimeIdentifier = "com.apple.CoreSimulator.SimRuntime.iOS-26-5";
	const devices = [
		{ name: "PUMPD Agent Lane 5", runtimeIdentifier, udid: "SIM-5" },
		{ name: "PUMPD Agent Lane 2", runtimeIdentifier, udid: "SIM-2" },
		{ name: "PUMPD Agent Lane 1", runtimeIdentifier, udid: "SIM-1" },
	];
	assert.equal(
		selectReusableSimulator(devices, { assigned: new Set(["SIM-1"]) })?.udid,
		"SIM-2",
	);
	assert.equal(
		selectReusableSimulator(devices, {
			assigned: new Set(["SIM-1"]),
			coolingDown: new Set(["SIM-2"]),
		})?.udid,
		"SIM-5",
	);
});
