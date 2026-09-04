import AgentToolingCore
import Foundation
import Observation

@MainActor
@Observable
final class AppNavigationState {
    private(set) var requestedSection: AppSection?
    private(set) var requestedSkillID: String?
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
            requestedMarketplacePackageID = nil
            pendingRequestQueue.removeAll()
            skillCreationQueue.removeAll()
        case .skill(let id):
            requestedSection = .skills
            requestedSkillID = id
            requestedMarketplacePackageID = nil
            pendingRequestQueue.removeAll()
            skillCreationQueue.removeAll()
        case .pendingRequest(let id):
            requestedSkillID = nil
            requestedMarketplacePackageID = nil
            if !pendingRequestQueue.contains(id) {
                pendingRequestQueue.append(id)
            }
        }
        revision += 1
    }

    func openMarketplacePackage(_ id: String) {
        guard !id.isEmpty else { return }
        requestedSection = .marketplace
        requestedSkillID = nil
        requestedMarketplacePackageID = id
        pendingRequestQueue.removeAll()
        revision += 1
    }

    /// Opens the client-facing pane with one durable, exact client scope.
    /// The scope survives navigation until the user explicitly returns to all
    /// clients, while the section request itself remains one-shot.
    func openClient(_ client: ClientKind) {
        selectedClient = client
        requestedSection = .syncCenter
        requestedSkillID = nil
        requestedMarketplacePackageID = nil
        pendingRequestQueue.removeAll()
        skillCreationQueue.removeAll()
        revision += 1
    }

    func showAllClients() {
        selectedClient = nil
        requestedSection = .syncCenter
        requestedSkillID = nil
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

    /// Makes a search-only recommendation available for Marketplace review.
    /// Missing or stale embedded metadata falls back to the Marketplace root;
    /// it never creates an installation plan.
    func openMarketplaceRecommendation(
        _ recommendation: ToolRecommendation,
        using model: AppModel
    ) {
        guard let packageID = recommendation.marketplacePackageID,
            let package = recommendation.marketplacePackage,
            model.retainMarketplaceRecommendation(package, expectedPackageID: packageID)
        else {
            open(.section(.marketplace))
            return
        }
        openMarketplacePackage(packageID)
    }

    func consumePendingRequest(_ id: UUID) {
        guard pendingRequestQueue.first == id else { return }
        pendingRequestQueue.removeFirst()
    }

    func openSkillCreationRequest(_ id: UUID) {
        requestedSection = .skills
        requestedSkillID = nil
        requestedMarketplacePackageID = nil
        if !skillCreationQueue.contains(id) { skillCreationQueue.append(id) }
        revision += 1
    }

    func consumeSkillCreationRequest(_ id: UUID) {
        guard skillCreationQueue.first == id else { return }
        skillCreationQueue.removeFirst()
    }
}

private extension AppSection {
    init(_ section: ExternalAppSection) {
        switch section {
        case .overview: self = .overview
        case .marketplace: self = .marketplace
        case .skills: self = .skills
        case .insights: self = .insights
        case .mcpServers: self = .mcpServers
        case .plugins: self = .plugins
        case .configurations: self = .profiles
        case .sync: self = .syncCenter
        case .activity: self = .activity
        case .accounts: self = .accounts
        case .settings: self = .settings
        }
    }
}
