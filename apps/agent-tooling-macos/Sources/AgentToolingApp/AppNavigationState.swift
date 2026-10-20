import AgentToolingCore
import Foundation
import Observation

/// Everything an outside request can ask the window to reveal, and nothing it
/// can ask the window to do. A route selects a screen, scopes it to one client,
/// or queues a review for a person to look at; approving or executing anything
/// stays on the screen the route landed on.
@MainActor
@Observable
final class AppNavigationState {
    private(set) var requestedSection: AppSection?
    private(set) var requestedSkillID: String?
    /// One row a screen should reveal when it opens, for the screens that have
    /// no route of their own. Revealing is not acting on it: a screen that reads
    /// this scrolls to a row and selects it, and does nothing else.
    private(set) var requestedItemID: String?
    /// A screen-specific instruction that names no row of its own — opening a
    /// sheet, say — for the one screen that owns it. Arriving is not acting:
    /// the screen decides what answering it means, the same way revealing
    /// `requestedItemID` is not selecting an action for that row.
    private(set) var requestedScreenRequest: ScreenRequest?
    private(set) var requestedMarketplacePackageID: String?
    private(set) var selectedClient: ClientKind?
    private var pendingRequestQueue: [UUID] = []
    var requestedPendingRequestID: UUID? { pendingRequestQueue.first }
    private var skillCreationQueue: [UUID] = []
    var requestedSkillCreationID: UUID? { skillCreationQueue.first }
    /// The setup stage a link asked for (`agent-tooling://setup`), which the
    /// shell opens once it is up. Asking opens the stage and nothing more: no
    /// other request and no queue is cleared, so a review another Mac asked
    /// for, or a skill to create, still waits for the screen that answers it.
    private(set) var requestedSetup: SetupEntry?
    private(set) var revision = 0

    @discardableResult
    func open(url: URL) -> Bool {
        guard let route = ExternalAppRoute(url: url) else { return false }
        open(route)
        return true
    }

    func open(_ route: ExternalAppRoute) {
        switch route {
        case .section(let section):
            requestedSection = AppSection(section)
            if requestedSection == .syncCenter {
                selectedClient = nil
            }
            clearRequests()
        case .skill(let id):
            requestedSection = .skills
            clearRequests()
            requestedSkillID = id
        case .pendingRequest(let id):
            // A queued review is additive: it keeps the queues it is joining,
            // so only the one-shot scalar requests are cleared here.
            clearRequests(clearPendingQueue: false, clearSkillCreationQueue: false)
            if !pendingRequestQueue.contains(id) {
                pendingRequestQueue.append(id)
            }
        case .createSkill(let id):
            openSkillCreationRequest(id)
            return
        case .setup:
            // Set up this Mac…: the stage at Your apps, over whatever the
            // window shows. A window of its own, not a screen of this one, so
            // it clears nothing.
            requestedSetup = .rerun
        }
        revision += 1
    }

    /// Resets the one-shot requests a fresh route must not carry with it. The
    /// two queues are FIFO and additive, so a route that is joining one of them
    /// keeps it by passing the matching flag as false; every exclusive route
    /// clears both. Keeping this in one place is what stops the eight callers
    /// from drifting apart over which of these they each remember to reset.
    private func clearRequests(clearPendingQueue: Bool = true, clearSkillCreationQueue: Bool = true) {
        requestedSkillID = nil
        requestedItemID = nil
        requestedScreenRequest = nil
        requestedMarketplacePackageID = nil
        if clearPendingQueue { pendingRequestQueue.removeAll() }
        if clearSkillCreationQueue { skillCreationQueue.removeAll() }
    }

    /// Selects one catalog entry for review. Selecting is not installing, and
    /// nothing downstream of this may treat it as an approval.
    func openMarketplacePackage(_ id: String) {
        guard !id.isEmpty else { return }
        requestedSection = .marketplace
        clearRequests(clearSkillCreationQueue: false)
        requestedMarketplacePackageID = id
        revision += 1
    }

