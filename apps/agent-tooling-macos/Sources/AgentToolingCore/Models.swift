import Foundation

public enum HealthState: String, Codable, CaseIterable, Sendable {
    case healthy
    case attention
    case pending
    case unavailable
}

public enum ClientKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude Code"
    case gemini = "Gemini CLI"

    public var id: String { rawValue }
}

public enum SkillAuthoringOrigin: String, Codable, Hashable, Sendable {
    case manual
    case codexGenerated
    case externalAdopted
}

public struct ClientState: Identifiable, Codable, Hashable, Sendable {
    public var id: ClientKind { client }
    public let client: ClientKind
    public var state: HealthState
    public var detail: String
    public var revision: String?
    /// Explicit observed presence. `nil` preserves compatibility with older
    /// desired-state records that only modeled health.
    public var isInstalled: Bool?

    public init(
        client: ClientKind,
        state: HealthState,
        detail: String,
        revision: String? = nil,
        isInstalled: Bool? = nil
    ) {
        self.client = client
        self.state = state
        self.detail = detail
        self.revision = revision
        self.isInstalled = isInstalled
    }

    public var reportsLocalPresence: Bool { isInstalled ?? (state == .healthy) }
}

public struct Skill: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var displayName: String
    public var summary: String
    public var bundle: String
    public var scope: String
    public var projectRoot: String?
    public var owned: Bool
    public var triggers: [String]
    public var negativeTrigger: String
    public var files: [String]
    public var clients: [ClientState]
    public var validationCount: Int
    /// Older snapshots omit this field. Generated packages use it to avoid
    /// passing rich source through the lossy template editor.
    public var authoringOrigin: SkillAuthoringOrigin?

    public init(
        id: String,
        name: String,
        displayName: String,
        summary: String,
        bundle: String,
        scope: String,
        owned: Bool,
        triggers: [String],
        negativeTrigger: String,
        files: [String],
        clients: [ClientState],
        validationCount: Int,
        projectRoot: String? = nil,
        authoringOrigin: SkillAuthoringOrigin? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.summary = summary
        self.bundle = bundle
        self.scope = scope
        self.projectRoot = projectRoot
        self.owned = owned
        self.triggers = triggers
        self.negativeTrigger = negativeTrigger
        self.files = files
        self.clients = clients
        self.validationCount = validationCount
        self.authoringOrigin = authoringOrigin
    }
}

public enum MCPTransport: String, Codable, CaseIterable, Sendable {
    case http = "HTTP"
    case stdio = "stdio"
}

public enum MCPDefinitionOrigin: String, Codable, Sendable {
    case managed
    case observed
}

public struct MCPServer: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var summary: String
    public var endpoint: String
    public var transport: MCPTransport
    public var authentication: String
    public var scope: String
    public var projectRoot: String?
    public var clients: [ClientState]
    public var repairCommand: String?
    public var secretNames: [String]
    /// Optional for backward compatibility with snapshots created before
    /// provenance was modeled explicitly.
    public var definitionOrigin: MCPDefinitionOrigin?

    public init(
        id: String,
        name: String,
        summary: String,
        endpoint: String,
        transport: MCPTransport,
        authentication: String,
        scope: String,
        projectRoot: String? = nil,
        clients: [ClientState],
        repairCommand: String? = nil,
        secretNames: [String] = [],
        definitionOrigin: MCPDefinitionOrigin = .observed
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.endpoint = endpoint
        self.transport = transport
        self.authentication = authentication
        self.scope = scope
        self.projectRoot = projectRoot
        self.clients = clients
        self.repairCommand = repairCommand
        self.secretNames = secretNames
        self.definitionOrigin = definitionOrigin
    }

    public var isManagedDefinition: Bool {
        definitionOrigin == .managed
            || (definitionOrigin == nil && summary == "Desired local MCP configuration")
    }

    public var aggregateState: HealthState {
        if clients.contains(where: { $0.state == .attention }) { return .attention }
        if clients.contains(where: { $0.state == .healthy }) { return .healthy }
        if clients.contains(where: { $0.state == .pending }) { return .pending }
        return .unavailable
    }
}

public struct Plugin: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var summary: String
    public var source: String
    public var scope: String
    public var revision: String
    public var skills: [String]
    public var profiles: [String]
    public var clients: [ClientState]
    public var installed: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        source: String,
        scope: String,
        revision: String,
        skills: [String],
        profiles: [String],
        clients: [ClientState],
        installed: Bool
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.source = source
        self.scope = scope
        self.revision = revision
        self.skills = skills
        self.profiles = profiles
        self.clients = clients
        self.installed = installed
    }
}

public struct ProfileCheck: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var detail: String
    public var state: HealthState
    public var manual: Bool

    public init(id: String, name: String, detail: String, state: HealthState, manual: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.state = state
        self.manual = manual
    }
}

