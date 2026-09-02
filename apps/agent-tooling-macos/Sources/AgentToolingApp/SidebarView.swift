import AgentToolingCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance = "System"
    @Binding var selection: AppSection
    @Binding var isCollapsed: Bool
    @Namespace private var selectionNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            productHeader
                .padding(.top, 36)
                .padding(.bottom, 8)

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
                            isCollapsed: isCollapsed,
                            namespace: selectionNamespace
                        ) {
                            withAnimation(.snappy(duration: 0.24)) { selection = section }
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
        .background(AgentTheme.sidebarGlass)
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
    /// check. Selecting one opens Sync, where app status lives.
    private var clientsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isCollapsed {
                Text("Clients")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            ForEach([ClientKind.claude, .codex, .gemini]) { client in
                let verdict = model.clientVerdict(for: client)
                Button {
                    withAnimation(.snappy(duration: 0.24)) { selection = .syncCenter }
                } label: {
                    HStack(spacing: isCollapsed ? 0 : 9) {
                        ClientBrandIcon(client: client, size: 16)
                            .frame(width: isCollapsed ? 32 : 18)
                        if !isCollapsed {
                            Text(client.rawValue)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            StatusGlyph(state: verdict.state, size: 12)
                        }
                    }
                    .padding(.horizontal, isCollapsed ? 0 : 9)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(client.rawValue): \(verdict.text)")
                .accessibilityLabel("\(client.rawValue), \(verdict.text)")
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
    let section: AppSection
    let selected: Bool
    let badge: String?
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

                if !isCollapsed {
                    Text(section.rawValue)
                        .font(.system(.callout, design: .default, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white : .primary)

                    Spacer(minLength: 0)

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
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(section.rawValue)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(selected ? "Selected" : "")
    }
}
