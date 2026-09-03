import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
	laneEligibleForReap,
	sameResolvedTarget,
} from "../scripts/ios-session-lane.mjs";
import { renderScreenshotIdentity } from "../scripts/lane-controller.mjs";
import { renderEvidenceMatchesLane } from "../scripts/lane-evidence.mjs";
import {
	chooseMetroPort,
	laneWithMetroProcess,
	tailscaleServeMappingMatchesLane,
	tailscaleServeOffArgs,
	tailscaleServePorts,
	tailscaleServeStartArgs,
	tailscaleStatusHasHttpsPort,
} from "../scripts/lane-metro.mjs";

test("a newly spawned Metro identity is tracked locally before registry persistence", () => {
	const lane = {
		key: "codex:lane-a",
		metro: { nonce: "nonce", port: 8087, tailscale: null },
	};
	const process = {
		host: "127.0.0.1",
		pid: 12345,
		processStartedAt: "Mon Sep  3 12:00:00 2026",
		startedAt: "2026-09-03T19:00:00.000Z",
		url: "http://127.0.0.1:8087",
	};
	const tracked = laneWithMetroProcess(lane, process);
	assert.equal(tracked.metro.pid, process.pid);
	assert.equal(tracked.metro.processStartedAt, process.processStartedAt);
	assert.equal(lane.metro.pid, undefined);
});

test("stale reaping removes only dead metadata and never a live lane", () => {
	const lane = { key: "codex:lane-a", updatedAt: "2026-01-01T00:00:00.000Z" };
	const selection = { cutoff: Date.parse("2026-01-02T00:00:00.000Z") };
	assert.equal(laneEligibleForReap(lane, selection, () => false), true);
	assert.equal(laneEligibleForReap(lane, selection, () => true), false);
	assert.equal(
		laneEligibleForReap(lane, { ...selection, excludeKey: lane.key }, () => false),
		false,
	);
});

test("resolved physical and simulator targets transition only when identity changes", () => {
	assert.equal(
		sameResolvedTarget(
			{ kind: "simulator", udid: "SIM-A" },
			{ kind: "simulator", udid: "SIM-A" },
		),
		true,
	);
	assert.equal(
		sameResolvedTarget(
			{ alias: "arens-iphone-pro", deviceId: "PHONE-A", kind: "physical" },
			{ alias: "arens-iphone-pro", deviceId: "PHONE-B", kind: "physical" },
		),
		false,
	);
	assert.equal(
		sameResolvedTarget(
			{ kind: "simulator", udid: "SIM-A" },
			{ alias: "arens-iphone-pro", deviceId: "PHONE-A", kind: "physical" },
		),
		false,
	);
});

test("Tailscale teardown is scoped to the lane HTTPS port", () => {
	assert.deepEqual(tailscaleServeOffArgs(8087), [
		"serve",
		"--https=8087",
		"--yes",
		"off",
	]);
	const status = {
		TCP: { 8087: { HTTPS: true } },
		Web: {
			"mac.tailnet.ts.net:8087": {
				Handlers: { "/": { Proxy: "http://127.0.0.1:8087" } },
			},
		},
	};
	assert.equal(tailscaleStatusHasHttpsPort(status, 8087), true);
	assert.equal(tailscaleStatusHasHttpsPort(status, 8088), false);
	assert.deepEqual(tailscaleServeStartArgs(8087), [
		"serve",
		"--https=8087",
		"http://127.0.0.1:8087",
	]);
	assert.equal(tailscaleServeStartArgs(8087).includes("--yes"), false);
	const lane = {
		metro: {
			port: 8087,
			tailscale: {
				serveHttpsPort: 8087,
				serveProxyUrl: "http://127.0.0.1:8087",
			},
		},
	};
	assert.equal(tailscaleServeMappingMatchesLane(status, lane), true);
	status.Web["mac.tailnet.ts.net:8087"].Handlers["/"].Proxy = "http://127.0.0.1:9999";
	assert.equal(tailscaleServeMappingMatchesLane(status, lane), false);
	status.Web["mac.tailnet.ts.net:8087"].Handlers["/"].Proxy = "http://127.0.0.1:8087";
	status.Services = {
		"svc:other": {
			TCP: { 8087: { HTTPS: true } },
			Web: {
				"other.tailnet.ts.net:8087": {
					Handlers: { "/": { Proxy: "http://127.0.0.1:7777" } },
				},
			},
		},
	};
	assert.equal(tailscaleServeMappingMatchesLane(status, lane), false);
});

test("Tailscale-aware allocation reserves every machine-global Serve port", async () => {
	const registry = { lanes: {} };
	const isAvailable = async () => true;
	const baseline = await chooseMetroPort(registry, "", { isAvailable });
	const status = {
		servicesConfiguration: {
			services: {
				"svc:configured-only": {
					endpoints: { [`tcp:${baseline + 3}`]: "http://127.0.0.1:9100" },
				},
			},
		},
		Services: {
			"svc:example": {
				TCP: {
					[baseline]: { HTTPS: true },
					[baseline + 2]: { TCPForward: "127.0.0.1:9000" },
				},
				Web: {
					[`service.tailnet.ts.net:${baseline}`]: {
						Handlers: { "/": { Proxy: `http://127.0.0.1:${baseline}` } },
					},
				},
			},
		},
	};
	assert.deepEqual(
		[...tailscaleServePorts(status)].sort((left, right) => left - right),
		[baseline, baseline + 2, baseline + 3],
	);
	assert.equal(
		await chooseMetroPort(registry, "", {
			exposure: "tailscale",
			isAvailable,
			tailscaleStatus: status,
		}),
		baseline + 1,
	);
	assert.equal(
		await chooseMetroPort(registry, "", {
			exposure: "local",
			isAvailable,
			tailscaleStatus: status,
		}),
		baseline,
	);
});

test("render evidence must be newer than both Metro and native verification", () => {
	const directory = mkdtempSync(path.join(tmpdir(), "ios-lane-evidence-"));
	const screenshot = path.join(directory, "render.png");
	writeFileSync(screenshot, "not-empty");
	const lane = {
		metro: { startedAt: "2026-01-01T00:00:01.000Z" },
		native: { verifiedAt: "2026-01-01T00:00:02.000Z" },
		render: {
			...renderScreenshotIdentity(screenshot),
			metroConnectionVerifiedAt: "2026-01-01T00:00:03.000Z",
			screenshot,
			verifiedAt: "2026-01-01T00:00:03.000Z",
		},
	};
	assert.equal(renderEvidenceMatchesLane(lane), true);
	lane.render.verifiedAt = "2026-01-01T00:00:00.000Z";
	assert.equal(renderEvidenceMatchesLane(lane), false);
	lane.render.verifiedAt = "2026-01-01T00:00:03.000Z";
	writeFileSync(screenshot, "mutated-after-proof");
	assert.equal(renderEvidenceMatchesLane(lane), false);
});
