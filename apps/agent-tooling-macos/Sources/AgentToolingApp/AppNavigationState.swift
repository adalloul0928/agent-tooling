import AgentToolingCore
import Foundation
import Observation

@MainActor
@Observable
final class AppNavigationState {
    private(set) var requestedSection: AppSection?
    private(set) var requestedSkillID: String?
    private(set) var requestedMarketplacePackageID: String?
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
            requestedSkillID = nil
            requestedMarketplacePackageID = nil
            skillCreationQueue.removeAll()
        case .skill(let id):
            requestedSection = .skills
            requestedSkillID = id
            requestedMarketplacePackageID = nil
            skillCreationQueue.removeAll()
        case .skillCreationRequest(let id):
            requestedSection = .skills
            requestedSkillID = nil
            requestedMarketplacePackageID = nil
            if !skillCreationQueue.contains(id) {
                skillCreationQueue.append(id)
            }
        }
        revision += 1
    }

    func openMarketplacePackage(_ id: String) {
        guard !id.isEmpty else { return }
        requestedSection = .marketplace
        requestedSkillID = nil
        requestedMarketplacePackageID = id
        skillCreationQueue.removeAll()
        revision += 1
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
