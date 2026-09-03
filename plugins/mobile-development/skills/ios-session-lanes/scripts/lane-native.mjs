import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
	cpSync,
	existsSync,
	lstatSync,
	mkdirSync,
	readFileSync,
	readdirSync,
	renameSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import path from "node:path";
import { safeKey } from "./lane-identifiers.mjs";
import { withFileLock } from "./lane-lock.mjs";
import {
	binaryRoot,
	deviceStateRoot,
	hashText,
	laneHome,
	now,
	profile,
	repoRoot,
	runCaptured,
	runInherited,
	simulatorControlLockPath,
} from "./lane-runtime-context.mjs";

const appId = profile.mobile.appId;
const cachedAppName = profile.mobile.cachedAppName;
const buildLockTimeoutMs = 30 * 60 * 1000;
const appBundleDigestVersion = 2;
const binaryCacheManifestVersion = 2;
const deviceMarkerVersion = 2;

export function nativeCacheKey(fingerprint, xcodeVersion, architecture) {
	return hashText(`${fingerprint}\0${xcodeVersion}\0${architecture}`);
}

export async function ensureNativeBinary(lane, environment, options) {
	const identity = currentNativeIdentity();
	if (lane.target.kind === "physical") {
		return ensurePhysicalBinary(lane, environment, options, identity);
	}
	return ensureSimulatorBinary(lane, environment, options, identity);
}

export function currentNativeIdentity() {
	const result = runCaptured(
		"corepack",
		[
			"pnpm",
			"--dir",
			profile.mobile.root,
			"exec",
			"fingerprint",
			"fingerprint:generate",
			"--platform",
			"ios",
		],
		repoRoot,
		{ env: { ...process.env, APP_VARIANT: "development" } },
	);
	let fingerprint;
	try {
		fingerprint = JSON.parse(result.stdout).hash;
	} catch {
		throw new Error("Expo native fingerprint output was invalid.");
	}
	if (!fingerprint) throw new Error("Expo native fingerprint did not include a hash.");
	const xcodeVersion = runCaptured("xcodebuild", ["-version"]).stdout.trim();
	return {
		cacheKey: nativeCacheKey(fingerprint, xcodeVersion, process.arch),
		fingerprint,
		xcodeVersion,
	};
}

async function ensureSimulatorBinary(lane, environment, options, identity) {
	const marker = readDeviceMarker(lane.target.udid);
	if (
		!options.build &&
		marker?.cacheKey === identity.cacheKey &&
		simulatorInstallMatchesMarker(lane.target.udid, marker)
	) {
		return { ...identity, decision: "reuse-installed", verifiedAt: now() };
	}
	const cache = readBinaryCache(identity.cacheKey);
	if (!options.build && cache) {
		const bundleIdentity = await installCachedSimulatorApp(
			lane.target.udid,
			cache.appPath,
			cache.bundleIdentity,
		);
		writeDeviceMarker(lane.target.udid, identity, bundleIdentity);
		return { ...identity, cachePath: cache.appPath, decision: "reuse-cache", verifiedAt: now() };
	}
	return withNativeBuildLock(identity.cacheKey, async () => {
		const refreshedCache = !options.build && readBinaryCache(identity.cacheKey);
		if (refreshedCache) {
			const bundleIdentity = await installCachedSimulatorApp(
				lane.target.udid,
				refreshedCache.appPath,
				refreshedCache.bundleIdentity,
			);
			writeDeviceMarker(lane.target.udid, identity, bundleIdentity);
			return {
				...identity,
				cachePath: refreshedCache.appPath,
				decision: "reuse-cache-after-wait",
				verifiedAt: now(),
			};
		}
		const genericApp = buildGenericSimulatorApp(environment, identity.cacheKey);
		let cachedPath;
		try {
			cachedPath = cacheSimulatorApp(genericApp.appPath, identity);
		} finally {
			rmSync(genericApp.stagingRoot, { force: true, recursive: true });
		}
		const cached = readBinaryCache(identity.cacheKey);
		if (!cached) throw new Error("The newly cached simulator app failed integrity validation.");
		const bundleIdentity = await installCachedSimulatorApp(
			lane.target.udid,
			cachedPath,
			cached.bundleIdentity,
		);
		writeDeviceMarker(lane.target.udid, identity, bundleIdentity);
		return {
			...identity,
			cachePath: cachedPath,
			decision: options.build ? "force-local-build" : "local-build-native-miss",
			verifiedAt: now(),
		};
	});
}

