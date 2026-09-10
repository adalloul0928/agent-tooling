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
            requestedSkillID = nil
            requestedItemID = nil
            requestedScreenRequest = nil
            requestedMarketplacePackageID = nil
            pendingRequestQueue.removeAll()
            skillCreationQueue.removeAll()
        case .skill(let id):
            requestedSection = .skills
            requestedSkillID = id
            requestedItemID = nil
            requestedScreenRequest = nil
            requestedMarketplacePackageID = nil
            pendingRequestQueue.removeAll()
            skillCreationQueue.removeAll()
        case .pendingRequest(let id):
            requestedSkillID = nil
            requestedItemID = nil
            requestedScreenRequest = nil
            requestedMarketplacePackageID = nil
            if !pendingRequestQueue.contains(id) {
                pendingRequestQueue.append(id)
            }
        }
        revision += 1
    }

    /// Selects one catalog entry for review. Selecting is not installing, and
    /// nothing downstream of this may treat it as an approval.
    func openMarketplacePackage(_ id: String) {
        guard !id.isEmpty else { return }
        requestedSection = .marketplace
        requestedSkillID = nil
        requestedItemID = nil
        requestedScreenRequest = nil
        requestedMarketplacePackageID = id
        pendingRequestQueue.removeAll()
        revision += 1
    }

    /// Opens one screen with one of its rows named, for the screens that have no
    /// external route of their own. Naming a row reveals it and nothing more.
    func openItem(_ id: String, in section: AppSection) {
        guard !id.isEmpty else { return }
        requestedSection = section
        requestedSkillID = nil
        requestedItemID = id
        requestedScreenRequest = nil
        requestedMarketplacePackageID = nil
        pendingRequestQueue.removeAll()
        skillCreationQueue.removeAll()
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
        requestedSkillID = nil
        requestedItemID = nil
        requestedScreenRequest = request
        requestedMarketplacePackageID = nil
        pendingRequestQueue.removeAll()
        skillCreationQueue.removeAll()
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
        requestedSkillID = nil
        requestedItemID = nil
        requestedScreenRequest = nil
        requestedMarketplacePackageID = nil
        pendingRequestQueue.removeAll()
        skillCreationQueue.removeAll()
        revision += 1
    }

    func showAllClients() {
        selectedClient = nil
        requestedSection = .syncCenter
        requestedSkillID = nil
        requestedItemID = nil
        requestedScreenRequest = nil
        requestedMarketplacePackageID = nil
        pendingRequestQueue.removeAll()
        skillCreationQueue.removeAll()
        revision += 1
    }

    func consumeRequestedSection(_ section: AppSection) {
        guard requestedSection == section else { return }
        requestedSection = nil
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
        requestedSkillID = nil
        requestedItemID = nil
        requestedScreenRequest = nil
        requestedMarketplacePackageID = nil
        if !skillCreationQueue.contains(id) { skillCreationQueue.append(id) }
        revision += 1
    }

    func consumeSkillCreationRequest(_ id: UUID) {
        guard skillCreationQueue.first == id else { return }
        skillCreationQueue.removeFirst()
    }
}

extension AppSection {
    /// External routes outlive the screens they were named for. Two of them now
    /// land somewhere else: what Configurations used to answer — what a scope
    /// requires — is Projects, and Accounts has no screen at all, so its route
    /// stops at the Apps pane rather than at a dead end.
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
        case .accounts: self = .syncCenter
        case .settings: self = .settings
        }
    }
}
