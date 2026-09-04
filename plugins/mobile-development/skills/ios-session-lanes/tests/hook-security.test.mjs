import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
	appendFileSync,
	chmodSync,
	closeSync,
	existsSync,
	fsyncSync,
	ftruncateSync,
	mkdirSync,
	mkdtempSync,
	openSync,
	readFileSync,
	readdirSync,
	realpathSync,
	rmSync,
	statSync,
	symlinkSync,
	writeFileSync,
	writeSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
	localBootstrapStatus,
	managedWorktreeAttestationStatus,
	receiptPathFor,
	writeManagedWorktreeAttestation,
} from "../scripts/bootstrap-worktree.mjs";
import {
	directBackendReason,
	directIosReason,
	directWorktreeReason,
	laneWrapperReason,
	requestedDeviceId,
	shellDynamicExecutionReason,
	shellSubstitutionReason,
	trustedLaneInvocationReason,
} from "../scripts/ios-session-hook.mjs";
import { assertSafeRuntimeRoot, install } from "../scripts/install-runtime.mjs";
import { normalizeGitHubOrigin, projectMatch } from "../scripts/project-context.mjs";

const hookPath = fileURLToPath(new URL("../scripts/ios-session-hook.mjs", import.meta.url));
const installerPath = fileURLToPath(new URL("../scripts/install-runtime.mjs", import.meta.url));
const legacyFiles = [
	"references/pumpd-project.json",
	"references/workflow.md",
	"scripts/bootstrap-worktree.mjs",
	"scripts/create-worktree.mjs",
	"scripts/install-runtime.mjs",
	"scripts/ios-session-hook.mjs",
	"scripts/ios-session-lane.mjs",
	"scripts/project-context.mjs",
];

function hash(value) {
	return createHash("sha256").update(value).digest("hex");
}

function legacyWrapperDocument(scriptPath) {
	return `#!/bin/sh\nexec node "${scriptPath.replaceAll('"', '\\"')}" "$@"\n`;
}

function createLegacyInstallation(fakeHome) {
	const runtimeRoot = path.join(
		fakeHome,
		"Library",
		"Application Support",
		"agent-tooling",
		"ios-session-lanes",
		"runtime",
	);
	const binDir = path.join(fakeHome, ".local", "bin");
	for (const relative of legacyFiles) {
		const destination = path.join(runtimeRoot, relative);
		mkdirSync(path.dirname(destination), { recursive: true });
		writeFileSync(destination, `legacy:${relative}\n`);
	}
	const hookPath = path.join(runtimeRoot, "scripts/ios-session-hook.mjs");
	const lanePath = path.join(runtimeRoot, "scripts/ios-session-lane.mjs");
	writeFileSync(
		path.join(runtimeRoot, "runtime-integrity.json"),
		`${JSON.stringify({
			scripts: {
				hook: { path: hookPath, sha256: hash(readFileSync(hookPath)) },
				lane: { path: lanePath, sha256: hash(readFileSync(lanePath)) },
			},
			version: 1,
		})}\n`,
	);
	mkdirSync(binDir, { recursive: true });
	const wrappers = {
		"ios-session-bootstrap": "bootstrap-worktree.mjs",
		"ios-session-lane": "ios-session-lane.mjs",
		"ios-session-worktree": "create-worktree.mjs",
	};
	for (const [name, script] of Object.entries(wrappers)) {
		writeFileSync(
			path.join(binDir, name),
			legacyWrapperDocument(path.join(runtimeRoot, "scripts", script)),
			{ mode: 0o755 },
		);
	}
	return { binDir, runtimeRoot, wrappers };
}

function runLegacyInstaller(fakeHome, extraArgs = []) {
	return spawnSync(
		process.execPath,
		[installerPath, "--migrate-legacy-runtime", ...extraArgs],
		{
			encoding: "utf8",
			env: { ...process.env, HOME: fakeHome },
		},
	);
}

function runRuntimeCheck(runtimeRoot, binDir, extraArgs = [], placement = "after") {
	const base = [
		"--check",
		"--runtime-root",
		runtimeRoot,
		"--bin-dir",
		binDir,
	];
	return spawnSync(
		process.execPath,
		[installerPath, ...(placement === "before" ? [...extraArgs, ...base] : [...base, ...extraArgs])],
		{ encoding: "utf8" },
	);
}

function legacySnapshot(fixture, settingsFile = "") {
	return {
		modes: {
			settings: settingsFile ? statSync(settingsFile).mode & 0o777 : 0,
			wrappers: Object.fromEntries(
				Object.keys(fixture.wrappers).map((name) => [
					name,
					statSync(path.join(fixture.binDir, name)).mode & 0o777,
				]),
			),
		},
		runtime: Object.fromEntries(
			[...legacyFiles, "runtime-integrity.json"].map((relative) => [
				relative,
				readFileSync(path.join(fixture.runtimeRoot, relative), "utf8"),
			]),
		),
		settings: settingsFile ? readFileSync(settingsFile, "utf8") : "",
		wrappers: Object.fromEntries(
			Object.keys(fixture.wrappers).map((name) => [
				name,
				readFileSync(path.join(fixture.binDir, name), "utf8"),
			]),
		),
	};
}

function treeSnapshot(root) {
	const entries = [];
	function visit(absolute, relative) {
		const metadata = statSync(absolute);
		if (metadata.isDirectory()) {
			entries.push({ mode: metadata.mode & 0o7777, path: relative, type: "directory" });
			for (const entry of readdirSync(absolute, { withFileTypes: true }).sort((a, b) =>
				a.name.localeCompare(b.name),
			)) {
				visit(
					path.join(absolute, entry.name),
					relative === "." ? entry.name : `${relative}/${entry.name}`,
				);
			}
			return;
		}
		entries.push({
			contents: readFileSync(absolute).toString("base64"),
			mode: metadata.mode & 0o7777,
			path: relative,
			type: "file",
		});
	}
	visit(root, ".");
	return entries;
}

function activeInstallerArtifact(name) {
	return (
		(name.includes(".stage-") && !name.includes(".abandoned-stage-")) ||
		name.includes(".legacy-backup-") ||
		name.includes(".previous-install-backup-")
	);
}

function git(root, args) {
	const result = spawnSync("git", args, { cwd: root, encoding: "utf8" });
	assert.equal(result.status, 0, result.stderr);
	return result.stdout.trim();
}

function createProject() {
	const root = mkdtempSync(path.join(tmpdir(), "pumpd-lane-hook-security-"));
	for (const relative of [
		"apps/mobile/app.config.ts",
		"apps/backend/supabase/config.toml",
		"pnpm-lock.yaml",
	]) {
		const destination = path.join(root, relative);
		mkdirSync(path.dirname(destination), { recursive: true });
		writeFileSync(destination, `${relative}\n`);
	}
	writeFileSync(
		path.join(root, "package.json"),
		`${JSON.stringify({ packageManager: "pnpm@10.34.5" })}\n`,
	);
	writeFileSync(
		path.join(root, "apps/mobile/eas.json"),
		`${JSON.stringify({ cli: { version: "21.0.2" } })}\n`,
	);
	git(root, ["init", "-q"]);
	git(root, ["remote", "add", "origin", "git@github.com:avad-technologies/pumpd-mobile-app.git"]);
	return root;
}

