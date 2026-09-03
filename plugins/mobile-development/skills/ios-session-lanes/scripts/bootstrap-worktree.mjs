#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
	chmodSync,
	existsSync,
	mkdirSync,
	readFileSync,
	realpathSync,
	renameSync,
	rmSync,
	statSync,
	writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
	assertSupportedProject,
	isMainModule,
	projectContext,
} from "./project-context.mjs";
import {
	assertLocalDopplerReferencesAvailable,
	parseLocalDopplerReferences,
} from "./lane-backend-secrets.mjs";
import { withFileLock } from "./lane-lock.mjs";

const receiptVersion = 5;
const attestationVersion = 1;
const commandTimeoutMs = 30 * 60 * 1000;
const remoteRefreshMs = 24 * 60 * 60 * 1000;

export function parseBootstrapOptions(args) {
	const options = {
		check: false,
		dopplerConfig: "",
		easEnvironment: "",
		force: false,
		json: false,
		projectRoot: "",
		quiet: false,
	};
	for (let index = 0; index < args.length; index += 1) {
		const arg = args[index];
		if (arg === "--") continue;
		if (arg === "--check") options.check = true;
		else if (arg === "--force") options.force = true;
		else if (arg === "--json") options.json = true;
		else if (arg === "--quiet") options.quiet = true;
		else if (arg === "--doppler-config")
			options.dopplerConfig = requireValue(args, ++index, arg);
		else if (arg === "--eas-environment")
			options.easEnvironment = requireValue(args, ++index, arg);
		else if (arg === "--project-root")
			options.projectRoot = requireValue(args, ++index, arg);
		else throw new Error(`Unknown bootstrap option ${arg}.`);
	}
	return options;
}

function requireValue(args, index, option) {
	const value = args[index];
	if (!value || value.startsWith("--")) {
		throw new Error(`${option} requires a value.`);
	}
	return value;
}

function contextFor(options = {}) {
	const context = projectContext(options.projectRoot || process.cwd());
	const profile = context.profile;
	return {
		...context,
		backendConfigPath: path.join(context.root, profile.backend.config),
		dopplerConfig: options.dopplerConfig || profile.backend.dopplerConfig,
		easEnvironment: options.easEnvironment || profile.mobile.easEnvironment,
		mobileEnvPath: path.join(
			context.mobileRoot,
			profile.mobile.environmentFile,
		),
	};
}

function run(
	command,
	args,
	cwd,
	{
		capture = false,
		environment = process.env,
		quiet = false,
		timeout = commandTimeoutMs,
	} = {},
) {
	const result = spawnSync(command, args, {
		cwd,
		encoding: "utf8",
		env: environment,
		stdio: capture ? "pipe" : quiet ? "ignore" : "inherit",
		timeout,
	});
	if (result.status !== 0) {
		const detail = capture
			? (result.error?.message || result.stderr || result.stdout || "").trim()
			: result.error?.message || `exit ${result.status}`;
		throw new Error(
			`${command} ${args.join(" ")} failed${detail ? `: ${detail}` : ""}.`,
		);
	}
	return (result.stdout ?? "").trim();
}

function hashText(value) {
	return createHash("sha256").update(value).digest("hex");
}

function hashFile(filePath) {
	return hashText(readFileSync(filePath));
}

function assertExactSemver(value, source) {
	if (!/^\d+\.\d+\.\d+$/.test(String(value ?? ""))) {
		throw new Error(`${source} must be an exact semantic version.`);
	}
	return String(value);
}

export function envNames(filePath) {
	return readFileSync(filePath, "utf8")
		.split(/\r?\n/)
		.map((line) => line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=/)?.[1])
		.filter(Boolean)
		.sort();
}

export function envReferences(filePath) {
	return parseLocalDopplerReferences(readFileSync(filePath, "utf8")).all;
}

function assertNames(source, names, required) {
	const available = new Set(names);
	const missing = required.filter((name) => !available.has(name));
	if (missing.length > 0) {
		throw new Error(`${source} is missing required names: ${missing.join(", ")}.`);
	}
}