async function ensurePhysicalBinary(lane, environment, options, identity) {
	const markerKey = `physical-${lane.target.alias}`;
	const marker = readDeviceMarker(markerKey);
	const installedApp = installedPhysicalAppIdentity(lane.target.deviceId);
	if (
		!options.build &&
		marker?.cacheKey === identity.cacheKey &&
		samePhysicalAppIdentity(marker?.physicalApp, installedApp)
	) {
		return { ...identity, decision: "reuse-physical-install", verifiedAt: now() };
	}
	if (!options.acknowledgePhysicalBuild) {
		const error = new Error(
			"The reachable iPhone needs a new local native development binary. Re-run with --acknowledge-physical-build while the device is attached, or use the simulator fallback. No EAS build was requested.",
		);
		error.code = "PHYSICAL_NATIVE_BUILD_REQUIRED";
		throw error;
	}
	return withNativeBuildLock(`physical-${identity.cacheKey}`, async () => {
		const refreshedMarker = readDeviceMarker(markerKey);
		const refreshedInstalledApp = installedPhysicalAppIdentity(lane.target.deviceId);
		if (
			!options.build &&
			refreshedMarker?.cacheKey === identity.cacheKey &&
			samePhysicalAppIdentity(refreshedMarker?.physicalApp, refreshedInstalledApp)
		) {
			return { ...identity, decision: "reuse-physical-install-after-wait", verifiedAt: now() };
		}
		buildPhysicalIosApp(lane, environment);
		const installedAfterBuild = installedPhysicalAppIdentity(lane.target.deviceId);
		if (!installedAfterBuild) {
			throw new Error(
				`The local physical-device build returned successfully, but ${appId} could not be verified on ${lane.target.name}.`,
			);
		}
		writeDeviceMarker(markerKey, identity, null, { physicalApp: installedAfterBuild });
		return {
			...identity,
			decision: options.build ? "force-local-physical-build" : "local-physical-build-native-miss",
			verifiedAt: now(),
		};
	});
}

export function parsePhysicalAppIdentity(payload, expectedBundleId = appId) {
	const apps = payload?.result?.apps;
	if (!Array.isArray(apps)) return null;
	const matching = apps.filter((app) => app?.bundleIdentifier === expectedBundleId);
	if (matching.length !== 1) return null;
	const app = matching[0];
	if (typeof app.url !== "string" || !app.url.trim()) return null;
	return {
		bundleIdentifier: expectedBundleId,
		bundleVersion: String(app.bundleVersion ?? ""),
		url: app.url,
		version: String(app.version ?? ""),
	};
}

export function samePhysicalAppIdentity(expected, actual) {
	return Boolean(
		expected?.bundleIdentifier &&
		expected.bundleIdentifier === actual?.bundleIdentifier &&
		expected.bundleVersion === actual?.bundleVersion &&
		expected.deviceId === actual?.deviceId &&
		expected.version === actual?.version &&
		expected.url === actual?.url,
	);
}

