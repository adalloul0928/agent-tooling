#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
	chmodSync,
	existsSync,
	mkdirSync,
	readFileSync,
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

const receiptVersion = 2;
const commandTimeoutMs = 30 * 60 * 1000;

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

export function envNames(filePath) {
	return readFileSync(filePath, "utf8")
		.split(/\r?\n/)
		.map((line) => line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=/)?.[1])
		.filter(Boolean)
		.sort();
}

export function envReferences(filePath) {
	const matches = readFileSync(filePath, "utf8").matchAll(/env\(([A-Z0-9_]+)\)/g);
	return [...new Set([...matches].map((match) => match[1]))].sort();
}

function assertNames(source, names, required) {
	const available = new Set(names);
	const missing = required.filter((name) => !available.has(name));
	if (missing.length > 0) {
		throw new Error(`${source} is missing required names: ${missing.join(", ")}.`);
	}
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
	const easVersion = easConfig.cli?.version;
	if (!easVersion) throw new Error("The mobile eas.json must pin cli.version.");
	return {
		dopplerConfig: context.dopplerConfig,
		easEnvironment: context.easEnvironment,
		easVersion,
		lockfileHash: hashFile(path.join(context.root, "pnpm-lock.yaml")),
		packageManager: rootPackage.packageManager,
	};
}

function receiptMatchesInputs(receipt, inputs) {
	return (
		receipt?.version === receiptVersion &&
		receipt.inputs?.dopplerConfig === inputs.dopplerConfig &&
		receipt.inputs?.easEnvironment === inputs.easEnvironment &&
		receipt.inputs?.easVersion === inputs.easVersion &&
		receipt.inputs?.lockfileHash === inputs.lockfileHash &&
		receipt.inputs?.packageManager === inputs.packageManager
	);
}

export function localBootstrapStatus(options = {}) {
	const context = contextFor(options);
	const inputs = readProjectInputs(context);
	const receipt = readReceipt(context);
	const reasons = [];
	if (!receipt) reasons.push("receipt absent");
	else if (!receiptMatchesInputs(receipt, inputs)) reasons.push("receipt inputs stale");
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
		if (receipt?.mobile?.namesHash !== hashText(names.join("\n"))) {
			reasons.push("mobile environment differs from receipt");
		}
	}
	return {
		inputs,
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
	run("corepack", ["pnpm", "install", "--frozen-lockfile"], context.root, {
		environment: { ...process.env, HUSKY: "0" },
		quiet: options.quiet,
	});
	return true;
}

function pullMobileEnvironment(context, options, receipt, inputs) {
	if (
		!options.force &&
		existsSync(context.mobileEnvPath) &&
		receiptMatchesInputs(receipt, inputs)
	) {
		chmodSync(context.mobileEnvPath, 0o600);
		return false;
	}
	run(
		"corepack",
		[
			"pnpm",
			"dlx",
			`eas-cli@${inputs.easVersion}`,
			"env:pull",
			"--environment",
			context.easEnvironment,
			"--path",
			context.profile.mobile.environmentFile,
			"--non-interactive",
		],
		context.mobileRoot,
		{ quiet: options.quiet },
	);
	chmodSync(context.mobileEnvPath, 0o600);
	return true;
}

function createReceipt(context, inputs, dopplerNames) {
	const mobileNames = envNames(context.mobileEnvPath);
	assertNames(
		`EAS ${context.easEnvironment} environment`,
		mobileNames,
		context.profile.mobile.requiredEnvironmentNames,
	);
	assertNames(
		`Doppler ${context.profile.backend.dopplerProject}/${context.dopplerConfig}`,
		dopplerNames,
		context.profile.backend.requiredDopplerNames,
	);
	const configReferences = envReferences(context.backendConfigPath);
	const available = new Set(dopplerNames);
	const unavailableConfigReferences = configReferences.filter(
		(name) => !available.has(name),
	);
	return {
		completedAt: new Date().toISOString(),
		doppler: {
			availableConfigReferenceCount:
				configReferences.length - unavailableConfigReferences.length,
			config: context.dopplerConfig,
			missingOptionalConfigReferences: unavailableConfigReferences,
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
		mobile: {
			environment: context.easEnvironment,
			namesCount: mobileNames.length,
			namesHash: hashText(mobileNames.join("\n")),
			path: path.relative(context.root, context.mobileEnvPath),
		},
		runtime: {
			node: process.version,
			platform: `${process.platform}-${process.arch}`,
			pnpm: run("corepack", ["pnpm", "--version"], context.root, {
				capture: true,
			}),
		},
		version: receiptVersion,
		worktree: context.root,
	};
}

export function bootstrap(options = parseBootstrapOptions([])) {
	const context = contextFor(options);
	assertSupportedProject(context.root);
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
	writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, {
		mode: 0o600,
	});
	if (!options.quiet) {
		console.log(
			`Mobile EAS ${context.easEnvironment} ready (${receipt.mobile.namesCount} names; values hidden).`,
		);
		console.log(
			`Doppler ${context.profile.backend.dopplerProject}/${context.dopplerConfig} ready (${receipt.doppler.namesCount} names; values hidden).`,
		);
		if (receipt.doppler.missingOptionalConfigReferences.length > 0) {
			console.warn(
				`Optional config references absent from Doppler: ${receipt.doppler.missingOptionalConfigReferences.join(", ")}.`,
			);
		}
		console.log(`Bootstrap receipt: ${receiptPath}`);
	}
	return {
		changed: installed || pulledMobileEnvironment,
		receipt,
		receiptPath,
	};
}

function main() {
	const options = parseBootstrapOptions(process.argv.slice(2));
	const result = bootstrap(options);
	if (options.json) {
		process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
	} else if (options.check && !options.quiet) {
		console.log(`Worktree bootstrap is current: ${result.receiptPath}`);
	}
}

if (isMainModule(import.meta.url)) {
	try {
		main();
	} catch (error) {
		console.error(`[bootstrap] ${error.message}`);
		process.exitCode = 1;
	}
}