export function validateBootstrapDopplerNames(
	configText,
	dopplerNames,
	requiredNames,
	source = "Doppler",
) {
	assertNames(source, dopplerNames, requiredNames);
	return assertLocalDopplerReferencesAvailable(configText, dopplerNames, {
		source,
	});
}

function readDopplerNames(context) {
	const output = run(
		"doppler",
		[
			"secrets",
			"--only-names",
			"--json",
			"--project",
			context.profile.backend.dopplerProject,
			"--config",
			context.dopplerConfig,
		],
		context.root,
		{ capture: true },
	);
	try {
		return Object.keys(JSON.parse(output)).sort();
	} catch {
		throw new Error("Doppler returned invalid names-only JSON.");
	}
}

function gitValue(context, args) {
	return run("git", args, context.root, { capture: true });
}

export function receiptPathFor(options = {}) {
	const context = contextFor(options);
	const gitDirectory = gitValue(context, ["rev-parse", "--absolute-git-dir"]);
	return path.join(gitDirectory, "agent-tooling-bootstrap-receipt.json");
}

export function managedAttestationPathFor(options = {}) {
	const context = contextFor(options);
	const gitDirectory = gitValue(context, ["rev-parse", "--absolute-git-dir"]);
	return path.join(gitDirectory, "agent-tooling-managed-worktree.json");
}

export function writeManagedWorktreeAttestation(options = {}, details = {}) {
	const context = assertSupportedProject(options.projectRoot || process.cwd());
	const attestationPath = managedAttestationPathFor({ projectRoot: context.root });
	const gitDirectory = gitValue(context, ["rev-parse", "--absolute-git-dir"]);
	const attestation = {
		client: String(details.client ?? "managed"),
		createdAt: new Date().toISOString(),
		createdBy: "ios-session-worktree",
		gitDirectory,
		origin: context.profile.match.canonicalGitHubOrigin,
		root: realpathSync(context.root),
		version: attestationVersion,
	};
	mkdirSync(path.dirname(attestationPath), { recursive: true, mode: 0o700 });
	const temporary = `${attestationPath}.${process.pid}-${randomBytes(6).toString("hex")}.tmp`;
	writeFileSync(temporary, `${JSON.stringify(attestation, null, 2)}\n`, { mode: 0o600 });
	renameSync(temporary, attestationPath);
	chmodSync(attestationPath, 0o600);
	return { attestation, attestationPath };
}

export function managedWorktreeAttestationStatus(options = {}) {
	const context = contextFor(options);
	const attestationPath = managedAttestationPathFor({ projectRoot: context.root });
	if (!existsSync(attestationPath)) {
		return { attestation: null, attestationPath, ok: false, reason: "managed worktree attestation absent" };
	}
	let attestation;
	try {
		attestation = JSON.parse(readFileSync(attestationPath, "utf8"));
	} catch {
		return { attestation: null, attestationPath, ok: false, reason: "managed worktree attestation invalid" };
	}
	const expectedGitDirectory = gitValue(context, ["rev-parse", "--absolute-git-dir"]);
	const valid =
		attestation.version === attestationVersion &&
		attestation.createdBy === "ios-session-worktree" &&
		attestation.root === realpathSync(context.root) &&
		attestation.gitDirectory === expectedGitDirectory &&
		attestation.origin === context.profile.match.canonicalGitHubOrigin &&
		(statSync(attestationPath).mode & 0o077) === 0;
	return {
		attestation,
		attestationPath,
		ok: valid,
		reason: valid ? "" : "managed worktree attestation does not match this worktree",
	};
}

function readReceipt(context) {
	const receiptPath = receiptPathFor({ projectRoot: context.root });
	if (!existsSync(receiptPath)) return null;
	try {
		return JSON.parse(readFileSync(receiptPath, "utf8"));
	} catch {
		throw new Error(`Invalid bootstrap receipt at ${receiptPath}.`);
	}
}