test("GitHub origin matching is canonical rather than substring based", () => {
	for (const origin of [
		"https://github.com/avad-technologies/pumpd-mobile-app.git",
		"git@github.com:avad-technologies/pumpd-mobile-app.git",
		"ssh://git@github.com/AVAD-TECHNOLOGIES/PUMPD-MOBILE-APP.git",
	]) {
		assert.equal(
			normalizeGitHubOrigin(origin),
			"github.com/avad-technologies/pumpd-mobile-app",
		);
	}
	for (const origin of [
		"https://github.com/attacker/pumpd-mobile-app.git",
		"https://github.com/avad-technologies/pumpd-mobile-app-evil.git",
		"https://evil.example/avad-technologies/pumpd-mobile-app.git",
	]) {
		assert.notEqual(
			normalizeGitHubOrigin(origin),
			"github.com/avad-technologies/pumpd-mobile-app",
		);
	}
	const project = createProject();
	assert.equal(projectMatch(project).ok, true);
	git(project, ["remote", "set-url", "origin", "https://github.com/attacker/pumpd-mobile-app.git"]);
	assert.equal(projectMatch(project).ok, false);
});

test("managed worktree attestations are private and bound to the exact worktree", () => {
	const root = createProject();
	const resolvedBaseCommit = "a".repeat(40);
	const written = writeManagedWorktreeAttestation(
		{ projectRoot: root },
		{ client: "codex", requestedBaseRef: "origin/codex/integration", resolvedBaseCommit },
	);
	assert.equal(written.attestation.createdBy, "ios-session-worktree");
	assert.equal(written.attestation.requestedBaseRef, "origin/codex/integration");
	assert.equal(written.attestation.resolvedBaseCommit, resolvedBaseCommit);
	assert.equal(managedWorktreeAttestationStatus({ projectRoot: root }).ok, true);
	chmodSync(written.attestationPath, 0o644);
	assert.equal(managedWorktreeAttestationStatus({ projectRoot: root }).ok, false);
	chmodSync(written.attestationPath, 0o600);
	writeFileSync(
		written.attestationPath,
		`${JSON.stringify({ ...written.attestation, requestedBaseRef: "origin/../attacker" })}\n`,
		{ mode: 0o600 },
	);
	assert.equal(managedWorktreeAttestationStatus({ projectRoot: root }).ok, false);
});

test("bootstrap receipts detect value-only mobile environment changes", () => {
	const root = createProject();
	const mobileEnvPath = path.join(root, "apps/mobile/.env.local");
	mkdirSync(path.join(root, "node_modules"));
	const environment = [
		"APP_VARIANT=development",
		"EXPO_PUBLIC_SUPABASE_KEY=first-key",
		"EXPO_PUBLIC_SUPABASE_URL=https://first.example",
		"GOOGLE_IOS_URL_SCHEME=first-scheme",
		"",
	].join("\n");
	writeFileSync(mobileEnvPath, environment, { mode: 0o600 });
	const lockfile = readFileSync(path.join(root, "pnpm-lock.yaml"));
	const receiptPath = receiptPathFor({ projectRoot: root });
	writeFileSync(
		receiptPath,
		`${JSON.stringify({
			completedAt: new Date().toISOString(),
			inputs: {
				backendConfigHash: hash(
					readFileSync(path.join(root, "apps/backend/supabase/config.toml")),
				),
				dopplerConfig: "dev_personal",
				easEnvironment: "development",
				easVersion: "21.0.2",
				lockfileHash: hash(lockfile),
				packageManager: "pnpm@10.34.5",
				pnpmVersion: "10.34.5",
			},
			mobile: { contentHash: hash(environment) },
			version: 5,
		})}\n`,
		{ mode: 0o600 },
	);
	assert.equal(localBootstrapStatus({ projectRoot: root }).ok, true);
	writeFileSync(
		mobileEnvPath,
		environment.replace("https://first.example", "https://second.example"),
	);
	assert.match(
		localBootstrapStatus({ projectRoot: root }).reasons.join("; "),
		/mobile environment differs from receipt/,
	);
	writeFileSync(
		path.join(root, "package.json"),
		`${JSON.stringify({ packageManager: "pnpm@10.34.6" })}\n`,
	);
	assert.throws(
		() => localBootstrapStatus({ projectRoot: root }),
		/trusted packageManager pnpm@10\.34\.5/,
	);
	writeFileSync(
		path.join(root, "package.json"),
		`${JSON.stringify({ packageManager: "pnpm@10.34.5" })}\n`,
	);
	writeFileSync(
		path.join(root, "apps/mobile/eas.json"),
		`${JSON.stringify({ cli: { version: "21.0.3" } })}\n`,
	);
	assert.throws(
		() => localBootstrapStatus({ projectRoot: root }),
		/trusted EAS CLI 21\.0\.2/,
	);
});

test("SessionStart never runs bootstrap commands in an unattested worktree", () => {
	const root = createProject();
	const result = spawnSync(process.execPath, [hookPath, "start", "--client", "codex"], {
		cwd: root,
		encoding: "utf8",
		input: JSON.stringify({ cwd: root, session_id: "security-test-session" }),
	});
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stdout, /WORKTREE BOOTSTRAP REQUIRED/);
	assert.match(result.stdout, /SessionStart did not run pnpm, EAS, or Doppler/);
	assert.equal(existsSync(path.join(root, "node_modules")), false);
	assert.equal(existsSync(path.join(root, "apps/mobile/.env.local")), false);
});

test("shell guards reject substitutions and alternate raw command forms", () => {
	for (const command of [
		'echo "$(supabase stop)"',
		"echo `supabase stop`",
		"cat <(xcrun simctl erase all)",
	]) {
		assert.match(shellSubstitutionReason(command), /substitutions/);
	}
	for (const command of [
		"cd apps/mobile && pnpm ios",
		"cd apps/mobile/ && pnpm ios",
		"pushd apps/mobile && pnpm ios",
		"pnpm -C apps/mobile ios",
		"pnpm --dir=apps/mobile start:local",
		"pnpm --filter @pumpd/mobile ios",
		"xcr''un --sdk iphonesimulator simctl boot lane-udid",
		"xcr\\\nun simctl --set /tmp/devices.plist boot lane-udid",
		"e''xpo start --port 8099",
	]) {
		assert.match(directIosReason(command), /bypass/);
	}
	assert.match(
		directIosReason("eas build --platform ios --profile=development"),
		/development build/,
	);
	for (const command of [
		"cd apps/backend && pnpm db:reset",
		"pnpm -C apps/backend stop",
		"pnpm --filter @pumpd/backend start",
		"supabase --workdir apps/backend stop",
	]) {
		assert.match(directBackendReason(command), /single-owner|owner lease/);
	}
	assert.match(directWorktreeReason("git -C . worktree add ../feature feature"), /bootstrap/);
	assert.match(
		directWorktreeReason("git -c advice.detachedHead=false worktree add ../feature feature"),
		/bootstrap/,
	);
	assert.match(
		shellDynamicExecutionReason("tool=expo; $tool start --port 8099"),
		/shell variables/,
	);
	assert.equal(shellDynamicExecutionReason("tool=printf; $tool ok"), "");
	assert.match(
		shellDynamicExecutionReason(
		"tool=ios-session-lane; $tool down --client codex --session-id other",
		),
		/shell variables/,
	);
	assert.match(
		laneWrapperReason(
			'ios-session-lane status --client codex --session-id lane "$(supabase stop)"',
			"codex",
			"lane",
		),
		/only top-level/,
	);
});