export function installedPhysicalAppIdentity(deviceId) {
	const outputPath = path.join(
		laneHome,
		`device-apps-${process.pid}-${randomBytes(6).toString("hex")}.json`,
	);
	try {
		const result = spawnSync(
			"xcrun",
			[
				"devicectl",
				"device",
				"info",
				"apps",
				"--device",
				deviceId,
				"--bundle-id",
				appId,
				"--timeout",
				"10",
				"--json-output",
				outputPath,
			],
			{ cwd: repoRoot, encoding: "utf8", timeout: 20_000 },
		);
		if (result.status !== 0 || !existsSync(outputPath)) return null;
		try {
			const identity = parsePhysicalAppIdentity(JSON.parse(readFileSync(outputPath, "utf8")));
			return identity ? { ...identity, deviceId } : null;
		} catch {
			return null;
		}
	} finally {
		rmSync(outputPath, { force: true });
	}
}

async function withNativeBuildLock(cacheKey, callback) {
	const globalLock = path.join(laneHome, "native-build-global.lock");
	const cacheLock = path.join(laneHome, `native-build-${cacheKey}.lock`);
	return withFileLock(globalLock, buildLockTimeoutMs, () =>
		withFileLock(cacheLock, buildLockTimeoutMs, callback),
	);
}

function buildGenericSimulatorApp(environment, cacheKey) {
	const stagingRoot = path.join(
		laneHome,
		"build-staging",
		`${safeKey(cacheKey)}-${process.pid}-${randomBytes(6).toString("hex")}`,
	);
	mkdirSync(stagingRoot, { recursive: true, mode: 0o700 });
	try {
		runInherited(
			"corepack",
			[
				"pnpm",
				"--dir",
				profile.mobile.root,
				"exec",
				"expo",
				"run:ios",
				"--device",
				"generic",
				"--output",
				stagingRoot,
				"--no-bundler",
			],
			repoRoot,
			environment,
		);
		const appPath = findAppBundle(stagingRoot);
		if (!appPath) throw new Error(`Generic Expo iOS build produced no .app under ${stagingRoot}.`);
		validateAppBundle(appPath);
		return { appPath, stagingRoot };
	} catch (error) {
		rmSync(stagingRoot, { force: true, recursive: true });
		throw error;
	}
}

function findAppBundle(directory) {
	for (const entry of readdirSync(directory, { withFileTypes: true })) {
		const absolute = path.join(directory, entry.name);
		if (entry.isDirectory() && entry.name.endsWith(".app")) return absolute;
		if (entry.isDirectory()) {
			const nested = findAppBundle(absolute);
			if (nested) return nested;
		}
	}
	return null;
}

function buildPhysicalIosApp(lane, environment) {
	runInherited(
		"corepack",
		[
			"pnpm",
			"--dir",
			profile.mobile.root,
			"exec",
			"expo",
			"run:ios",
			"--device",
			lane.target.deviceId,
			"--no-bundler",
		],
		repoRoot,
		environment,
	);
}

export function installedSimulatorAppPath(udid) {
	const result = spawnSync("xcrun", ["simctl", "get_app_container", udid, appId, "app"], {
		cwd: repoRoot,
		encoding: "utf8",
		timeout: 30_000,
	});
	return result.status === 0 ? result.stdout.trim() || null : null;
}

function readBinaryCache(cacheKey) {
	const directory = path.join(binaryRoot, cacheKey);
	const manifestPath = path.join(directory, "manifest.json");
	const appPath = path.join(directory, cachedAppName);
	if (!existsSync(manifestPath) || !existsSync(appPath)) return null;
	try {
		const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
		if (
			manifest.schemaVersion !== binaryCacheManifestVersion ||
			manifest.appId !== appId ||
			manifest.cacheKey !== cacheKey
		) {
			return null;
		}
		const bundleIdentity = validateAppBundle(appPath);
		if (!sameBundleIdentity(manifest.bundleIdentity, bundleIdentity)) return null;
		return { appPath, bundleIdentity, manifest };
	} catch {
		return null;
	}
}

