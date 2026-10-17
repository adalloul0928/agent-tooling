import Foundation

/// The one reviewed way to reach an MCP server a registry listing published,
/// recovered from the listing itself.
///
/// The registry provider only ever writes native install routes for a listing
/// it could review end to end: an `https` streamable-http endpoint that carries
/// no headers or variables, or a stdio `npx -y <pkg>@<version>` command with no
/// environment and a pinned version. When a listing needs credentials, a
/// header, a variable, or an unpinned version, the provider writes no routes at
/// all — so the presence of a route is itself the signal that the destination
/// is safe to record without asking anyone for a secret.
///
/// This reads that reviewed destination back out of the routes so Discover can
/// record the server through the very same managed-MCP intake the Paste sheet
/// uses, rather than through the native-plugin adoption path that only ever
/// accepted `claude:`/`codex:` catalog identifiers. The endpoint and command
/// are recovered from Claude Code's route, whose argument shape is the plain
/// `mcp add --transport <t> --scope <s> <id> <endpoint-or---command>` form, and
/// are handed straight to `MCPDefinitionValidator` so a recovered destination
/// that somehow does not validate is refused here rather than recorded.
public enum ReviewedMarketplaceMCPServer {
    /// What the listing needs before it can be reached, and whether this app can
    /// supply it without a person entering anything.
    public enum Availability: Equatable, Sendable {
        /// A reviewed route exists; the draft is ready to record.
        case reviewed(MCPDraft)
        /// The listing has no reviewed route, so recording it would need a
        /// credential, a manual step, or a pinned version this app does not have.
        case needsManualSetup
    }

    /// Whether this package is even an MCP server. Discover shows one button for
    /// these and per-client buttons for plugin listings, so the two are told
    /// apart on this one fact rather than on the identifier prefix.
    public static func isMCPServerListing(_ package: MarketplacePackage) -> Bool {
        package.components.contains(.mcpServer)
    }

    /// The reviewed connection for an MCP-server listing, or `needsManualSetup`
    /// when the provider published no route because the destination could not
    /// be reviewed without a secret or a manual step.
    ///
    /// Returns `nil` when the package is not an MCP server at all, so a caller
    /// can keep the plugin path for plugin listings.
    public static func availability(for package: MarketplacePackage) -> Availability? {
        guard isMCPServerListing(package) else { return nil }
        guard let draft = reviewedDraft(for: package) else { return .needsManualSetup }
        return .reviewed(draft)
    }

    /// Builds a draft from the listing's reviewed route, preferring the http
    /// route when both a http and a stdio route were published. The name is the
    /// server's short install identifier, which is what the routes were keyed
    /// on and what the client would have been told to call the server.
    ///
    /// Returns `nil` when there is no route, or when the recovered destination
    /// does not pass the same validation the Paste sheet's definitions pass.
    static func reviewedDraft(for package: MarketplacePackage) -> MCPDraft? {
        let routes = package.nativeInstalls
        guard !routes.isEmpty else { return nil }
        // Prefer the reviewed HTTPS endpoint when both shapes exist: it is the
        // same address on every Mac, so recording it needs nothing device-local.
        guard let recovered = recover(from: routes, transport: .http)
            ?? recover(from: routes, transport: .stdio)
        else { return nil }
        guard (try? MCPDefinitionValidator.validate(recovered.endpoint, transport: recovered.transport)) != nil
        else { return nil }

        var draft = MCPDraft()
        draft.name = installName(for: package)
        draft.transport = recovered.transport
        draft.endpoint = recovered.endpoint
        // A reviewed route carries no credentials by construction, so the
        // connection is recorded as needing none rather than defaulting to
        // OAuth, which would falsely claim a sign-in step.
        draft.authentication = "None"
        draft.scope = .user
        return draft
    }

    /// The install identifier the routes were built from — the server name's
    /// last path segment. Falls back to the display name so a draft always has
    /// something to be named, which validation will still check.
    private static func installName(for package: MarketplacePackage) -> String {
        let candidate = package.name.split(separator: "/").last.map(String.init) ?? package.name
        return candidate.isEmpty ? package.name : candidate
    }

    private struct Recovered {
        let transport: MCPTransport
        /// For http this is the URL; for stdio it is the space-joined command,
        /// which is the form `MCPDefinitionValidator` parses back into argv.
        let endpoint: String
    }

    /// Reads the endpoint or command back out of Claude Code's route, whose
    /// argument vector is the plainest of the four and always present. The
    /// shapes match `MCPClientCommand.addArguments(.claude, …)` exactly.
    private static func recover(
        from routes: [NativeInstall], transport: MCPTransport
    ) -> Recovered? {
        guard let route = routes.first(where: { $0.client == .claude }) else { return nil }
        let arguments = route.arguments
        // `mcp add --transport <http|stdio> --scope <scope> <serverID> …`
        guard arguments.count >= 6, arguments[0] == "mcp", arguments[1] == "add",
            arguments[2] == "--transport"
        else { return nil }
        switch transport {
        case .http:
            guard arguments[3] == "http", let endpoint = arguments.last, !endpoint.isEmpty else { return nil }
            return Recovered(transport: .http, endpoint: endpoint)
        case .stdio:
            guard arguments[3] == "stdio", let separator = arguments.firstIndex(of: "--") else { return nil }
            let command = Array(arguments[arguments.index(after: separator)...])
            guard !command.isEmpty else { return nil }
            return Recovered(transport: .stdio, endpoint: command.joined(separator: " "))
        }
    }
}
