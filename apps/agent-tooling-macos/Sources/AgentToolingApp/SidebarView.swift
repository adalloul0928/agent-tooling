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
    /// Whether Apps shows the apps on this Mac beneath it. Remembered across
    /// launches; the Apps row itself is always there.
    @AppStorage("sidebar.appsExpanded") private var appsExpanded = true
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
                HStack {
                    Text("Agent Tooling")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    appearanceButton
                }

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
        }
        // No background or glass overlay: NavigationSplitView owns the
        // sidebar material, including its adaptive foreground appearance.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation sidebar")
    }

    /// What the app has already read and already checked, turned into at most
    /// one glyph per row.
    ///
    /// Reading the library the sidebar is drawn beside cannot start a scan, and
    /// neither can reading the last check, so a screen with nothing to report
    /// simply carries nothing.
    private var health: SectionHealth {
        .observed(library: workspace.library.state?.library, device: workspace.device)
    }

    /// What the list highlights: a screen, or one app under Apps. The apps are
    /// not a fourth group of screens; an app row is the Apps screen narrowed to
    /// that app, and the highlight moving to it is what says so.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                if selection.sidebarDestination == .syncCenter, let client = navigation.selectedClient {
                    return .client(client)
                }
                return .section(selection.sidebarDestination)
            },
            set: { item in
                switch item {
                case .section(let section): openSection(section)
                case .client(let client): navigation.openClient(client)
                case nil: break
                }
            })
    }

    @ViewBuilder
    private func navigationRows(_ sections: [AppSection]) -> some View {
        ForEach(sections) { section in
            // Only the apps this Mac manages hang under Apps. One it does not
            // is set up from the Apps screen ("Choose apps…") and appears here
            // once it is; until then a row for it would be a row for nothing.
            if section == .syncCenter, !workspace.device.managedClients.isEmpty {
                DisclosureGroup(isExpanded: $appsExpanded) {
                    ForEach(workspace.device.managedClients) { client in
                        clientRow(client)
                    }
                } label: {
                    sectionRow(section)
                }
            } else {
                sectionRow(section)
            }
        }
    }

    private func sectionRow(_ section: AppSection) -> some View {
        HStack {
            Label(section.navigationTitle, systemImage: section.symbol)
            Spacer(minLength: 4)
            if health[section] == .attention {
                StatusGlyph(state: .attention, size: 12)
                    .accessibilityLabel("Needs attention")
            }
        }
        // Apps carries both kinds of attention it can act on: clients the
        // check could not reach and connections the health check found broken.
        .badge(section == .syncCenter ? workspace.device.attentionCount + workspace.health.attentionCount : 0)
        .tag(SidebarItem.section(section))
        .contentShape(Rectangle())
        // Selecting an already-highlighted parent still returns to its
        // main screen, or clears a client scope on the Apps screen.
        .simultaneousGesture(TapGesture().onEnded { openSection(section) })
        .help(section.navigationTitle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(section.navigationTitle)
        .accessibilityAction { openSection(section) }
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

    /// One managed app under Apps. The list's own highlight marks the chosen
    /// one; the glyph is the last check's verdict on it.
    private func clientRow(_ client: ClientKind) -> some View {
        let verdict = workspace.device.verdict(for: client)
        let selected = selection.sidebarDestination == .syncCenter && navigation.selectedClient == client
        return HStack(spacing: 8) {
            ClientBrandIcon(client: client, size: 15)
                .frame(width: 20)
            Text(client.rawValue)
                .lineLimit(1)
            Spacer(minLength: 4)
            StatusGlyph(state: verdict.state, size: 11)
        }
        .tag(SidebarItem.client(client))
        .contentShape(Rectangle())
        // Choosing the highlighted app again keeps it; the Apps row above is
        // the way back to every app.
        .simultaneousGesture(TapGesture().onEnded { navigation.openClient(client) })
        .help("\(client.rawValue) on this Mac. \(verdict.detail)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(client.rawValue)
        .accessibilityValue([selected ? "Selected" : "", verdict.text].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAction { navigation.openClient(client) }
    }
}

/// A row the sidebar list can highlight.
enum SidebarItem: Hashable {
    case section(AppSection)
    case client(ClientKind)
}
