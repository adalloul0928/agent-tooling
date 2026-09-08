import AgentToolingCore
import SwiftUI

struct SidebarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance = "System"
    @Binding var selection: AppSection
    @Binding var isCollapsed: Bool
    let openPalette: () -> Void
    @Namespace private var selectionNamespace

    init(selection: Binding<AppSection>, isCollapsed: Binding<Bool>, openPalette: @escaping () -> Void = {}) {
        _selection = selection
        _isCollapsed = isCollapsed
        self.openPalette = openPalette
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            productHeader
                .padding(.top, 36)
                .padding(.bottom, 8)

            paletteButton
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(NavigationGroup.allCases, id: \.self) { group in
                    if !group.rawValue.isEmpty {
                        groupHeader(group.rawValue)
                    }
                    ForEach(group.sections) { section in
                        SidebarRow(
                            section: section,
                            selected: selection == section,
                            badge: badge(for: section),
                            health: model.sectionHealth(for: section),
                            isCollapsed: isCollapsed,
                            namespace: selectionNamespace
                        ) {
                            if section == .syncCenter {
                                navigation.showAllClients()
                            }
                            selection = section
                        }
                    }
                }
            }

            Spacer(minLength: 12)

            clientsBlock
                .padding(.bottom, 10)
        }
        .padding(.horizontal, isCollapsed ? 8 : 10)
        .frame(width: isCollapsed ? AgentTheme.collapsedSidebarWidth : AgentTheme.sidebarWidth)
        .background {
            // Nothing is painted over the window material: the sidebar is the
            // material, the way Finder's is, so it stays see-through and meets
            // the window edge without a step. Only the accessibility fallback,
            // which has no material to show, needs a surface of its own.
            if reduceTransparency { AgentTheme.contentBackground }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation sidebar")
    }

    @ViewBuilder
    private func groupHeader(_ title: String) -> some View {
        if isCollapsed {
            Divider().opacity(0.35).padding(.vertical, 8)
        } else {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)
        }
    }

    private var productHeader: some View {
        Group {
            if isCollapsed {
                HStack(spacing: 0) {
                    appearanceButton
                    collapseButton
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AgentTheme.blue)
                        .frame(width: 24, height: 24)

                    Text("Agent Tooling")
                        .font(.system(.subheadline, design: .default, weight: .semibold))

                    Spacer(minLength: 6)

                    appearanceButton
                    collapseButton
                }
            }
        }
        .padding(.leading, isCollapsed ? 3 : 6)
        .frame(maxWidth: .infinity)
    }

    /// One search over every named object and action in the app. It is a real
    /// control so the shortcut is discoverable rather than folklore.
    private var paletteButton: some View {
        Button(action: openPalette) {
            HStack(spacing: isCollapsed ? 0 : 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: isCollapsed ? 32 : 18)
                if !isCollapsed {
                    Text("Search")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("⌘K")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, isCollapsed ? 0 : 9)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.055)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help("Search clients, tools, sources, receipts, and actions")
        .accessibilityLabel("Search everything")
    }

    private var appearanceButton: some View {
        Button {
            appearance = colorScheme == .dark ? "Light" : "Dark"
        } label: {
            Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(colorScheme == .dark ? "Use light appearance" : "Use dark appearance")
        .accessibilityLabel(colorScheme == .dark ? "Use light appearance" : "Use dark appearance")
    }

    private var collapseButton: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            Image(systemName: isCollapsed ? "sidebar.right" : "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityLabel(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    /// The three clients this Mac is managing, with the verdict from the last
    /// check. Selecting one opens the Clients pane with an exact, durable scope.
    private var clientsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isCollapsed {
                Text("Clients")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            ForEach(model.availableClients) { client in
                let verdict = model.clientVerdict(for: client)
                let selected = selection == .syncCenter && navigation.selectedClient == client
                Button {
                    navigation.openClient(client)
                    selection = .syncCenter
                } label: {
                    HStack(spacing: isCollapsed ? 0 : 9) {
                        ClientBrandIcon(client: client, size: 16)
                            .frame(width: isCollapsed ? 32 : 18)
                        if !isCollapsed {
                            Text(client.rawValue)
                                .font(.system(.callout, design: .default, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? AgentTheme.blue : Color.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            StatusGlyph(state: verdict.state, size: 12, tint: selected ? AgentTheme.blue : nil)
                        }
                    }
                    .padding(.horizontal, isCollapsed ? 0 : 9)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AgentTheme.blue.opacity(0.13))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(reduceMotion ? nil : AgentMotion.selection, value: selected)
                .help("Show only \(client.rawValue) in Clients. \(verdict.text).")
                .accessibilityLabel("Show \(client.rawValue) only")
                .accessibilityValue([selected ? "Selected" : "", verdict.text].filter { !$0.isEmpty }.joined(separator: ", "))
            }
        }
    }

    private func badge(for section: AppSection) -> String? {
        switch section {
        case .syncCenter: return model.attentionCount == 0 ? nil : "\(model.attentionCount)"
        default: return nil
        }
    }
}

private struct SidebarRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let section: AppSection
    let selected: Bool
    let badge: String?
    /// Only ever set when the screen has something to report. A healthy app
    /// shows no dots at all.
    let health: HealthState?
    let isCollapsed: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: isCollapsed ? 0 : 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? .white : .secondary)
                    .frame(width: isCollapsed ? 32 : 18)
                    .overlay(alignment: .topTrailing) {
                        if isCollapsed, let health {
                            Circle()
                                .fill(dotColor(health))
                                .frame(width: 6, height: 6)
                                .offset(x: -4, y: -1)
                        }
                    }

                if !isCollapsed {
                    Text(section.rawValue)
                        .font(.system(.callout, design: .default, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white : .primary)

                    Spacer(minLength: 0)

                    if let health {
                        StatusGlyph(state: health, size: 11, tint: selected ? Color.white : nil)
                    }

                    if let badge {
                        Text(badge)
                            .contentTransition(.numericText())
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(selected ? .white : .secondary)
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.07)))
                    }
                }
            }
            .padding(.horizontal, isCollapsed ? 0 : 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AgentTheme.blue)
                        .shadow(color: AgentTheme.blue.opacity(0.28), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "sidebar-selection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : AgentMotion.quick, value: hovering)
        .animation(reduceMotion ? nil : AgentMotion.selection, value: selected)
        .help(helpText)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue([selected ? "Selected" : "", healthText].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var helpText: String {
        healthText.isEmpty ? section.rawValue : "\(section.rawValue): \(healthText)"
    }

    private var healthText: String {
        switch health {
        case .attention: "Needs attention"
        case .unavailable: "Not available"
        case .pending: "Waiting on you"
        case .healthy, nil: ""
        }
    }

    private func dotColor(_ state: HealthState) -> Color {
        switch state {
        case .healthy: AgentTheme.ok
        case .attention: AgentTheme.warning
        case .pending: Color.secondary
        case .unavailable: AgentTheme.failure
        }
    }
}
