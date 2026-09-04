import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { createServer } from "node:net";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
	envNames,
	envReferences,
	parseBootstrapOptions,
	validateBootstrapDopplerNames,
} from "../scripts/bootstrap-worktree.mjs";
import {
	branchName,
	parseWorktreeOptions,
	resolveRemoteBase,
	safeWorktreeName,
	validateOriginRemoteTrackingRef,
} from "../scripts/create-worktree.mjs";
import {
	applyRecordedLaneSelection,
	assertNoReservedControllerFlags,
	classifySimulatorBootResult,
	isPortAvailable,
	lanePreset,
	laneSelectionIsConfirmed,
	nativeCacheKey,
	normalizeBackendChoice,
	parseOptions,
	parseTarget,
	sessionKey,
} from "../scripts/ios-session-lane.mjs";
import { backendContract } from "../scripts/lane-backend.mjs";
import {
	agentDeviceTarget,
	manualUrlAction,
	snapshotLooksRendered,
} from "../scripts/lane-controller.mjs";
import { withFileLock } from "../scripts/lane-lock.mjs";
import {
	directBackendReason,
	directIosReason,
	directWorktreeReason,
	isLaneCommand,
	isWorktreeCommand,
	iosSimulatorToolIsReadOnly,
	laneWrapperReason,
	simViewToolIsReadOnly,
} from "../scripts/ios-session-hook.mjs";
import {
	install,
	mergeHooks,
	removeManagedHooks,
} from "../scripts/install-runtime.mjs";

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
		'ONE = "env(OPENAI_API_KEY)"\nTWO = "env(OPENAI_API_KEY)"\nTHREE = "env(AI_MODEL)"\n[remotes.preview]\nREMOTE = "env(REMOTE_ONLY)"\n',
	);
	assert.deepEqual(envNames(envPath), [
		"APP_VARIANT",
		"EXPO_PUBLIC_SUPABASE_URL",
	]);
	assert.deepEqual(envReferences(configPath), ["AI_MODEL", "OPENAI_API_KEY"]);
});

test("bootstrap requires every local Supabase env reference available in Doppler", () => {
	const configText = `
[auth.sms.twilio_verify]
auth_token = "env(LOCAL_AUTH_TOKEN)"
[edge_runtime.secrets]
OPENAI_API_KEY = "env(OPENAI_API_KEY)"
[remotes.preview]
ignored = "env(REMOTE_ONLY)"
`;
	assert.throws(
		() =>
			validateBootstrapDopplerNames(
				configText,
				["OPENAI_API_KEY", "PROFILE_REQUIRED"],
				["PROFILE_REQUIRED"],
				"Doppler test/config",
			),
		/Doppler test\/config is missing local Supabase config names: LOCAL_AUTH_TOKEN/,
	);
	assert.deepEqual(
		validateBootstrapDopplerNames(
			configText,
			["LOCAL_AUTH_TOKEN", "OPENAI_API_KEY", "PROFILE_REQUIRED"],
			["PROFILE_REQUIRED"],
			"Doppler test/config",
		),
		{
			all: ["LOCAL_AUTH_TOKEN", "OPENAI_API_KEY"],
			edgeRuntime: ["OPENAI_API_KEY"],
		},
	);
});

test("worktree creator produces safe client-specific branch names", () => {
	assert.equal(safeWorktreeName("Feature / Lane A"), "feature-lane-a");
	assert.equal(branchName("claude", "feature-auth"), "claude/feature-auth");
	assert.equal(branchName("codex", "feature-auth"), "codex/feature-auth");
	assert.deepEqual(
		parseWorktreeOptions(["--", "--client", "claude", "--name", "Feature Auth"]),
		{
			baseRef: "origin/preview",
			baseRefSource: "default",
			client: "claude",
			destinationRoot: "",
			hook: false,
			name: "feature-auth",
			projectRoot: "",
		},
	);
	assert.throws(() => safeWorktreeName("../../"), /safe worktree name/);
});

