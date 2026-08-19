import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
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
	classifySimulatorBootResult,
	nativeCacheKey,
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

test("CLI parsing keeps local Supabase as the default", () => {
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
	assert.equal(parsed.options.sessionId, "thread-1");
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