public struct ToolingProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var summary: String
    public var inheritedFrom: String?
    public var scope: ToolingScope
    public var projectRoot: String?
    public var checks: [ProfileCheck]
    public var enabledPlugins: [String]
    public var requiredMCPs: [String]
    /// Skills this configuration expects. Older snapshots predate the field
    /// and decode as empty.
    public var requiredSkills: [String]
    /// Collections this configuration builds on. A Collection is material,
    /// not a contract: including one widens the required list below, and
    /// changes desired state only until a plan is reviewed and synced.
    public var includedCollections: [String]

    public init(
        id: String,
        name: String,
        summary: String,
        inheritedFrom: String? = nil,
        scope: ToolingScope = .user,
        projectRoot: String? = nil,
        checks: [ProfileCheck],
        enabledPlugins: [String],
        requiredMCPs: [String],
        requiredSkills: [String] = [],
        includedCollections: [String] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.inheritedFrom = inheritedFrom
        self.scope = scope
        self.projectRoot = projectRoot
        self.checks = checks
        self.enabledPlugins = enabledPlugins
        self.requiredMCPs = requiredMCPs
        self.requiredSkills = requiredSkills
        self.includedCollections = includedCollections
    }

    public var passingChecks: Int { checks.filter { $0.state == .healthy }.count }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, inheritedFrom, scope, projectRoot, checks, enabledPlugins, requiredMCPs, requiredSkills,
            includedCollections
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        inheritedFrom = try container.decodeIfPresent(String.self, forKey: .inheritedFrom)
        scope = try container.decodeIfPresent(ToolingScope.self, forKey: .scope) ?? .user
        projectRoot = try container.decodeIfPresent(String.self, forKey: .projectRoot)
        checks = try container.decodeIfPresent([ProfileCheck].self, forKey: .checks) ?? []
        enabledPlugins = try container.decodeIfPresent([String].self, forKey: .enabledPlugins) ?? []
        requiredMCPs = try container.decodeIfPresent([String].self, forKey: .requiredMCPs) ?? []
        requiredSkills = try container.decodeIfPresent([String].self, forKey: .requiredSkills) ?? []
        includedCollections = try container.decodeIfPresent([String].self, forKey: .includedCollections) ?? []
    }
}

public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case sync
    case validation
    case authentication
    case configuration
    case publication
}

public struct ActivityReceipt: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var kind: ActivityKind
    public var title: String
    public var detail: String
    public var date: Date
    public var state: HealthState
    public var command: String?
    public var duration: TimeInterval?
    public var affectedPaths: [String]
    /// Links back to the operation receipt that produced this entry so the
    /// Activity detail can itemize every step instead of showing one aggregate
    /// verdict. Optional: entries that did not come from a plan have none, and
    /// records written before this field existed decode as `nil`.
    public var operationReceiptID: UUID?

    public init(
        id: UUID = UUID(),
        kind: ActivityKind,
        title: String,
        detail: String,
        date: Date,
        state: HealthState,
        command: String? = nil,
        duration: TimeInterval? = nil,
        affectedPaths: [String] = [],
        operationReceiptID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.date = date
        self.state = state
        self.command = command
        self.duration = duration
        self.affectedPaths = affectedPaths
        self.operationReceiptID = operationReceiptID
    }

    /// Keeps receipts created by early alpha builds readable without rewriting
    /// immutable history in the workspace database.
    public var displayTitle: String {
        title == "Reality scan completed" ? "Setup check completed" : title
    }
}

public enum SyncStageState: String, Codable, CaseIterable, Sendable {
    case waiting
    case running
    case complete
    case attention
}

public struct SyncStage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var detail: String
    public var symbol: String
    public var state: SyncStageState

    public init(id: String, title: String, detail: String, symbol: String, state: SyncStageState) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.state = state
    }
}

public struct SkillDraft: Sendable, Equatable {
    public var name = ""
    public var purpose = ""
    public var triggers: [String] = ["", "", ""]
    public var negativeTrigger = ""
    public var includeScript = false
    public var includeReference = false
    /// Git export is intentionally optional. A new user can create and install
    /// a skill without creating a repository or an account.
    public var syncClients = true
    public var runCanary = true
    public var selectedTargets: Set<ClientKind> = Set(ClientKind.allCases)
    public var scope: ToolingScope = .user
    public var projectRoot = ""

    public init() {}
}

public struct MCPDraft: Sendable, Equatable {
    public var name = ""
    public var endpoint = ""
    public var transport: MCPTransport = .http
    public var authentication = "OAuth"
    public var scope: ToolingScope = .user
    public var projectRoot = ""
    public var addToCodex = true
    public var addToClaude = true
    public var addToGemini = true

    public var selectedTargets: Set<ClientKind> {
        var targets: Set<ClientKind> = []
        if addToClaude { targets.insert(.claude) }
        if addToCodex { targets.insert(.codex) }
        if addToGemini { targets.insert(.gemini) }
        return targets
    }

    public init() {}
}
