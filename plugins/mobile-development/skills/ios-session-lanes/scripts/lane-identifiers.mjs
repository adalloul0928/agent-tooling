import { createHash } from "node:crypto";

export function requireIdentifier(value, label) {
	if (!value || !/^[A-Za-z0-9._:-]+$/.test(value)) {
		throw new Error(`A safe ${label} is required.`);
	}
	return value;
}

export function sessionKey(client, sessionId) {
	return `${requireIdentifier(client, "client")}:${requireIdentifier(
		sessionId,
		"session id",
	)}`;
}

export function safeKey(key) {
	const original = String(key);
	const readable =
		original
			.replace(/[^A-Za-z0-9._-]+/g, "-")
			.replace(/^-+|-+$/g, "")
			.slice(0, 48) || "key";
	const digest = createHash("sha256").update(original).digest("hex").slice(0, 16);
	return `${readable}-${digest}`;
}
