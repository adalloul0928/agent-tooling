import { localBootstrapStatus } from "./bootstrap-worktree.mjs";
import { requireIdentifier } from "./lane-identifiers.mjs";
import { profile, repoRoot } from "./lane-runtime-context.mjs";

const laneSelection = profile.laneSelection;
const physicalDeviceAliases = profile.physicalDevices;
const managedControllers = new Set(["agent-device", "argent", "maestro", "xcodebuildmcp"]);

export function parseTarget(value) {
	if (value === "simulator") return { alias: "automatic", kind: "simulator" };
	const match = String(value ?? "").match(/^physical:([A-Za-z0-9._-]+)$/);
	if (!match || !physicalDeviceAliases[match[1]]) {
		throw new Error(
			`--target must be "simulator" or one of: ${Object.keys(physicalDeviceAliases)
				.map((alias) => `physical:${alias}`)
				.join(", ")}.`,
		);
	}
	return { alias: match[1], kind: "physical" };
}

export function normalizeBackendChoice(value) {
	return value === "remote" ? "preview" : value;
}

export function lanePreset(name) {
	const preset = laneSelection.presets[name];
	if (!preset) {
		throw new Error(`Unknown lane preset ${name}. Choose one of: ${Object.keys(laneSelection.presets).join(", ")}.`);
	}
	return structuredClone(preset);
}

function requireValue(args, index, option) {
	const value = args[index];
	if (!value || value.startsWith("--")) throw new Error(`${option} requires a value.`);
	return value;
}

function requestedPreset(args) {
	const separator = args.indexOf("--");
	const searchable = separator >= 0 ? args.slice(0, separator) : args;
	const index = searchable.indexOf("--preset");
	if (index < 0) return { explicit: false, name: laneSelection.defaultPreset };
	return { explicit: true, name: requireValue(searchable, index + 1, "--preset") };
}

export function parseOptions(args) {
	const selectedPreset = requestedPreset(args);
	const preset = lanePreset(selectedPreset.name);
	const options = {
		acknowledgePhysicalBuild: false,
		acknowledgeSharedReset: false,
		acknowledgeStaleOwner: false,
		backend: preset.backend,
		backendExplicit: false,
		build: preset.build,
		client: process.env.IOS_SESSION_LANES_CLIENT ?? "",
		controller: preset.controller,
		controllerArgs: [],
		controllerExplicit: false,
		deadOnly: true,
		dopplerConfig:
			process.env.IOS_SESSION_LANES_DOPPLER_CONFIG ?? profile.backend.dopplerConfig,
		expose: preset.expose,
		exposeExplicit: false,
		forceController: false,
		json: false,
		preset: selectedPreset.name,
		presetExplicit: selectedPreset.explicit,
		quiet: false,
		recordedSelection: false,
		sessionId: process.env.IOS_SESSION_LANES_SESSION_ID ?? "",
		staleAfterMinutes: 120,
		target: preset.target,
		targetExplicit: false,
		udid: "",
	};
	const positionals = [];
	for (let index = 0; index < args.length; index += 1) {
		const arg = args[index];
		if (arg === "--") {
			options.controllerArgs = args.slice(index + 1);
			break;
		}
		if (arg === "--build") options.build = true;
		else if (arg === "--json") options.json = true;
		else if (arg === "--quiet") options.quiet = true;
		else if (arg === "--force-controller") options.forceController = true;
		else if (arg === "--dead-only") options.deadOnly = true;
		else if (arg === "--acknowledge-physical-build") options.acknowledgePhysicalBuild = true;
		else if (arg === "--acknowledge-shared-reset") options.acknowledgeSharedReset = true;
		else if (arg === "--acknowledge-stale-owner") options.acknowledgeStaleOwner = true;
		else if (arg === "--preset") index += 1;
		else if (arg === "--client") options.client = requireValue(args, ++index, arg);
		else if (arg === "--session-id") options.sessionId = requireValue(args, ++index, arg);
		else if (arg === "--backend") {
			options.backend = requireValue(args, ++index, arg);
			options.backendExplicit = true;
		} else if (arg === "--doppler-config") options.dopplerConfig = requireValue(args, ++index, arg);
		else if (arg === "--target") {
			options.target = requireValue(args, ++index, arg);
			options.targetExplicit = true;
		} else if (arg === "--udid") options.udid = requireValue(args, ++index, arg);
		else if (arg === "--controller") {
			options.controller = requireValue(args, ++index, arg);
			options.controllerExplicit = true;
		} else if (arg === "--expose") {
			options.expose = requireValue(args, ++index, arg);
			options.exposeExplicit = true;
		} else if (arg === "--stale-after-minutes") {
			options.staleAfterMinutes = Number(requireValue(args, ++index, arg));
		} else if (arg.startsWith("--")) throw new Error(`Unknown option ${arg}`);
		else positionals.push(arg);
	}
	options.backend = normalizeBackendChoice(options.backend);
	if (
		options.presetExplicit &&
		(options.targetExplicit || options.backendExplicit || options.exposeExplicit)
	) {
		throw new Error(
			"Do not combine --preset with --target, --backend, or --expose. Choose a preset or provide all three custom choices.",
		);
	}
	if (
		!options.presetExplicit &&
		options.targetExplicit &&
		options.backendExplicit &&
		options.exposeExplicit
	) {
		options.preset = "custom";
	}
	return { command: positionals[0] ?? "help", options };
}