test("the actual pre-tool hook has no whole-command inspection bypass", () => {
	const root = createProject();
	const result = spawnSync(process.execPath, [hookPath, "pretool", "--client", "codex"], {
		cwd: root,
		encoding: "utf8",
		input: JSON.stringify({
			cwd: root,
			session_id: "security-test-session",
			tool_input: { command: 'echo "$(supabase stop)"' },
			tool_name: "Bash",
		}),
	});
	assert.equal(result.status, 0, result.stderr);
	const decision = JSON.parse(result.stdout);
	assert.equal(decision.hookSpecificOutput.permissionDecision, "deny");
	assert.match(decision.hookSpecificOutput.permissionDecisionReason, /substitutions/);
});

test("the actual Codex Bash hook denies normalized command bypass forms", () => {
	const root = createProject();
	const commands = [
		"xcr''un simctl boot LANE",
		"e''xpo start --port 9999",
		"xcr\\\nun simctl boot LANE",
		"tool=expo; $tool start --port 9999",
		"tool=ios-session-lane; $tool down --client codex --session-id other",
		"xcrun simctl --set /tmp/device_set.plist boot LANE",
		"xcrun --sdk iphonesimulator simctl boot LANE",
		"eas build --platform ios --profile=development",
		"supabase --workdir apps/backend stop",
		"git -c advice.detachedHead=false worktree add ../x main",
		"cd apps/mobile/ && pnpm ios",
		"pushd apps/mobile && pnpm ios",
		"ios-session-''lane down --client codex --session-id other",
	];
	for (const command of commands) {
		const result = spawnSync(process.execPath, [hookPath, "pretool", "--client", "codex"], {
			cwd: root,
			encoding: "utf8",
			input: JSON.stringify({
				cwd: root,
				session_id: "security-test-session",
				tool_input: { command },
				tool_name: "Bash",
			}),
		});
		assert.equal(result.status, 0, result.stderr);
		assert.equal(
			JSON.parse(result.stdout).hookSpecificOutput.permissionDecision,
			"deny",
			command,
		);
	}
});

test("the actual pre-tool hook permits unrelated shell substitutions and variables", () => {
	const root = createProject();
	for (const command of [
		'echo "$(date)"',
		"cat <(printf harmless)",
		"tool=printf; $tool '%s\\n' harmless",
	]) {
		const result = spawnSync(process.execPath, [hookPath, "pretool", "--client", "codex"], {
			cwd: root,
			encoding: "utf8",
			input: JSON.stringify({
				cwd: root,
				session_id: "security-test-session",
				tool_input: { command },
				tool_name: "Bash",
			}),
		});
		assert.equal(result.status, 0, result.stderr);
		assert.equal(result.stdout, "", command);
	}
});

test("the actual pre-tool hook permits wrapper inspection but still denies guarded companions", () => {
	const root = createProject();
	for (const command of [
		"rg -n ios-session-lane plugins",
		"rg -n 'ios-session-worktree' .",
		"printf '%s\\n' ios-session-lane",
		"command -v ios-session-lane",
		'echo "$(rg ios-session-lane .)"',
	]) {
		const result = spawnSync(process.execPath, [hookPath, "pretool", "--client", "codex"], {
			cwd: root,
			encoding: "utf8",
			input: JSON.stringify({
				cwd: root,
				session_id: "security-test-session",
				tool_input: { command },
				tool_name: "Bash",
			}),
		});
		assert.equal(result.status, 0, result.stderr);
		assert.equal(result.stdout, "", command);
	}
	for (const command of [
		"rg ios-session-lane .; xcrun simctl boot OTHER-UDID",
		"echo ios-session-lane && expo start --port 9999",
		"ios-session-lane status --client codex --session-id security-test-session; supabase stop",
	]) {
		const result = spawnSync(process.execPath, [hookPath, "pretool", "--client", "codex"], {
			cwd: root,
			encoding: "utf8",
			input: JSON.stringify({
				cwd: root,
				session_id: "security-test-session",
				tool_input: { command },
				tool_name: "Bash",
			}),
		});
		assert.equal(result.status, 0, result.stderr);
		assert.equal(JSON.parse(result.stdout).hookSpecificOutput.permissionDecision, "deny", command);
	}
});

test("device identifiers exclude generic IDs and reject ambiguity", () => {
	assert.equal(requestedDeviceId({ id: "unrelated", params: { udid: "LANE-UDID" } }), "LANE-UDID");
	assert.equal(
		requestedDeviceId({ deviceId: "ONE", nested: { simulator_id: "TWO" } }),
		"",
	);
	assert.equal(requestedDeviceId({ id: "unrelated-only" }), "");
});

test("installed lane wrappers require the runtime path and digest handshake", async () => {
	const root = mkdtempSync(path.join(tmpdir(), "pumpd-lane-integrity-"));
	const runtimeRoot = path.join(root, "runtime");
	const binDir = path.join(root, "bin");
	const installed = await install({
		binDir,
		claudeSettingsFile: "",
		codexHooksFile: "",
		dryRun: false,
		removeManagedUserHooks: false,
		runtimeRoot,
	});
	const installedRuntimeRoot = installed.runtimeRoot;
	const installedHook = await import(
		`${pathToFileURL(path.join(installedRuntimeRoot, "scripts/ios-session-hook.mjs")).href}?integrity=${Date.now()}`
	);
	const wrapperPath = path.join(binDir, "ios-session-lane");
	const wrapperDocument = readFileSync(wrapperPath, "utf8");
	const command = `${JSON.stringify(wrapperPath)} status --client codex --session-id test-session`;
	assert.equal(
		installedHook.trustedLaneInvocationReason(command, {
			cwd: root,
			environment: { ...process.env, PATH: binDir },
			runtimeRoot: installedRuntimeRoot,
		}),
		"",
	);
	appendFileSync(wrapperPath, "# tampered\n");
	assert.match(
		installedHook.trustedLaneInvocationReason(command, {
			cwd: root,
			environment: { ...process.env, PATH: binDir },
			runtimeRoot: installedRuntimeRoot,
		}),
		/exact generated|digest/,
	);
	writeFileSync(wrapperPath, wrapperDocument, { mode: 0o755 });
	await install({
		binDir,
		claudeSettingsFile: "",
		codexHooksFile: "",
		dryRun: false,
		removeManagedUserHooks: false,
		runtimeRoot,
	});
	const repairedHook = await import(
		`${pathToFileURL(path.join(installedRuntimeRoot, "scripts/ios-session-hook.mjs")).href}?integrity-repaired=${Date.now()}`
	);
	const dependencyPath = path.join(installedRuntimeRoot, "scripts/lane-state.mjs");
	appendFileSync(dependencyPath, "// tampered dependency\n");
	assert.match(
		repairedHook.trustedLaneInvocationReason(command, {
			cwd: root,
			environment: { ...process.env, PATH: binDir },
			runtimeRoot: installedRuntimeRoot,
		}),
		/complete path and digest handshake/,
	);
	const integrityPath = path.join(installedRuntimeRoot, "runtime-integrity.json");
	const recomputedIntegrity = JSON.parse(readFileSync(integrityPath, "utf8"));
	recomputedIntegrity.files["scripts/lane-state.mjs"] = hash(readFileSync(dependencyPath));
	writeFileSync(integrityPath, `${JSON.stringify(recomputedIntegrity, null, 2)}\n`);
	assert.match(
		trustedLaneInvocationReason(command, {
			cwd: root,
			environment: { ...process.env, PATH: binDir },
			runtimeRoot: installedRuntimeRoot,
		}),
		/complete path and digest handshake|complete runtime revision/,
	);
});