function readProjectInputs(context) {
	const easConfig = JSON.parse(
		readFileSync(path.join(context.mobileRoot, "eas.json"), "utf8"),
	);
	const rootPackage = JSON.parse(
		readFileSync(path.join(context.root, "package.json"), "utf8"),
	);
	const pnpmVersion = assertExactSemver(
		context.profile.toolchain?.pnpmVersion,
		"The trusted profile pnpmVersion",
	);
	const easVersion = assertExactSemver(
		context.profile.toolchain?.easCliVersion,
		"The trusted profile easCliVersion",
	);
	const expectedPackageManager = `pnpm@${pnpmVersion}`;
	if (rootPackage.packageManager !== expectedPackageManager) {
		throw new Error(
			`package.json must declare the trusted packageManager ${expectedPackageManager}.`,
		);
	}
	if (easConfig.cli?.version !== easVersion) {
		throw new Error(`apps/mobile/eas.json must declare the trusted EAS CLI ${easVersion}.`);
	}
	return {
		backendConfigHash: hashFile(context.backendConfigPath),
		dopplerConfig: context.dopplerConfig,
		easEnvironment: context.easEnvironment,
		easVersion,
		lockfileHash: hashFile(path.join(context.root, "pnpm-lock.yaml")),
		packageManager: expectedPackageManager,
		pnpmVersion,
	};
}

function receiptMatchesInputs(receipt, inputs) {
	return (
		receipt?.version === receiptVersion &&
		receipt.inputs?.backendConfigHash === inputs.backendConfigHash &&
		receipt.inputs?.dopplerConfig === inputs.dopplerConfig &&
		receipt.inputs?.easEnvironment === inputs.easEnvironment &&
		receipt.inputs?.easVersion === inputs.easVersion &&
		receipt.inputs?.lockfileHash === inputs.lockfileHash &&
		receipt.inputs?.packageManager === inputs.packageManager &&
		receipt.inputs?.pnpmVersion === inputs.pnpmVersion
	);
}

function receiptIsFresh(receipt) {
	const completed = Date.parse(receipt?.completedAt ?? "");
	return Number.isFinite(completed) && Date.now() - completed < remoteRefreshMs;
}

function lfsStatus(context) {
	const output = run("git", ["lfs", "ls-files"], context.root, { capture: true });
	const missing = output
		.split(/\r?\n/)
		.map((line) => line.match(/^[0-9a-f]+\s+([-*])\s+(.+)$/i))
		.filter((match) => match?.[1] === "-")
		.map((match) => match[2]);
	return { fileCount: output ? output.split(/\r?\n/).filter(Boolean).length : 0, missing };
}

export function localBootstrapStatus(options = {}) {
	const context = contextFor(options);
	const inputs = readProjectInputs(context);
	const receipt = readReceipt(context);
	const reasons = [];
	if (!receipt) reasons.push("receipt absent");
	else if (!receiptMatchesInputs(receipt, inputs)) reasons.push("receipt inputs stale");
	else if (!receiptIsFresh(receipt)) reasons.push("remote environment refresh due");
	if (!existsSync(path.join(context.root, "node_modules"))) reasons.push("node_modules absent");
	const lfs = lfsStatus(context);
	if (lfs.missing.length > 0) reasons.push(`Git LFS objects missing: ${lfs.missing.length}`);
	if (!existsSync(context.mobileEnvPath)) {
		reasons.push(`${context.profile.mobile.root}/${context.profile.mobile.environmentFile} absent`);
	} else {
		const names = envNames(context.mobileEnvPath);
		const missing = context.profile.mobile.requiredEnvironmentNames.filter(
			(name) => !names.includes(name),
		);
		if (missing.length > 0) {
			reasons.push(`mobile names missing: ${missing.join(", ")}`);
		}
		if ((statSync(context.mobileEnvPath).mode & 0o077) !== 0) {
			reasons.push("mobile environment permissions are not 0600");
		}
		if (receipt?.mobile?.contentHash !== hashFile(context.mobileEnvPath)) {
			reasons.push("mobile environment differs from receipt");
		}
	}
	return {
		inputs,
		lfs,
		ok: reasons.length === 0,
		reasons,
		receipt,
		receiptPath: receiptPathFor({ projectRoot: context.root }),
	};
}

