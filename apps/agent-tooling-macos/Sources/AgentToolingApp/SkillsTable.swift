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

/// The Skills table's columns: the geometry every collection table shares
/// (`CollectionColumns`), and the columns only this one has.
struct SkillTableColumns {
    /// Whether anything on this list has a description to put in one.
    let describing: Bool
    private let table: CollectionColumns

    init(width: CGFloat, selecting: Bool, describing: Bool) {
        self.describing = describing
        table = CollectionColumns(width: width, layout: .skills(selecting: selecting, describing: describing))
    }

    var expanded: Bool { table.expanded }
    var name: CGFloat { table.name }
    /// The Managed column.
    var verdict: CGFloat { expanded ? CollectionColumn.Skills.verdict : CollectionColumn.Skills.verdictCompact }
    var plugin: CGFloat { table.share(CollectionColumn.Skills.pluginShare, upTo: CollectionColumn.Skills.pluginMax) }
    var marketplace: CGFloat {
        table.share(CollectionColumn.Skills.marketplaceShare, upTo: CollectionColumn.Skills.marketplaceMax)
    }
}

/// How many copies of one skill the library holds, for the badge beside its
/// name. Nil, and no badge, when there is only the one.
struct SkillCopySummary: Equatable {
    let copies: Int
    /// Different contents among them that the last check could compare.
    let versions: Int

    init?(copies: Int, versions: Int) {
        guard copies > 1 else { return nil }
        self.copies = copies
        self.versions = versions
    }

    var label: String {
        versions > 1 ? CountNoun("version").phrase(versions) : CountNoun("copy", plural: "copies").phrase(copies)
    }

    /// The chip on a compact row, where the copies and whether they differ
    /// share one capsule: "2 copies · 2 versions", or "2 copies · same
    /// content" when every copy the last check compared is alike. Your
    /// library's list on the setup stage (S06) shows it.
    var compactLabel: String {
        let count = CountNoun("copy", plural: "copies").phrase(copies)
        return versions > 1 ? "\(count) · \(CountNoun("version").phrase(versions))" : "\(count) · same content"
    }

    var explanation: String {
        versions > 1
            ? "\(copies) copies of this skill, and they are not all the same: \(versions) different versions. An app uses the copy it has. Open it to see which is where."
            : "\(copies) copies of this skill, from different plugins or folders. Open it to see each one and where it was found."
    }
}

struct SkillCollectionRow: View {
    let skill: SkillEntry
    let presentation: SkillPresentation
    let observed: Set<ClientKind>
    /// Who manages this copy. The index decides, since only it knows which
    /// copies another tool placed.
    let management: SkillManagement
    /// Other copies of the same skill, when there are any.
    var copies: SkillCopySummary? = nil
    /// How many other copies in this section the row also stands for.
    var moreSources = 0
    let selected: Bool
    var selecting = false
    var isAssignable = false
    let columns: SkillTableColumns
    /// What the last update check said about this skill, when it follows a
    /// repository and the check had something to say.
    var update: UpdateAvailability? = nil
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

    /// The narrow layout's height: the name alone, with one caption line
    /// under it, or with two.
    private var stackedHeight: CGFloat {
        [Size.stackedRowHeight, Size.stackedRowHeightOneCaption, Size.stackedRowHeightTwoCaptions][min(captionLines, 2)]
    }

    /// The Managed column's word, which on a selected row ranks between the
    /// name and its secondary text.
    private var managedLabelColor: Color {
        selected ? AgentTheme.onSelection.opacity(Opacity.labelOnSelection) : Color.secondary
    }

