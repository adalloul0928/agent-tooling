import SwiftUI

struct ConnectionSource: Equatable {
    let source: String
    let plugin: String?
    let marketplace: String?

    init(_ raw: String) {
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
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
            case "Codex native MCP inventory", "Codex configuration": source = "Codex"
            case "Claude Code configuration": source = "Claude"
            case "Gemini CLI configuration": source = "Gemini"
            default: source = raw.hasPrefix("/") ? "Local config" : "Other"
            }
        }
    }

    static func title(_ id: String) -> String {
        id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
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
                .foregroundStyle(color)
                .background(color.opacity(active ? 0.25 : 0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(active ? 0.65 : 0), lineWidth: 1))
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