function cacheSimulatorApp(sourcePath, identity) {
	validateAppBundle(sourcePath);
	const directory = path.join(binaryRoot, identity.cacheKey);
	const temporary = `${directory}.${process.pid}.tmp`;
	rmSync(temporary, { force: true, recursive: true });
	mkdirSync(temporary, { recursive: true, mode: 0o700 });
	const appPath = path.join(temporary, cachedAppName);
	cpSync(sourcePath, appPath, { recursive: true });
	const bundleIdentity = validateAppBundle(appPath);
	writeFileSync(
		path.join(temporary, "manifest.json"),
		`${JSON.stringify(
				{
					appId,
					architecture: process.arch,
					builtAt: now(),
					bundleIdentity,
					cacheKey: identity.cacheKey,
					fingerprint: identity.fingerprint,
					schemaVersion: binaryCacheManifestVersion,
					xcodeVersion: identity.xcodeVersion,
			},
			null,
			2,
		)}\n`,
		{ mode: 0o600 },
	);
	rmSync(directory, { force: true, recursive: true });
	renameSync(temporary, directory);
	return path.join(directory, cachedAppName);
}

export function appBundleContentDigest(appPath, executableName) {
	if (!executableName || path.basename(executableName) !== executableName) {
		throw new Error(`Invalid app executable name ${executableName || "(missing)"}.`);
	}
	return appBundleContentIdentity(appPath, executableName).digest;
}

export function appBundleContentIdentity(appPath, executableName) {
	if (!executableName || path.basename(executableName) !== executableName) {
		throw new Error(`Invalid app executable name ${executableName || "(missing)"}.`);
	}
	const rootStat = lstatSync(appPath);
	if (!rootStat.isDirectory()) {
		throw new Error(`App bundle root is not a regular directory: ${appPath}.`);
	}
	const files = collectAppBundleFiles(appPath);
	const fileNames = new Set(files.map((file) => file.relative));
	for (const required of ["Info.plist", executableName]) {
		if (!fileNames.has(required)) throw new Error(`App bundle is missing ${required}: ${appPath}.`);
	}
	const hash = createHash("sha256");
	hashLengthPrefixed(hash, Buffer.from(`pumpd-app-bundle-v${appBundleDigestVersion}`, "utf8"));
	hashLengthPrefixed(hash, Buffer.from(String(files.length), "utf8"));
	for (const file of files) {
		hashLengthPrefixed(hash, Buffer.from(file.relative, "utf8"));
		hashLengthPrefixed(hash, readFileSync(file.absolute));
	}
	return {
		digest: hash.digest("hex"),
		digestVersion: appBundleDigestVersion,
		fileCount: files.length,
	};
}

function collectAppBundleFiles(appPath) {
	const files = [];
	const visit = (directory, segments) => {
		const entries = readdirSync(directory, { withFileTypes: true }).sort((left, right) =>
			left.name < right.name ? -1 : left.name > right.name ? 1 : 0,
		);
		for (const entry of entries) {
			const absolute = path.join(directory, entry.name);
			const relativeSegments = [...segments, entry.name];
			const relative = relativeSegments.join("/");
			const stat = lstatSync(absolute);
			if (stat.isSymbolicLink()) {
				throw new Error(`App bundle contains a symbolic link, which is not cache-safe: ${relative}.`);
			}
			if (stat.isDirectory()) {
				visit(absolute, relativeSegments);
				continue;
			}
			if (!stat.isFile()) {
				throw new Error(`App bundle contains a non-regular file, which is not cache-safe: ${relative}.`);
			}
			files.push({ absolute, relative });
		}
	};
	visit(appPath, []);
	return files;
}

function hashLengthPrefixed(hash, value) {
	const length = Buffer.allocUnsafe(8);
	length.writeBigUInt64BE(BigInt(value.length));
	hash.update(length);
	hash.update(value);
}

