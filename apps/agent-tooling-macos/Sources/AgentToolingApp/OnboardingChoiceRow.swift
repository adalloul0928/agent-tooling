import AgentToolingCore
import SwiftUI

/// Selection rows only read the immutable scan snapshot. Scrolling never
/// rebuilds the model's inventory or searches client configuration files.
struct OnboardingChoiceRow: View {
    let candidate: OnboardingCandidate
    let children: [OnboardingCandidate]
    @Binding var isSelected: Bool
    let onInspect: () -> Void
    var isPersonalCopy = false
    var onMakePersonalCopy: (() -> Void)? = nil
    var onKeepSource: (() -> Void)? = nil
    var onLinkRepository: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .labelsHidden().toggleStyle(.checkbox)
                .disabled(!candidate.canTrack)
                .accessibilityLabel("Track \(candidate.name)")
            if candidate.kind == .plugin {
                ToolIdentityIcon(packageID: candidate.itemID, size: 34)
            } else {
                Image(systemName: candidate.kind == .skill ? "doc.text" : "server.rack")
                    .font(.system(size: 21)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                if candidate.kind == .plugin && !children.isEmpty {
                    Button(action: onInspect) {
                        Text(OnboardingListPolicy.contentsSummary(children))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show tools included with \(candidate.name)")
                } else if candidate.kind != .mcpServer {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if candidate.kind == .plugin, let marketplace = ConnectionSource(candidate.itemID).marketplaceTitle {
                Text(marketplace).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 160, alignment: .trailing)
            }
            if isPersonalCopy {
                Text("Personal copy").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let binding = candidate.repositoryBinding {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Following repository").font(.system(size: 12))
                    Text(binding.ref).font(.system(size: 12)).lineLimit(1)
                }.foregroundStyle(.secondary).help(binding.repositoryURL)
            } else if candidate.disposition == .managed {
                Text("In your library").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(candidate.clients) { client in
                    ClientBrandIcon(client: client, size: 18).help(client.rawValue)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(candidate.clients.map(\.rawValue).joined(separator: ", "))
            if candidate.canCopy {
                Menu {
                    if candidate.repositoryBinding == nil {
                        Button("Link repository…") { onLinkRepository?() }
                            .disabled(!isSelected || onLinkRepository == nil)
                        Divider()
                    }
                    if isPersonalCopy {
                        Button("Keep source version") { onKeepSource?() }.disabled(onKeepSource == nil)
                    } else {
                        Button("Make personal copy…") { onMakePersonalCopy?() }.disabled(onMakePersonalCopy == nil)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 24)
                .accessibilityLabel("Options for \(candidate.name)")
                .help("Tracking keeps the original source. Make a personal copy only if you want to maintain your own version.")
            }
        }
        .frame(height: candidate.kind == .mcpServer ? 48 : 64)
        .help(candidate.kind == .plugin ? candidate.itemID : candidate.disposition == .unavailable ? candidate.guidance : candidate.summary)
    }

    private var subtitle: String {
        if candidate.disposition == .unavailable { return "Source not located · track existing setup" }
        if candidate.kind == .plugin { return "Plugin bundle" }
        let summary = candidate.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = !summary.isEmpty && ![">", ">-", ">+", "|", "|-", "|+"].contains(summary)
        return hasSummary ? summary : "Standalone skill"
    }
}

enum OnboardingListPolicy {
    static func filtered(_ candidates: [OnboardingCandidate], search: String) -> [OnboardingCandidate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    static func contentsSummary(_ children: [OnboardingCandidate]) -> String {
        let skills = children.count { $0.kind == .skill }
        let servers = children.count { $0.kind == .mcpServer }
        var parts: [String] = []
        if skills > 0 { parts.append("\(skills) \(skills == 1 ? "skill" : "skills")") }
        if servers > 0 { parts.append("\(servers) \(servers == 1 ? "connection" : "connections")") }
        return parts.isEmpty ? "Plugin bundle" : "Includes " + parts.joined(separator: " · ")
    }

    static func reviewRows(_ candidates: [OnboardingCandidate]) -> [OnboardingCandidate] {
        let order: [ToolingItemKind: Int] = [.plugin: 0, .skill: 1, .mcpServer: 2]
        return candidates.sorted {
            if $0.kind != $1.kind { return order[$0.kind, default: 3] < order[$1.kind, default: 3] }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func availableName(_ proposed: String, existing: [String]) -> String {
        let names = Set(existing.map { $0.lowercased() })
        guard names.contains(proposed.lowercased()) else { return proposed }
        var suffix = 2
        while names.contains("\(proposed) \(suffix)".lowercased()) { suffix += 1 }
        return "\(proposed) \(suffix)"
    }
}
