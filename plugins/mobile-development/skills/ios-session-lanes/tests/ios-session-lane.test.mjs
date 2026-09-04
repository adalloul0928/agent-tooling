import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
	mkdirSync,
	mkdtempSync,
	readFileSync,
	realpathSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
	envNames,
	envReferences,
	parseBootstrapOptions,
} from "../scripts/bootstrap-worktree.mjs";
import {
	branchName,
	parseWorktreeOptions,
	safeWorktreeName,
} from "../scripts/create-worktree.mjs";
import {
	applyRecordedLaneSelection,
	classifySimulatorBootResult,
	lanePreset,
	laneSelectionIsConfirmed,
	nativeCacheKey,
	normalizeBackendChoice,
	parseOptions,
	parseTarget,
	sessionKey,
} from "../scripts/ios-session-lane.mjs";
import {
	directBackendReason,
	directIosReason,
	directWorktreeReason,
	isLaneCommand,
	simViewToolIsReadOnly,
} from "../scripts/ios-session-hook.mjs";
import { install, mergeHooks } from "../scripts/install-runtime.mjs";
import {
	assertSupportedProject,
	bundledProfile,
	normalizeProjectProfile,
	normalizeRepositoryRemote,
	projectMatch,
	resolveProjectRoot,
} from "../scripts/project-context.mjs";

const expectedRepositoryIdentity = "github.com/avad-technologies/pumpd-mobile-app";

test("repository remotes normalize exact HTTPS, SSH, and SCP identities", () => {
	for (const remote of [
		"https://github.com/avad-technologies/pumpd-mobile-app.git",
		"HTTPS://GITHUB.COM/AVAD-TECHNOLOGIES/PUMPD-MOBILE-APP.GIT/",
		"ssh://git@github.com/avad-technologies/pumpd-mobile-app.git",
		"ssh://git@github.com:22/avad-technologies/pumpd-mobile-app",
		"git@github.com:avad-technologies/pumpd-mobile-app.git",
		" git@GITHUB.COM:AVAD-TECHNOLOGIES/PUMPD-MOBILE-APP ",
	]) {
		assert.equal(normalizeRepositoryRemote(remote)?.key, expectedRepositoryIdentity);
	}
});

test("repository remotes reject host, owner, repository, and path lookalikes", () => {
	for (const remote of [
		"https://github.com.evil/avad-technologies/pumpd-mobile-app",
		"https://evil.example/github.com/avad-technologies/pumpd-mobile-app",
		"https://github.com@evil.example/avad-technologies/pumpd-mobile-app",
		"https://github.com/attacker/avad-technologies/pumpd-mobile-app",
		"https://github.com/avad-technologies/pumpd-mobile-app/extra",
		"git@github.com-evil:avad-technologies/pumpd-mobile-app",
		"https://githуb.com/avad-technologies/pumpd-mobile-app",
	]) {
		assert.equal(normalizeRepositoryRemote(remote), null, remote);
	}
	for (const remote of [
		"https://github.com/attacker/pumpd-mobile-app",
		"https://github.com/avad-technologies/pumpd-mobile-app-suffix",
	]) {
		assert.notEqual(
			normalizeRepositoryRemote(remote)?.key,
			expectedRepositoryIdentity,
		);
	}
});

test("repository remotes reject unsupported and ambiguous syntax", () => {
	for (const remote of [
		"http://github.com/avad-technologies/pumpd-mobile-app",
		"git://github.com/avad-technologies/pumpd-mobile-app",
		"file:///tmp/pumpd-mobile-app",
		"../pumpd-mobile-app",
		"https://token@github.com/avad-technologies/pumpd-mobile-app",
		"https://github.com:8443/avad-technologies/pumpd-mobile-app",
		"https://github.com/avad-technologies/pumpd-mobile-app?ref=main",
		"https://github.com/avad-technologies/pumpd-mobile-app#main",
		"https://github.com/avad-technologies%2Fpumpd-mobile-app",
		"https://github.com/avad-technologies\\pumpd-mobile-app",
		"https://github.com/avad-technologies/../pumpd-mobile-app",
		"https://github.com/avad-technologies/pumpd-mobile-app/.",
		"https://github.com/avad-technologies/pumpd-mobile-app\nhttps://evil.example/x/y",
		"https://github.com/avad-technologies/pumpd-mobile-app\n",
		"",
	]) {
		assert.equal(normalizeRepositoryRemote(remote), null, remote);
	}
});

