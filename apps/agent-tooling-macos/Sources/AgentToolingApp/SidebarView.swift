import AgentToolingCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance = "System"
    @Binding var selection: AppSection
    let openPalette: () -> Void

    // Column visibility belongs to NavigationSplitView. Keep the binding in
    // the initializer for callers that render the sidebar independently.
    init(selection: Binding<AppSection>, isCollapsed: Binding<Bool>, openPalette: @escaping () -> Void = {}) {
        _selection = selection
        self.openPalette = openPalette
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agent Tooling")
                    .font(.headline)
                    .lineLimit(1)

                paletteButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            List(selection: sidebarSelection) {
                ForEach(NavigationGroup.allCases, id: \.self) { group in
                    if group.rawValue.isEmpty {
                        navigationRows(group.sections)
                    } else {
                        Section(group.rawValue) {
                            navigationRows(group.sections)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            clientsBlock
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        // No background or glass overlay: NavigationSplitView owns the
        // sidebar material, including its adaptive foreground appearance.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation sidebar")
    }

    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { selection.sidebarDestination },
            set: { section in
                guard let section else { return }
                openSection(section)
            }
        )
    }

    @ViewBuilder
    private func navigationRows(_ sections: [AppSection]) -> some View {
        ForEach(sections) { section in
            HStack {
                Label(section.navigationTitle, systemImage: section.symbol)
                Spacer(minLength: 4)
                if model.sectionHealth(for: section) == .attention {
                    StatusGlyph(state: .attention, size: 12)
                        .accessibilityLabel("Needs attention")
                }
            }
            .badge(section == .syncCenter ? model.attentionCount : 0)
            .tag(section)
            .contentShape(Rectangle())
            // Selecting an already-highlighted parent still returns to its
            // main screen, or clears a client scope on the Apps screen.
            .simultaneousGesture(TapGesture().onEnded { openSection(section) })
            .help(section.navigationTitle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(section.navigationTitle)
            .accessibilityAction { openSection(section) }
        }
    }

    private func openSection(_ section: AppSection) {
        if section == .syncCenter, navigation.selectedClient != nil {
            navigation.showAllClients()
        }
        selection = section
    }

    /// One search over every named object and action in the app.
    private var paletteButton: some View {
        Button(action: openPalette) {
            HStack(spacing: 8) {
                Label("Search", systemImage: "magnifyingglass")
                Spacer(minLength: 0)
                Text("⌘K")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .keyboardShortcut("k", modifiers: .command)
        .help("Search clients, tools, sources, receipts, and actions")
        .accessibilityLabel("Search everything")
    }

    private var appearanceButton: some View {
        Button {
            appearance = colorScheme == .dark ? "Light" : "Dark"
        } label: {
            Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(colorScheme == .dark ? "Use light appearance" : "Use dark appearance")
        .accessibilityLabel(colorScheme == .dark ? "Use light appearance" : "Use dark appearance")
    }

    /// Client shortcuts retain an exact scope independently of navigation.
    private var clientsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("On this Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                appearanceButton
            }

            ForEach(model.availableClients) { client in
                let verdict = model.clientVerdict(for: client)
                let selected = selection == .syncCenter && navigation.selectedClient == client
                Button {
                    navigation.openClient(client)
                    selection = .syncCenter
                } label: {
                    HStack(spacing: 8) {
                        ClientBrandIcon(client: client, size: 16)
                        Text(client.rawValue)
                            .fontWeight(selected ? .semibold : .regular)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        StatusGlyph(state: verdict.state, size: 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .help("Show only \(client.rawValue) in Apps. \(verdict.text).")
                .accessibilityLabel("Show \(client.rawValue) only")
                .accessibilityValue([selected ? "Selected" : "", verdict.text].filter { !$0.isEmpty }.joined(separator: ", "))
            }
        }
    }
}