test("v3 integrity rejects runtime mode, empty-directory, and wrapper mode drift", async () => {
	const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-runtime-v3-integrity-")));
	const runtimeRoot = path.join(parent, "runtime");
	const binDir = path.join(parent, "bin");
	const options = {
		binDir,
		claudeSettingsFile: "",
		codexHooksFile: "",
		dryRun: false,
		removeManagedUserHooks: false,
		runtimeRoot,
	};
	try {
		const first = await install(options);
		assert.deepEqual(first.recoveryBackups, []);
		const integrity = JSON.parse(readFileSync(path.join(runtimeRoot, "runtime-integrity.json")));
		assert.equal(integrity.version, 3);
		assert.equal(integrity.wrappers["ios-session-lane"].mode, 0o755);
		assert.equal(integrity.tree.some((entry) => entry.path === "scripts"), true);
		assert.equal(integrity.tree.some((entry) => entry.path === "runtime-integrity.json"), false);

		const scriptsPath = path.join(runtimeRoot, "scripts");
		const scriptsMode = statSync(scriptsPath).mode & 0o7777;
		const driftMode = scriptsMode === 0o700 ? 0o711 : 0o700;
		const emptyDirectory = path.join(runtimeRoot, "references", "external-empty-directory");
		mkdirSync(emptyDirectory);
		chmodSync(scriptsPath, driftMode);
		await assert.rejects(install(options), /full integrity inventory failed/);
		assert.equal(existsSync(emptyDirectory), true);
		assert.equal(statSync(scriptsPath).mode & 0o7777, driftMode);
		rmSync(emptyDirectory, { recursive: true });
		chmodSync(scriptsPath, scriptsMode);

		const wrapperPath = path.join(binDir, "ios-session-lane");
		chmodSync(wrapperPath, 0o644);
		await assert.rejects(install(options), /unmanaged iOS lane wrapper mode/);
		assert.equal(statSync(wrapperPath).mode & 0o7777, 0o644);
		chmodSync(wrapperPath, 0o755);

		const refreshed = await install(options);
		assert.equal(refreshed.recoveryBackups.length, 4);
		for (const backup of refreshed.recoveryBackups) assert.equal(existsSync(backup.path), true);
	} finally {
		rmSync(parent, { force: true, recursive: true });
	}
});

test("runtime check validates the current installation without any filesystem mutation", async () => {
	const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-runtime-check-current-")));
	const runtimeRoot = path.join(parent, "runtime");
	const binDir = path.join(parent, "bin");
	const settingsFile = path.join(parent, "settings.json");
	try {
		await install({
			binDir,
			claudeSettingsFile: "",
			codexHooksFile: "",
			dryRun: false,
			removeManagedUserHooks: false,
			runtimeRoot,
		});
		const before = treeSnapshot(parent);
		const result = runRuntimeCheck(runtimeRoot, binDir);
		assert.equal(result.status, 0, result.stderr);
		assert.equal(result.stderr, "");
		assert.deepEqual(JSON.parse(result.stdout), {
			binDir,
			integrityVersion: 3,
			runtimeRoot,
			status: "ok",
			wrappers: 3,
		});
		assert.deepEqual(treeSnapshot(parent), before);
		assert.equal(existsSync(`${runtimeRoot}.installer.lock`), false);

		writeFileSync(settingsFile, '{"hooks":{"Existing":[]}}\n', { mode: 0o600 });
		const beforeRejected = treeSnapshot(parent);
		for (const extraArgs of [
			["--dry-run"],
			["--dry-run", "--help"],
			["--migrate-legacy-runtime"],
			["--remove-managed-user-hooks"],
			["--claude-settings-file", settingsFile],
			["--codex-hooks-file", settingsFile],
		]) {
			for (const placement of ["before", "after"]) {
				const rejected = runRuntimeCheck(runtimeRoot, binDir, extraArgs, placement);
				assert.equal(rejected.status, 1, rejected.stdout);
				assert.equal(rejected.stdout, "");
				assert.deepEqual(JSON.parse(rejected.stderr), {
					code: "incompatible-options",
					message: `--check cannot be combined with ${extraArgs[0]}.`,
					status: "error",
				});
				assert.deepEqual(treeSnapshot(parent), beforeRejected);
			}
		}
	} finally {
		rmSync(parent, { force: true, recursive: true });
	}
});

test("runtime check reports missing, tampered, and source-stale installations without mutation", async () => {
	const cases = [
		{
			code: "runtime-missing",
			name: "missing runtime",
			withoutInstall: true,
		},
		{
			code: "wrapper-missing",
			mutate({ binDir }) {
				rmSync(path.join(binDir, "ios-session-lane"));
			},
			name: "missing wrapper",
		},
		{
			code: "wrapper-content-drift",
			mutate({ binDir }) {
				appendFileSync(path.join(binDir, "ios-session-worktree"), "# stale wrapper\n");
			},
			name: "stale wrapper",
		},
		{
			code: "wrapper-missing",
			mutate({ binDir }) {
				const wrapperPath = path.join(binDir, "ios-session-bootstrap");
				const copyPath = path.join(binDir, "ios-session-bootstrap-copy");
				writeFileSync(copyPath, readFileSync(wrapperPath), { mode: 0o755 });
				rmSync(wrapperPath);
				symlinkSync(copyPath, wrapperPath);
			},
			name: "symlink wrapper",
		},
		{
			code: "runtime-integrity-drift",
			mutate({ runtimeRoot }) {
				appendFileSync(path.join(runtimeRoot, "scripts/lane-state.mjs"), "// tampered runtime\n");
			},
			name: "tampered runtime",
		},
		{
			code: "runtime-integrity-mode-drift",
			mutate({ runtimeRoot }) {
				chmodSync(path.join(runtimeRoot, "runtime-integrity.json"), 0o644);
			},
			name: "integrity manifest mode drift",
		},
		{
			code: "source-revision-drift",
			mutate({ runtimeRoot }) {
				const relative = "references/workflow.md";
				const payloadPath = path.join(runtimeRoot, relative);
				appendFileSync(payloadPath, "\nStale installed revision.\n");
				const integrityPath = path.join(runtimeRoot, "runtime-integrity.json");
				const integrity = JSON.parse(readFileSync(integrityPath, "utf8"));
				const digest = hash(readFileSync(payloadPath));
				integrity.files[relative] = digest;
				integrity.tree.find((entry) => entry.path === relative).sha256 = digest;
				writeFileSync(integrityPath, `${JSON.stringify(integrity, null, 2)}\n`);
			},
			name: "self-consistent stale source payload",
		},
		{
			code: "source-revision-drift",
			mutate({ runtimeRoot }) {
				const relative = "references/workflow.md";
				rmSync(path.join(runtimeRoot, relative));
				const integrityPath = path.join(runtimeRoot, "runtime-integrity.json");
				const integrity = JSON.parse(readFileSync(integrityPath, "utf8"));
				delete integrity.files[relative];
				integrity.tree = integrity.tree.filter((entry) => entry.path !== relative);
				writeFileSync(integrityPath, `${JSON.stringify(integrity, null, 2)}\n`);
			},
			name: "self-consistent missing source payload",
		},
		{
			code: "source-revision-drift",
			mutate({ runtimeRoot }) {
				const relative = "unexpected-runtime.txt";
				const payloadPath = path.join(runtimeRoot, relative);
				writeFileSync(payloadPath, "self-certified extra runtime entry\n", { mode: 0o600 });
				const integrityPath = path.join(runtimeRoot, "runtime-integrity.json");
				const integrity = JSON.parse(readFileSync(integrityPath, "utf8"));
				const digest = hash(readFileSync(payloadPath));
				integrity.files[relative] = digest;
				integrity.tree.push({ mode: 0o600, path: relative, sha256: digest, type: "file" });
				writeFileSync(integrityPath, `${JSON.stringify(integrity, null, 2)}\n`);
			},
			name: "self-consistent extra runtime entry",
		},
		{
			code: "source-revision-drift",
			mutate({ runtimeRoot }) {
				chmodSync(runtimeRoot, 0o711);
				const integrityPath = path.join(runtimeRoot, "runtime-integrity.json");
				const integrity = JSON.parse(readFileSync(integrityPath, "utf8"));
				integrity.tree.find((entry) => entry.path === ".").mode = 0o711;
				writeFileSync(integrityPath, `${JSON.stringify(integrity, null, 2)}\n`);
			},
			name: "self-consistent runtime root mode drift",
		},
		{
			code: "wrapper-manifest-drift",
			mutate({ runtimeRoot }) {
				const integrityPath = path.join(runtimeRoot, "runtime-integrity.json");
				const integrity = JSON.parse(readFileSync(integrityPath, "utf8"));
				integrity.wrappers.unexpected = {
					mode: 0o755,
					path: "/tmp/unexpected",
					sha256: hash("unexpected"),
				};
				writeFileSync(integrityPath, `${JSON.stringify(integrity, null, 2)}\n`);
			},
			name: "extra wrapper manifest record",
		},
	];
	for (const fixture of cases) {
		const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-runtime-check-drift-")));
		const runtimeRoot = path.join(parent, "runtime");
		const binDir = path.join(parent, "bin");
		try {
			if (!fixture.withoutInstall) {
				await install({
					binDir,
					claudeSettingsFile: "",
					codexHooksFile: "",
					dryRun: false,
					removeManagedUserHooks: false,
					runtimeRoot,
				});
			}
			fixture.mutate?.({ binDir, runtimeRoot });
			const before = treeSnapshot(parent);
			const result = runRuntimeCheck(runtimeRoot, binDir);
			assert.equal(result.status, 1, `${fixture.name}: ${result.stdout}`);
			assert.equal(result.stdout, "", fixture.name);
			const report = JSON.parse(result.stderr);
			assert.equal(report.status, "drift", fixture.name);
			assert.equal(report.code, fixture.code, fixture.name);
			assert.deepEqual(treeSnapshot(parent), before, fixture.name);
			assert.equal(existsSync(`${runtimeRoot}.installer.lock`), false, fixture.name);
		} finally {
			rmSync(parent, { force: true, recursive: true });
		}
	}
});