test("worktree bases accept only conservative origin remote-tracking refs", () => {
	assert.equal(validateOriginRemoteTrackingRef("origin/preview"), "origin/preview");
	assert.equal(
		validateOriginRemoteTrackingRef("origin/codex/integrate-simulator-fleet-simslim"),
		"origin/codex/integrate-simulator-fleet-simslim",
	);
	assert.deepEqual(
		parseWorktreeOptions(["--base-ref", "origin/codex/integration", "--name", "feature"]),
		{
			baseRef: "origin/codex/integration",
			baseRefSource: "base-ref",
			client: "manual",
			destinationRoot: "",
			hook: false,
			name: "feature",
			projectRoot: "",
		},
	);
	assert.equal(
		parseWorktreeOptions(["--base", "origin/preview"]).baseRefSource,
		"legacy-base",
	);

	for (const rejected of [
		"a".repeat(40),
		"preview",
		"refs/heads/preview",
		"upstream/preview",
		"origin/../preview",
		"origin/foo/../../bar",
		"origin/foo;touch-pwned",
		"origin/foo$(id)",
		"origin/foo\nbar",
		"origin/-upload-pack=evil",
		"origin/foo.lock",
		"origin/foo..bar",
		"origin/foo@{1}",
		"origin/foo\\bar",
		"origin//foo",
		"origin/foo/",
		"origin/.hidden",
	]) {
		assert.throws(
			() => validateOriginRemoteTrackingRef(rejected),
			/origin\/<branch>/,
			rejected,
		);
	}
	assert.throws(
		() =>
			parseWorktreeOptions([
				"--base-ref",
				"origin/preview",
				"--base",
				"origin/preview",
			]),
		/exactly one/,
	);
	assert.throws(
		() => parseWorktreeOptions(["--allow-stale-base"]),
		/no longer supported/,
	);
});

test("worktree bases fetch one exact origin branch and resolve one immutable commit", () => {
	const commit = "a".repeat(40);
	const calls = [];
	const execute = (command, args, cwd, options) => {
		calls.push({ args, command, cwd, options });
		return calls.length === 1
			? { status: 0, stderr: "", stdout: "" }
			: { status: 0, stderr: "", stdout: `${commit}\n` };
	};
	assert.deepEqual(resolveRemoteBase("/repo", "origin/codex/integration", execute), {
		requestedBaseRef: "origin/codex/integration",
		resolvedBaseCommit: commit,
	});
	assert.deepEqual(calls, [
		{
			args: [
				"fetch",
				"--no-tags",
				"origin",
				"+refs/heads/codex/integration:refs/remotes/origin/codex/integration",
			],
			command: "git",
			cwd: "/repo",
			options: { allowFailure: true, quiet: true },
		},
		{
			args: [
				"rev-parse",
				"--verify",
				"--end-of-options",
				"refs/remotes/origin/codex/integration^{commit}",
			],
			command: "git",
			cwd: "/repo",
			options: { allowFailure: true, quiet: true },
		},
	]);
});

