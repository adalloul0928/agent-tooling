import Foundation

/// Where a connection entry came from, as far as the listing can tell.
///
/// This is not a guess about ownership; it is only what the printed line says
/// about itself. A `plugin:` prefix names the plugin that contributed the
/// server, a claude.ai indicator marks a hosted connector, and a scope word
/// from `mcp get` places a plain server in one of the three scopes a client
/// keeps. Anything the text does not say is `.unknown`, so a row never claims
/// a source the listing did not actually print.
public enum ConnectionHealthSource: Equatable, Sendable {
    case plugin(String)
    case claudeAI
    case user
    case project
    case unknown

    /// The plugin name, when this entry came from one. Nil otherwise, so a row
    /// can badge a plugin server without unpacking the enum each time.
    public var pluginName: String? {
        if case .plugin(let name) = self { return name }
        return nil
    }
}

/// The connection state a listing reported for one server, in the vocabulary
/// the two clients actually print.
///
/// `.unknown` carries the raw text it could not classify rather than dropping
/// it, so a state this app has not seen before is shown as-is instead of being
/// silently folded into "failed". `.failed` carries the detail printed after
/// the em dash, because that detail is what decides whether a re-authentication
/// is even the right offer.
public enum ConnectionHealthStatus: Equatable, Sendable {
    case connected
    case needsAuthentication
    case failed(detail: String)
    case pendingApproval
    case disabled
    case notConfigured
    case unknown(rawText: String)

    /// Whether this state is one a person should be nudged toward. Connected,
    /// disabled and not-configured are settled; the rest are things to look at.
    public var needsAttention: Bool {
        switch self {
        case .connected, .disabled, .notConfigured: false
        case .needsAuthentication, .failed, .pendingApproval, .unknown: true
        }
    }

    /// The health vocabulary the rest of the app already draws with, so a row
    /// on this screen reads the same as a client verdict anywhere else.
    public var healthState: HealthState {
        switch self {
        case .connected: .healthy
        case .needsAuthentication, .pendingApproval, .unknown: .attention
        case .failed: .unavailable
        case .disabled, .notConfigured: .pending
        }
    }

    /// A short plain-words label for the state, for a badge or a screen reader.
    public var label: String {
        switch self {
        case .connected: "Connected"
        case .needsAuthentication: "Needs authentication"
        case .failed: "Failed to connect"
        case .pendingApproval: "Pending approval"
        case .disabled: "Disabled for this project"
        case .notConfigured: "Not configured"
        case .unknown: "Status unknown"
        }
    }
}

/// One connection a client listed, parsed out of its own health output.
///
/// `name` is the identifier the client uses (`plugin:foo:bar` and all), and
/// `displayName` is the same thing with a `plugin:` prefix stripped so a person
/// reads the server's own name. `summary` is the command or URL exactly as the
/// client printed it, run through the credential redactor first, so a bearer
/// token pasted into a header never lands on screen. `rawLine` is kept for the
/// detail popover and for tests, so what was parsed can always be shown against
/// what was printed.
public struct ConnectionHealthEntry: Identifiable, Equatable, Sendable {
    public let client: ClientKind
    public let name: String
    public let displayName: String
    public let source: ConnectionHealthSource
    public let status: ConnectionHealthStatus
    public let summary: String
    public let rawLine: String

    /// Stable within one report: the client plus the server's own name. A
    /// listing does not repeat a server under one client, so this is enough to
    /// key a row without depending on the printed order.
    public var id: String { "\(client.rawValue)::\(name)" }

    public init(
        client: ClientKind,
        name: String,
        displayName: String,
        source: ConnectionHealthSource,
        status: ConnectionHealthStatus,
        summary: String,
        rawLine: String
    ) {
        self.client = client
        self.name = name
        self.displayName = displayName
        self.source = source
        self.status = status
        self.summary = summary
        self.rawLine = rawLine
    }

    /// The plugin badge text, when this entry came from a plugin.
    public var pluginName: String? { source.pluginName }

    /// Whether this entry is a claude.ai connector, so a row can badge it and
    /// the action classifier can route it to the connectors page.
    public var isClaudeAIConnector: Bool { source == .claudeAI }

    /// Whether the summary points at an HTTP or SSE endpoint. Re-authentication
    /// is only offered for a remote server; a local stdio command signs in
    /// through the client's own session, not a per-server OAuth flow.
    public var isRemoteEndpoint: Bool {
        let lowered = summary.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }
}

/// What a person can do about one connection entry.
///
/// The classifier is a pure function of the entry, so the same reasoning that
/// decides which button a row shows is the reasoning a test pins down. Nothing
/// here runs anything; it only names the offer.
public enum ConnectionHealthAction: Equatable, Sendable {
    /// Sign in again through the client's own OAuth flow. Carries the client
    /// and the server name so the caller can build exactly `<cli> mcp login
    /// <name>` without re-deriving either.
    case reauthenticate(client: ClientKind, name: String)
    /// Open the claude.ai connectors page, for a hosted connector that cannot
    /// sign in locally.
    case openClaudeAIConnectors
    /// Nothing to run: the fix is manual. Carries the plain-words steps to show
    /// in a help popover — running the client and opening `/mcp`, say.
    case reconnectOnly(guidance: String)
    /// Settled states offer nothing.
    case none

    /// The claude.ai connectors page. One constant so the classifier, the
    /// session and any test all point at the same address.
    public static let claudeAIConnectorsURL = URL(string: "https://claude.ai/customize/connectors")
}

/// Classifies the one honest offer for an entry, from the entry alone.
///
/// The rules, in order:
///  - A hosted connector, or a failure whose detail names an Anthropic-hosted
///    server or a rejected session token, cannot OAuth locally. The only useful
///    move is the connectors page.
///  - A remote server that needs authentication or has failed can sign in again
///    through the client's own flow.
///  - Pending approval, and a stdio server that needs attention, are fixed by
///    running the client and opening `/mcp`; there is nothing this app can run
///    for them.
///  - Everything settled offers nothing.
public enum ConnectionHealthActionClassifier {
    public static func action(for entry: ConnectionHealthEntry) -> ConnectionHealthAction {
        // A rejected session token is a client login problem, not a per-server
        // one, and an Anthropic-hosted connector has no local OAuth at all.
        // Both are answered on the connectors page rather than by a login the
        // CLI would refuse.
        if entry.isClaudeAIConnector || mentionsHostedOrSessionToken(entry) {
            return .openClaudeAIConnectors
        }

        switch entry.status {
        case .needsAuthentication, .failed:
            if entry.isRemoteEndpoint {
                return .reauthenticate(client: entry.client, name: entry.name)
            }
            // A local server that failed is not signed in from here; the client
            // is where it is reconnected.
            return .reconnectOnly(guidance: Self.reconnectGuidance)
        case .pendingApproval:
            return .reconnectOnly(guidance: Self.approvalGuidance)
        case .connected, .disabled, .notConfigured, .unknown:
            return .none
        }
    }

    /// Whether a failure detail points at a hosted connector or a rejected
    /// session token. Read off the failure detail only, since that is where the
    /// client prints the reason.
    private static func mentionsHostedOrSessionToken(_ entry: ConnectionHealthEntry) -> Bool {
        guard case .failed(let detail) = entry.status else { return false }
        let lowered = detail.lowercased()
        return lowered.contains("anthropic-hosted") || lowered.contains("session token")
    }

    static let reconnectGuidance =
        "This is a local server. Run `claude` in a terminal and open /mcp to reconnect it."
    static let approvalGuidance =
        "This server is waiting for approval. Run `claude` in a terminal to approve it."
}