test("bundled Codex and Claude hooks authenticate a custom-root installed wrapper", async () => {
	const fakeHome = mkdtempSync(path.join(tmpdir(), "pumpd-lane-bundled-hook-home-"));
	const runtimeRoot = path.join(fakeHome, "custom-runtime");
	const binDir = path.join(fakeHome, ".local", "bin");
	const project = createProject();
	try {
		await install({
			binDir,
			claudeSettingsFile: "",
			codexHooksFile: "",
			dryRun: false,
			removeManagedUserHooks: false,
			runtimeRoot,
		});
		const wrapperPath = path.join(binDir, "ios-session-lane");
		const wrapperResult = spawnSync(wrapperPath, ["list"], {
			cwd: project,
			encoding: "utf8",
			env: {
				...process.env,
				HOME: fakeHome,
				IOS_SESSION_LANES_STATE_DIR: path.join(fakeHome, "lane-state"),
			},
		});
		assert.equal(wrapperResult.status, 0, wrapperResult.stderr);
		for (const client of ["codex", "claude"]) {
			const sessionId = `bundled-${client}-session`;
			const result = spawnSync(
				process.execPath,
				[hookPath, "pretool", "--client", client],
				{
					cwd: project,
					encoding: "utf8",
					env: { ...process.env, HOME: fakeHome, PATH: `${binDir}:${process.env.PATH}` },
					input: JSON.stringify({
						cwd: project,
						session_id: sessionId,
						tool_input: {
							command: `${JSON.stringify(wrapperPath)} status --client ${client} --session-id ${sessionId}`,
						},
						tool_name: "Bash",
					}),
				},
			);
			assert.equal(result.status, 0, result.stderr);
			assert.equal(result.stdout, "");
		}
	} finally {
		rmSync(fakeHome, { force: true, recursive: true });
	}
});

test("runtime installation refuses protected and arbitrary existing roots", async () => {
	assert.throws(() => assertSafeRuntimeRoot("/"), /unsafe/);
	assert.throws(() => assertSafeRuntimeRoot(homedir()), /unsafe/);
	assert.throws(() => assertSafeRuntimeRoot(process.cwd()), /unsafe/);
	const parent = mkdtempSync(path.join(tmpdir(), "pumpd-lane-unowned-runtime-"));
	const runtimeRoot = path.join(parent, "existing-runtime");
	mkdirSync(runtimeRoot);
	const sentinel = path.join(runtimeRoot, "do-not-delete.txt");
	writeFileSync(sentinel, "preserve me\n");
	mkdirSync(path.join(runtimeRoot, "scripts"));
	writeFileSync(path.join(runtimeRoot, "scripts/ios-session-hook.mjs"), "forged hook\n");
	writeFileSync(path.join(runtimeRoot, "scripts/ios-session-lane.mjs"), "forged lane\n");
	writeFileSync(
		path.join(runtimeRoot, "runtime-integrity.json"),
		`${JSON.stringify({
			scripts: {
				hook: { path: path.join(runtimeRoot, "scripts/ios-session-hook.mjs") },
				lane: { path: path.join(runtimeRoot, "scripts/ios-session-lane.mjs") },
			},
			version: 1,
		})}\n`,
	);
	try {
		await assert.rejects(
			install({
				binDir: path.join(parent, "bin"),
				claudeSettingsFile: "",
				codexHooksFile: "",
				dryRun: false,
				removeManagedUserHooks: false,
				runtimeRoot,
			}),
			/unowned directory/,
		);
		assert.equal(readFileSync(sentinel, "utf8"), "preserve me\n");
	} finally {
		rmSync(parent, { force: true, recursive: true });
	}
});

test("runtime installation never overwrites an unmanaged wrapper", async () => {
	const parent = mkdtempSync(path.join(tmpdir(), "pumpd-lane-unmanaged-wrapper-"));
	const runtimeRoot = path.join(parent, "runtime");
	const binDir = path.join(parent, "bin");
	mkdirSync(binDir);
	const sentinel = path.join(binDir, "ios-session-lane");
	writeFileSync(sentinel, "#!/bin/sh\necho user-owned\n", { mode: 0o755 });
	try {
		await assert.rejects(
			install({
				binDir,
				claudeSettingsFile: "",
				codexHooksFile: "",
				dryRun: false,
				removeManagedUserHooks: false,
				runtimeRoot,
			}),
			/unmanaged iOS lane wrapper/,
		);
		assert.equal(readFileSync(sentinel, "utf8"), "#!/bin/sh\necho user-owned\n");
		assert.equal(existsSync(runtimeRoot), false);
	} finally {
		rmSync(parent, { force: true, recursive: true });
	}
});