    var body: some View {
        HStack(spacing: Space.lg) {
            Button(action: activate) {
                HStack(spacing: Space.lg) {
                    if selecting {
                        SelectionCheckbox(selected: selected, enabled: isAssignable).frame(width: Size.glyphSlot)
                    }
                    HStack(spacing: Space.md) {
                        KindTile(kind: .skill, size: Size.tileSmall, ghost: !skill.isMaintainedHere)
                            .foregroundStyle(selected ? AgentTheme.onSelection.opacity(Opacity.quiet) : Color.secondary)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            HStack(spacing: Space.md) {
                                Text(skill.displayName).font(AgentFont.bodyMedium).lineLimit(1)
                                if let copies {
                                    Text(copies.label)
                                        .font(AgentFont.microMedium).lineLimit(1).fixedSize()
                                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
                                        .background(.quaternary, in: Capsule())
                                        .foregroundStyle(
                                            selected
                                                ? AgentTheme.onSelection.opacity(Opacity.labelOnSelection)
                                                : copies.versions > 1 ? AgentTheme.warning : Color.secondary
                                        )
                                        .help(copies.explanation)
                                        .accessibilityLabel(copies.label)
                                }
                                if let update, update.hasUpdate { UpdateStateBadge(availability: update) }
                            }
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
                        Text(
                            (presentation.pluginName ?? skill.parentPluginLabel ?? "Standalone")
                                + (moreSources > 0 ? " +\(moreSources)" : "")
                        )
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
            ClientMarks(present: observed, size: Size.brandMark, selected: selected)
                .frame(width: Size.foundInColumn, alignment: .trailing)
            Group {
                if case .placed(let clients) = management {
                    // The word says whose it is; the discs say where this app
                    // put it. One disc alone would only say "Claude".
                    HStack(spacing: Space.sm) {
                        Text(management.label)
                            .font(AgentFont.caption).foregroundStyle(managedLabelColor)
                        PlacementStack(placed: clients, size: Size.tileSmall)
                    }
                } else {
                    Text(management.label)
                        .font(AgentFont.caption).foregroundStyle(managedLabelColor)
                        .lineLimit(1)
                }
            }
            .frame(width: columns.verdict, alignment: .trailing)
            .help(management.explanation)
        }
        .foregroundStyle(selected ? AgentTheme.onSelection : Color.primary)
        .padding(.horizontal, Space.xl)
        .frame(height: columns.expanded ? Size.rowHeight : stackedHeight)
        .rowSelection(selected)
        .hairlineBottom()
    }
}

/// The Managed column's answers. "Found in" says where a skill is;
/// this says who put it there and who can change it.
enum SkillManagement: Equatable {
    /// Yours, and this app placed it in these apps.
    case placed(Set<ClientKind>)
    /// Yours, but not placed anywhere yet.
    case yoursUnplaced
    /// Came with a plugin. The plugin is what an app installs or removes.
    case byPlugin
    /// Managed by another tool; local changes may be overwritten by its sync.
    case byTool(ObservedExternalManager)
    /// Found in an app's folder; this app did not put it there and holds no
    /// copy, so it can show and try it, not place, edit, or update it.
    case notByThisApp

    init(_ skill: SkillEntry, placedBy manager: ObservedExternalManager? = nil) {
        let placed = skill.requestedClients
        if !placed.isEmpty {
            self = .placed(placed)
        } else if skill.ownership == .trackedOnly, let manager {
            self = .byTool(manager)
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
        case .byTool(let manager): manager.tool
        case .notByThisApp: "Unmanaged"
        }
    }

    var explanation: String {
        switch self {
        case .placed:
            "Yours. This app placed it in the apps shown. Whether each install is in place is checked on the Apps screen."
        case .yoursUnplaced:
            "Yours, in this library, but not placed in any app yet. Install it from its details."
        case .byPlugin:
            "Came with a plugin. The plugin is what gets installed or removed; this library lists the skill so you can find it, see where it is, and try it."
        case .byTool(let manager):
            "Placed by \(manager.label), which keeps it in step. Change or remove it there: anything changed here would be undone at its next sync."
        case .notByThisApp:
            "Found in an app's folder, but this app did not put it there and holds no copy. It can show and try it, not place, edit, or update it."
        }
    }
}
