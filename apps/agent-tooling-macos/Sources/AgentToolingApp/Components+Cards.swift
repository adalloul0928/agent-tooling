import AgentToolingCore
import AppKit
import SwiftUI

// MARK: - Toolbar and cards

struct PageToolbar<Actions: View>: View {
    @Environment(\.workspaceSelection) private var section
    @Environment(\.workspaceNavigate) private var navigate
    @Environment(\.connectionCategory) private var connectionCategory
    let title: String
    let context: String?
    /// Whether the section's own title wins over `title`. It does for every
    /// ordinary screen; a screen narrowed to one thing (one app's page) passes
    /// false so the thing it is about is what the page is called.
    let usesSectionTitle: Bool
    @ViewBuilder let actions: Actions

    init(title: String, context: String? = nil, usesSectionTitle: Bool = true, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.context = context
        self.usesSectionTitle = usesSectionTitle
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(usesSectionTitle ? (section?.workspaceTitle ?? title) : title)
                        .font(AgentFont.pageTitle)
                    if let context {
                        Text(context)
                            .font(AgentFont.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                GlassEffectContainer(spacing: Space.md) {
                    HStack(spacing: Space.md) {
                        actions
                    }
                }
                .tint(nil as Color?)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.vertical, Space.lg)
            .frame(minHeight: Size.toolbarHeight)

            if let section, !section.workspaceTabs.isEmpty {
                HStack(spacing: Space.xl) {
                    WorkspaceSegmentedPicker(
                        "\(section.workspaceTitle ?? title) section",
                        selection: Binding(get: { section }, set: { navigate($0) })
                    ) {
                        ForEach(section.workspaceTabs) { tab in
                            Text(tab.tabTitle).tag(tab)
                        }
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                    if let connectionCategory {
                        WorkspaceSegmentedPicker("Connection type", selection: connectionCategory) {
                            Text("MCP servers").tag("MCP servers")
                            Text("Connectors").tag("Connectors")
                        }
                        .fixedSize()
                    }
                }
                .padding(.horizontal, WorkspaceLayout.pageInset)
                .padding(.bottom, Space.lg)
                Hairline()
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var workspaceSelection: AppSection? = nil
    @Entry var workspaceNavigate: (AppSection) -> Void = { _ in }
    @Entry var connectionCategory: Binding<String>? = nil
    @Entry var availableClients: [ClientKind] = ClientKind.allCases
}

/// One search field treatment across the library. Native text editing and
/// accessibility are retained, including an explicit clear action.
struct InventorySearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Clear \(placeholder.lowercased())")
            }
        }
        .font(AgentFont.body)
        .padding(.horizontal, Space.lg)
        .frame(height: Size.controlHeight)
        .background(AgentTheme.panelBrightening, in: RoundedRectangle.control)
        .background(.thickMaterial, in: RoundedRectangle.control)
        .overlay(RoundedRectangle.control.strokeBorder(AgentTheme.hairlineStroke, lineWidth: Hairline.width))
    }
}

struct InspectorHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(title).font(AgentFont.captionMedium).foregroundStyle(.secondary)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(AgentFont.captionSemibold).frame(width: Size.iconButton, height: Size.iconButton)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Close \(title.lowercased())").accessibilityLabel("Close \(title.lowercased())")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, WorkspaceLayout.paneInset).frame(height: Size.headerHeight)
        .background(AgentTheme.controlBackground.opacity(0.35))
        .hairlineBottom()
    }
}

/// Finite, mutually exclusive choices use the same native control everywhere.
/// Use one supported native capsule shape and neutral tint across toolbars
/// and content panes; the system draws selection, focus, and accessibility states.
struct WorkspaceSegmentedPicker<Value: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder let content: Content

    init(_ title: String, selection: Binding<Value>, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        Picker(title, selection: $selection) { content }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(AgentFont.body)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .tint(nil as Color?)
            .accessibilityLabel(title)
    }
}

extension View {
    /// Filter and sorting menus share the system's neutral pop-up treatment.
    func inventoryMenuStyle() -> some View {
        menuStyle(.borderedButton)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .tint(nil as Color?)
            .foregroundStyle(.primary)
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(AgentFont.heading)
            Spacer()
            trailing
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: Size.headerHeight)
        .hairlineBottom()
    }
}

/// Title above, card below. Cards are only ever a list of rows.
struct TitledCard<Trailing: View, Content: View>: View {
    private let title: String
    private let count: String?
    private let trailing: Trailing
    private let content: Content

    init(_ title: String, count: String? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text(title).font(AgentFont.heading)
                if let count {
                    Text(count).font(AgentFont.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                trailing
                    .font(AgentFont.captionMedium)
            }
            .padding(.horizontal, Space.xxs)
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()
        }
    }
}

extension TitledCard where Trailing == EmptyView {
    init(_ title: String, count: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, count: count, trailing: { EmptyView() }, content: content)
    }
}

/// The row grammar: a leading tile or glyph, a name, one clause, a verdict.
struct InfoRow<Leading: View, Trailing: View>: View {
    let title: String
    let detail: String?
    let leading: Leading
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Space.lg) {
            leading
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(AgentFont.bodyMedium)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.lg)
            trailing
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .frame(minHeight: Size.rowHeight)
    }
}

extension InfoRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title, detail: detail, leading: leading, trailing: { EmptyView() })
    }
}

/// The shape every review sheet takes: a header, the review that scrolls
/// between two hairlines, and a footer bar pinned to one height. Each sheet
/// supplies its own already-padded header and content and its own footer row
/// (the buttons differ); the scaffold owns the dividers, the footer-bar inset
/// and height, and the sheet's size so the four review sheets cannot drift
/// apart on them the way they had begun to.
struct ReviewSheetLayout<Header: View, Content: View, Footer: View>: View {
    let size: CGSize
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(
        size: CGSize,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.size = size
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView { content }
            Hairline()
            footer
                .padding(.horizontal, Space.xxxl)
                .frame(height: Size.sheetBarHeight)
        }
        .sheetSize(size)
    }
}