test("installer canonicalizes symlink ancestors but rejects symlink targets and protected aliases", async () => {
	const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-lane-canonical-paths-")));
	const physical = path.join(parent, "physical");
	const alias = path.join(parent, "alias");
	mkdirSync(physical);
	symlinkSync(physical, alias);
	try {
		const installed = await install({
			binDir: path.join(alias, "bin"),
			claudeSettingsFile: "",
			codexHooksFile: "",
			dryRun: false,
			removeManagedUserHooks: false,
			runtimeRoot: path.join(alias, "runtime"),
		});
		assert.equal(installed.runtimeRoot, path.join(physical, "runtime"));
		assert.equal(installed.binDir, path.join(physical, "bin"));

		const binTarget = path.join(parent, "bin-target");
		const binLink = path.join(parent, "bin-link");
		mkdirSync(binTarget);
		symlinkSync(binTarget, binLink);
		await assert.rejects(
			install({
				binDir: binLink,
				claudeSettingsFile: "",
				codexHooksFile: "",
				dryRun: false,
				removeManagedUserHooks: false,
				runtimeRoot: path.join(parent, "second-runtime"),
			}),
			/symbolic-link iOS lane bin directory/,
		);

		const runtimeTarget = path.join(parent, "runtime-target");
		const runtimeLink = path.join(parent, "runtime-link");
		mkdirSync(runtimeTarget);
		symlinkSync(runtimeTarget, runtimeLink);
		assert.throws(() => assertSafeRuntimeRoot(runtimeLink), /symbolic-link iOS lane runtime root/);

		const sourceAlias = path.join(parent, "source-alias");
		symlinkSync(process.cwd(), sourceAlias);
		assert.throws(
			() => assertSafeRuntimeRoot(path.join(sourceAlias, "unsafe-runtime")),
			/unsafe iOS lane runtime root/,
		);
	} finally {
		rmSync(parent, { force: true, recursive: true });
	}
});

test("installer rejects Claude and Codex settings aliases for the same canonical file", async () => {
	const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-hook-settings-alias-")));
	const settingsDirectory = path.join(parent, "settings");
	const settingsAlias = path.join(parent, "settings-alias");
	const settingsFile = path.join(settingsDirectory, "hooks.json");
	const original = `${JSON.stringify({ hooks: {}, userSetting: true })}\n`;
	mkdirSync(settingsDirectory);
	writeFileSync(settingsFile, original, { mode: 0o600 });
	symlinkSync(settingsDirectory, settingsAlias);
	try {
		await assert.rejects(
			install({
				binDir: path.join(parent, "bin"),
				claudeSettingsFile: settingsFile,
				codexHooksFile: path.join(settingsAlias, "hooks.json"),
				dryRun: false,
				removeManagedUserHooks: false,
				runtimeRoot: path.join(parent, "runtime"),
			}),
			/must use different files/,
		);
		assert.equal(readFileSync(settingsFile, "utf8"), original);
		assert.equal(existsSync(path.join(parent, "runtime")), false);
		assert.equal(existsSync(path.join(parent, "bin")), false);
	} finally {
		rmSync(parent, { force: true, recursive: true });
	}
});

test("installer rejects cross-client settings reuse across separate invocations", async () => {
	const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-hook-client-reuse-")));
	const settingsDirectory = path.join(parent, "settings");
	const settingsAlias = path.join(parent, "settings-alias");
	const settingsFile = path.join(settingsDirectory, "hooks.json");
	const binDir = path.join(parent, "bin");
	const runtimeRoot = path.join(parent, "runtime");
	mkdirSync(settingsDirectory);
	writeFileSync(settingsFile, `${JSON.stringify({ hooks: {}, userSetting: true })}\n`, {
		mode: 0o600,
	});
	symlinkSync(settingsDirectory, settingsAlias);
	try {
		await install({
			binDir,
			claudeSettingsFile: "",
			codexHooksFile: settingsFile,
			dryRun: false,
			removeManagedUserHooks: false,
			runtimeRoot,
		});
		const codexDocument = readFileSync(settingsFile, "utf8");
		assert.match(codexDocument, /--client codex/);
		await install({
			binDir,
			claudeSettingsFile: "",
			codexHooksFile: path.join(settingsAlias, "hooks.json"),
			dryRun: false,
			removeManagedUserHooks: false,
			runtimeRoot,
		});
		assert.equal(readFileSync(settingsFile, "utf8"), codexDocument);
		await assert.rejects(
			install({
				binDir,
				claudeSettingsFile: path.join(settingsAlias, "hooks.json"),
				codexHooksFile: "",
				dryRun: false,
				removeManagedUserHooks: false,
				runtimeRoot,
			}),
			/already contains managed hooks for a different client/,
		);
		assert.equal(readFileSync(settingsFile, "utf8"), codexDocument);
	} finally {
		rmSync(parent, { force: true, recursive: true });
	}
});

test("explicit legacy migration retains recoverable backups and is idempotent", () => {
	const fakeHome = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-legacy-migration-")));
	const fixture = createLegacyInstallation(fakeHome);
	const before = legacySnapshot(fixture);
	try {
		const first = runLegacyInstaller(fakeHome);
		assert.equal(first.status, 0, first.stderr);
		const firstResult = JSON.parse(first.stdout);
		assert.equal(firstResult.legacyMigration.status, "migrated");
		assert.equal(existsSync(firstResult.legacyMigration.runtimeBackup), true);
		for (const [relative, contents] of Object.entries(before.runtime)) {
			assert.equal(
				readFileSync(path.join(firstResult.legacyMigration.runtimeBackup, relative), "utf8"),
				contents,
			);
		}
		for (const [name, backupPath] of Object.entries(
			firstResult.legacyMigration.wrapperBackups,
		)) {
			assert.equal(readFileSync(backupPath, "utf8"), before.wrappers[name]);
		}
		assert.equal(
			JSON.parse(
				readFileSync(path.join(firstResult.runtimeRoot, ".agent-tooling-runtime-owner.json"), "utf8"),
			).owner,
			"agent-tooling-ios-session-lanes-runtime",
		);
		const retained = [
			firstResult.legacyMigration.runtimeBackup,
			...Object.values(firstResult.legacyMigration.wrapperBackups),
		];
		const second = runLegacyInstaller(fakeHome);
		assert.equal(second.status, 0, second.stderr);
		assert.equal(JSON.parse(second.stdout).legacyMigration.status, "already-current");
		for (const backupPath of retained) assert.equal(existsSync(backupPath), true);
		assert.equal(
			readdirSync(path.dirname(fixture.runtimeRoot)).filter((name) => name.includes("legacy-backup")).length,
			1,
		);
		assert.equal(
			readdirSync(fixture.binDir).filter((name) => name.includes("legacy-backup")).length,
			3,
		);
	} finally {
		rmSync(fakeHome, { force: true, recursive: true });
	}
});

test("legacy migration rejects extra inventory, symlinks, wrapper changes, and implicit adoption", () => {
	for (const mutate of [
		(fixture) => writeFileSync(path.join(fixture.runtimeRoot, "unexpected.txt"), "sentinel\n"),
		(fixture) => {
			const target = path.join(fixture.runtimeRoot, "scripts/project-context.mjs");
			rmSync(target);
			symlinkSync("ios-session-hook.mjs", target);
		},
		(fixture) => appendFileSync(path.join(fixture.binDir, "ios-session-lane"), "# changed\n"),
		(fixture) => chmodSync(path.join(fixture.binDir, "ios-session-lane"), 0o644),
	]) {
		const fakeHome = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-legacy-reject-")));
		const fixture = createLegacyInstallation(fakeHome);
		mutate(fixture);
		try {
			const result = runLegacyInstaller(fakeHome);
			assert.notEqual(result.status, 0);
			assert.equal(existsSync(fixture.runtimeRoot), true);
			assert.equal(
				readdirSync(path.dirname(fixture.runtimeRoot)).some((name) => name.includes("legacy-backup")),
				false,
			);
		} finally {
			rmSync(fakeHome, { force: true, recursive: true });
		}
	}

	const fakeHome = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-legacy-explicit-")));
	const fixture = createLegacyInstallation(fakeHome);
	try {
		const result = spawnSync(process.execPath, [installerPath], {
			encoding: "utf8",
			env: { ...process.env, HOME: fakeHome },
		});
		assert.notEqual(result.status, 0);
		assert.match(result.stderr, /unowned directory/);
		assert.equal(existsSync(fixture.runtimeRoot), true);
	} finally {
		rmSync(fakeHome, { force: true, recursive: true });
	}
});

