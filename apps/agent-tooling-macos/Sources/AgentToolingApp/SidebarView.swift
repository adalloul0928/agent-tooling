import AgentToolingCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("appearance") private var appearance = "System"
    @Binding var selection: AppSection
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            productHeader
                .padding(.top, 10)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(AppSection.allCases) { section in
                    if section == .syncCenter {
                        Divider()
                            .opacity(0.30)
                            .padding(.vertical, 9)
                    }
                    SidebarRow(
                        section: section,
                        selected: selection == section,
                        badge: badge(for: section),
                        isCollapsed: isCollapsed
                    ) {
                        withAnimation(.snappy(duration: 0.24)) { selection = section }
                    }
                }
            }

            Spacer(minLength: 12)

            if isCollapsed {
                Image(systemName: overallState == .healthy ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .help(overallState == .healthy ? "Checked on this Mac" : "Setup needs review")
                    .padding(.top, 12)
                    .overlay(alignment: .top) { Divider().opacity(0.55) }
                    .padding(.bottom, 13)
            } else {
                HStack(spacing: 7) {
                    StatusDot(state: overallState, size: 7)
                    Text(overallState == .healthy ? "Checked on this Mac" : "Setup needs review")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 5)
                .padding(.top, 12)
                .overlay(alignment: .top) { Divider().opacity(0.55) }
                .padding(.bottom, 13)
            }
        }
        .padding(.horizontal, isCollapsed ? 8 : 11)
        .frame(width: isCollapsed ? AgentTheme.collapsedSidebarWidth : AgentTheme.sidebarWidth)
        .background(AgentTheme.sidebarBackground.opacity(reduceTransparency ? 1 : 0.94))
        .overlay(alignment: .topTrailing) {
            Rectangle().fill(AgentTheme.separator.opacity(0.45)).frame(width: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation sidebar")
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
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AgentTheme.blue)
                        .frame(width: 26, height: 26)

                    Text("Agent Tooling")
                        .font(.system(.subheadline, design: .default, weight: .semibold))

                    Spacer(minLength: 6)

                    appearanceButton
                    collapseButton
                }
            }
        }
        .padding(.leading, isCollapsed ? 3 : 5)
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
        .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityLabel(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    private var overallState: HealthState {
        guard !model.targetObservations.isEmpty else { return .pending }
        return model.targetObservations.allSatisfy(\.isCommandAvailable) ? .healthy : .attention
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: isCollapsed ? 0 : 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? .white : .secondary)
                    .frame(width: isCollapsed ? 32 : 18)

                if !isCollapsed {
                    Text(section.rawValue)
                        .font(.system(.callout, design: .default, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .white : .primary)

                    Spacer(minLength: 0)

                    if let badge {
                        Text(badge)
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .foregroundStyle(selected ? .white.opacity(0.88) : .secondary)
                    }
                }
            }
            .padding(.horizontal, isCollapsed ? 0 : 8)
            .frame(height: 33)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AgentTheme.blue : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.rawValue)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(selected ? "Selected" : "")
    }

}
