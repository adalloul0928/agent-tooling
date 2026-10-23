import AgentToolingCore
import AppKit
import Observation
import SwiftUI

/// Distinct SwiftUI scene IDs and AppKit window identifiers keep setup and Home
/// separate when handling links and Dock clicks.
enum AppWindow: String, Sendable {
    case main
    case setup

    var sceneID: String { rawValue }

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("agent-tooling-\(rawValue)")
    }

    /// The window on screen now, if there is one.
    @MainActor var window: NSWindow? {
        NSApp?.windows.first { $0.identifier == identifier }
    }
}

/// Whether a window opens by itself when the app launches.
enum LaunchPresence: Equatable, Sendable {
    /// As SwiftUI decides: the main window opens.
    case automatic
    /// Opens at launch.
    case presented
    /// Stays closed until something opens it.
    case suppressed

    var sceneBehavior: SceneLaunchBehavior {
        switch self {
        case .automatic: .automatic
        case .presented: .presented
        case .suppressed: .suppressed
        }
    }
}

/// Opens one of the app's windows. A window's root makes one from its
/// `openWindow`; a test makes one that records what it was asked to open.
@MainActor
struct WindowOpener {
    private let open: @MainActor (AppWindow) -> Void

    init(_ open: @escaping @MainActor (AppWindow) -> Void) {
        self.open = open
    }

    init(_ action: OpenWindowAction) {
        self.init { action(id: $0.sceneID) }
    }

    func callAsFunction(_ window: AppWindow) {
        open(window)
    }
}

/// Probes locator, setup progress and interrupted joins before windows draw,
/// without opening a store.
@MainActor
struct LaunchProbe {
    var recordState: (URL?) -> WorkspaceLaunch.RecordState
    /// The setup record in a workspace's container.
    var progress: (URL) -> SetupProgressRecord?
    /// The one join container a stopped join left in the support folder, if
    /// there is exactly one.
    var orphanJoin: (URL?) -> WorkspaceObjectID?

    static var live: LaunchProbe {
        LaunchProbe(
            recordState: { WorkspaceLaunch.recordState(supportRoot: $0) },
            progress: { LiveSetupProgressStore(container: $0).load() },
            orphanJoin: { AppLaunchState.orphanedJoin(supportRoot: $0) })
    }
}

/// Injectable application and window effects, with recording substitutes for tests.
@MainActor
struct LaunchSystem {
    var terminate: @MainActor () -> Void
    var reveal: @MainActor ([URL]) -> Void
    var activate: @MainActor () -> Void
    /// Raises visible or minimized windows. Closed windows require `openWindow`.
    var bringForward: @MainActor (AppWindow) -> Bool
    /// Closes the key window the way its close button would.
    var closeKeyWindow: @MainActor () -> Void
    /// Closes a completed presentation without invoking its close-button confirmation.
    var closeWindow: @MainActor (AppWindow) -> Void
    /// Whether the key window is a sheet, which ⌘W closes as a sheet rather
    /// than as the window it holds.
    var keyWindowIsSheet: @MainActor () -> Bool

    static var live: LaunchSystem {
        LaunchSystem(
            terminate: { NSApp.terminate(nil) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting($0) },
            activate: { NSApp.activate() },
            bringForward: { role in
                guard let window = role.window, window.isVisible || window.isMiniaturized else { return false }
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                return true
            },
            closeKeyWindow: { NSApp.keyWindow?.performClose(nil) },
            closeWindow: { $0.window?.close() },
            keyWindowIsSheet: { NSApp.keyWindow?.sheetParent != nil })
    }
}

/// Coordinates shared windows, navigation, and launch state. The synchronous record
/// probe selects setup or the main window before scenes draw. Existing libraries
/// open independently of window tasks; this coordinator never creates one.
/// Hand-off saves progress, changes phase, opens the main window, then dismisses
/// setup. Unreadable records show recovery options instead of creating a library.
@MainActor @Observable
final class AppLaunchState {
    enum Phase: Equatable, Sendable {
        /// The setup stage owns the app: a first run, or one carrying on.
        case setup
        /// The library is being opened for the main window.
        case opening
        /// The main window owns the app.
        case ready
        /// The library could not be opened, and why.
        case failed(String)
        /// The library record could not be read; the stage says why.
        case unreadable(UnreadableReason)
    }