test("legacy transaction restores runtime, wrappers, and settings after injected failures", () => {
	const fakeHome = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-legacy-rollback-")));
	const fixture = createLegacyInstallation(fakeHome);
	const settingsFile = path.join(fakeHome, ".claude", "settings.json");
	mkdirSync(path.dirname(settingsFile), { recursive: true });
	writeFileSync(
		settingsFile,
		`${JSON.stringify({ hooks: { Stop: [{ hooks: [{ command: "node user.js", type: "command" }] }] } })}\n`,
		{ mode: 0o640 },
	);
	const before = legacySnapshot(fixture, settingsFile);
	try {
		for (const phase of ["backed-up", "promoted:ios-session-lane"]) {
			const script = `
				import { install } from ${JSON.stringify(pathToFileURL(installerPath).href)};
				try {
					await install({
						binDir: ${JSON.stringify(fixture.binDir)},
						claudeSettingsFile: ${JSON.stringify(settingsFile)},
						codexHooksFile: "",
						dryRun: false,
						migrateLegacyRuntime: true,
						removeManagedUserHooks: false,
						runtimeRoot: ${JSON.stringify(fixture.runtimeRoot)},
						transactionPhaseHook(current) {
							if (current === ${JSON.stringify(phase)}) throw new Error("injected transaction failure");
						},
					});
					process.exitCode = 2;
				} catch (error) {
					console.error(error.message);
					process.exitCode = 19;
				}
			`;
			const result = spawnSync(
				process.execPath,
				["--input-type=module", "--eval", script],
				{ encoding: "utf8", env: { ...process.env, HOME: fakeHome } },
			);
			assert.equal(result.status, 19, result.stderr);
			assert.match(result.stderr, /injected transaction failure/);
			assert.match(result.stderr, /Recovery copies were retained at:/);
			assert.deepEqual(legacySnapshot(fixture, settingsFile), before);
			assert.equal(existsSync(`${settingsFile}.before-ios-session-lanes.json`), false);
			assert.equal(
				readdirSync(path.dirname(fixture.runtimeRoot)).some(activeInstallerArtifact),
				false,
			);
			assert.equal(
				readdirSync(fixture.binDir).some(activeInstallerArtifact),
				false,
			);
		}
	} finally {
		rmSync(fakeHome, { force: true, recursive: true });
	}
});

test("legacy wrapper backup drift retains the edit and restores the exact old wrapper", () => {
	const fakeHome = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-legacy-wrapper-drift-")));
	const fixture = createLegacyInstallation(fakeHome);
	const wrapperPath = path.join(fixture.binDir, "ios-session-lane");
	const external = "external legacy wrapper edit\n";
	const before = legacySnapshot(fixture);
	try {
		const script = `
			import { closeSync, fsyncSync, ftruncateSync, openSync, writeSync } from "node:fs";
			import { install } from ${JSON.stringify(pathToFileURL(installerPath).href)};
			const wrapperFd = openSync(${JSON.stringify(wrapperPath)}, "r+");
			try {
				await install({
					binDir: ${JSON.stringify(fixture.binDir)},
					claudeSettingsFile: "",
					codexHooksFile: "",
					dryRun: false,
					migrateLegacyRuntime: true,
					removeManagedUserHooks: false,
					runtimeRoot: ${JSON.stringify(fixture.runtimeRoot)},
					transactionPhaseHook(current) {
						if (current !== "backed-up") return;
						ftruncateSync(wrapperFd, 0);
						writeSync(wrapperFd, ${JSON.stringify(external)}, 0, "utf8");
						fsyncSync(wrapperFd);
						closeSync(wrapperFd);
					},
				});
				process.exitCode = 2;
			} catch (error) {
				console.error(error.message);
				process.exitCode = 19;
			}
		`;
		const result = spawnSync(process.execPath, ["--input-type=module", "--eval", script], {
			encoding: "utf8",
			env: { ...process.env, HOME: fakeHome },
		});
		assert.equal(result.status, 19, result.stderr);
		assert.match(result.stderr, /backup changed before transaction completion/);
		assert.match(result.stderr, /Recovery copies were retained at:/);
		assert.deepEqual(legacySnapshot(fixture), before);
		const recoveries = readdirSync(fixture.binDir).filter((name) =>
			name.includes(".ios-session-lane.external-change-"),
		);
		assert.equal(recoveries.length, 1);
		const recoveryPath = path.join(fixture.binDir, recoveries[0]);
		assert.equal(readFileSync(recoveryPath, "utf8"), external);
		assert.equal(statSync(recoveryPath).mode & 0o777, 0o755);
		assert.equal(
			readdirSync(path.dirname(fixture.runtimeRoot)).some((name) => /(?:stage|backup)/.test(name)),
			false,
		);
	} finally {
		rmSync(fakeHome, { force: true, recursive: true });
	}
});

test("installer detects settings drift and preserves concurrent edits during rollback", () => {
	for (const phase of ["staged", "backed-up", "promoted", "backed-up-fd"]) {
		const fakeHome = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-settings-drift-")));
		const fixture = createLegacyInstallation(fakeHome);
		const settingsFile = path.join(fakeHome, ".claude", "settings.json");
		const original = `${JSON.stringify({ hooks: {}, userSetting: true })}\n`;
		const external = `${JSON.stringify({ hooks: {}, concurrentEdit: phase })}\n`;
		mkdirSync(path.dirname(settingsFile), { recursive: true });
		writeFileSync(settingsFile, original, { mode: 0o640 });
		const before = legacySnapshot(fixture, settingsFile);
		try {
			const script = `
				import {
					chmodSync,
					closeSync,
					fsyncSync,
					ftruncateSync,
					openSync,
					writeFileSync,
					writeSync,
				} from "node:fs";
				import { install } from ${JSON.stringify(pathToFileURL(installerPath).href)};
				const settingsFd = ${JSON.stringify(phase)} === "backed-up-fd"
					? openSync(${JSON.stringify(settingsFile)}, "r+")
					: null;
				try {
					await install({
						binDir: ${JSON.stringify(fixture.binDir)},
						claudeSettingsFile: ${JSON.stringify(settingsFile)},
						codexHooksFile: "",
						dryRun: false,
						migrateLegacyRuntime: true,
						removeManagedUserHooks: false,
						runtimeRoot: ${JSON.stringify(fixture.runtimeRoot)},
						transactionPhaseHook(current) {
							const expectedPhase = ${JSON.stringify(phase)} === "backed-up-fd"
								? "backed-up"
								: ${JSON.stringify(phase)};
							if (current !== expectedPhase) return;
							if (settingsFd !== null) {
								ftruncateSync(settingsFd, 0);
								writeSync(settingsFd, ${JSON.stringify(external)}, 0, "utf8");
								fsyncSync(settingsFd);
								closeSync(settingsFd);
								return;
							}
							writeFileSync(${JSON.stringify(settingsFile)}, ${JSON.stringify(external)}, { mode: 0o600 });
							chmodSync(${JSON.stringify(settingsFile)}, 0o600);
						},
					});
					process.exitCode = 2;
				} catch (error) {
					console.error(error.message);
					process.exitCode = 19;
				}
			`;
			const result = spawnSync(
				process.execPath,
				["--input-type=module", "--eval", script],
				{ encoding: "utf8", env: { ...process.env, HOME: fakeHome } },
			);
			assert.equal(result.status, 19, result.stderr);
			assert.match(
				result.stderr,
				phase === "staged"
					? /changed after staging/
					: phase === "backed-up"
						? /changed before promotion/
						: phase === "promoted"
							? /changed after promotion/
							: /backup changed before transaction completion/,
			);
			const after = legacySnapshot(fixture, settingsFile);
			assert.deepEqual(after.runtime, before.runtime);
			assert.deepEqual(after.wrappers, before.wrappers);
			assert.deepEqual(after.modes.wrappers, before.modes.wrappers);
			const retained = readdirSync(path.dirname(settingsFile)).filter(
				(name) =>
					name.includes(".settings.json.external-change-") ||
					name.includes(".settings.json.failed-install-"),
			);
			if (phase === "staged") {
				assert.equal(after.settings, external);
				assert.equal(after.modes.settings, 0o600);
				assert.deepEqual(retained, []);
			} else {
				assert.equal(after.settings, original);
				assert.equal(after.modes.settings, 0o640);
				const externalRecoveries = retained.filter(
					(name) => readFileSync(path.join(path.dirname(settingsFile), name), "utf8") === external,
				);
				assert.equal(externalRecoveries.length, 1);
				assert.match(result.stderr, /Recovery copies were retained at:/);
			}
			assert.equal(existsSync(`${settingsFile}.before-ios-session-lanes.json`), false);
			assert.equal(
				readdirSync(path.dirname(fixture.runtimeRoot)).some(activeInstallerArtifact),
				false,
			);
			assert.equal(
				readdirSync(fixture.binDir).some(activeInstallerArtifact),
				false,
			);
		} finally {
			rmSync(fakeHome, { force: true, recursive: true });
		}
	}
});