function installDependencies(context, options, receipt, inputs) {
	const hasModules = existsSync(path.join(context.root, "node_modules"));
	if (!options.force && hasModules && receiptMatchesInputs(receipt, inputs)) {
		return false;
	}
	run("corepack", [`pnpm@${inputs.pnpmVersion}`, "install", "--frozen-lockfile"], context.root, {
		environment: { ...process.env, HUSKY: "0" },
		quiet: options.quiet,
	});
	return true;
}

function materializeGitLfs(context, options, receipt, inputs) {
	const before = lfsStatus(context);
	if (
		!options.force &&
		before.missing.length === 0 &&
		receiptMatchesInputs(receipt, inputs)
	) {
		return false;
	}
	run("git", ["lfs", "install", "--local"], context.root, { quiet: options.quiet });
	run("git", ["lfs", "pull"], context.root, { quiet: options.quiet });
	run("git", ["lfs", "checkout"], context.root, { quiet: options.quiet });
	const after = lfsStatus(context);
	if (after.missing.length > 0) {
		throw new Error(`Git LFS still has ${after.missing.length} unmaterialized object(s).`);
	}
	return true;
}

function pullMobileEnvironment(context, options, receipt, inputs) {
	if (
		!options.force &&
		existsSync(context.mobileEnvPath) &&
		receiptMatchesInputs(receipt, inputs) &&
		receiptIsFresh(receipt) &&
		receipt.mobile?.contentHash === hashFile(context.mobileEnvPath)
	) {
		chmodSync(context.mobileEnvPath, 0o600);
		return false;
	}
	const finalRelative = context.profile.mobile.environmentFile;
	const temporaryRelative = `.env.${process.pid}-${randomBytes(6).toString("hex")}.local`;
	const temporaryPath = path.join(context.mobileRoot, temporaryRelative);
	for (const candidate of [finalRelative, temporaryRelative]) {
		const ignored = spawnSync("git", ["check-ignore", "--quiet", "--", path.join(context.profile.mobile.root, candidate)], {
			cwd: context.root,
		});
		if (ignored.status !== 0) {
			throw new Error(`Refusing to write ${candidate}; it is not gitignored.`);
		}
	}
	writeFileSync(temporaryPath, "", { mode: 0o600 });
	try {
		run(
			"corepack",
			[
				`pnpm@${inputs.pnpmVersion}`,
				"dlx",
				`eas-cli@${inputs.easVersion}`,
				"env:pull",
				"--environment",
				context.easEnvironment,
				"--path",
				temporaryRelative,
				"--non-interactive",
			],
			context.mobileRoot,
			{ quiet: options.quiet },
		);
		chmodSync(temporaryPath, 0o600);
		assertNames(
			`EAS ${context.easEnvironment} environment`,
			envNames(temporaryPath),
			context.profile.mobile.requiredEnvironmentNames,
		);
		renameSync(temporaryPath, context.mobileEnvPath);
		chmodSync(context.mobileEnvPath, 0o600);
	} catch (error) {
		rmSync(temporaryPath, { force: true });
		throw error;
	}
	return true;
}