export function assertSession(options) {
	requireIdentifier(options.client, "client");
	requireIdentifier(options.sessionId, "session id");
}

export function assertBootstrap() {
	const status = localBootstrapStatus({ projectRoot: repoRoot });
	if (!status.ok) {
		throw new Error(
			`This worktree was not bootstrapped at creation time: ${status.reasons.join("; ")}. Run ios-session-bootstrap separately.`,
		);
	}
}

export function prepareTargetDefaults(options, target) {
	if (target.kind !== "physical") return;
	if (options.backendExplicit && options.backend !== "preview") {
		throw new Error("Physical lanes must use --backend preview; local Supabase is never exposed.");
	}
	if (options.exposeExplicit && options.expose !== "tailscale") {
		throw new Error("Physical lanes must use --expose tailscale.");
	}
	options.backend = "preview";
	options.expose = "tailscale";
}

export function assertBackendChoice(backend) {
	if (backend !== "local" && backend !== "preview") {
		throw new Error('--backend must be either "local" or "preview".');
	}
}

export function laneSelectionIsConfirmed(options) {
	return Boolean(
		options.presetExplicit ||
		options.recordedSelection ||
		(options.targetExplicit && options.backendExplicit && options.exposeExplicit)
	);
}

export function applyRecordedLaneSelection(options, lane) {
	if (laneSelectionIsConfirmed(options) || !lane) return false;
	const requestedTarget = lane.requestedTarget ?? lane.target;
	options.target = requestedTarget.kind === "physical" ? `physical:${requestedTarget.alias}` : "simulator";
	options.backend = normalizeBackendChoice(lane.backend);
	options.expose = lane.exposure;
	options.preset = lane.preset ?? "legacy";
	options.recordedSelection = true;
	return true;
}

export function assertLaneSelection(options) {
	if (laneSelectionIsConfirmed(options)) return;
	throw new Error(
		"Lane choices were not confirmed. Ask the user to choose a lane preset, then pass " +
			`--preset <name>. Recommended: ${laneSelection.defaultPreset}.`,
	);
}

export function assertExposureChoice(expose) {
	if (expose !== "local" && expose !== "tailscale") {
		throw new Error('--expose must be either "local" or "tailscale".');
	}
}

export function assertControllerChoice(controller) {
	if (!managedControllers.has(controller)) throw new Error(`Unknown controller ${controller}.`);
}

export function assertDarwin() {
	if (process.platform !== "darwin") {
		throw new Error(`${profile.displayName} iOS lanes require macOS with Xcode installed.`);
	}
}