    enum UnreadableReason: Equatable, Sendable {
        /// A newer Agent Tooling wrote the record.
        case newerFormat
        /// The record is not one any Agent Tooling writes.
        case damaged
        /// The record could not be read from disk, with the reason.
        case io(String)
    }

    /// What quitting waits for (plan §2.6).
    enum TerminationPlan: Equatable, Sendable {
        /// Nothing is running: quit now.
        case now
        /// Something stoppable is running: stop it, keeping nothing, then quit.
        case afterStopping
        /// Something is past the point where stopping would leave half a
        /// change: wait it out, with no limit, then quit.
        case afterFinishing
    }

    /// The section a new shell opens on and the hints its launch work reads,
    /// as the main window takes them once.
    struct ShellStart: Equatable, Sendable {
        var section: AppSection
        var hints: ShellLaunchHints
    }

    /// The running app's launch state, for the application delegate, which
    /// SwiftUI makes before anything can hand it one.
    static weak var active: AppLaunchState?

    let context: LaunchContext
    /// One resolved defaults store shared by app preferences and every scene.
    let defaults: UserDefaults
    /// The one queue of outside requests the shell, the menu-bar item, the
    /// app's commands and links all reach.
    let navigation: AppNavigationState
    /// What the stage reads, commits and joins through.
    let environment: LaunchpadEnvironment

    private(set) var phase: Phase {
        didSet { updateAutomaticSync() }
    }
    /// The library, once it is open: from the launch, or from the stage's
    /// commit point, which hands it over while the phase stays `setup`.
    private(set) var workspace: WorkspaceLaunch.Workspace? {
        didSet {
            if oldValue?.sync !== workspace?.sync { oldValue?.sync?.stopAutomaticSync() }
            updateAutomaticSync()
        }
    }
    /// Persists across stage-window closure during setup; re-entry creates a new flow.
    private(set) var flow: LaunchpadFlow?
    /// A fresh presentation never inherits a retained window's previous fade.
    private(set) var stagePresentationID = UUID()
    /// The entry the flow was, or is next to be, made for.
    private(set) var pendingEntry: SetupEntry
    private(set) var isStageOpen = false {
        didSet { updateAutomaticSync() }
    }
    private(set) var isStageKey = false
    /// Whether a shell is up in the main window.
    private(set) var isShellOpen = false
    /// Where the next shell opens, set by the hand-off.
    private(set) var handOffSection: AppSection?
    /// What the next shell's launch work reads once.
    private(set) var shellLaunchHints = ShellLaunchHints()

    private let probe: LaunchProbe
    private let system: LaunchSystem
    @ObservationIgnored private var opening: Task<Void, Never>?
    /// Retains a root-provided opener for Dock events, links and delegate callbacks.
    @ObservationIgnored private var windowOpener: WindowOpener?

    /// Decides who owns the launch, synchronously, and starts opening the
    /// library when the decision needs it.
    init(
        context: LaunchContext, environment: LaunchpadEnvironment, probe: LaunchProbe = .live,
        navigation: AppNavigationState = AppNavigationState(), system: LaunchSystem = .live
    ) {
        self.context = context
        defaults = context.defaults
        self.environment = environment
        self.probe = probe
        self.navigation = navigation
        self.system = system
        let decision = Self.decide(
            probe.recordState(context.workspaceRoot), progress: probe.progress,
            orphanJoin: { probe.orphanJoin(context.workspaceRoot) })
        phase = decision.phase
        pendingEntry = decision.entry
        makeLaunchFlowIfReady()
        startOpeningIfNeeded()
    }

    /// The app as it launches: the stage's live environment, with a
    /// rehearsal's installation override applied over what inspection finds.
    static func live(context: LaunchContext) -> AppLaunchState {
        var environment = LaunchpadEnvironment.live(context: context)
        let inspect = environment.installation
        environment.installation = { context.installation(inspected: inspect()) }
        return AppLaunchState(context: context, environment: environment)
    }

    // MARK: - The decision

