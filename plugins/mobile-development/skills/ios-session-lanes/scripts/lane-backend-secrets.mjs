export function parseLocalDopplerReferences(configText) {
	let section = "";
	const all = new Set();
	const edgeRuntime = new Set();
	for (const originalLine of String(configText).split(/\r?\n/)) {
		const line = stripTomlComment(originalLine).trim();
		if (!line) continue;
		const header = line.match(/^\[([^\]]+)]$/);
		if (header) {
			section = header[1].trim();
			continue;
		}
		if (section === "remotes" || section.startsWith("remotes.")) continue;
		for (const match of line.matchAll(/env\(([A-Za-z_][A-Za-z0-9_]*)\)/g)) {
			all.add(match[1]);
			if (section === "edge_runtime.secrets") edgeRuntime.add(match[1]);
		}
	}
	return {
		all: [...all].sort(),
		edgeRuntime: [...edgeRuntime].sort(),
	};
}

export function assertLocalDopplerReferencesAvailable(
	configText,
	availableNames,
	{ source = "Doppler" } = {},
) {
	const references = parseLocalDopplerReferences(configText);
	const available = new Set(availableNames);
	const missing = references.all.filter((name) => !available.has(name));
	if (missing.length > 0) {
		throw new Error(
			`${source} is missing local Supabase config names: ${missing.join(", ")}.`,
		);
	}
	if (references.edgeRuntime.length === 0) {
		throw new Error(
			"Local [edge_runtime.secrets] does not declare any Doppler references.",
		);
	}
	return references;
}

function stripTomlComment(line) {
	let quote = "";
	let escaped = false;
	for (let index = 0; index < line.length; index += 1) {
		const character = line[index];
		if (quote === '"' && escaped) {
			escaped = false;
			continue;
		}
		if (quote === '"' && character === "\\") {
			escaped = true;
			continue;
		}
		if (quote) {
			if (character === quote) quote = "";
			continue;
		}
		if (character === '"' || character === "'") quote = character;
		else if (character === "#") return line.slice(0, index);
	}
	return line;
}