    /// Opens one screen with one of its rows named, for the screens that have no
    /// external route of their own. Naming a row reveals it and nothing more.
    func openItem(_ id: String, in section: AppSection) {
        guard !id.isEmpty else { return }
        requestedSection = section
        clearRequests()
        requestedItemID = id
        revision += 1
    }

    func consumeRequestedItem(_ id: String) {
        guard requestedItemID == id else { return }
        requestedItemID = nil
    }

    /// Opens the screen a request with no row of its own belongs to, and hands
    /// it the request. Landing on the screen is the shell's job, the same as
    /// every other route here; answering the request — opening a sheet, say —
    /// is the screen's, once it consumes it.
    func openScreenRequest(_ request: ScreenRequest) {
        requestedSection = request.section
        clearRequests()
        requestedScreenRequest = request
        revision += 1
    }

    func consumeScreenRequest(_ request: ScreenRequest) {
        guard requestedScreenRequest == request else { return }
        requestedScreenRequest = nil
    }

    /// Opens the client-facing pane with one durable, exact client scope.
    /// The scope survives navigation until the user explicitly returns to all
    /// clients, while the section request itself remains one-shot.
    func openClient(_ client: ClientKind) {
        selectedClient = client
        requestedSection = .syncCenter
        clearRequests()
        revision += 1
    }

    func showAllClients() {
        selectedClient = nil
        requestedSection = .syncCenter
        clearRequests()
        revision += 1
    }

    func consumeRequestedSection(_ section: AppSection) {
        guard requestedSection == section else { return }
        requestedSection = nil
    }

    /// The shell opened the stage a link asked for.
    func consumeSetupRequest() {
        requestedSetup = nil
    }

    /// Drops the section a route asked for, with the one-shot reveals that
    /// came with it: the setup stage's hand-off opens its own section, which
    /// wins over a link queued while setup ran. Neither queue is cleared, so a
    /// review another Mac asked for, or a skill to create, still waits for the
    /// screen that answers it.
    ///
    /// A setup link queued while setup ran goes with the section: the stage
    /// it asked for is the one handing off, and the shell the hand-off opens
    /// would otherwise open it again.
    func discardRequestedSection() {
        requestedSection = nil
        requestedSetup = nil
        clearRequests(clearPendingQueue: false, clearSkillCreationQueue: false)
    }

    /// Shows `section` in a shell that is already open: the hand-off back
    /// from a stage opened over it. A reveal, nothing more; no queue or
    /// request is cleared.
    func reveal(_ section: AppSection) {
        requestedSection = section
        revision += 1
    }

    func consumeMarketplacePackage(_ id: String) {
        guard requestedMarketplacePackageID == id else { return }
        requestedMarketplacePackageID = nil
    }

    func consumePendingRequest(_ id: UUID) {
        guard pendingRequestQueue.first == id else { return }
        pendingRequestQueue.removeFirst()
    }

    func openSkillCreationRequest(_ id: UUID) {
        requestedSection = .skills
        // A creation request joins its own FIFO queue, so neither queue is
        // cleared; only the one-shot scalar requests are.
        clearRequests(clearPendingQueue: false, clearSkillCreationQueue: false)
        if !skillCreationQueue.contains(id) { skillCreationQueue.append(id) }
        revision += 1
    }

    func consumeSkillCreationRequest(_ id: UUID) {
        guard skillCreationQueue.first == id else { return }
        skillCreationQueue.removeFirst()
    }
}

extension AppSection {
    /// External routes outlive the screens they were named for. One of them now
    /// lands somewhere else: what Configurations used to answer — what a scope
    /// requires — is Projects. Accounts is a tab of Apps again.
    fileprivate init(_ section: ExternalAppSection) {
        switch section {
        case .overview: self = .overview
        case .marketplace: self = .marketplace
        case .skills: self = .skills
        case .insights: self = .insights
        case .mcpServers: self = .mcpServers
        case .plugins: self = .plugins
        case .configurations: self = .projects
        case .sync: self = .syncCenter
        case .activity: self = .activity
        case .accounts: self = .accounts
        case .settings: self = .settings
        case .checkup: self = .checkup
        }
    }
}
