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
        navigation: AppNavigationState? = nil,
        paletteVisible: Bool = false
    ) {
        self.workspace = workspace
        _selection = State(initialValue: initialSection)
        _navigation = State(initialValue: navigation ?? AppNavigationState())
        _paletteVisible = State(initialValue: paletteVisible)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(
                workspace: workspace, selection: $selection,
                openPalette: { paletteVisible = true }
            )
            .allowsHitTesting(!paletteVisible)
            .minuteTicker()
            .navigationSplitViewColumnWidth(min: Size.sidebarMin, ideal: Size.sidebarIdeal, max: Size.sidebarMax)
        } detail: {
            SectionContent(section: selection, workspace: workspace)
                .environment(\.workspaceSelection, selection)
                .environment(\.workspaceNavigate, navigate)
                .environment(\.availableClients, enabledClients)
                // What an Install button needs beyond the library: the planner
                // and executor, each app's status, and the service. With these
                // in the environment, choosing apps and installing is one step.
                .environment(
                    \.installPipeline,
                    InstallPipeline(
                        deployment: workspace.deployment, device: workspace.device,
                        service: workspace.service, homeRoot: workspace.homeRoot)
                )
                // Relative times ("checked 9m ago") re-tick about once a minute
                // here; the launch scan lives on the split view's own `.task`
                // below, outside this wrapper, so a redraw is never a re-scan.
                .minuteTicker()
                // Top, not centre: a screen that does not claim the whole
                // column is a page with space under it, not a card floating in
                // the middle of the window.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(!paletteVisible)
            // No background of its own. The one glass backdrop behind the
            // whole split view is the ground for the sidebar and the
            // content alike — a tint here is exactly what made them differ.
        }
        .navigationSplitViewStyle(.balanced)
        // The window toolbar draws no material of its own; the shared canvas
        // behind the whole split view is the only ground the top strip has.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(WindowBackdropMaterial().ignoresSafeArea())
        .foregroundStyle(.primary)
        .animation(reduceMotion ? nil : AgentMotion.selection, value: sidebarCollapsed)
        .groupBoxStyle(ControlGroupBoxStyle())
        // While the palette is up, the window under it is scenery. Hover
        // tracking on macOS does not respect what is drawn on top, so rows
        // beneath the palette would light up as the pointer crossed them;
        // the hover highlights are switched off here, and each column's
        // content stops taking the pointer (above). The switch sits on the
        // columns' contents, not on the split view: with hit testing off,
        // the split view drops its toolbar inset and the page jumps up
        // under the title bar.
        .environment(\.hoverSuppressed, paletteVisible)
        // Spotlight rules, not sheet rules: the palette floats over the window,
        // a click anywhere outside it puts it away, and Escape does the same
        // (the palette's own onExitCommand). A sheet would swallow the outside
        // click as modal chrome.
        .overlay {
            if paletteVisible {
                ZStack {
                    AgentTheme.scrim
                        .contentShape(Rectangle())
                        .onTapGesture { paletteVisible = false }
                        .accessibilityLabel("Dismiss command palette")
                        .accessibilityAddTraits(.isButton)
                    CommandPaletteView(
                        workspace: workspace,
                        onActivate: { outcome in
                            paletteVisible = false
                            Task { @MainActor in activate(outcome) }
                        },
                        onClose: { paletteVisible = false }
                    )
                    .clipShape(RoundedRectangle.panel)
                    .overlay(
                        RoundedRectangle.panel
                            .strokeBorder(AgentTheme.hairlineStroke, lineWidth: Hairline.width)
                    )
                    .elevation(.palette)
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : AgentMotion.quick, value: paletteVisible)
        // Checking this Mac's apps is a scan, so it starts after the window is
        // up and off this actor. Nothing on screen waits for it.
        .task {
            // Read the library once for every section, and — only when this Mac
            // is set to check its apps on open — check them alongside it. Both
            // run off this actor; neither blocks the shell. The manual Check
            // apps button is unaffected by this choice.
            async let library: Void = workspace.library.refresh()
            if workspace.device.automaticallyCheckHealth {
                async let device: Void = workspace.device.refresh()
                _ = await (library, device)
            } else {
                await library
            }
            // The daily deep dive. The library has been read by now, so the
            // scan has skills to compare against; it runs in the background
            // and the Insights screen shows its answer when it arrives.
            await workspace.insights.runScheduledDeepDiveIfStale(
                options: InsightScanOptions(clients: Set(workspace.device.managedClients)),
                managedClients: workspace.device.managedClients)
            // The weekly checkup, after the deep dive so the two do not both
            // hold the assistant at once. Audit first, fast; review behind it.
            await workspace.setup.runScheduledCheckupIfStale()
            // Updates, on the cadence Settings chose. Kinds set to install
            // automatically are installed here; the rest wait on Home.
            await workspace.updates.checkIfDue()
            // Other Macs. A pass on open, then whenever the library changes
            // here, each time asking the scheduler whether now is a moment.
            await syncPass()
        }
        .onChange(of: workspace.library.lastReceipt?.committedRevisionID) { _, _ in
            // A write landed. Share it, after the burst of writes a single
            // action can make has settled.
            syncAfterWrite?.cancel()
            syncAfterWrite = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await syncPass()
            }
        }
        .onAppear(perform: applyExternalNavigation)
        .onChange(of: navigation.revision) { _, _ in applyExternalNavigation() }
        .onChange(of: workspace.device.enabledClients) { _, _ in
            // A client this Mac stopped managing cannot go on scoping a screen.
            guard let client = navigation.selectedClient, !workspace.device.isEnabled(client) else { return }
            navigation.showAllClients()
        }
        .environment(navigation)
    }

    @State private var syncAfterWrite: Task<Void, Never>?

    /// One scheduled sync pass, then whatever arrived gets installed by
    /// policy. The scheduler decides whether a pass runs at all; this only
    /// makes sure the two halves run in order.
    private func syncPass() async {
        guard let sync = workspace.sync else { return }
        sync.load()
        if sync.statusProvider == nil {
            sync.statusProvider = {
                [
                    weak device = workspace.device, weak library = workspace.library, weak deployment = workspace.deployment,
                    weak accounts = workspace.accounts
                ] in
                await MainActor.run {
                    guard let device, let library, let deployment else { return nil }
                    return PublishedDeviceStatus.current(
                        device: device, library: library, deployment: deployment, accounts: accounts)
                }
            }
        }
        let before = sync.lastArrival
        _ = await sync.runScheduledPass()
        if let arrival = sync.lastArrival, arrival != before {
            await workspace.incoming.review()
        }
    }

    /// What the marks on a row are allowed to show: the apps this Mac manages,
    /// in the registry's own order.
    private var enabledClients: [ClientKind] {
        workspace.device.managedClients
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
                navigation.openScreenRequest(request)
            }
        case .checkApps:
            Task { await workspace.device.refresh() }
        case .checkConnectionHealth:
            navigate(.health)
            Task { await workspace.health.check() }
        case .reviewSync:
            navigation.showAllClients()
            navigation.openScreenRequest(.reviewChanges)
        }
    }
}