test("project profile v2 requires a structured safe repository identity", () => {
	const profile = bundledProfile();
	assert.equal(profile.schemaVersion, 2);
	assert.deepEqual(profile.match.repository, {
		host: "github.com",
		owner: "avad-technologies",
		remote: "origin",
		repo: "pumpd-mobile-app",
	});
	assert.throws(
		() => normalizeProjectProfile({ ...profile, schemaVersion: 1 }),
		/schemaVersion 2/,
	);
	assert.throws(
		() =>
			normalizeProjectProfile({
				...profile,
				match: { ...profile.match, requiredPaths: ["../pnpm-lock.yaml"] },
			}),
		/unsafe required path/,
	);
	assert.throws(
		() =>
			normalizeProjectProfile({
				...profile,
				match: {
					...profile.match,
					repository: { ...profile.match.repository, owner: "attacker/avad" },
				},
			}),
		/invalid owner or repository/,
	);
});

test("project matching requires one exact origin and every required path", (t) => {
	const valid = makeProjectRepository(t, {
		remote: "git@github.com:avad-technologies/pumpd-mobile-app.git",
	});
	assert.equal(projectMatch(valid).ok, true);

	const wrongOwner = makeProjectRepository(t, {
		remote: "https://github.com/attacker/pumpd-mobile-app.git",
	});
	const wrongOwnerMatch = projectMatch(wrongOwner);
	assert.equal(wrongOwnerMatch.ok, false);
	assert.equal(wrongOwnerMatch.reason, "origin_mismatch");
	assert.equal(
		wrongOwnerMatch.repositoryIdentity,
		"github.com/attacker/pumpd-mobile-app",
	);

	const missingPath = makeProjectRepository(t, {
		omitRequiredPath: "pnpm-lock.yaml",
		remote: "https://github.com/avad-technologies/pumpd-mobile-app.git",
	});
	assert.equal(projectMatch(missingPath).ok, false);
	assert.equal(projectMatch(missingPath).reason, "required_paths_missing");
	assert.deepEqual(projectMatch(missingPath).missingPaths, ["pnpm-lock.yaml"]);
});

test("project matching fails closed for missing, malformed, and multiple origins", (t) => {
	const missing = makeProjectRepository(t, {});
	assert.equal(projectMatch(missing).reason, "origin_unavailable");

	const malformed = makeProjectRepository(t, {
		remote: "https://credential-value@github.com/avad-technologies/pumpd-mobile-app",
	});
	const malformedMatch = projectMatch(malformed);
	assert.equal(malformedMatch.ok, false);
	assert.equal(malformedMatch.reason, "origin_unrecognized");
	assert.equal(malformedMatch.repositoryIdentity, null);

	const multiple = makeProjectRepository(t, {
		remote: "https://github.com/avad-technologies/pumpd-mobile-app.git",
	});
	runGit(multiple, [
		"config",
		"--add",
		"remote.origin.url",
		"git@github.com:attacker/pumpd-mobile-app.git",
	]);
	assert.equal(projectMatch(multiple).reason, "origin_ambiguous");
	assert.equal(projectMatch(multiple).ok, false);
});

