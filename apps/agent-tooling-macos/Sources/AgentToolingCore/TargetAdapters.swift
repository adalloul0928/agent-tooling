import Foundation

public protocol ClientAdapter: Sendable {
    var client: ClientKind { get }
    var surface: TargetSurface { get }
    var capabilities: TargetCapabilities { get }
    func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation
    func skillDestination(skillID: String, homeURL: URL) -> URL
}

public typealias TargetAdapter = ClientAdapter

struct ClaudeCodeAdapter: TargetAdapter, DeclaresLocalReads {
    let client: ClientKind = .claude
    let surface: TargetSurface = .claudeCode
    let capabilities = TargetCapabilities(
        supportsPluginInstall: true,
        supportsProjectScope: true,
        supportsLocalMarketplace: true,
        supportsMCPAuthentication: true,
        supportsConnectorDiscovery: false,
        requiresNewSession: true,
        requiresRestart: false,
        supportsMachineReadableOutput: true
    )

    /// How this adapter finds its tool. The locator's own search in the app; a
    /// test passes one that looks only in its own folders.
    let locate: @Sendable (ClientKind, URL) -> URL?

    init(locate: @escaping @Sendable (ClientKind, URL) -> URL? = ClientAdapterRegistry.liveLocate) {
        self.locate = locate
    }

    func readLocations(homeURL: URL) -> ClientReadLocations {
        ClientReadLocations(
            client: client,
            configurationFiles: [
                homeURL.appending(path: ".claude/settings.json"),
                homeURL.appending(path: ".claude.json"),
            ],
            skillRoots: [homeURL.appending(path: ".claude/skills", directoryHint: .isDirectory)],
            pluginRoots: [homeURL.appending(path: ".claude/plugins", directoryHint: .isDirectory)],
            commands: [ClientReadLocations.versionArguments, ClientReadLocations.pluginListArguments]
        )
    }

    func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation {
        await LocalTargetScan.perform(
            surface: surface, homeURL: homeURL, locations: readLocations(homeURL: homeURL), capabilities: capabilities,
            runner: runner, locate: locate)
    }

    public func skillDestination(skillID: String, homeURL: URL) -> URL {
        homeURL.appending(path: ".claude/skills/\(skillID)", directoryHint: .isDirectory)
    }
}

struct CodexAdapter: TargetAdapter, DeclaresLocalReads {
    let client: ClientKind = .codex
    let surface: TargetSurface = .codexCLI
    let capabilities = TargetCapabilities(
        supportsPluginInstall: true,
        supportsProjectScope: true,
        supportsLocalMarketplace: true,
        supportsMCPAuthentication: true,
        supportsConnectorDiscovery: false,
        requiresNewSession: true,
        requiresRestart: false,
        supportsMachineReadableOutput: true
    )

    /// How this adapter finds its tool. The locator's own search in the app; a
    /// test passes one that looks only in its own folders.
    let locate: @Sendable (ClientKind, URL) -> URL?

    init(locate: @escaping @Sendable (ClientKind, URL) -> URL? = ClientAdapterRegistry.liveLocate) {
        self.locate = locate
    }

    /// `~/.agents/skills` is the folder Codex shares with Gemini CLI.
    func readLocations(homeURL: URL) -> ClientReadLocations {
        ClientReadLocations(
            client: client,
            configurationFiles: [homeURL.appending(path: ".codex/config.toml")],
            skillRoots: [
                homeURL.appending(path: ".agents/skills", directoryHint: .isDirectory),
                homeURL.appending(path: ".codex/skills", directoryHint: .isDirectory),
            ],
            pluginRoots: [
                homeURL.appending(path: ".codex/plugins", directoryHint: .isDirectory),
                homeURL.appending(path: ".codex/plugins/cache", directoryHint: .isDirectory),
            ],
            commands: [
                ClientReadLocations.versionArguments, ClientReadLocations.pluginListArguments, ClientReadLocations.mcpListArguments,
            ]
        )
    }

    func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation {
        await LocalTargetScan.perform(
            surface: surface, homeURL: homeURL, locations: readLocations(homeURL: homeURL), capabilities: capabilities,
            runner: runner, locate: locate)
    }

