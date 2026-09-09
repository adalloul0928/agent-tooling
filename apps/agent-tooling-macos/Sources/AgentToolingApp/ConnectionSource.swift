import AgentToolingCore
import SwiftUI

struct ConnectionSource: Equatable {
    let source: String
    let plugin: String?
    let marketplace: String?

    init(_ raw: String) {
        let identifier: String
        if raw.hasPrefix("codex:") {
            identifier = String(raw.dropFirst("codex:".count))
        } else if raw.hasPrefix("claude:") {
            identifier = String(raw.dropFirst("claude:".count))
        } else {
            identifier = raw
        }
        let parts = identifier.split(separator: "@", omittingEmptySubsequences: false)
        let validID: (Substring) -> Bool = {
            !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
        if parts.count == 2, parts.allSatisfy(validID) {
            source = "Plugin"
            plugin = String(parts[0])
            marketplace = String(parts[1])
        } else {
            plugin = nil
            marketplace = nil
            switch raw {
            case "Codex native MCP inventory", "Codex configuration", "Codex CLI configuration": source = "Codex"
            case "Claude Code configuration": source = "Claude Code"
            case "Gemini CLI configuration": source = "Gemini CLI"
            case "Agent Tooling managed definition": source = "Local library"
            default: source = raw.hasPrefix("/") ? "Config file" : "Not recorded"
            }
        }
    }

    init(server: MCPServer) {
        self.init(server.isManagedDefinition ? "Agent Tooling managed definition" : server.endpoint)
    }

    var pluginTitle: String? { plugin.map(Self.title) }
    var marketplaceTitle: String? { marketplace.map(Self.title) }

    /// Keep a declared display name, removing the catalog suffix only when it
    /// is the item's own qualified identifier or its already-humanized form.
    static func pluginName(_ displayName: String, identifier: String) -> String {
        let identity = ConnectionSource(identifier)
        guard let plugin = identity.plugin, let marketplace = identity.marketplace else { return displayName }
        let displayedIdentity = ConnectionSource(displayName)
        if displayedIdentity.plugin == plugin, displayedIdentity.marketplace == marketplace {
            return title(plugin)
        }
        if displayName == "\(title(plugin))@\(title(marketplace))" {
            return title(plugin)
        }
        return displayName
    }

    static func title(_ id: String) -> String {
        let names = ["openai": "OpenAI", "github": "GitHub", "mcp": "MCP", "ios": "iOS", "cli": "CLI", "pdf": "PDF"]
        return id.split(separator: "-").map {
            names[$0.lowercased()] ?? ($0.prefix(1).uppercased() + $0.dropFirst())
        }.joined(separator: " ")
    }
}

struct ConnectionFilterPill: View {
    let title: String
    let color: Color
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(active ? AgentTheme.blue : Color.secondary)
                .background(AgentTheme.blue.opacity(active ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AgentTheme.blue.opacity(active ? 0.45 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(active ? "Clear \(title) filter" : "Filter by \(title)")
        .accessibilityLabel("\(active ? "Clear" : "Filter by") \(title)")
    }
}

/// Value identity stays stable across rows, filtering, and app launches.
enum ConnectionPillColors {
    static func color(for value: String) -> Color {
        switch value.lowercased() {
        case "codex": return .green
        case "claude": return .orange
        case "gemini": return .blue
        case "plugin": return .purple
        case "mobile-development": return .pink
        case "developer-workflows": return .blue
        case "simview": return .yellow
        case "agent-tooling": return .teal
        case "toolingtools": return .purple
        case "http": return .green
        case "stdio": return .orange
        case "local config", "other": return .gray
        default:
            let palette: [Color] = [.blue, .orange, .pink, .teal, .purple, .green, .yellow, .cyan]
            let hash = value.lowercased().utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
            return palette[Int(hash % UInt64(palette.count))]
        }
    }
}
