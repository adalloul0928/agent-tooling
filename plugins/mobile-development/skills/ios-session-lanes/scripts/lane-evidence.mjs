import { existsSync, writeFileSync } from "node:fs";
import path from "node:path";
import { localBootstrapStatus } from "./bootstrap-worktree.mjs";
import {
	assertBackendCompatible,
	detectRunningBackend,
	readLocalSupabaseStatus,
	verifyBackendLoopbackBindings,
} from "./lane-backend.mjs";
import {
	laneWriterLeaseIsCurrent,
	renderEvidenceMatchesScreenshot,
	verifyFreshRenderedSimulatorApp,
} from "./lane-controller.mjs";
import {
	currentNativeIdentity,
	installedSimulatorBinaryIdentity,
	readDeviceMarker,
	simulatorInstallMatchesMarker,
} from "./lane-native.mjs";
import { metroIdentityCheck } from "./lane-metro.mjs";
import {
	now,
	profile,
	repoRoot,
} from "./lane-runtime-context.mjs";
import {
	metroProcessOwned,
	readRegistry,
	targetResourceKey,
} from "./lane-state.mjs";
import { readSimulatorDevices } from "./lane-target.mjs";

const appId = profile.mobile.appId;

export async function collectEvidence(lane, { refreshRender = true } = {}) {
	const checks = [];
	checks.push(check("last-error", !lane.lastError, lane.lastError ?? "none"));
	const bootstrap = localBootstrapStatus({ projectRoot: repoRoot });
	checks.push(
		check(
			"bootstrap",
			bootstrap.ok,
			bootstrap.ok ? "receipt current" : bootstrap.reasons.join("; "),
		),
	);
	checks.push(check("worktree", path.resolve(lane.worktree) === repoRoot, lane.worktree));
	checks.push(check("metro-process", metroProcessOwned(lane), `pid ${lane.metro.pid ?? "none"}`));
	checks.push(await metroIdentityCheck(lane));
	if (lane.target.kind === "simulator") {
		const currentRegistry = readRegistry();
		const currentLane = currentRegistry.lanes[lane.key];
		if (
			refreshRender &&
			currentLane &&
			laneWriterLeaseIsCurrent(currentRegistry, currentLane, "agent-device")
		) {
			try {
				await verifyFreshRenderedSimulatorApp(currentLane);
				lane = readRegistry().lanes[lane.key] ?? lane;
			} catch (error) {
				checks.push(check("fresh-render", false, error.message));
			}
		}
		const device = readSimulatorDevices().find((item) => item.udid === lane.target.udid);
		checks.push(check("simulator-booted", device?.state === "Booted", device?.state ?? "missing"));
		const installed = installedSimulatorBinaryIdentity(lane.target.udid);
		checks.push(
			check(
				"app-installed",
				Boolean(installed?.appPath),
				installed?.appPath ?? appId,
			),
		);
		const marker = readDeviceMarker(lane.target.udid);
		let currentIdentity = null;
		let identityError = null;
		try {
			currentIdentity = currentNativeIdentity();
		} catch (error) {
			identityError = error.message;
		}
		checks.push(
			check(
				"native-fingerprint",
				Boolean(
					currentIdentity?.cacheKey &&
					lane.native?.cacheKey === currentIdentity.cacheKey &&
					marker?.cacheKey === currentIdentity.cacheKey &&
					simulatorInstallMatchesMarker(lane.target.udid, marker)
				),
				identityError ?? lane.native?.decision ?? "missing",
			),
		);
		checks.push(
			check(
				"rendered-app",
				renderEvidenceMatchesLane(lane),
				lane.render?.screenshot ?? "not verified",
			),
		);
	} else {
		checks.push(pendingCheck("physical-device", "joint device validation remains pending"));
	}
	if (lane.backend === "local") {
		const running = readLocalSupabaseStatus({ allowFailure: true });
		let compatible = false;
		let detail = "not running";
		if (running) {
			try {
				const detected = detectRunningBackend();
				assertBackendCompatible(detected);
				verifyBackendLoopbackBindings();
				compatible = true;
				detail = detected.mountWorktree ?? "mount unknown";
			} catch (error) {
				detail = error.message;
			}
		}
		checks.push(check("shared-backend", compatible, detail));
	} else {
		checks.push(check("preview-backend", true, "EAS Preview development environment"));
	}
	const registry = readRegistry();
	const lease = registry.resources.controllers[targetResourceKey(lane.target)];
	checks.push(
		check(
			"controller-writer",
			lease?.ownerKey === lane.key && lease?.controller === lane.controller?.controller,
			lease ? `${lease.controller}:${lease.ownerKey}` : "missing",
		),
	);
	const hasFailure = checks.some((item) => item.status === "fail");
	const hasPending = checks.some((item) => item.status === "pending");
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
		passed: !hasFailure && !hasPending,
		physicalJointTestPending: lane.target.kind === "physical",
		status: hasFailure ? "failed" : hasPending ? "pending" : "passed",
		version: 1,
	};
}

export function renderEvidenceMatchesLane(lane) {
	const renderTime = Date.parse(lane.render?.verifiedAt ?? "");
	const metroConnectionTime = Date.parse(lane.render?.metroConnectionVerifiedAt ?? "");
	const metroTime = Date.parse(lane.metro?.startedAt ?? "");
	const nativeTime = Date.parse(lane.native?.verifiedAt ?? "");
	return Boolean(
		lane.render?.verifiedAt &&
		lane.render?.metroConnectionVerifiedAt &&
		existsSync(lane.render?.screenshot) &&
		renderEvidenceMatchesScreenshot(lane.render) &&
		Number.isFinite(renderTime) &&
		Number.isFinite(metroConnectionTime) &&
		renderTime >= metroTime &&
		renderTime >= nativeTime &&
		metroConnectionTime >= metroTime &&
		metroConnectionTime >= nativeTime
	);
}

export function writeEvidence(lane, evidence) {
	writeFileSync(lane.evidenceFile, `${JSON.stringify(evidence, null, 2)}\n`, {
		mode: 0o600,
	});
}

export function failedCheckNames(evidence) {
	return evidence.checks.filter((item) => item.status === "fail").map((item) => item.name);
}

function check(name, ok, detail) {
	return { detail: String(detail), name, ok: Boolean(ok), status: ok ? "pass" : "fail" };
}

function pendingCheck(name, detail) {
	return { detail: String(detail), name, ok: false, status: "pending" };
}
