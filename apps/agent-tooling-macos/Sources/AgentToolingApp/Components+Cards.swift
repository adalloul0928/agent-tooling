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
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(usesSectionTitle ? (section?.workspaceTitle ?? title) : title)
                        .font(.system(size: 20, weight: .semibold))
                    if let context {
                        Text(context)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        actions
                    }
                }
                .tint(nil as Color?)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.vertical, 10)
            .frame(minHeight: 58)

            if let section, !section.workspaceTabs.isEmpty {
                HStack(spacing: 16) {
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
                .padding(.bottom, 10)
                Divider().opacity(0.5)
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
        HStack(spacing: 8) {
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
        .font(.system(size: 13))
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(AgentTheme.panelBrightening, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AgentTheme.separator.opacity(0.4), lineWidth: 0.5))
    }
}

struct InspectorHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Close \(title.lowercased())").accessibilityLabel("Close \(title.lowercased())")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 20).frame(height: 48)
        .background(AgentTheme.controlBackground.opacity(0.35))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
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
            .font(.system(size: 13))
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
                .font(.subheadline.weight(.semibold))
            Spacer()
            trailing
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(title).font(.subheadline.weight(.semibold))
                if let count {
                    Text(count).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                trailing
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 2)
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
        HStack(spacing: 11) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

extension InfoRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title, detail: detail, leading: leading, trailing: { EmptyView() })
    }
}

struct TagCloud: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
        }
    }
}

