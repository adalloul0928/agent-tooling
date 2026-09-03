import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
	existsSync,
	lstatSync,
	mkdirSync,
	readFileSync,
	renameSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import path from "node:path";

const incompleteOwnerGraceMs = 10_000;

function processStartedAt(pid) {
	if (!Number.isInteger(pid) || pid <= 0) return null;
	try {
		process.kill(pid, 0);
	} catch (error) {
		if (error.code !== "EPERM") return null;
	}
	const result = spawnSync("ps", ["-p", String(pid), "-o", "lstart="], {
		encoding: "utf8",
	});
	return result.status === 0 ? result.stdout.trim() || null : null;
}

function lockOwner(lockPath) {
	try {
		const stat = lstatSync(lockPath);
		const filesystemIdentity = `${stat.dev}:${stat.ino}:${stat.birthtimeMs}:${stat.mtimeMs}`;
		if (!stat.isDirectory()) {
			const pid = Number(readFileSync(lockPath, "utf8").trim());
			const startedAt = processStartedAt(pid);
			return {
				alive: Boolean(startedAt),
				legacy: true,
				reclaimIdentity: `legacy:${filesystemIdentity}:${pid}`,
				stale: !startedAt,
			};
		}
		const ownerPath = path.join(lockPath, "owner.json");
		if (!existsSync(ownerPath)) {
			return {
				alive: false,
				reclaimIdentity: `incomplete:${filesystemIdentity}`,
				stale: Date.now() - stat.mtimeMs > incompleteOwnerGraceMs,
			};
		}
		const owner = JSON.parse(readFileSync(ownerPath, "utf8"));
		const currentStart = processStartedAt(owner.pid);
		return {
			...owner,
			alive: Boolean(currentStart && currentStart === owner.processStartedAt),
			reclaimIdentity: `owned:${filesystemIdentity}:${owner.token ?? "missing"}:${owner.pid ?? "missing"}:${owner.processStartedAt ?? "missing"}`,
			stale: !currentStart || currentStart !== owner.processStartedAt,
		};
	} catch (error) {
		if (error.code === "ENOENT") return null;
		return { alive: false, stale: false };
	}
}

function moveAside(lockPath, suffix) {
	const tombstone = `${lockPath}.${suffix}-${process.pid}-${randomBytes(6).toString("hex")}`;
	try {
		renameSync(lockPath, tombstone);
		return tombstone;
	} catch (error) {
		if (error.code === "ENOENT") return null;
		throw error;
	}
}

function removeStaleLock(lockPath) {
	const owner = lockOwner(lockPath);
	if (!owner?.stale) return false;
	const identity = createHash("sha256")
		.update(owner.reclaimIdentity ?? "unknown")
		.digest("hex")
		.slice(0, 24);
	const tombstone = `${lockPath}.stale-${identity}`;
	try {
		renameSync(lockPath, tombstone);
		// Keep this deterministic tombstone. A concurrent reclaimer that observed
		// the same stale owner must find it, so it cannot rename a newly acquired
		// live lock (the classic stale-lock ABA race).
		return true;
	} catch (error) {
		if (["ENOENT", "EEXIST", "ENOTEMPTY", "EISDIR", "ENOTDIR"].includes(error.code)) {
			return false;
		}
		throw error;
	}
}

function lockBackoff(attempt) {
	const ceiling = Math.min(250, 20 * 2 ** Math.min(attempt, 4));
	return Math.max(10, Math.floor(ceiling / 2 + Math.random() * (ceiling / 2)));
}

export async function withFileLock(lockPath, timeoutMs, callback) {
	mkdirSync(path.dirname(lockPath), { recursive: true, mode: 0o700 });
	const token = randomBytes(16).toString("hex");
	const startedAt = Date.now();
	let acquired = false;
	let attempt = 0;
	while (!acquired && Date.now() - startedAt < timeoutMs) {
		let createdThisAttempt = false;
		try {
			mkdirSync(lockPath, { mode: 0o700 });
			createdThisAttempt = true;
			const identity = processStartedAt(process.pid);
			if (!identity) throw new Error("Could not establish this lock owner's process identity.");
			writeFileSync(
				path.join(lockPath, "owner.json"),
				`${JSON.stringify(
					{
						acquiredAt: new Date().toISOString(),
						pid: process.pid,
						processStartedAt: identity,
						token,
					},
					null,
					2,
				)}\n`,
				{ mode: 0o600 },
			);
			acquired = true;
		} catch (error) {
			if (error.code !== "EEXIST") {
				if (createdThisAttempt) {
					rmSync(lockPath, { force: true, recursive: true });
				}
				throw error;
			}
			if (!removeStaleLock(lockPath)) {
				await new Promise((resolve) => setTimeout(resolve, lockBackoff(attempt)));
			}
			attempt += 1;
		}
	}
	if (!acquired) throw new Error(`Timed out acquiring ${lockPath}.`);
	try {
		return await callback();
	} finally {
		const owner = lockOwner(lockPath);
		if (owner?.token === token) {
			const tombstone = moveAside(lockPath, "released");
			if (tombstone) rmSync(tombstone, { force: true, recursive: true });
		}
	}
}
