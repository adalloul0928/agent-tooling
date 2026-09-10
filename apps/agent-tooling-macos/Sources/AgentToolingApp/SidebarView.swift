import AgentToolingCore
import SwiftUI

/// Three groups of screens, then the apps on this Mac.
///
/// The client block is not a fourth group of screens. It scopes the Apps pane to
/// one client and keeps that scope until somebody clears it, which is why it
/// lives below the list rather than inside it.
struct SidebarView: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance = "System"
    @Binding var selection: AppSection
    let openPalette: () -> Void

    init(
        workspace: WorkspaceLaunch.Workspace,
        selection: Binding<AppSection>,
        openPalette: @escaping () -> Void = {}
    ) {
        self.workspace = workspace
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

    /// What the app has already read, turned into at most one glyph per row.
    ///
    /// Reading the library the sidebar is drawn beside cannot start a scan, so a
    /// screen with nothing to report simply carries nothing.
    private var health: SectionHealth {
        guard let library = workspace.library.state?.library else { return SectionHealth() }
        return SectionHealth(inventory: VersionedInventoryProjection.inventory(library))
    }

    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { selection.sidebarDestination },
            set: { section in
                guard let section else { return }
                openSection(section)
            })
    }

    @ViewBuilder
    private func navigationRows(_ sections: [AppSection]) -> some View {
        ForEach(sections) { section in
            HStack {
                Label(section.navigationTitle, systemImage: section.symbol)
                Spacer(minLength: 4)
                if health[section] == .attention {
                    StatusGlyph(state: .attention, size: 12)
                        .accessibilityLabel("Needs attention")
                }
            }
            .badge(section == .syncCenter ? workspace.device.attentionCount : 0)
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
        .help("Search apps, tools, presets, projects, and actions")
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
    ///
    /// An app this Mac has stopped managing is dimmed rather than removed: a row
    /// that disappears reads as an app that is gone, and it is not.
    private var clientsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("On this Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                appearanceButton
            }

            ForEach(workspace.device.availableClients) { client in
                clientRow(client)
            }

            if navigation.selectedClient != nil {
                Button("Show all apps") { navigation.showAllClients() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Stop scoping Apps to one client.")
            }
        }
    }

    private func clientRow(_ client: ClientKind) -> some View {
        let verdict = workspace.device.verdict(for: client)
        let enabled = workspace.device.isEnabled(client)
        let selected = selection.sidebarDestination == .syncCenter && navigation.selectedClient == client
        return Button {
            navigation.openClient(client)
        } label: {
            HStack(spacing: 8) {
                ClientBrandIcon(client: client, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(client.rawValue)
                        .fontWeight(selected ? .semibold : .regular)
                        .lineLimit(1)
                    Text(verdict.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                StatusGlyph(state: verdict.state, size: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .opacity(enabled ? 1 : 0.45)
        .help(
            enabled
                ? "Show only \(client.rawValue) in Apps. \(verdict.text)."
                : "\(client.rawValue) is not managed on this Mac. \(verdict.text)."
        )
        .accessibilityLabel("Show \(client.rawValue) only")
        .accessibilityValue(
            [selected ? "Selected" : "", enabled ? "" : "Not managed on this Mac", verdict.text]
                .filter { !$0.isEmpty }
                .joined(separator: ", "))
    }
}
