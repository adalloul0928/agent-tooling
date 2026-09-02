import AgentToolingCore
import Foundation

/// The last thing a response passes through before it leaves the process.
///
/// Responses are already built by hand from an allowlist of fields, so nothing
/// here should ever fire. It fires anyway, on every string leaf of every
/// result, because a transcript is forwarded to a model provider and often
/// pasted into an issue: one stray `configurationPaths` entry is a home
/// directory, a username, and a project layout leaked at once. Construction is
/// the control; this is the assertion that the control held.
enum ResponseRedaction {
    static let withheldPathPlaceholder = "[path withheld]"
    static let withheldSecretPlaceholder = "[secret withheld]"
    static let maximumStringCharacters = 4_096

    /// Rewrites every string leaf of a result. Object keys are left alone: they
    /// come from this target's own literals, never from workspace content.
    static func redacted(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields): .object(fields.mapValues(redacted))
        case .array(let values): .array(values.map(redacted))
        case .string(let text): .string(redactedText(text))
        case .number, .bool, .null: value
        }
    }

    static func redactedText(_ value: String) -> String {
        var result = String(value.prefix(maximumStringCharacters))
        result = result.unicodeScalars.reduce(into: "") { partial, scalar in
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" {
                partial.append(" ")
            } else {
                partial.unicodeScalars.append(scalar)
            }
        }
        if containsSecretMarker(result) { return withheldSecretPlaceholder }
        guard containsFileSystemPath(result) else { return result }
        var withheldPreviousToken = false
        let tokens = result.split(separator: " ", omittingEmptySubsequences: false).map { rawToken -> String in
            let token = String(rawToken)
            // A path containing a space arrives as several tokens, so once one
            // token is withheld every following token that still looks like a
            // path fragment is withheld with it.
            let isContinuation = withheldPreviousToken && token.contains("/")
            guard containsFileSystemPath(token) || isContinuation else {
                withheldPreviousToken = false
                return token
            }
            withheldPreviousToken = true
            return withheldPathPlaceholder
        }
        return tokens.joined(separator: " ")
    }

    /// True when the value names a location on this machine's file system.
    /// Both the literal home directory and any absolute or tilde path count,
    /// so a value survives only when it is genuinely location-free.
    static func containsFileSystemPath(_ value: String) -> Bool {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if homePath.count > 1, value.contains(homePath) { return true }
        if value.contains("~/") { return true }
        if value.hasPrefix("/") || value.contains(" /") { return true }
        for prefix in ["/Users/", "/home/", "/private/", "/var/", "/tmp/", "/opt/", "/Volumes/"] where value.contains(prefix) {
            return true
        }
        return false
    }

    /// Recognizes the shapes a credential takes in a configuration file. This
    /// is a backstop for values that should never have been selected for a
    /// response, not a filter that makes it safe to select them.
    static func containsSecretMarker(_ value: String) -> Bool {
        let lowered = value.lowercased()
        for marker in ["authorization:", "bearer ", "api_key=", "apikey=", "access_token=", "client_secret=", "password="]
        where lowered.contains(marker) {
            return true
        }
        for prefix in ["sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-", "aki_", "akia"] where lowered.contains(prefix) {
            return true
        }
        if let components = URLComponents(string: value), components.user != nil || components.password != nil { return true }
        return false
    }

    /// Collapses a source, bundle, or endpoint down to something safe to name
    /// in a transcript: the host of an HTTP endpoint, the base name of an
    /// executable, or nothing at all.
    static func locationFreeSummary(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host,
            !host.isEmpty
        {
            return redactedText("\(scheme)://\(host)")
        }
        guard !containsFileSystemPath(trimmed), !containsSecretMarker(trimmed) else { return nil }
        return redactedText(trimmed)
    }

    /// The executable name of a stdio command, with its directory and every
    /// argument dropped. `/Users/someone/.local/bin/weather-mcp --key abc`
    /// becomes `weather-mcp`.
    static func executableName(from command: String) -> String? {
        guard let arguments = try? MCPDefinitionValidator.parseCommandLine(command),
            let executable = arguments.first,
            !executable.isEmpty
        else { return nil }
        let name = String(executable.split(separator: "/").last ?? "")
        guard !name.isEmpty, !containsFileSystemPath(name), !containsSecretMarker(name) else { return nil }
        return redactedText(name)
    }
}