test("installer snapshots the full runtime tree and preserves concurrent variants", async () => {
	for (const phase of ["staged", "backed-up", "backed-up-fd"]) {
		const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-runtime-drift-")));
		const binDir = path.join(parent, "bin");
		const runtimeRoot = path.join(parent, "runtime");
		const options = {
			binDir,
			claudeSettingsFile: "",
			codexHooksFile: "",
			dryRun: false,
			removeManagedUserHooks: false,
			runtimeRoot,
		};
		let runtimeFd = null;
		try {
			await install(options);
			const before = treeSnapshot(runtimeRoot);
			const external = `external runtime edit during ${phase}\n`;
			const editedRelative = "scripts/project-context.mjs";
			if (phase === "backed-up-fd") {
				runtimeFd = openSync(path.join(runtimeRoot, editedRelative), "r+");
			}
			await assert.rejects(
				install({
					...options,
					transactionPhaseHook(current) {
						const expectedPhase = phase === "backed-up-fd" ? "backed-up" : phase;
						if (current !== expectedPhase) return;
						if (runtimeFd !== null) {
							ftruncateSync(runtimeFd, 0);
							writeSync(runtimeFd, external, 0, "utf8");
							fsyncSync(runtimeFd);
							closeSync(runtimeFd);
							runtimeFd = null;
							return;
						}
						if (phase === "backed-up") mkdirSync(runtimeRoot);
						writeFileSync(path.join(runtimeRoot, "concurrent-runtime-edit.txt"), external, {
							mode: 0o600,
						});
					},
				}),
				phase === "staged"
					? /changed after staging/
					: phase === "backed-up"
						? /changed before promotion/
						: /backup changed before transaction completion/,
			);
			assert.deepEqual(treeSnapshot(runtimeRoot), before);
			const recoveries = readdirSync(parent).filter((name) =>
				name.includes(".runtime.external-change-"),
			);
			assert.equal(recoveries.length, 1);
			const recoveryRoot = path.join(parent, recoveries[0]);
			if (phase === "backed-up-fd") {
				assert.equal(readFileSync(path.join(recoveryRoot, editedRelative), "utf8"), external);
			} else {
				assert.equal(
					readFileSync(path.join(recoveryRoot, "concurrent-runtime-edit.txt"), "utf8"),
					external,
				);
			}
			assert.equal(
				readdirSync(parent).some(activeInstallerArtifact),
				false,
			);
		} finally {
			if (runtimeFd !== null) closeSync(runtimeFd);
			rmSync(parent, { force: true, recursive: true });
		}
	}
});

test("failed staging retains a path-swapped runtime stage instead of deleting it", async () => {
	const parent = realpathSync(mkdtempSync(path.join(tmpdir(), "pumpd-stage-swap-")));
	const runtimeRoot = path.join(parent, "runtime");
	const sentinel = "external stage replacement\n";
	try {
		await assert.rejects(
			install({
				binDir: path.join(parent, "bin"),
				claudeSettingsFile: "",
				codexHooksFile: "",
				dryRun: false,
				removeManagedUserHooks: false,
				runtimeRoot,
				transactionPhaseHook(phase) {
					if (phase !== "staged") return;
					const stageName = readdirSync(parent).find((name) => name.startsWith(".runtime.stage-"));
					assert.ok(stageName);
					const stagePath = path.join(parent, stageName);
					rmSync(stagePath, { force: true, recursive: true });
					mkdirSync(stagePath);
					writeFileSync(path.join(stagePath, "external-sentinel.txt"), sentinel);
					throw new Error("injected stage swap failure");
				},
			}),
			(error) => {
				assert.match(error.message, /injected stage swap failure/);
				assert.match(error.message, /Recovery copies were retained at:/);
				return true;
			},
		);
		assert.equal(existsSync(runtimeRoot), false);
		assert.equal(
			readdirSync(parent).some((name) => name.startsWith(".runtime.stage-")),
			false,
		);
		const recoveries = readdirSync(parent).filter((name) =>
			name.startsWith(".runtime.abandoned-stage-"),
		);
		assert.equal(recoveries.length, 1);
		assert.equal(
			readFileSync(path.join(parent, recoveries[0], "external-sentinel.txt"), "utf8"),
			sentinel,
		);
	} finally {
		rmSync(parent, { force: true, recursive: true });
	}
});

test("installer help exposes legacy migration and read-only checking", () => {
	const result = spawnSync(process.execPath, [installerPath, "--help"], { encoding: "utf8" });
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stdout, /--check/);
	assert.match(result.stdout, /--migrate-legacy-runtime/);
});

test("bundled hook manifests use native roots without global worktree interception", () => {
	const hooksRoot = new URL("../../../hooks/", import.meta.url);
	const claude = JSON.parse(readFileSync(new URL("claude-hooks.json", hooksRoot), "utf8"));
	const codex = JSON.parse(readFileSync(new URL("codex-hooks.json", hooksRoot), "utf8"));
	assert.equal(claude.hooks.WorktreeCreate, undefined);
	for (const document of [claude, codex]) {
		const serialized = JSON.stringify(document);
		assert.doesNotMatch(serialized, /functions\.exec/);
		const matcher = new RegExp(document.hooks.PreToolUse[0].matcher);
		assert.equal(matcher.test("exec_command"), true);
		assert.equal(matcher.test("mcp__agent_device__tap"), true);
		assert.equal(matcher.test("mcp__maestro__run_flow"), true);
	}
	assert.match(JSON.stringify(claude), /\$\{CLAUDE_PLUGIN_ROOT\}/);
	assert.match(JSON.stringify(codex), /\$\{PLUGIN_ROOT\}/);
});
