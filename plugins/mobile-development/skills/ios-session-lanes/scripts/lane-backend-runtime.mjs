import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
	chmodSync,
	closeSync,
	copyFileSync,
	existsSync,
	fsyncSync,
	lstatSync,
	mkdirSync,
	openSync,
	readFileSync,
	renameSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import path from "node:path";
import {
	backendDockerNetwork,
	listBackendProjectContainers,
} from "./lane-backend-docker.mjs";
import { requireIdentifier } from "./lane-identifiers.mjs";
import {
	assertLocalDopplerReferencesAvailable,
	parseLocalDopplerReferences,
} from "./lane-backend-secrets.mjs";
import {
	backendRoot,
	laneHome,
	profile,
	repoRoot,
	runCaptured,
} from "./lane-runtime-context.mjs";

const operationTimeoutMs = 30 * 60 * 1000;
const backendEnvStagingRoot = path.join(laneHome, "backend-env-staging");

export { parseLocalDopplerReferences };

export function readLocalSupabaseStatus(
	{
		allowFailure = false,
		dopplerConfig = profile.backend.dopplerConfig,
	} = {},
) {
	let result;
	try {
		const stdout = runBackendCapturedWithDoppler(dopplerConfig, [
			"corepack",
			"pnpm",
			"--dir",
			profile.backend.root,
			"exec",
			"supabase",
			"status",
			"-o",
			"json",
			"--network-id",
			backendDockerNetwork,
		]);
		result = { status: 0, stdout };
	} catch (error) {
		result = { error, status: null, stdout: "" };
	}
	const containers = result.status === 0 ? [] : listBackendProjectContainers();
	const classified = classifyBackendStatusResult(result, containers);
	if (classified.state === "running") return classified.data;
	if (allowFailure) return null;
	throw new Error(
		"Shared local Supabase is not running. One session must use ios-session-lane backend-up; ordinary lanes only consume it.",
	);
}

export function classifyBackendStatusResult(result, containers = []) {
	if (result?.status === 0) {
		try {
			return { data: JSON.parse(result.stdout), state: "running" };
		} catch {
			throw new Error("Supabase status returned invalid JSON.");
		}
	}
	if (!Array.isArray(containers)) {
		throw new Error("Local Supabase container inventory was unavailable.");
	}
	if (containers.length === 0) return { data: null, state: "stopped" };
	throw new Error(
		`Could not determine local Supabase health: the status probe failed while ${
			containers.length
		} project container${containers.length === 1 ? " remains" : "s remain"}. Ownership was preserved.`,
	);
}

export function materializeBackendEnv(statusData) {
	const publishableKey = statusData.PUBLISHABLE_KEY ?? statusData.ANON_KEY ?? "";
	const secretKey = statusData.SECRET_KEY ?? statusData.SERVICE_ROLE_KEY ?? "";
	if (!statusData.API_URL || !publishableKey || !secretKey) return;
	const envPath = path.join(backendRoot, ".env");
	const ignored = spawnSync("git", ["check-ignore", "--quiet", "--", envPath], { cwd: repoRoot });
	if (ignored.status !== 0) {
		throw new Error("Refusing to materialize local Supabase credentials because apps/backend/.env is not gitignored.");
	}
	const values = new Map([
		["SUPABASE_URL", statusData.API_URL],
		["SUPABASE_PUBLISHABLE_KEY", publishableKey],
		["SUPABASE_SECRET_KEY", secretKey],
	]);
	for (const [name, value] of values) {
		if (/\r|\n/.test(String(value))) throw new Error(`Local Supabase ${name} contained a newline.`);
	}
	const existing = existsSync(envPath) ? readFileSync(envPath, "utf8").split(/\r?\n/) : [];
	const preserved = existing.filter((line) => {
		const name = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=/)?.[1];
		return !name || !values.has(name);
	});
	while (preserved.at(-1) === "") preserved.pop();
	const content = [
		...preserved,
		...Array.from(values, ([name, value]) => `${name}=${value}`),
		"",
	].join("\n");
	replaceFileFromPrivateStage(envPath, content);
}

export function replaceFileFromPrivateStage(
	destination,
	content,
	{ stagingDirectory = backendEnvStagingRoot } = {},
) {
	if (existsSync(destination) && !lstatSync(destination).isFile()) {
		throw new Error(`Refusing to replace non-regular backend environment path ${destination}.`);
	}
	mkdirSync(stagingDirectory, { recursive: true, mode: 0o700 });
	if (!lstatSync(stagingDirectory).isDirectory()) {
		throw new Error(`Backend environment staging path is not a directory: ${stagingDirectory}.`);
	}
	chmodSync(stagingDirectory, 0o700);
	const token = `${process.pid}-${randomBytes(12).toString("hex")}`;
	const stagedPath = path.join(stagingDirectory, `backend-env-${token}.stage`);
	const backupPath = path.join(stagingDirectory, `backend-env-${token}.backup`);
	let stagedExists = false;
	let backupExists = false;
	writeFileSync(stagedPath, content, { flag: "wx", mode: 0o600 });
	stagedExists = true;
	try {
		try {
			renameSync(stagedPath, destination);
			stagedExists = false;
		} catch (error) {
			if (error.code !== "EXDEV") throw error;
			if (existsSync(destination)) {
				copyFileSync(destination, backupPath);
				chmodSync(backupPath, 0o600);
				backupExists = true;
			}
			try {
				copyFileSync(stagedPath, destination);
				chmodSync(destination, 0o600);
				if (readFileSync(destination, "utf8") !== content) {
					throw new Error(`Backend environment verification failed for ${destination}.`);
				}
			} catch (copyError) {
				if (backupExists) {
					copyFileSync(backupPath, destination);
					chmodSync(destination, 0o600);
				} else {
					rmSync(destination, { force: true });
				}
				throw copyError;
			}
		}
		chmodSync(destination, 0o600);
		const descriptor = openSync(destination, "r");
		try {
			fsyncSync(descriptor);
		} finally {
			closeSync(descriptor);
		}
	} finally {
		if (stagedExists) rmSync(stagedPath, { force: true });
		if (backupExists) rmSync(backupPath, { force: true });
	}
}

