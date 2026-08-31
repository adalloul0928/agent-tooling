import Foundation

/// Navigation-only routes accepted from local integrations such as Raycast.
/// A route may reveal a pending request, but it can never approve or execute
/// an operation.
public enum ExternalAppRoute: Equatable, Sendable {
    case section(ExternalAppSection)
    case skill(String)
    case skillCreationRequest(UUID)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "agent-tooling",
            url.user == nil,
            url.password == nil,
            url.port == nil,
            url.query == nil,
            url.fragment == nil,
            let host = url.host(percentEncoded: false)?.lowercased()
        else { return nil }

        let components = url.pathComponents.filter { $0 != "/" }
        switch (host, components) {
        case ("requests", let values) where values.count == 1:
            guard let id = UUID(uuidString: values[0]) else { return nil }
            self = .skillCreationRequest(id)
        case ("skills", let values) where values.count == 1:
            guard let id = try? WorkspaceLibrary.normalizedIdentifier(values[0]), id == values[0] else { return nil }
            self = .skill(id)
        case (_, let values) where values.isEmpty:
            guard let section = ExternalAppSection(rawValue: host) else { return nil }
            self = .section(section)
        default:
            return nil
        }
    }
}

public enum ExternalAppSection: String, CaseIterable, Sendable {
    case overview
    case marketplace
    case skills
    case insights
    case mcpServers = "mcp-servers"
    case plugins
    case configurations
    case sync
    case activity
    case accounts
    case settings
}