    public func skillDestination(skillID: String, homeURL: URL) -> URL {
        homeURL.appending(path: ".agents/skills/\(skillID)", directoryHint: .isDirectory)
    }
}

struct GeminiCLIAdapter: TargetAdapter, DeclaresLocalReads {
    let client: ClientKind = .gemini
    let surface: TargetSurface = .geminiCLI
    let capabilities = TargetCapabilities(
        supportsPluginInstall: true,
        supportsProjectScope: true,
        supportsLocalMarketplace: true,
        supportsMCPAuthentication: true,
        supportsConnectorDiscovery: false,
        requiresNewSession: true,
        requiresRestart: false,
        supportsMachineReadableOutput: true
    )

    /// How this adapter finds its tool. The locator's own search in the app; a
    /// test passes one that looks only in its own folders.
    let locate: @Sendable (ClientKind, URL) -> URL?

    init(locate: @escaping @Sendable (ClientKind, URL) -> URL? = ClientAdapterRegistry.liveLocate) {
        self.locate = locate
    }

    /// `~/.agents/skills` is Codex's folder, which Gemini CLI also reads.
    /// `~/.gemini/extensions` is walked for skills and listed for extensions.
    func readLocations(homeURL: URL) -> ClientReadLocations {
        ClientReadLocations(
            client: client,
            configurationFiles: [
                homeURL.appending(path: ".gemini/settings.json"),
                homeURL.appending(path: ".gemini/settings.toml"),
            ],
            skillRoots: [
                homeURL.appending(path: ".gemini/skills", directoryHint: .isDirectory),
                homeURL.appending(path: ".agents/skills", directoryHint: .isDirectory),
                homeURL.appending(path: ".gemini/extensions", directoryHint: .isDirectory),
            ],
            pluginRoots: [homeURL.appending(path: ".gemini/extensions", directoryHint: .isDirectory)],
            commands: [ClientReadLocations.versionArguments]
        )
    }

    func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation {
        await LocalTargetScan.perform(
            surface: surface, homeURL: homeURL, locations: readLocations(homeURL: homeURL), capabilities: capabilities,
            runner: runner, locate: locate)
    }

    public func skillDestination(skillID: String, homeURL: URL) -> URL {
        homeURL.appending(path: ".gemini/skills/\(skillID)", directoryHint: .isDirectory)
    }
}

/// Kiro CLI reads skills from `~/.kiro/skills` and MCP servers from
/// `~/.kiro/settings/mcp.json`. Plugin installation is unsupported.
struct KiroCLIAdapter: TargetAdapter, DeclaresLocalReads {
    let client: ClientKind = .kiro
    let surface: TargetSurface = .kiroCLI
    let capabilities = TargetCapabilities(
        supportsPluginInstall: false,
        supportsProjectScope: true,
        supportsLocalMarketplace: false,
        supportsMCPAuthentication: false,
        supportsConnectorDiscovery: false,
        requiresNewSession: true,
        requiresRestart: false,
        supportsMachineReadableOutput: false
    )

    /// How this adapter finds its tool. The locator's own search in the app; a
    /// test passes one that looks only in its own folders.
    let locate: @Sendable (ClientKind, URL) -> URL?

    init(locate: @escaping @Sendable (ClientKind, URL) -> URL? = ClientAdapterRegistry.liveLocate) {
        self.locate = locate
    }

    func readLocations(homeURL: URL) -> ClientReadLocations {
        ClientReadLocations(
            client: client,
            configurationFiles: [
                homeURL.appending(path: ".kiro/settings/mcp.json"),
                homeURL.appending(path: ".kiro/settings/cli.json"),
            ],
            skillRoots: [homeURL.appending(path: ".kiro/skills", directoryHint: .isDirectory)],
            pluginRoots: [],
            commands: [ClientReadLocations.versionArguments]
        )
    }

    func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation {
        await LocalTargetScan.perform(
            surface: surface, homeURL: homeURL, locations: readLocations(homeURL: homeURL), capabilities: capabilities,
            runner: runner, locate: locate)
    }

    public func skillDestination(skillID: String, homeURL: URL) -> URL {
        homeURL.appending(path: ".kiro/skills/\(skillID)", directoryHint: .isDirectory)
    }
}