    /// What a launch does, from what the probe found (plan §2.1).
    ///
    /// | workspace.json | other evidence | phase | entry |
    /// |---|---|---|---|
    /// | absent | no orphan | setup | firstRun |
    /// | absent | one orphan join container | setup | finishJoin |
    /// | newer, damaged or unreadable | — | unreadable | — |
    /// | present | setup record in progress | setup | continueFirstRun |
    /// | present | any other record, or none | opening | — |
    static func decide(
        _ record: WorkspaceLaunch.RecordState, progress: (URL) -> SetupProgressRecord?,
        orphanJoin: () -> WorkspaceObjectID?
    ) -> (phase: Phase, entry: SetupEntry) {
        switch record {
        case .none:
            if let orphan = orphanJoin() { return (.setup, .finishJoin(orphan)) }
            return (.setup, .firstRun)
        case .newerFormat:
            return (.unreadable(.newerFormat), .firstRun)
        case .damaged:
            return (.unreadable(.damaged), .firstRun)
        case .unreadable(let reason):
            return (.unreadable(.io(reason)), .firstRun)
        case .present(_, let container):
            guard let record = progress(container), record.state == .inProgress else { return (.opening, .firstRun) }
            return (.setup, .continueFirstRun(resumeStep(record)))
        }
    }

    /// Resumes at the saved cursor, advancing pre-commit cursors past creation
    /// when the library already exists.
    static func resumeStep(_ record: SetupProgressRecord) -> LaunchpadStep {
        let firstAfterCommit: LaunchpadStep = record.path == .join ? .arrivals : .found
        guard let cursor = record.cursor, cursor.isPostCommit else { return firstAfterCommit }
        return cursor
    }

    /// Finds exactly one interrupted join with an in-progress setup record.
    /// Zero or multiple candidates fall back to first run.
    nonisolated static func orphanedJoin(supportRoot: URL?) -> WorkspaceObjectID? {
        guard let root = supportRoot?.standardizedFileURL ?? (try? WorkspaceLocator.defaultRoot()) else { return nil }
        let workspaces = root.appending(path: "workspaces-v1", directoryHint: .isDirectory)
        guard
            let folders = try? FileManager.default.contentsOfDirectory(
                at: workspaces, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return nil }
        let orphans = folders.compactMap { folder -> WorkspaceObjectID? in
            let name = folder.lastPathComponent
            guard let id = UUID(uuidString: name), name == id.uuidString.lowercased(),
                let record = LiveSetupProgressStore(container: folder).load(),
                record.state == .inProgress, record.path == .join
            else { return nil }
            return WorkspaceObjectID(rawValue: id)
        }
        return orphans.count == 1 ? orphans.first : nil
    }

    // MARK: - What the windows read

    /// Whether the setup stage owns the app: the main window stays closed and
    /// the menu-bar item offers only Show Setup and Quit.
    var ownsLaunch: Bool {
        switch phase {
        case .setup, .unreadable: true
        case .opening, .ready, .failed: false
        }
    }

    var mainPresence: LaunchPresence { ownsLaunch ? .suppressed : .automatic }
    var stagePresence: LaunchPresence { ownsLaunch ? .presented : .suppressed }
    var mainLaunchBehavior: SceneLaunchBehavior { mainPresence.sceneBehavior }
    var stageLaunchBehavior: SceneLaunchBehavior { stagePresence.sceneBehavior }

    /// The library once the main window owns the app; nil until then.
    var readyWorkspace: WorkspaceLaunch.Workspace? { phase == .ready ? workspace : nil }

    /// The library the app's commands act on: nil while setup owns the app
    /// and while the stage is the key window, so ⇧⌘R, ⇧⌘D and ⌃⌘S never
    /// reach past the stage.
    var commandWorkspace: WorkspaceLaunch.Workspace? { isStageKey ? nil : readyWorkspace }

    /// The stage is open over a live shell: the shell holds its
    /// write-triggered sync and incoming review until it closes.
    var stagePresentedOverShell: Bool { phase == .ready && isStageOpen }