export function appBundleIdentity(appPath) {
	const plistPath = path.join(appPath, "Info.plist");
	if (!existsSync(plistPath)) throw new Error(`Cached app has no Info.plist: ${appPath}.`);
	const bundleId = runCaptured("plutil", [
		"-extract",
		"CFBundleIdentifier",
		"raw",
		"-o",
		"-",
		plistPath,
	]).stdout.trim();
	if (bundleId !== appId) throw new Error(`Cached app bundle id ${bundleId} did not match ${appId}.`);
	const executableName = runCaptured("plutil", [
		"-extract",
		"CFBundleExecutable",
		"raw",
		"-o",
		"-",
		plistPath,
	]).stdout.trim();
	const contentIdentity = appBundleContentIdentity(appPath, executableName);
	return {
		bundleId,
		...contentIdentity,
		executableName,
	};
}

function validateAppBundle(appPath) {
	return appBundleIdentity(appPath);
}

function sameBundleIdentity(expected, actual) {
	return Boolean(
		expected?.bundleId &&
		expected.bundleId === actual?.bundleId &&
		expected.executableName === actual?.executableName &&
		expected.digestVersion === appBundleDigestVersion &&
		actual?.digestVersion === appBundleDigestVersion &&
		expected.fileCount === actual?.fileCount &&
		expected.digest === actual?.digest,
	);
}

async function installCachedSimulatorApp(udid, appPath, expectedIdentity) {
	const cachedIdentity = validateAppBundle(appPath);
	if (!sameBundleIdentity(expectedIdentity, cachedIdentity)) {
		throw new Error("The cached simulator app changed after its manifest was written.");
	}
	return withFileLock(simulatorControlLockPath, buildLockTimeoutMs, async () => {
		const result = spawnSync("xcrun", ["simctl", "install", udid, appPath], {
			cwd: repoRoot,
			encoding: "utf8",
			timeout: 60_000,
		});
		if (result.status !== 0) {
			const error = new Error(
				`xcrun simctl install ${udid} failed: ${(
					result.error?.message || result.stderr || result.stdout || `exit ${result.status}`
				).trim()}`,
			);
			if (result.error?.code === "ETIMEDOUT") error.code = "NATIVE_SIMULATOR_UNRESPONSIVE";
			throw error;
		}
		const installed = installedSimulatorBinaryIdentity(udid);
		if (!installed || !sameBundleIdentity(cachedIdentity, installed.bundleIdentity)) {
			throw new Error(`Simulator ${udid} installed an app whose binary identity did not match the cache.`);
		}
		return installed.bundleIdentity;
	});
}

function deviceMarkerPath(deviceKey) {
	return path.join(deviceStateRoot, `${safeKey(deviceKey)}.json`);
}

export function readDeviceMarker(deviceKey) {
	const markerPath = deviceMarkerPath(deviceKey);
	if (!existsSync(markerPath)) return null;
	try {
		const marker = JSON.parse(readFileSync(markerPath, "utf8"));
		return marker.schemaVersion === deviceMarkerVersion ? marker : null;
	} catch {
		return null;
	}
}

export function installedSimulatorBinaryIdentity(udid) {
	const appPath = installedSimulatorAppPath(udid);
	if (!appPath) return null;
	try {
		return { appPath, bundleIdentity: appBundleIdentity(appPath) };
	} catch {
		return null;
	}
}

export function simulatorInstallMatchesMarker(udid, marker = readDeviceMarker(udid)) {
	const installed = installedSimulatorBinaryIdentity(udid);
	return Boolean(installed && sameBundleIdentity(marker?.bundleIdentity, installed.bundleIdentity));
}

function writeDeviceMarker(deviceKey, identity, bundleIdentity = null, extra = {}) {
	writeFileSync(
		deviceMarkerPath(deviceKey),
		`${JSON.stringify(
			{
				...identity,
				...extra,
				bundleIdentity,
				installedAt: now(),
				schemaVersion: deviceMarkerVersion,
			},
			null,
			2,
		)}\n`,
		{ mode: 0o600 },
	);
}