public struct ClientAdapterRegistry: Sendable {
    public let adapters: [any TargetAdapter]

    /// The four adapters this app ships. Named here rather than inline in the
    /// initializer so the adapter types themselves stay internal: only the
    /// protocol they satisfy needs to cross the module boundary.
    public static let bundledAdapters: [any TargetAdapter] = [
        ClaudeCodeAdapter(), CodexAdapter(), GeminiCLIAdapter(), KiroCLIAdapter(),
    ]

    public init(adapters: [any TargetAdapter] = ClientAdapterRegistry.bundledAdapters) {
        self.adapters = adapters
    }

    /// The locator's own search, which every bundled adapter uses unless it
    /// is given another.
    static let liveLocate: @Sendable (ClientKind, URL) -> URL? = { ClientExecutableLocator.locate($0, homeURL: $1) }

    /// The four bundled adapters, each finding its tool with `locate` instead
    /// of the locator's own search. The stage passes the detection it drew;
    /// a fixture passes one that sees only its own home, so a tool installed
    /// on the Mac running the tests is never found.
    public static func bundled(locate: @escaping @Sendable (ClientKind, URL) -> URL?) -> ClientAdapterRegistry {
        ClientAdapterRegistry(adapters: [
            ClaudeCodeAdapter(locate: locate), CodexAdapter(locate: locate), GeminiCLIAdapter(locate: locate),
            KiroCLIAdapter(locate: locate),
        ])
    }

    /// A registry whose scans answer with observations already read, reading
    /// no file and running no command. A first read commits through it, so
    /// the library is made from exactly what was read on the stage.
    ///
    /// One adapter per surface, the latest `lastScannedAt` winning, because
    /// the snapshot validator and the evidence derivation each require one
    /// observation per surface. An observation whose surface belongs to no
    /// app is left out.
    public static func replaying(_ observations: [TargetObservation]) -> ClientAdapterRegistry {
        var latest: [TargetSurface: TargetObservation] = [:]
        for observation in observations {
            if let kept = latest[observation.surface], kept.lastScannedAt >= observation.lastScannedAt { continue }
            latest[observation.surface] = observation
        }
        let adapters: [any TargetAdapter] = latest.values
            .sorted { $0.surface.rawValue < $1.surface.rawValue }
            .compactMap { observation in
                observation.surface.client.map { ReplayClientAdapter(observation: observation, client: $0) }
            }
        return ClientAdapterRegistry(adapters: adapters)
    }

    /// The bundled adapter for `client`, finding its tool the live way. Its
    /// declaration is what a read of that app touches.
    static func bundledAdapter(for client: ClientKind) -> any TargetAdapter & DeclaresLocalReads {
        switch client {
        case .claude: ClaudeCodeAdapter()
        case .codex: CodexAdapter()
        case .gemini: GeminiCLIAdapter()
        case .kiro: KiroCLIAdapter()
        }
    }

    public func adapter(for client: ClientKind) -> (any TargetAdapter)? {
        adapters.first { $0.client == client }
    }

    public func scanAll(homeURL: URL, runner: any CommandRunning, clients: Set<ClientKind> = Set(ClientKind.allCases)) async
        -> [TargetObservation]
    {
        await withTaskGroup(of: TargetObservation.self) { group in
            for adapter in adapters where clients.contains(adapter.client) {
                group.addTask { await adapter.scan(homeURL: homeURL, runner: runner) }
            }
            var observations: [TargetObservation] = []
            for await observation in group { observations.append(observation) }
            return observations.sorted { $0.surface.displayName < $1.surface.displayName }
        }
    }
}

/// Answers a scan with an observation already read. Its client's skills still
/// go where that client keeps them, so a replayed workspace plans the same
/// destinations a scanned one does.
struct ReplayClientAdapter: TargetAdapter {
    let observation: TargetObservation
    let client: ClientKind

    var surface: TargetSurface { observation.surface }
    var capabilities: TargetCapabilities { observation.capabilities }

    func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation { observation }

    func skillDestination(skillID: String, homeURL: URL) -> URL {
        ClientAdapterRegistry.bundledAdapter(for: client).skillDestination(skillID: skillID, homeURL: homeURL)
    }
}
