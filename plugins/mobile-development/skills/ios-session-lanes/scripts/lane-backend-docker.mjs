import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { backendContract } from "./lane-backend-contract.mjs";
import {
	backendRoot,
	now,
	profile,
	repoRoot,
	repositoryHash,
	runCaptured,
} from "./lane-runtime-context.mjs";
import { readRegistry } from "./lane-state.mjs";

const probeTimeoutMs = 30 * 1000;
const backendAttestationVersion = 1;
export const backendDockerNetwork = `pumpd-supabase-${repositoryHash}`;

function backendProjectId() {
	const match = readFileSync(path.join(backendRoot, "supabase/config.toml"), "utf8").match(
		/^project_id\s*=\s*"([^"]+)"/m,
	);
	if (!match) throw new Error("Supabase config has no root project_id.");
	return match[1];
}

export function listBackendProjectContainers() {
	const result = spawnSync(
		"docker",
		["ps", "-a", "--no-trunc", "--format", "{{.ID}}\t{{.Names}}\t{{.State}}"],
		{
			cwd: repoRoot,
			encoding: "utf8",
			maxBuffer: 10 * 1024 * 1024,
			timeout: probeTimeoutMs,
		},
	);
	if (result.status !== 0) {
		throw new Error(
			"Could not inspect Docker while determining whether local Supabase is stopped. Ownership was preserved.",
		);
	}
	const projectId = backendProjectId();
	const escapedProjectId = projectId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	const expectedName = new RegExp(`^supabase_.+_${escapedProjectId}$`);
	return result.stdout
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter(Boolean)
		.map((line) => {
			const [id, name, state] = line.split("\t");
			return { id, name, state };
		})
		.filter(({ name }) => expectedName.test(name));
}

export function detectRunningBackend(registeredBackend = readRegistry().backend) {
	const container = `supabase_edge_runtime_${backendProjectId()}`;
	const inspection = inspectEdgeRuntimeContainer(container);
	const mountWorktree = inspection
		? worktreeFromFunctionsMounts(inspection.mounts)
		: null;
	const containerAttestation = inspection
		? {
			containerCreatedAt: inspection.createdAt,
			containerId: inspection.id,
			dockerNetworks: inspection.networks,
			projectId: backendProjectId(),
			schemaVersion: backendAttestationVersion,
		}
		: null;
	return {
		compatibility: mountWorktree && existsSync(mountWorktree) ? backendContract(mountWorktree) : null,
		containerAttestation,
		createdAt: registeredBackend?.createdAt ?? now(),
		managed: Boolean(
			registeredBackend?.managed &&
			registeredBackend.mountWorktree &&
			mountWorktree &&
			path.resolve(registeredBackend.mountWorktree) === path.resolve(mountWorktree)
		),
		mountWorktree,
		ownerKey: registeredBackend?.ownerKey ?? null,
	};
}

function inspectEdgeRuntimeContainer(container) {
	const result = spawnSync(
		"docker",
		["inspect", "--format", "{{json .}}", container],
		{
			cwd: repoRoot,
			encoding: "utf8",
			maxBuffer: 10 * 1024 * 1024,
			timeout: probeTimeoutMs,
		},
	);
	if (result.status !== 0) return null;
	try {
		return parseBackendContainerInspection(result.stdout);
	} catch {
		return null;
	}
}

export function parseBackendContainerInspection(output) {
	const inspection = JSON.parse(output);
	if (
		!inspection ||
		typeof inspection !== "object" ||
		typeof inspection.Id !== "string" ||
		!inspection.Id ||
		typeof inspection.Created !== "string" ||
		!inspection.Created ||
		!Array.isArray(inspection.Mounts) ||
		!inspection.NetworkSettings ||
		typeof inspection.NetworkSettings.Networks !== "object" ||
		!inspection.NetworkSettings.Networks
	) {
		throw new Error("Docker returned an incomplete Supabase container inspection.");
	}
	return {
		createdAt: inspection.Created,
		id: inspection.Id,
		mounts: inspection.Mounts,
		networks: Object.keys(inspection.NetworkSettings.Networks).sort(),
	};
}

export function worktreeFromFunctionsMounts(mounts) {
	if (!Array.isArray(mounts)) return null;
	const suffix = `/${profile.backend.root}/supabase/functions`;
	for (const mount of mounts) {
		const destination = normalizeContainerPath(mount?.Destination);
		if (
			destination !== "/home/deno/functions" &&
			!destination.endsWith(suffix)
		) {
			continue;
		}
		const source = normalizeDockerHostPath(mount?.Source);
		if (!source.endsWith(suffix)) continue;
		const worktree = source.slice(0, -suffix.length);
		if (path.isAbsolute(worktree) && worktree !== path.parse(worktree).root) {
			return worktree;
		}
	}
	return null;
}

function normalizeContainerPath(value) {
	return String(value ?? "").replace(/\\/g, "/").replace(/\/+$/, "");
}