test("worktree base resolution fails closed on fetch and SHA attestation errors", () => {
	let callCount = 0;
	assert.throws(
		() =>
			resolveRemoteBase("/repo", "origin/preview", () => {
				callCount += 1;
				return { status: 1, stderr: "offline", stdout: "" };
			}),
		/never use a stale integration base/,
	);
	assert.equal(callCount, 1);

	assert.throws(
		() =>
			resolveRemoteBase("/repo", "origin/preview", (_command, args) =>
				args[0] === "fetch"
					? { status: 0, stderr: "", stdout: "" }
					: { status: 0, stderr: "", stdout: "not-a-commit\n" },
			),
		/immutable commit/,
	);

	let injectionExecuted = false;
	assert.throws(
		() =>
			resolveRemoteBase("/repo", "origin/preview;touch-pwned", () => {
				injectionExecuted = true;
				return { status: 0, stdout: "a".repeat(40) };
			}),
		/origin\/<branch>/,
	);
	assert.equal(injectionExecuted, false);
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
	assert.equal(parsed.options.deadOnly, true);
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
	const source = ["ios-session-lane.mjs", "lane-target.mjs"]
		.map((name) => readFileSync(new URL(`../scripts/${name}`, import.meta.url), "utf8"))
		.join("\n");
	assert.doesNotMatch(source, /["'](?:delete|erase)["']/);
	assert.match(source, /simulatorQuarantine/);
});

test("Tailscale exposure uses owned HTTPS proxying to loopback", () => {
	const source = ["ios-session-lane.mjs", "lane-metro.mjs"]
		.map((name) => readFileSync(new URL(`../scripts/${name}`, import.meta.url), "utf8"))
		.join("\n");
	assert.match(source, /`--https=\$\{lane\.metro\.port\}`/);
	assert.match(source, /`http:\/\/127\.0\.0\.1:\$\{lane\.metro\.port\}`/);
	assert.match(source, /\["serve", `--https=\$\{port\}`, "--yes", "off"\]/);
	assert.doesNotMatch(source, /["'`]--tcp(?:=|["'`])/);
	assert.doesNotMatch(source, /serve["'`]?\s*,?\s*["'`]reset/);
});

test("agent-device uses the correct identifier for simulator and physical lanes", () => {
	assert.equal(
		agentDeviceTarget({ key: "codex:sim", target: { kind: "simulator", udid: "SIM-UDID" } }),
		"SIM-UDID",
	);
	assert.equal(
		agentDeviceTarget({ key: "codex:phone", target: { deviceId: "PHONE-ID", kind: "physical" } }),
		"PHONE-ID",
	);
	assert.throws(
		() => agentDeviceTarget({ key: "codex:broken", target: { kind: "physical" } }),
		/missing its agent-device identifier/,
	);
});

test("render evidence rejects the Expo development shell and loading errors", () => {
	const shell = `Snapshot: 20 visible nodes
@e1 [application] "PUMPD Development"
@e2 [text] "Development Build"
@e3 [scroll-area] "DEVELOPMENT SERVERS"`;
	const error = `Snapshot: 4 visible nodes
@e1 [alert] "Error loading app"
@e2 [text] "The request to http://127.0.0.1:8081 timed out."
@e3 [button] "OK"`;
	const app = `Snapshot: 8 visible nodes
@e1 [application] "PUMPD"
@e2 [text] "Today's workout"
@e3 [button] "Start workout"`;
	assert.equal(snapshotLooksRendered(shell), false);
	assert.equal(snapshotLooksRendered(error), false);
	assert.equal(snapshotLooksRendered(app), true);
});

test("fresh Expo shells recover through the exact lane URL", () => {
	const url = "https://mac.tailnet.ts.net:8081";
	assert.deepEqual(
		manualUrlAction(
			'Snapshot: 4 visible nodes\n@e3 [button] "Enter URL manually"',
			url,
		),
		{ kind: "enter", line: '@e3 [button] "Enter URL manually"' },
	);
	assert.deepEqual(
		manualUrlAction(
			'Snapshot: 5 visible nodes\n@e4 [text-field] [editable]\n@e5 [button] "Connect" [disabled]',
			url,
		),
		{ kind: "focus", line: "@e4 [text-field] [editable]" },
	);
	assert.deepEqual(
		manualUrlAction(
			`Snapshot: 5 visible nodes\n@e4 [text-field] "${url}" [editable]\n@e5 [button] "Connect"`,
			url,
		),
		{ kind: "connect", line: '@e5 [button] "Connect"' },
	);
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

test("mentioning the lane wrapper cannot hide a raw iOS command", () => {
	for (const command of [
		"xcrun simctl erase all # ios-session-lane",
		"ios-session-lane status --client codex --session-id thread-1; xcrun simctl shutdown all",
		"ios-session-lane status --client codex --session-id thread-1 && pnpm exec expo start --port 8088",
		"printf lane | xcrun simctl boot AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
	]) {
		assert.notEqual(directIosReason(command), "", command);
	}
});

test("raw shared Supabase lifecycle commands are blocked", () => {
	assert.match(directBackendReason("supabase start"), /owner lease/);
	assert.match(directBackendReason("supabase db reset"), /must not run/);
	assert.match(
		directBackendReason("pnpm --dir apps/backend db:reset"),
		/single-owner/,
	);
});

test("mentioning the lane wrapper cannot hide a raw backend command", () => {
	for (const command of [
		"supabase db reset # ios-session-lane",
		"ios-session-lane status --client codex --session-id thread-1; supabase stop",
		"ios-session-lane status --client codex --session-id thread-1 && pnpm --dir apps/backend db:reset",
	]) {
		assert.notEqual(directBackendReason(command), "", command);
	}
});

test("raw worktree creation is blocked unless it uses the bootstrap wrapper", () => {
	assert.match(directWorktreeReason("git worktree add ../feature -b feature"), /bootstrap/);
	assert.equal(
		directWorktreeReason("ios-session-worktree --name feature"),
		"",
	);
});

test("mentioning the worktree wrapper cannot hide raw worktree creation", () => {
	for (const command of [
		"git worktree add ../feature -b feature # ios-session-worktree",
		"ios-session-worktree --name feature; git worktree add ../other -b other",
		"ios-session-worktree --name feature && git worktree add ../other -b other",
	]) {
		assert.notEqual(directWorktreeReason(command), "", command);
	}
});

test("a standalone session-lane wrapper has no independently guarded operation", () => {
	const command =
		"ios-session-lane up --client codex --session-id thread-1 --build";
	assert.equal(isLaneCommand(command), true);
	assert.equal(directIosReason(command), "");
	assert.equal(directBackendReason(command), "");
});

test("wrapper parsing distinguishes invocations from harmless inspection text", () => {
	for (const command of [
		"rg -n ios-session-lane plugins",
		"rg -n 'ios-session-worktree' .",
		"printf '%s\\n' ios-session-lane",
		"command -v ios-session-lane",
		'echo "$(rg ios-session-lane .)"',
	]) {
		assert.equal(isLaneCommand(command), false, command);
		assert.equal(isWorktreeCommand(command), false, command);
		assert.equal(laneWrapperReason(command, "codex", "thread-1"), "", command);
	}
	assert.equal(
		isLaneCommand("ios-session-lane status --client codex --session-id thread-1"),
		true,
	);
	assert.equal(isWorktreeCommand("ios-session-worktree --name feature"), true);
	assert.equal(
		isLaneCommand('echo "$(ios-session-lane status --client codex --session-id thread-1)"'),
		true,
	);
	for (const command of [
		"rg ios-session-lane .; xcrun simctl boot OTHER-UDID",
		"echo ios-session-lane && expo start --port 9999",
		'rg ios-session-lane "$(supabase stop)"',
	]) {
		assert.ok(
			directIosReason(command) || directBackendReason(command) || directWorktreeReason(command),
			command,
		);
	}
});

test("lane wrapper commands are bound to the current client and session", () => {
	assert.equal(
		laneWrapperReason(
			"ios-session-lane status --client codex --session-id thread-1",
			"codex",
			"thread-1",
		),
		"",
	);
	assert.match(
		laneWrapperReason(
			"ios-session-lane down --client codex --session-id other-thread",
			"codex",
			"thread-1",
		),
		/exact session id/,
	);
	assert.match(
		laneWrapperReason(
			"ios-session-lane status --client claude --session-id thread-1",
			"codex",
			"thread-1",
		),
		/hook client/,
	);
	assert.match(
		laneWrapperReason(
			"ios-session-lane status --client codex --session-id thread-1; xcrun simctl erase all",
			"codex",
			"thread-1",
		),
		/only top-level/,
	);
});

test("lane controller adapters reject caller-supplied target selectors", () => {
	const agentDeviceFlags = ["--platform", "--device", "--udid", "--session", "-d"];
	for (const reserved of agentDeviceFlags) {
		assert.throws(
			() => assertNoReservedControllerFlags([reserved, "someone-elses-device"], agentDeviceFlags),
			/owned by the iOS lane/,
		);
	}
	for (const reserved of agentDeviceFlags.filter((flag) => flag.startsWith("--"))) {
		assert.throws(
			() => assertNoReservedControllerFlags([`${reserved}=someone-elses-device`], agentDeviceFlags),
			/owned by the iOS lane/,
		);
	}
	assert.doesNotThrow(() =>
		assertNoReservedControllerFlags(["tap", "100", "200"], agentDeviceFlags),
	);

	const maestroFlags = ["--udid", "--device"];
	assert.throws(
		() => assertNoReservedControllerFlags(["test", "flow.yaml", "--udid=wrong"], maestroFlags),
		/owned by the iOS lane/,
	);
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
	assert.equal(twice.hooks.UserPromptSubmit.length, 1);
	assert.match(
		twice.hooks.UserPromptSubmit[0].hooks[0].command,
		/heartbeat --client codex/,
	);
	assert.equal(twice.hooks.UserPromptSubmit[0].hooks[0].timeout, 5);
});

test("installed hooks guard Codex Bash and simulator MCP tools and end within the Codex limit", () => {
	const installed = mergeHooks(
		{ hooks: {} },
		"codex",
		"/tmp/agent-tooling-ios-session-lanes/runtime/scripts/ios-session-hook.mjs",
	);
	const preToolGroup = installed.hooks.PreToolUse.at(-1);
	const matcher = new RegExp(preToolGroup.matcher);
	for (const toolName of [
		"Bash",
		"mcp__ios_simulator__ui_view",
		"mcp__ios-simulator__ui_tap",
		"mcp__simview__take_screenshot",
	]) {
		assert.equal(matcher.test(toolName), true, toolName);
	}
	assert.equal(matcher.test("functions.exec"), false);
	assert.equal(installed.hooks.SessionEnd.at(-1).hooks.at(-1).timeout, 3);
});

test("the hook is a no-op outside a registered project", () => {
	const directory = mkdtempSync(path.join(tmpdir(), "pumpd-lane-non-project-"));
	const hook = fileURLToPath(new URL("../scripts/ios-session-hook.mjs", import.meta.url));
	const environment = { ...process.env };
	delete environment.IOS_SESSION_LANES_PROJECT_ROOT;
	const result = spawnSync(
		process.execPath,
		[hook, "pretool", "--client", "codex"],
		{
			cwd: directory,
			encoding: "utf8",
			env: environment,
			input: JSON.stringify({
				cwd: directory,
				session_id: "thread-outside-project",
				tool_input: { command: "xcrun simctl erase all" },
				tool_name: "functions.exec",
			}),
		},
	);
	assert.equal(result.status, 0, result.stderr);
	assert.equal(result.stdout, "");
	assert.equal(result.stderr, "");
});

test("repeated installation preserves the pristine client config backup", async () => {
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
		removeManagedUserHooks: false,
		runtimeRoot: path.join(directory, "runtime"),
	};
	const first = await install(options);
	const staleRuntimeFile = path.join(first.runtimeRoot, "scripts", "removed-in-source.mjs");
	writeFileSync(staleRuntimeFile, "stale\n");
	await assert.rejects(install(options), /full integrity inventory/);
	assert.equal(readFileSync(staleRuntimeFile, "utf8"), "stale\n");
	rmSync(staleRuntimeFile);
	await install(options);
	assert.deepEqual(
		JSON.parse(
			readFileSync(`${settingsFile}.before-ios-session-lanes.json`, "utf8"),
		),
		original,
	);
});

test("managed user hooks can be removed without touching unrelated hooks", () => {
	const original = {
		hooks: {
			PreToolUse: [
				{
					matcher: "Bash",
					hooks: [
						{ command: "node unrelated.js", type: "command" },
						{
							command: "node ios-session-hook.mjs # agent-tooling-ios-session-lanes",
							type: "command",
						},
					],
				},
			],
		},
		permissions: { deny: ["Read(.env)"] },
	};
	const cleaned = removeManagedHooks(original);
	assert.equal(cleaned.hooks.PreToolUse.length, 1);
	assert.equal(cleaned.hooks.PreToolUse[0].matcher, "Bash");
	assert.equal(cleaned.hooks.PreToolUse[0].hooks.length, 1);
	assert.match(cleaned.hooks.PreToolUse[0].hooks[0].command, /unrelated/);
	assert.deepEqual(cleaned.permissions, original.permissions);
	const merged = mergeHooks(
		original,
		"codex",
		"/tmp/agent-tooling-ios-session-lanes/runtime/scripts/ios-session-hook.mjs",
	);
	assert.equal(
		merged.hooks.PreToolUse.some((group) =>
			group.hooks.some((hook) => hook.command === "node unrelated.js"),
		),
		true,
	);
});

test("file locks serialize callers, reject active theft, and recover dead owners", async () => {
	const directory = mkdtempSync(path.join(tmpdir(), "pumpd-lane-lock-test-"));
	const lockPath = path.join(directory, "serial.lock");
	let active = 0;
	let maximum = 0;
	await Promise.all(
		Array.from({ length: 5 }, () =>
			withFileLock(lockPath, 2_000, async () => {
				active += 1;
				maximum = Math.max(maximum, active);
				await new Promise((resolve) => setTimeout(resolve, 20));
				active -= 1;
			}),
		),
	);
	assert.equal(maximum, 1);

	await withFileLock(lockPath, 2_000, async () => {
		await assert.rejects(
			withFileLock(lockPath, 75, async () => {}),
			/Timed out acquiring/,
		);
	});

	const stalePath = path.join(directory, "stale.lock");
	mkdirSync(stalePath);
	writeFileSync(
		path.join(stalePath, "owner.json"),
		JSON.stringify({ pid: 2_147_483_647, processStartedAt: "dead", token: "dead" }),
	);
	let recovered = false;
	await withFileLock(stalePath, 2_000, async () => {
		recovered = true;
	});
	assert.equal(recovered, true);
	assert.equal(existsSync(stalePath), false);
});

test("Metro port allocation detects an IPv6-loopback listener", async () => {
	const server = createServer();
	await new Promise((resolve, reject) => {
		server.once("error", reject);
		server.listen(0, "::1", resolve);
	});
	try {
		assert.equal(await isPortAvailable(server.address().port), false);
	} finally {
		await new Promise((resolve) => server.close(resolve));
	}
});

test("backend contract changes for functions, templates, and seed content", () => {
	const directory = mkdtempSync(path.join(tmpdir(), "pumpd-backend-contract-test-"));
	for (const relative of [
		"apps/backend/supabase/functions/coach/index.ts",
		"apps/backend/supabase/templates/invite.html",
		"apps/backend/supabase/seed.sql",
	]) {
		const file = path.join(directory, relative);
		mkdirSync(path.dirname(file), { recursive: true });
		writeFileSync(file, `${relative}:one\n`);
	}
	for (const args of [["init", "-q"], ["add", "."]]) {
		const result = spawnSync("git", args, { cwd: directory, encoding: "utf8" });
		assert.equal(result.status, 0, result.stderr);
	}
	const initial = backendContract(directory);
	assert.equal(initial.fileCount, 3);
	writeFileSync(
		path.join(directory, "apps/backend/supabase/functions/coach/index.ts"),
		"changed\n",
	);
	assert.notEqual(backendContract(directory).hash, initial.hash);
});

test("bundled Claude and Codex hooks use client-native roots and lifecycle events", () => {
	const claude = JSON.parse(
		readFileSync(new URL("../../../hooks/claude-hooks.json", import.meta.url), "utf8"),
	);
	const codex = JSON.parse(
		readFileSync(new URL("../../../hooks/codex-hooks.json", import.meta.url), "utf8"),
	);
	assert.equal(claude.hooks.WorktreeCreate, undefined);
	assert.equal(codex.hooks.WorktreeCreate, undefined);
	for (const [rootVariable, document] of [
		["CLAUDE_PLUGIN_ROOT", claude],
		["PLUGIN_ROOT", codex],
	]) {
		assert.ok(document.hooks.SessionStart);
		assert.ok(document.hooks.UserPromptSubmit);
		assert.ok(document.hooks.PreToolUse);
		assert.equal(document.hooks.SessionEnd[0].hooks[0].timeout, 3);
		const serialized = JSON.stringify(document);
		assert.match(serialized, new RegExp(`\\$\\{${rootVariable}\\}`));
	}
});

test("SimView is limited to observation while the lane input writer is active", () => {
	assert.equal(simViewToolIsReadOnly("mcp__simview__connect_device"), true);
	assert.equal(simViewToolIsReadOnly("mcp__simview__take_screenshot"), true);
	assert.equal(simViewToolIsReadOnly("mcp__simview__get_element_tree"), true);
	assert.equal(simViewToolIsReadOnly("mcp__simview__tap_element"), false);
	assert.equal(simViewToolIsReadOnly("mcp__simview__type_text"), false);
	assert.equal(simViewToolIsReadOnly("mcp__simview__enable_ui_probe"), false);
});

test("the iOS Simulator MCP is observation-only", () => {
	for (const toolName of [
		"mcp__ios_simulator__ui_describe_all",
		"mcp__ios_simulator__ui_describe_point",
		"mcp__ios_simulator__ui_find_element",
		"mcp__ios_simulator__ui_view",
		"mcp__ios_simulator__screenshot",
	]) {
		assert.equal(iosSimulatorToolIsReadOnly(toolName), true, toolName);
	}
	for (const toolName of [
		"mcp__ios_simulator__ui_tap",
		"mcp__ios_simulator__ui_type",
		"mcp__ios_simulator__ui_swipe",
		"mcp__ios_simulator__install_app",
		"mcp__ios_simulator__launch_app",
		"mcp__ios_simulator__record_video",
		"mcp__ios_simulator__stop_recording",
	]) {
		assert.equal(iosSimulatorToolIsReadOnly(toolName), false, toolName);
	}
});