test("an explicit project root outranks the ambient compatibility override", (t) => {
	const valid = makeProjectRepository(t, {
		remote: "https://github.com/avad-technologies/pumpd-mobile-app.git",
	});
	const invalid = makeProjectRepository(t, {
		remote: "https://github.com/attacker/pumpd-mobile-app.git",
	});
	const previous = process.env.IOS_SESSION_LANES_PROJECT_ROOT;
	process.env.IOS_SESSION_LANES_PROJECT_ROOT = valid;
	try {
		assert.equal(resolveProjectRoot(invalid), realpathSync(invalid));
		assert.equal(projectMatch(invalid).ok, false);
	} finally {
		if (previous === undefined) delete process.env.IOS_SESSION_LANES_PROJECT_ROOT;
		else process.env.IOS_SESSION_LANES_PROJECT_ROOT = previous;
	}
});

test("linked worktrees resolve and validate independently", (t) => {
	const parent = temporaryDirectory(t, "pumpd-worktree-origin-test-");
	const primary = path.join(parent, "primary");
	const linked = path.join(parent, "linked");
	mkdirSync(primary);
	initializeProjectRepository(primary, {
		commit: true,
		remote: "https://github.com/avad-technologies/pumpd-mobile-app.git",
	});
	runGit(primary, ["worktree", "add", "--no-track", "-b", "linked-test", linked]);

	const match = projectMatch(linked);
	assert.equal(match.ok, true);
	assert.equal(match.root, realpathSync(linked));
	assert.notEqual(match.root, realpathSync(primary));
});

