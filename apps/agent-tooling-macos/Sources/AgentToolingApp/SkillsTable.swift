import AgentToolingCore
import AppKit
import SwiftUI

/// The App filter: any app, or one of the clients this app knows. Every
/// `ClientKind` has a case here, so a client the registry gains is a filter the
/// screen offers; Kiro was missing from this list and so from the menu.
enum SkillClientFilter: String, CaseIterable, Identifiable {
    case all = "Any app"
    case claude = "Claude Code"
    case codex = "Codex"
    case gemini = "Gemini CLI"
    case kiro = "Kiro CLI"

    var id: String { rawValue }

    var client: ClientKind? {
        switch self {
        case .all: nil
        case .claude: .claude
        case .codex: .codex
        case .gemini: .gemini
        case .kiro: .kiro
        }
    }

    func matches(_ observed: Set<ClientKind>) -> Bool {
        guard let client else { return true }
        return observed.contains(client)
    }
}

struct SkillTableColumns {
    let width: CGFloat
    let selecting: Bool
    /// Whether anything on this list has a description to put in one.
    let describing: Bool
    var expanded: Bool { width >= 940 }
    var verdict: CGFloat { expanded ? 96 : 78 }
    var name: CGFloat {
        guard expanded else { return max(140, width - 144 - verdict - (selecting ? 32 : 0)) }
        // With no description column the name takes the space back rather than
        // leaving a gap where one used to be.
        return describing ? min(300, width * 0.24) : min(520, width * 0.42)
    }
    var plugin: CGFloat { min(200, width * 0.17) }
    var marketplace: CGFloat { min(180, width * 0.15) }
}

struct SkillCollectionRow: View {
    let skill: SkillEntry
    let presentation: SkillPresentation
    let observed: Set<ClientKind>
    let selected: Bool
    var selecting = false
    var isAssignable = false
    let columns: SkillTableColumns
    let activate: () -> Void

    private var summary: String {
        let value = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", ">-", ">", "|", "|-"].contains(value) ? "—" : value
    }

    /// Where it came from, in one clause, for the layout that has no room for
    /// the plugin and source columns.
    private var origin: String? {
        presentation.compactDescription ?? skill.parentPluginLabel ?? skill.sourceLabel
    }

    /// A caption line the narrow layout has to make room for.
    private var captionLines: Int {
        (columns.describing ? 1 : 0) + (origin == nil ? 0 : 1)
    }

    /// What has been asked for, never what is installed.
    private var verdict: String {
        let count = skill.requestedAssignments.filter(\.desiredPresence).count
        guard count > 0 else { return skill.isAssignable ? "Not assigned" : "Tracked" }
        return count == 1 ? "1 place" : "\(count) places"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: activate) {
                HStack(spacing: 12) {
                    if selecting {
                        SelectionCheckbox(selected: selected, enabled: isAssignable).frame(width: 20)
                    }
                    HStack(spacing: 9) {
                        KindTile(kind: .skill, size: 20, ghost: !skill.isMaintainedHere)
                            .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(skill.displayName).font(.callout.weight(.medium)).lineLimit(1)
                            if !columns.expanded {
                                if columns.describing {
                                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if let origin {
                                    Text(origin).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(origin)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: columns.name, alignment: .leading)
                    if columns.expanded {
                        if columns.describing {
                            Text(summary).font(.callout).foregroundStyle(.secondary)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .help(summary)
                        } else {
                            Spacer(minLength: 0)
                        }
                        Text(presentation.pluginName ?? skill.parentPluginLabel ?? "Standalone")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: columns.plugin, alignment: .leading)
                        Text(presentation.marketplaceName ?? skill.sourceLabel ?? "—")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: columns.marketplace, alignment: .leading)
                            .help(presentation.marketplaceName ?? skill.sourceLabel ?? "No recorded source")
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(skill.displayName)
            ClientMarks(present: observed, size: 15)
                .frame(width: 72, alignment: .trailing)
            Text(verdict)
                .font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                .frame(width: columns.verdict, alignment: .trailing)
                .help("Where this skill has been asked for. Installation is checked separately.")
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 16)
        .frame(height: columns.expanded ? 44 : [40, 48, 64][min(captionLines, 2)])
        .rowSelection(selected)
        .overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }
}

