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
    var verdict: CGFloat { expanded ? 104 : 96 }
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

    /// Who manages this skill, which is a different claim from where it was
    /// found. Where this app placed it, the apps are shown; otherwise the
    /// words say who does manage it, so a row never reads as "not available".
    private var management: SkillManagement { SkillManagement(skill) }

    var body: some View {
        HStack(spacing: Space.lg) {
            Button(action: activate) {
                HStack(spacing: Space.lg) {
                    if selecting {
                        SelectionCheckbox(selected: selected, enabled: isAssignable).frame(width: Size.glyphSlot)
                    }
                    HStack(spacing: Space.md) {
                        KindTile(kind: .skill, size: Size.tileSmall, ghost: !skill.isMaintainedHere)
                            .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(skill.displayName).font(AgentFont.bodyMedium).lineLimit(1)
                            if !columns.expanded {
                                if columns.describing {
                                    Text(summary).font(AgentFont.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if let origin {
                                    Text(origin).font(AgentFont.caption).foregroundStyle(.secondary).lineLimit(1).help(origin)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: columns.name, alignment: .leading)
                    if columns.expanded {
                        if columns.describing {
                            Text(summary).font(AgentFont.body).foregroundStyle(.secondary)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .help(summary)
                        } else {
                            Spacer(minLength: 0)
                        }
                        Text(presentation.pluginName ?? skill.parentPluginLabel ?? "Standalone")
                            .font(AgentFont.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: columns.plugin, alignment: .leading)
                        Text(presentation.marketplaceName ?? skill.sourceLabel ?? "—")
                            .font(AgentFont.caption).foregroundStyle(.secondary).lineLimit(1)
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
            ClientMarks(present: observed, size: Size.brandMark)
                .frame(width: 72, alignment: .trailing)
            Group {
                if case .placed(let clients) = management {
                    // The word says whose it is; the discs say where this app
                    // put it. One disc alone would only say "Claude".
                    HStack(spacing: Space.sm) {
                        Text(management.label)
                            .font(AgentFont.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        PlacementStack(placed: clients, size: Size.tileSmall)
                    }
                } else {
                    Text(management.label)
                        .font(AgentFont.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: columns.verdict, alignment: .trailing)
            .help(management.explanation)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, Space.xl)
        .frame(height: columns.expanded ? 44 : [40, 48, 64][min(captionLines, 2)])
        .rowSelection(selected)
        .hairlineBottom()
    }
}


/// The Managed column's four answers. "Found in" says where a skill is;
/// this says who put it there and who can change it.
enum SkillManagement: Equatable {
    /// Yours, and this app placed it in these apps.
    case placed(Set<ClientKind>)
    /// Yours, but not placed anywhere yet.
    case yoursUnplaced
    /// Came with a plugin. The plugin is what an app installs or removes.
    case byPlugin
    /// Found in an app's folder; this app did not put it there and holds no
    /// copy, so it can show and try it, not place, edit, or update it.
    case notByThisApp

    init(_ skill: SkillEntry) {
        let placed = skill.requestedClients
        if !placed.isEmpty {
            self = .placed(placed)
        } else if skill.ownership == .trackedOnly {
            self = .notByThisApp
        } else if skill.ownership == .nativeOwned {
            self = .byPlugin
        } else {
            self = .yoursUnplaced
        }
    }

    /// One word each. The discs beside "Yours" say where; no discs says
    /// nowhere yet. The hover text carries the sentence.
    var label: String {
        switch self {
        case .placed, .yoursUnplaced: "Yours"
        case .byPlugin: "Plugin"
        case .notByThisApp: "Unmanaged"
        }
    }

    var explanation: String {
        switch self {
        case .placed:
            "Yours. This app placed it in the apps shown. Whether each install is in place is checked on the Apps screen."
        case .yoursUnplaced:
            "Yours, in this library, but not placed in any app yet. Choose where to use it from its details."
        case .byPlugin:
            "Came with a plugin. The plugin is what gets installed or removed; this library lists the skill so you can find it, see where it is, and try it."
        case .notByThisApp:
            "Found in an app's folder, but this app did not put it there and holds no copy. It can show and try it, not place, edit, or update it."
        }
    }
}