export function backendResetCommands(networkId = backendDockerNetwork) {
	requireIdentifier(networkId, "Docker network id");
	return [
		[
			"corepack",
			"pnpm",
			"--dir",
			profile.backend.root,
			"exec",
			"supabase",
			"db",
			"reset",
			"--network-id",
			networkId,
		],
		[
			"corepack",
			"pnpm",
			"--dir",
			path.posix.join(path.posix.dirname(profile.backend.root), "catalog"),
			"run",
			"media:publish",
		],
	];
}

export function backendMediaPublishEnvironment(
	statusData,
	baseEnvironment = process.env,
) {
	const secretKey = statusData?.SECRET_KEY;
	const serviceRoleKey = statusData?.SERVICE_ROLE_KEY;
	if (!statusData?.API_URL || (!secretKey && !serviceRoleKey)) {
		throw new Error(
			"Local Supabase status did not include its API URL and secret/service-role key for catalog media publishing.",
		);
	}
	return {
		...baseEnvironment,
		...(secretKey
			? { SUPABASE_SECRET_KEY: secretKey }
			: { SUPABASE_SERVICE_ROLE_KEY: serviceRoleKey }),
		SUPABASE_URL: statusData.API_URL,
	};
}

export function allowedDopplerConfigs() {
	const configured = profile.backend.allowedDopplerConfigs;
	return Array.isArray(configured) && configured.length > 0
		? [...new Set(configured)]
		: [profile.backend.dopplerConfig];
}

export function assertAllowedDopplerConfig(config, expectedConfig = null) {
	requireIdentifier(config, "Doppler config");
	const allowed = allowedDopplerConfigs();
	if (!allowed.includes(config)) {
		throw new Error(
			`Doppler config ${config} is not approved for local development. Allowed: ${allowed.join(", ")}.`,
		);
	}
	if (expectedConfig && config !== expectedConfig) {
		throw new Error(
			`Shared Supabase is pinned to Doppler config ${config}; refusing requested config ${expectedConfig}.`,
		);
	}
	return config;
}

function availableBackendSecretNames(config) {
	const output = runCaptured("doppler", [
		"secrets",
		"--only-names",
		"--json",
		"--project",
		profile.backend.dopplerProject,
		"--config",
		config,
	]).stdout;
	let names;
	try {
		names = new Set(Object.keys(JSON.parse(output)));
	} catch {
		throw new Error("Doppler returned invalid names-only JSON.");
	}
	const configPath = path.join(backendRoot, "supabase/config.toml");
	const references = assertLocalDopplerReferencesAvailable(
		readFileSync(configPath, "utf8"),
		names,
	);
	return references.all;
}

export function runBackendWithDoppler(config, command, environment = process.env) {
	const secretNames = availableBackendSecretNames(config);
	runSensitiveCommand(
		"doppler",
		dopplerRunArgs(config, secretNames, command),
		environment,
	);
}

export function runSensitiveCommand(command, args, environment = process.env) {
	const result = spawnSync(command, args, {
		cwd: repoRoot,
		encoding: "utf8",
		env: environment,
		maxBuffer: 20 * 1024 * 1024,
		timeout: operationTimeoutMs,
	});
	if (result.status !== 0) {
		throw new Error(
			`Sensitive local backend command ${command} failed with ${
				result.error?.code ?? `exit ${result.status ?? "unknown"}`
			}. Output was suppressed.`,
		);
	}
}

function runBackendCapturedWithDoppler(config, command) {
	const secretNames = availableBackendSecretNames(config);
	const result = spawnSync(
		"doppler",
		dopplerRunArgs(config, secretNames, command),
		{
			cwd: repoRoot,
			encoding: "utf8",
			maxBuffer: 10 * 1024 * 1024,
			timeout: operationTimeoutMs,
		},
	);
	if (result.status !== 0) {
		throw new Error(
			`Doppler-wrapped local Supabase command failed with ${
				result.error?.code ?? `exit ${result.status ?? "unknown"}`
			}.`,
		);
	}
	return result.stdout;
}

function dopplerRunArgs(config, secretNames, command) {
	return [
		"--silent",
		"run",
		"--project",
		profile.backend.dopplerProject,
		"--config",
		config,
		"--no-fallback",
		"--only-secrets",
		secretNames.join(","),
		"--",
		...command,
	];
}