    /// The stage has nothing of its own to show: the main window owns the app
    /// and no re-entry is under way. A stage window open now hands over to
    /// the main window.
    var stageHasNothingToShow: Bool { !ownsLaunch && flow == nil }

    /// Where a new shell opens: the hand-off's section, else the launch's.
    var initialSection: AppSection {
        handOffSection ?? context.request?.section ?? context.section ?? .overview
    }

    var shellStart: ShellStart { ShellStart(section: initialSection, hints: shellLaunchHints) }

    /// The folder the library record lives in.
    var supportFolder: URL? {
        context.workspaceRoot ?? (try? WorkspaceLocator.defaultRoot())
    }

    /// What the unreadable screen's buttons do.
    var unreadableActions: LaunchpadUnreadableScreen.Actions {
        LaunchpadUnreadableScreen.Actions(
            quit: { [weak self] in self?.quit() },
            showInFinder: { [weak self] in self?.showSupportFolder() },
            tryAgain: { [weak self] in
                guard let self else { return }
                Task { await self.tryAgain() }
            })
    }

    // MARK: - Opening the library

    /// Opens an existing library and shares any in-flight open. Creation belongs
    /// to the setup stage.
    func openExisting() async {
        if let opening {
            await opening.value
            return
        }
        guard needsOpening else { return }
        let task = Task { await performOpen() }
        opening = task
        await task.value
        opening = nil
    }

    /// Setup owns its writes until hand-off. Once ready, the workspace keeps
    /// syncing even when no Settings pane or main window is mounted.
    private func updateAutomaticSync() {
        guard phase == .ready, !isStageOpen, let workspace else {
            workspace?.sync?.stopAutomaticSync()
            return
        }
        workspace.installSyncStatusProvider()
        let incoming = workspace.incoming
        workspace.sync?.startAutomaticSync(onArrival: { [weak incoming] in await incoming?.review() })
    }

    /// The unreadable screen's and the failure screen's Try again: reads the
    /// record again and does what it now says.
    func tryAgain() async {
        switch phase {
        case .failed, .unreadable: break
        case .setup, .opening, .ready: return
        }
        await opening?.value
        let decision = Self.decide(
            probe.recordState(context.workspaceRoot), progress: probe.progress,
            orphanJoin: { probe.orphanJoin(context.workspaceRoot) })
        phase = decision.phase
        pendingEntry = decision.entry
        flow = nil
        workspace = nil
        makeLaunchFlowIfReady()
        await openExisting()
    }

    private var needsOpening: Bool {
        switch phase {
        case .opening, .failed: true
        case .setup:
            if case .continueFirstRun = pendingEntry { flow == nil } else { false }
        case .ready, .unreadable: false
        }
    }

    private func startOpeningIfNeeded() {
        guard needsOpening else { return }
        opening = Task { [weak self] in
            await self?.performOpen()
            self?.opening = nil
        }
    }