function createReceipt(context, inputs, dopplerNames) {
	const mobileNames = envNames(context.mobileEnvPath);
	assertNames(
		`EAS ${context.easEnvironment} environment`,
		mobileNames,
		context.profile.mobile.requiredEnvironmentNames,
	);
	const configText = readFileSync(context.backendConfigPath, "utf8");
	const configReferences = validateBootstrapDopplerNames(
		configText,
		dopplerNames,
		context.profile.backend.requiredDopplerNames,
		`Doppler ${context.profile.backend.dopplerProject}/${context.dopplerConfig}`,
	);
	return {
		completedAt: new Date().toISOString(),
		doppler: {
			config: context.dopplerConfig,
			localConfigReferenceCount: configReferences.all.length,
			localConfigReferencesHash: hashText(configReferences.all.join("\n")),
			namesCount: dopplerNames.length,
			namesHash: hashText(dopplerNames.join("\n")),
			project: context.profile.backend.dopplerProject,
		},
		git: {
			branch: gitValue(context, ["branch", "--show-current"]) || "detached",
			commit: gitValue(context, ["rev-parse", "HEAD"]),
			commonDirectory: gitValue(context, ["rev-parse", "--git-common-dir"]),
		},
		inputs,
		lfs: lfsStatus(context),
		mobile: {
			contentHash: hashFile(context.mobileEnvPath),
			environment: context.easEnvironment,
			namesCount: mobileNames.length,
			namesHash: hashText(mobileNames.join("\n")),
			path: path.relative(context.root, context.mobileEnvPath),
		},
		runtime: {
			node: process.version,
			platform: `${process.platform}-${process.arch}`,
			pnpm: run("corepack", [`pnpm@${inputs.pnpmVersion}`, "--version"], context.root, {
				capture: true,
			}),
		},
		version: receiptVersion,
		worktree: context.root,
	};
}

export async function bootstrap(options = parseBootstrapOptions([])) {
	const context = contextFor(options);
	assertSupportedProject(context.root);
	const lockPath = `${receiptPathFor({ projectRoot: context.root })}.lock`;
	return withFileLock(lockPath, commandTimeoutMs, () => bootstrapLocked(context, options));
}

function bootstrapLocked(context, options) {
	const inputs = readProjectInputs(context);
	const priorReceipt = readReceipt(context);
	if (options.check) {
		const status = localBootstrapStatus({
			...options,
			projectRoot: context.root,
		});
		if (!status.ok) {
			throw new Error(
				`Worktree bootstrap is incomplete: ${status.reasons.join("; ")}.`,
			);
		}
		return { changed: false, receipt: status.receipt, receiptPath: status.receiptPath };
	}

	if (!options.quiet) console.log(`Bootstrapping ${context.root}`);
	const installed = installDependencies(context, options, priorReceipt, inputs);
	const materializedLfs = materializeGitLfs(context, options, priorReceipt, inputs);
	const pulledMobileEnvironment = pullMobileEnvironment(
		context,
		options,
		priorReceipt,
		inputs,
	);
	const dopplerNames = readDopplerNames(context);
	const receipt = createReceipt(context, inputs, dopplerNames);
	const receiptPath = receiptPathFor({ projectRoot: context.root });
	mkdirSync(path.dirname(receiptPath), { recursive: true, mode: 0o700 });
	const temporaryReceipt = `${receiptPath}.${process.pid}.tmp`;
	writeFileSync(temporaryReceipt, `${JSON.stringify(receipt, null, 2)}\n`, {
		mode: 0o600,
	});
	renameSync(temporaryReceipt, receiptPath);
	chmodSync(receiptPath, 0o600);
	if (!options.quiet) {
		console.log(
			`Mobile EAS ${context.easEnvironment} ready (${receipt.mobile.namesCount} names; values hidden).`,
		);
		console.log(
			`Doppler ${context.profile.backend.dopplerProject}/${context.dopplerConfig} ready (${receipt.doppler.namesCount} names; values hidden).`,
		);
		console.log(`Bootstrap receipt: ${receiptPath}`);
	}
	return {
		changed: installed || materializedLfs || pulledMobileEnvironment,
		receipt,
		receiptPath,
	};
}

async function main() {
	const options = parseBootstrapOptions(process.argv.slice(2));
	const result = await bootstrap(options);
	if (options.json) {
		process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
	} else if (options.check && !options.quiet) {
		console.log(`Worktree bootstrap is current: ${result.receiptPath}`);
	}
}

if (isMainModule(import.meta.url)) {
	try {
		await main();
	} catch (error) {
		console.error(`[bootstrap] ${error.message}`);
		process.exitCode = 1;
	}
}
