import AgentToolingCore
import Foundation

/// Unverified clientInfo from initialize, used only as review-screen text.
/// Any local process can impersonate a client. Never use this value for
/// permissions, rate limits, queue bounds, redaction or any policy decision.
struct UntrustedClientIdentity: Hashable, Sendable {
    static let unknown = UntrustedClientIdentity(name: "Unidentified MCP client", version: nil)
    static let maximumNameCharacters = 96
    static let maximumVersionCharacters = 32

    /// Self-reported, unverified, display only.
    var name: String
    /// Self-reported, unverified, display only.
    var version: String?

    var displayLabel: String {
        guard let version, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }

    /// Reads `initialize.params.clientInfo`. Anything missing, oversized, or
    /// control-character bearing collapses to `unknown` rather than failing the
    /// handshake, because the value carries no authority either way.
    static func fromInitializeParams(_ params: JSONValue?) -> UntrustedClientIdentity {
        guard case .object(let fields)? = params,
            case .object(let clientInfo)? = fields["clientInfo"]
        else { return .unknown }
        guard case .string(let rawName)? = clientInfo["name"],
            let name = sanitized(rawName, maximum: maximumNameCharacters)
        else { return .unknown }
        var version: String?
        if case .string(let rawVersion)? = clientInfo["version"] {
            version = sanitized(rawVersion, maximum: maximumVersionCharacters)
        }
        return UntrustedClientIdentity(name: name, version: version)
    }

    private static func sanitized(_ value: String, maximum: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return ResponseRedaction.redactedText(String(trimmed.prefix(maximum)))
    }
}