    private func performOpen() async {
        let carriesOn = phase == .setup
        if case .failed = phase { phase = .opening }
        do {
            let opened = try await WorkspaceLaunch.open(
                supportRoot: context.workspaceRoot, homeRoot: environment.homeURL, services: environment.sessions)
            workspace = opened
            if carriesOn {
                flow = LaunchpadFlow(entry: pendingEntry, environment: environment, workspace: opened)
            } else {
                phase = .ready
                // A launch that names a screen request arrives with it already
                // asked for, so the section it opens on consumes it.
                if let request = context.request { navigation.openScreenRequest(request) }
            }
        } catch {
            workspace = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// The stage's walk for a launch that owns the app and needs no library
    /// opened first: a first run, or a join to finish.
    private func makeLaunchFlowIfReady() {
        guard phase == .setup, flow == nil else { return }
        switch pendingEntry {
        case .firstRun, .finishJoin:
            flow = LaunchpadFlow(entry: pendingEntry, environment: environment)
        case .continueFirstRun, .resume, .rerun, .revisit:
            break
        }
    }

    // MARK: - The stage

    /// Opens or raises setup without replacing a flow already shown or owning launch.
    func presentStage(_ entry: SetupEntry, openWindow: WindowOpener) {
        remember(openWindow)
        switch phase {
        case .opening, .failed:
            return
        case .setup, .unreadable:
            break
        case .ready:
            guard let workspace else { return }
            if flow == nil || flow?.pendingHandOff != nil {
                let ended = flow
                pendingEntry = entry
                stagePresentationID = UUID()
                flow = LaunchpadFlow(entry: entry, environment: environment, workspace: workspace)
                if let ended { Task { await ended.prepareToQuit() } }
            }
        }
        show(.setup)
        system.activate()
    }

    /// The library the stage's commit point made or joined, handed over while
    /// setup still owns the app.
    func didCommit(_ workspace: WorkspaceLaunch.Workspace) {
        guard phase == .setup else { return }
        self.workspace = workspace
    }

    /// Hands the flow's workspace to the shell after progress was saved. The chosen
    /// section overrides queued navigation; pending review and creation requests remain.
    /// Launch checks are skipped only when this setup flow already read and audited
    /// apps in the current launch.
    func handOff(to section: AppSection, openWindow: WindowOpener) {
        guard let handed = flow?.workspace ?? workspace else { return }
        workspace = handed
        navigation.discardRequestedSection()
        if isShellOpen {
            navigation.reveal(section)
        } else {
            handOffSection = section
            shellLaunchHints = ShellLaunchHints(justHandedOff: flow?.hasReadTheApps ?? false)
        }
        phase = .ready
        remember(openWindow)
        show(.main)
        system.activate()
    }

    /// SwiftUI dismissal presses the intercepted close button. A completed
    /// hand-off closes the native window directly instead of asking again.
    func closeStage(presentationID: UUID) {
        guard stagePresentationID == presentationID else { return }
        system.closeWindow(.setup)
    }

    /// The stage's ⌘W and red close button: FooterConfirm, the review
    /// panel's Cancel, or, on the unreadable screen, where nothing is left to
    /// do but quit, Quit Agent Tooling.
    func requestStageClose() {
        if let flow {
            flow.requestClose()
        } else if case .unreadable = phase {
            quit()
        }
    }

    /// Closes an active sheet before prompting to close setup. Other windows close normally.
    func closeKeyWindow() {
        if isStageKey, !system.keyWindowIsSheet() {
            requestStageClose()
        } else {
            system.closeKeyWindow()
        }
    }

    /// Quit Agent Tooling, and FooterConfirm's Quit setup, before the commit
    /// point, where nothing is on disk. Quitting waits for what is running
    /// (`terminationPlan()`).
    func quit() {
        system.terminate()
    }

    func stageAppeared(openWindow: WindowOpener) {
        isStageOpen = true
        remember(openWindow)
    }

    /// Cancels and discards a closed re-entry flow; retains the flow owning first run.
    func stageDisappeared(presentationID: UUID? = nil) {
        guard presentationID == nil || presentationID == stagePresentationID else { return }
        isStageOpen = false
        isStageKey = false
        guard phase == .ready, let ended = flow else { return }
        flow = nil
        Task { await ended.prepareToQuit() }
    }

    /// Whether the stage, or a sheet or child window over it, is the key
    /// window, as its window reports it.
    func stageKeyChanged(_ isKey: Bool) {
        if isKey { isStageOpen = true }
        guard isStageKey != isKey else { return }
        isStageKey = isKey
    }

    /// A link that arrived while setup owns the app: it waits in the queue
    /// for the shell, and the stage comes forward.
    func queueLinkDuringSetup(_ url: URL) {
        _ = navigation.open(url: url)
        show(.setup)
        system.activate()
    }

    /// A link the main window received: the shell reveals what it names.
    func openLink(_ url: URL) {
        guard !ownsLaunch else {
            queueLinkDuringSetup(url)
            return
        }
        guard navigation.open(url: url) else { return }
        bringMainForward()
    }

    /// Raises or reopens Home using the supplied opener, which remains available
    /// when no window root is active.
    func bringMainForward(openWindow: WindowOpener? = nil) {
        if let openWindow { remember(openWindow) }
        show(.main)
        system.activate()
    }

    /// Show in Finder: the support folder, with the record selected.
    func showSupportFolder() {
        guard let supportFolder else { return }
        system.reveal([supportFolder.appending(path: WorkspaceLocator.recordFileName)])
    }

    // MARK: - The main window

    /// The main window's root appeared, on any launch: its `openWindow` is
    /// kept for the Dock and links, so a main window the person closes later
    /// opens again.
    func mainAppeared(openWindow: WindowOpener) {
        remember(openWindow)
    }

    /// A shell is up. The hints and section it opened with are its own now,
    /// so a later shell, after the main window is closed and opened again,
    /// opens as any other would.
    func shellAppeared() {
        isShellOpen = true
        consumeShellLaunchHints()
    }

    func shellDisappeared() {
        isShellOpen = false
    }

    func consumeShellLaunchHints() {
        shellLaunchHints = ShellLaunchHints()
        handOffSection = nil
    }

    /// The menu-bar item's and the main menu's Review Changes…: Apps, with a
    /// plan on it. Preparing is not applying; writing anything is still a
    /// decision made there.
    func reviewChanges(openWindow: WindowOpener? = nil) {
        guard readyWorkspace != nil else { return }
        navigation.showAllClients()
        navigation.openScreenRequest(.reviewChanges)
        bringMainForward(openWindow: openWindow)
    }

    /// The menu-bar item's and the main menu's Check Apps.
    func checkApps() {
        guard let workspace = readyWorkspace else { return }
        Task { await workspace.device.refresh() }
    }

    // MARK: - The Dock and quitting

    /// Raises setup while it owns launch; otherwise opens Home. Returns true only
    /// when SwiftUI must supply a fallback reopen because no opener was available.
    func reopen(hasVisibleWindows: Bool) -> Bool {
        if ownsLaunch {
            guard show(.setup) else { return true }
            system.activate()
            return false
        }
        guard !hasVisibleWindows else { return true }
        guard show(.main) else { return true }
        system.activate()
        return false
    }

    /// What ⌘Q, the menu-bar item's Quit and the Dock's Quit wait for.
    func terminationPlan() -> TerminationPlan {
        switch flow?.interruption ?? .idle {
        case .idle: .now
        case .stoppable: .afterStopping
        case .finishing: .afterFinishing
        }
    }

    /// Cancels stoppable work within one grace, then awaits finishing writes without
    /// a time limit. A cancellation can race with a commit starting, and that commit
    /// can leave sign-in reads running, so check for finishing work before stopping
    /// its remaining reads. Work that already used its grace is not waited on twice.
    func prepareToTerminate(_ plan: TerminationPlan) async {
        guard plan != .now, let flow else { return }
        await flow.prepareToQuit()
        // Read as the wait begins, with nothing between: whether there is
        // finishing work for `finishPendingWork` to wait out.
        let finishing = flow.interruption.isFinishing
        await flow.finishPendingWork()
        if finishing { await flow.prepareToQuit() }
    }

    // MARK: - The menu-bar item

    /// The menu-bar item, top to bottom, for the phase the app is in.
    var menuBarItems: [MenuBarItem] {
        Self.menuBarItems(
            for: phase, checking: readyWorkspace?.device.isChecking ?? false,
            preparing: readyWorkspace?.deployment.isBusy ?? false)
    }

    /// Menu-bar state follows launch phase and disables actions during active work.
    static func menuBarItems(for phase: Phase, checking: Bool = false, preparing: Bool = false) -> [MenuBarItem] {
        switch phase {
        case .setup, .unreadable:
            [.showSetup, .divider, .quit]
        case .opening:
            [.opening, .divider, .quit]
        case .failed:
            [.couldNotOpen, .tryAgain, .divider, .quit]
        case .ready:
            [
                .openAgentTooling, .divider, .checkApps(checking: checking), .reviewChanges(preparing: preparing), .divider,
                .quit,
            ]
        }
    }

    private func remember(_ opener: WindowOpener) {
        windowOpener = opener
    }

    /// Brings `window` forward, or, when it is not showing, opens it through
    /// the last `openWindow` handed in. Says whether either happened.
    @discardableResult
    private func show(_ window: AppWindow) -> Bool {
        if system.bringForward(window) { return true }
        guard let windowOpener else { return false }
        windowOpener(window)
        return true
    }
}