function normalizeDockerHostPath(value) {
	let normalized = normalizeContainerPath(value);
	for (const prefix of ["/host_mnt", "/run/desktop/mnt/host"]) {
		if (normalized === prefix || normalized.startsWith(`${prefix}/`)) {
			normalized = normalized.slice(prefix.length) || "/";
			break;
		}
	}
	return normalized;
}

export function backendContainerAttestationsMatch(left, right) {
	if (!left || !right) return false;
	return (
		left.schemaVersion === backendAttestationVersion &&
		right.schemaVersion === backendAttestationVersion &&
		left.projectId === right.projectId &&
		left.containerId === right.containerId &&
		left.containerCreatedAt === right.containerCreatedAt &&
		JSON.stringify([...(left.dockerNetworks ?? [])].sort()) ===
			JSON.stringify([...(right.dockerNetworks ?? [])].sort())
	);
}

export function assertExpectedBackendNetwork(detected) {
	if (!detected.containerAttestation?.dockerNetworks?.includes(backendDockerNetwork)) {
		throw new Error(
			`The managed Supabase edge runtime is not attached to ${backendDockerNetwork}.`,
		);
	}
}

export function assertManagedBackendOwnership(registered, detected) {
	if (!registered?.managed || !detected.managed) {
		throw new Error("The running Supabase stack no longer matches its managed mount lease.");
	}
	assertExpectedBackendNetwork(detected);
	if (!registered.containerAttestation) {
		throw new Error(
			"The managed Supabase lease predates container attestation; adopt it explicitly before destructive operations.",
		);
	}
	if (!backendContainerAttestationsMatch(registered.containerAttestation, detected.containerAttestation)) {
		throw new Error(
			"The running Supabase containers were replaced after this managed lease was recorded; refusing destructive control.",
		);
	}
}

function isLoopbackAddress(value) {
	return value === "127.0.0.1" || value === "::1" || value === "[::1]";
}

export function assertLoopbackBindings(bindings) {
	if (!Array.isArray(bindings) || bindings.length === 0) {
		throw new Error("Could not prove any published Supabase container ports.");
	}
	const unsafe = bindings.filter((binding) => !isLoopbackAddress(binding.hostIp));
	if (unsafe.length > 0) {
		throw new Error(
			`Refusing shared Supabase with non-loopback Docker bindings: ${unsafe
				.map((binding) => `${binding.container}:${binding.containerPort}->${binding.hostIp || "all"}:${binding.hostPort}`)
				.join(", ")}.`,
		);
	}
	return bindings;
}

export function verifyBackendLoopbackBindings() {
	const projectId = backendProjectId();
	const rows = runCaptured("docker", ["ps", "--format", "{{.ID}}\t{{.Names}}"])
		.stdout
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter(Boolean)
		.map((line) => {
			const [id, ...nameParts] = line.split(/\s+/);
			return { id, name: nameParts.join(" ") };
		})
		.filter(({ name }) => name.startsWith("supabase_") && name.endsWith(`_${projectId}`));
	if (rows.length === 0) throw new Error(`Could not find running Supabase containers for ${projectId}.`);
	const bindings = [];
	for (const container of rows) {
		const ports = JSON.parse(
			runCaptured("docker", ["inspect", "--format", "{{json .NetworkSettings.Ports}}", container.id])
				.stdout,
		);
		for (const [containerPort, published] of Object.entries(ports ?? {})) {
			for (const binding of published ?? []) {
				bindings.push({
					container: container.name,
					containerPort,
					hostIp: binding.HostIp ?? "",
					hostPort: binding.HostPort ?? "",
				});
			}
		}
	}
	return assertLoopbackBindings(bindings);
}

export function ensureBackendDockerNetwork() {
	const listing = runCaptured("docker", [
		"network",
		"ls",
		"--format",
		"{{.Name}}",
	]);
	const exists = listing.stdout
		.split(/\r?\n/)
		.some((name) => name.trim() === backendDockerNetwork);
	if (!exists) {
		runCaptured("docker", [
			"network",
			"create",
			"--driver",
			"bridge",
			"--opt",
			"com.docker.network.bridge.host_binding_ipv4=127.0.0.1",
			backendDockerNetwork,
		]);
	}
	const inspected = JSON.parse(
		runCaptured("docker", [
			"network",
			"inspect",
			"--format",
			"{{json .}}",
			backendDockerNetwork,
		]).stdout,
	);
	assertBackendDockerNetworkConfiguration(inspected);
}

export function assertBackendDockerNetworkConfiguration(network) {
	const binding = network?.Options?.["com.docker.network.bridge.host_binding_ipv4"];
	if (network?.Driver !== "bridge" || binding !== "127.0.0.1") {
		throw new Error(
			`Refusing Docker network ${backendDockerNetwork}: expected bridge with loopback-only default host binding.`,
		);
	}
	return network;
}