test("unsupported-project diagnostics never expose a raw credential-bearing origin", (t) => {
	const root = makeProjectRepository(t, {
		remote: "https://credential-value@github.com/avad-technologies/pumpd-mobile-app.git",
	});
	assert.throws(
		() => assertSupportedProject(root),
		(error) => {
			assert.doesNotMatch(error.message, /credential-value|https:\/\//u);
			assert.match(error.message, /origin_unrecognized/u);
			return true;
		},
	);
});

test("the global hook stays silent when invoked outside a Git worktree", (t) => {
	const outsideGit = temporaryDirectory(t, "pumpd-hook-non-git-test-");
	const hook = fileURLToPath(
		new URL("../scripts/ios-session-hook.mjs", import.meta.url),
	);
	const result = spawnSync(
		process.execPath,
		[hook, "start", "--client", "codex"],
		{
			cwd: outsideGit,
			encoding: "utf8",
			input: JSON.stringify({ cwd: outsideGit, session_id: "outside-git" }),
			stdio: ["pipe", "pipe", "pipe"],
		},
	);
	assert.equal(result.status, 0, result.stderr);
	assert.equal(result.stdout, "");
	assert.equal(result.stderr, "");
});

test("session keys distinguish clients and sessions", () => {
	assert.equal(sessionKey("codex", "thread-1"), "codex:thread-1");
	assert.notEqual(
		sessionKey("codex", "thread-1"),
		sessionKey("claude", "thread-1"),
	);
	assert.notEqual(
		sessionKey("codex", "thread-1"),
		sessionKey("codex", "thread-2"),
	);
});

test("bootstrap parsing keeps environment setup separate from lane startup", () => {
	assert.deepEqual(parseBootstrapOptions([]), {
		check: false,
		dopplerConfig: "",
		easEnvironment: "",
		force: false,
		json: false,
		projectRoot: "",
		quiet: false,
	});
	assert.equal(parseBootstrapOptions(["--check"]).check, true);
	assert.equal(parseBootstrapOptions(["--", "--check"]).check, true);
	assert.throws(() => parseBootstrapOptions(["--skip-mobile-env"]), /Unknown/);
});

test("bootstrap metadata extracts names without environment values", () => {
	const directory = mkdtempSync(path.join(tmpdir(), "pumpd-bootstrap-test-"));
	const envPath = path.join(directory, ".env.local");
	const configPath = path.join(directory, "config.toml");
	writeFileSync(envPath, "EXPO_PUBLIC_SUPABASE_URL=secret\nexport APP_VARIANT=development\n");
	writeFileSync(
		configPath,
		'ONE = "env(OPENAI_API_KEY)"\nTWO = "env(OPENAI_API_KEY)"\nTHREE = "env(AI_MODEL)"\n',
	);
	assert.deepEqual(envNames(envPath), [
		"APP_VARIANT",
		"EXPO_PUBLIC_SUPABASE_URL",
	]);
	assert.deepEqual(envReferences(configPath), ["AI_MODEL", "OPENAI_API_KEY"]);
});

test("worktree creator produces safe client-specific branch names", () => {
	assert.equal(safeWorktreeName("Feature / Lane A"), "feature-lane-a");
	assert.equal(branchName("claude", "feature-auth"), "claude/feature-auth");
	assert.equal(branchName("codex", "feature-auth"), "codex/feature-auth");
	assert.deepEqual(
		parseWorktreeOptions(["--", "--client", "claude", "--name", "Feature Auth"]),
		{
			base: "origin/preview",
			client: "claude",
			destinationRoot: "",
			hook: false,
			name: "feature-auth",
			projectRoot: "",
		},
	);
	assert.throws(() => safeWorktreeName("../../"), /safe worktree name/);
});

test("CLI parsing recommends local Supabase but requires confirmation", () => {
	const parsed = parseOptions([
		"up",
		"--client",
		"codex",
		"--session-id",
		"thread-1",
		"--build",
	]);
	assert.equal(parsed.command, "up");
	assert.equal(parsed.options.backend, "local");
	assert.equal(parsed.options.build, true);
	assert.equal(parsed.options.client, "codex");
	assert.equal(parsed.options.preset, "simulator-local");
	assert.equal(parsed.options.presetExplicit, false);
	assert.equal(parsed.options.sessionId, "thread-1");
	assert.equal(laneSelectionIsConfirmed(parsed.options), false);
});

test("lane presets encode the user-facing device, backend, and network choices", () => {
	const local = parseOptions(["up", "--preset", "simulator-local"]);
	assert.equal(local.options.target, "simulator");
	assert.equal(local.options.backend, "local");
	assert.equal(local.options.expose, "local");
	assert.equal(laneSelectionIsConfirmed(local.options), true);

	const preview = parseOptions(["up", "--preset", "simulator-preview"]);
	assert.equal(preview.options.target, "simulator");
	assert.equal(preview.options.backend, "preview");
	assert.equal(preview.options.expose, "local");

	const iphone = lanePreset("iphone-preview");
	assert.equal(iphone.target, "physical:arens-iphone-pro");
	assert.equal(iphone.backend, "preview");
	assert.equal(iphone.expose, "tailscale");
	assert.throws(() => lanePreset("unknown"), /Unknown lane preset/);
});

test("custom lane choices must explicitly cover target, backend, and exposure", () => {
	const custom = parseOptions([
		"up",
		"--target",
		"simulator",
		"--backend",
		"remote",
		"--expose",
		"tailscale",
	]);
	assert.equal(custom.options.backend, "preview");
	assert.equal(custom.options.preset, "custom");
	assert.equal(laneSelectionIsConfirmed(custom.options), true);
	assert.equal(normalizeBackendChoice("local"), "local");
	assert.equal(normalizeBackendChoice("remote"), "preview");

	const incomplete = parseOptions(["up", "--backend", "preview"]);
	assert.equal(laneSelectionIsConfirmed(incomplete.options), false);
	assert.throws(
		() =>
			parseOptions([
				"up",
				"--preset",
				"simulator-local",
				"--backend",
				"preview",
			]),
		/Do not combine --preset/,
	);
});

test("an existing lane reconnects from its recorded choices without asking again", () => {
	const parsed = parseOptions(["up", "--client", "codex", "--session-id", "thread-1"]);
	const restored = applyRecordedLaneSelection(parsed.options, {
		backend: "preview",
		exposure: "tailscale",
		preset: "simulator-preview-tailscale",
		requestedTarget: { alias: "automatic", kind: "simulator" },
	});
	assert.equal(restored, true);
	assert.equal(parsed.options.backend, "preview");
	assert.equal(parsed.options.expose, "tailscale");
	assert.equal(parsed.options.preset, "simulator-preview-tailscale");
	assert.equal(laneSelectionIsConfirmed(parsed.options), true);
});

test("lane targets reserve the simulator pool and the named physical iPhone", () => {
	assert.deepEqual(parseTarget("simulator"), {
		alias: "automatic",
		kind: "simulator",
	});
	assert.deepEqual(parseTarget("physical:arens-iphone-pro"), {
		alias: "arens-iphone-pro",
		kind: "physical",
	});
	assert.throws(() => parseTarget("physical:someone-elses-phone"), /--target/);
});

test("native cache identity includes fingerprint, Xcode, and architecture", () => {
	assert.equal(nativeCacheKey("native-a", "Xcode 26", "arm64").length, 64);
	assert.notEqual(
		nativeCacheKey("native-a", "Xcode 26", "arm64"),
		nativeCacheKey("native-b", "Xcode 26", "arm64"),
	);
});

test("bootstatus detects terminal migration text even when simctl exits zero", () => {
	assert.deepEqual(
		classifySimulatorBootResult({
			status: 0,
			stdout: "Status=3, isTerminal=YES\nData Migration Failed\n",
		}),
		{
			code: "SIMULATOR_DATA_MIGRATION_FAILED",
			message: "Data Migration Failed",
		},
	);
	assert.equal(
		classifySimulatorBootResult({ status: 0, stdout: "Status=0, isTerminal=YES" }),
		null,
	);
});

test("lane runtime never deletes or erases simulator devices", () => {
	const source = readFileSync(
		new URL("../scripts/ios-session-lane.mjs", import.meta.url),
		"utf8",
	);
	assert.doesNotMatch(source, /["'](?:delete|erase)["']/);
	assert.match(source, /simulatorQuarantine/);
});

test("raw Metro, simulator, and undirected Maestro commands are blocked", () => {
	assert.match(directIosReason("pnpm exec expo start --port 8083"), /Direct Expo/);
	assert.match(
		directIosReason("xcrun simctl boot AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
		/simulator mutation/,
	);
	assert.match(directIosReason("maestro test flow.yaml"), /input-writer/);
	assert.match(
		directIosReason("maestro --udid abc test flow.yaml"),
		/input-writer/,
	);
	assert.match(directIosReason("killall Simulator"), /another session/);
	assert.match(
		directIosReason('xcodebuild test -destination "platform=iOS Simulator,id=abc"'),
		/assigned destination/,
	);
	assert.match(
		directIosReason("eas build --platform ios --profile development"),
		/never submits an EAS development build/,
	);
	assert.equal(directIosReason("eas build --platform ios --profile production"), "");
});

test("raw shared Supabase lifecycle commands are blocked", () => {
	assert.match(directBackendReason("supabase start"), /owner lease/);
	assert.match(directBackendReason("supabase db reset"), /must not run/);
	assert.match(
		directBackendReason("pnpm --dir apps/backend db:reset"),
		/single-owner/,
	);
});

test("raw worktree creation is blocked unless it uses the bootstrap wrapper", () => {
	assert.match(directWorktreeReason("git worktree add ../feature -b feature"), /bootstrap/);
	assert.equal(
		directWorktreeReason("ios-session-worktree --name feature"),
		"",
	);
});

test("session lane commands bypass the raw-command guard", () => {
	const command =
		"ios-session-lane up --client codex --session-id thread-1 --build";
	assert.equal(isLaneCommand(command), true);
	assert.equal(directIosReason(command), "");
	assert.equal(directBackendReason(command), "");
});

test("hook installation is additive and idempotent", () => {
	const original = {
		hooks: {
			SessionStart: [
				{
					hooks: [{ command: "node existing.js", type: "command" }],
				},
			],
		},
		permissions: { deny: ["Read(.env)"] },
	};
	const once = mergeHooks(
		original,
		"codex",
		"/tmp/agent-tooling-ios-session-lanes/runtime/scripts/ios-session-hook.mjs",
	);
	const twice = mergeHooks(
		once,
		"codex",
		"/tmp/agent-tooling-ios-session-lanes/runtime/scripts/ios-session-hook.mjs",
	);
	assert.deepEqual(twice, once);
	assert.deepEqual(twice.permissions, original.permissions);
	assert.equal(
		twice.hooks.SessionStart.filter((group) =>
			group.hooks.some((hook) => hook.command.includes("ios-session-hook")),
		).length,
		1,
	);
});

test("repeated installation preserves the pristine client config backup", () => {
	const directory = mkdtempSync(path.join(tmpdir(), "pumpd-lane-install-test-"));
	const settingsFile = path.join(directory, "settings.json");
	const original = {
		hooks: {
			Stop: [{ hooks: [{ command: "node existing.js", type: "command" }] }],
		},
		permissions: { deny: ["Read(.env)"] },
	};
	writeFileSync(settingsFile, `${JSON.stringify(original)}\n`);
	const options = {
		binDir: path.join(directory, "bin"),
		claudeSettingsFile: settingsFile,
		codexHooksFile: "",
		dryRun: false,
		runtimeRoot: path.join(directory, "runtime"),
	};
	install(options);
	install(options);
	assert.deepEqual(
		JSON.parse(
			readFileSync(`${settingsFile}.before-ios-session-lanes.json`, "utf8"),
		),
		original,
	);
});

test("SimView is limited to observation while the lane input writer is active", () => {
	assert.equal(simViewToolIsReadOnly("mcp__simview__connect_device"), true);
	assert.equal(simViewToolIsReadOnly("mcp__simview__take_screenshot"), true);
	assert.equal(simViewToolIsReadOnly("mcp__simview__get_element_tree"), true);
	assert.equal(simViewToolIsReadOnly("mcp__simview__tap_element"), false);
	assert.equal(simViewToolIsReadOnly("mcp__simview__type_text"), false);
	assert.equal(simViewToolIsReadOnly("mcp__simview__enable_ui_probe"), false);
});

function makeProjectRepository(t, options) {
	const root = temporaryDirectory(t, "pumpd-project-origin-test-");
	initializeProjectRepository(root, options);
	return root;
}

function initializeProjectRepository(
	root,
	{ commit = false, omitRequiredPath = "", remote = "" } = {},
) {
	runGit(root, ["init", "--quiet", "--initial-branch=main"]);
	runGit(root, ["config", "user.email", "ios-session-lanes@example.invalid"]);
	runGit(root, ["config", "user.name", "iOS Session Lanes Tests"]);
	if (remote) runGit(root, ["remote", "add", "origin", remote]);
	for (const relative of bundledProfile().match.requiredPaths) {
		if (relative === omitRequiredPath) continue;
		const target = path.join(root, relative);
		mkdirSync(path.dirname(target), { recursive: true });
		writeFileSync(target, `fixture for ${relative}\n`);
	}
	if (commit) {
		runGit(root, ["add", "."]);
		runGit(root, ["commit", "--quiet", "-m", "fixture"]);
	}
}

function temporaryDirectory(t, prefix) {
	const root = mkdtempSync(path.join(tmpdir(), prefix));
	t.after(() => rmSync(root, { force: true, recursive: true }));
	return root;
}

function runGit(root, args) {
	const result = spawnSync("git", args, {
		cwd: root,
		encoding: "utf8",
		stdio: ["ignore", "pipe", "pipe"],
	});
	assert.equal(
		result.status,
		0,
		`git ${args.join(" ")} failed: ${(result.stderr || result.stdout || "").trim()}`,
	);
	return result.stdout.trim();
}
