import AgentToolingCore
import SwiftUI

/// The window: three sidebar groups on the left, one section on the right, and
/// one palette over both.
///
/// The shell owns navigation and nothing else. It never reads a session's
/// contents, never decides what a screen may do, and never presents a screen's
/// own sheet; a section that needs to reach another section asks
/// `AppNavigationState`, which is put in the environment here. That is what
/// keeps this file finished while the screens behind it are still arriving.
struct AppShellView: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var navigation: AppNavigationState
    @State private var selection: AppSection
    @State private var paletteVisible = false

    /// `navigation` is supplied when something outside the window — a menu-bar
    /// item, an app command, a link — has to reach the same state the sidebar
    /// reads. Left out, the shell makes its own, which is what a preview or a
    /// render test wants.
    init(
        workspace: WorkspaceLaunch.Workspace,
        initialSection: AppSection = .overview,
        navigation: AppNavigationState? = nil
    ) {
        self.workspace = workspace
        _selection = State(initialValue: initialSection)
        _navigation = State(initialValue: navigation ?? AppNavigationState())
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(
                workspace: workspace, selection: $selection,
                openPalette: { paletteVisible = true }
            )
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            SectionContent(section: selection, workspace: workspace)
                .environment(\.workspaceSelection, selection)
                .environment(\.workspaceNavigate, navigate)
                .environment(\.availableClients, enabledClients)
                // Top, not centre: a screen that does not claim the whole
                // column is a page with space under it, not a card floating in
                // the middle of the window.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AgentTheme.contentBackground, ignoresSafeAreaEdges: [.top, .bottom, .trailing])
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowBackdropMaterial().ignoresSafeArea())
        .foregroundStyle(.primary)
        .animation(reduceMotion ? nil : AgentMotion.selection, value: sidebarCollapsed)
        .groupBoxStyle(ControlGroupBoxStyle())
        .sheet(isPresented: $paletteVisible) {
            CommandPaletteView(
                workspace: workspace,
                onActivate: { outcome in
                    paletteVisible = false
                    // The sheet is still closing; running the outcome on the
                    // next turn keeps a navigation change from racing it.
                    Task { @MainActor in activate(outcome) }
                },
                onClose: { paletteVisible = false })
        }
        // Checking this Mac's apps is a scan, so it starts after the window is
        // up and off this actor. Nothing on screen waits for it.
        .task { await workspace.device.refresh() }
        .onAppear(perform: applyExternalNavigation)
        .onChange(of: navigation.revision) { _, _ in applyExternalNavigation() }
        .onChange(of: workspace.device.enabledClients) { _, _ in
            // A client this Mac stopped managing cannot go on scoping a screen.
            guard let client = navigation.selectedClient, !workspace.device.isEnabled(client) else { return }
            navigation.showAllClients()
        }
        .environment(navigation)
    }

    /// What the marks on a row are allowed to show: the apps this Mac manages,
    /// in the registry's own order.
    private var enabledClients: [ClientKind] {
        workspace.device.availableClients.filter(workspace.device.isEnabled)
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarCollapsed ? .detailOnly : .all },
            set: { sidebarCollapsed = $0 == .detailOnly })
    }

    /// Opening Apps without naming a client always means every client, so the
    /// scope a previous visit left behind never silently narrows a new one.
    private func navigate(_ section: AppSection) {
        if section == .syncCenter {
            navigation.showAllClients()
        } else {
            selection = section
        }
    }

    private func applyExternalNavigation() {
        guard let requested = navigation.requestedSection else { return }
        selection = requested
        navigation.consumeRequestedSection(requested)
    }

    /// A palette result runs the screen's own action. Nothing here writes to a
    /// client: the two actions it can start are a read-only scan and preparing a
    /// plan somebody still has to approve.
    private func activate(_ outcome: CommandPaletteOutcome) {
        switch outcome {
        case .navigate(let section):
            navigate(section)
        case .openClient(let client):
            navigation.openClient(client)
        case .openSkill(let id):
            navigation.open(.skill(id))
        case .screenRequest(let request):
            if let itemID = request.itemID {
                navigation.openItem(itemID, in: request.section)
            } else {
                selection = request.section
            }
        case .checkSetup:
            Task { await workspace.device.refresh() }
        case .reviewSync:
            navigation.showAllClients()
            Task { await workspace.deployment.prepare() }
        }
    }
}
