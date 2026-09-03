import Foundation

public protocol ClientAdapter: Sendable {
    var client: ClientKind { get }
    var surface: TargetSurface { get }
    var capabilities: TargetCapabilities { get }
    func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation
    func skillDestination(skillID: String, homeURL: URL) -> URL
}

public typealias TargetAdapter = ClientAdapter

public struct ClaudeCodeAdapter: TargetAdapter {
    public let client: ClientKind = .claude
    public let surface: TargetSurface = .claudeCode
    public let capabilities = TargetCapabilities(
        supportsPluginInstall: true,
        supportsProjectScope: true,
        supportsLocalMarketplace: true,
        supportsMCPAuthentication: true,
        supportsConnectorDiscovery: false,
        requiresNewSession: true,
        requiresRestart: false,
        supportsMachineReadableOutput: true
    )

    public init() {}

    public func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation {
        await LocalTargetScan.perform(
            surface: surface,
            executable: "claude",
            homeURL: homeURL,
            configurationURLs: [
                homeURL.appending(path: ".claude/settings.json"),
                homeURL.appending(path: ".claude.json"),
            ],
            skillRoots: [homeURL.appending(path: ".claude/skills", directoryHint: .isDirectory)],
            pluginRoots: [homeURL.appending(path: ".claude/plugins", directoryHint: .isDirectory)],
            capabilities: capabilities,
            runner: runner
        )
    }

    public func skillDestination(skillID: String, homeURL: URL) -> URL {
        homeURL.appending(path: ".claude/skills/\(skillID)", directoryHint: .isDirectory)
    }
}

public struct CodexAdapter: TargetAdapter {
    public let client: ClientKind = .codex
    public let surface: TargetSurface = .codexCLI
    public let capabilities = TargetCapabilities(
        supportsPluginInstall: true,
        supportsProjectScope: true,
        supportsLocalMarketplace: true,
        supportsMCPAuthentication: true,
        supportsConnectorDiscovery: false,
        requiresNewSession: true,
        requiresRestart: false,
        supportsMachineReadableOutput: true
    )

    public init() {}

    public func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation {
        await LocalTargetScan.perform(
            surface: surface,
            executable: "codex",
            homeURL: homeURL,
            configurationURLs: [homeURL.appending(path: ".codex/config.toml")],
            skillRoots: [
                homeURL.appending(path: ".agents/skills", directoryHint: .isDirectory),
                homeURL.appending(path: ".codex/skills", directoryHint: .isDirectory),
            ],
            pluginRoots: [
                homeURL.appending(path: ".codex/plugins", directoryHint: .isDirectory),
                homeURL.appending(path: ".codex/plugins/cache", directoryHint: .isDirectory),
            ],
            capabilities: capabilities,
            runner: runner
        )
    }

    public func skillDestination(skillID: String, homeURL: URL) -> URL {
        homeURL.appending(path: ".agents/skills/\(skillID)", directoryHint: .isDirectory)
    }
}

public struct GeminiCLIAdapter: TargetAdapter {
    public let client: ClientKind = .gemini
    public let surface: TargetSurface = .geminiCLI
    public let capabilities = TargetCapabilities(
        supportsPluginInstall: true,
        supportsProjectScope: true,
        supportsLocalMarketplace: true,
        supportsMCPAuthentication: true,
        supportsConnectorDiscovery: false,
        requiresNewSession: true,
        requiresRestart: false,
        supportsMachineReadableOutput: true
    )

    public init() {}

    public func scan(homeURL: URL, runner: any CommandRunning) async -> TargetObservation {
        await LocalTargetScan.perform(
            surface: surface,
            executable: "gemini",
            homeURL: homeURL,
            configurationURLs: [
                homeURL.appending(path: ".gemini/settings.json"),
                homeURL.appending(path: ".gemini/settings.toml"),
            ],
            skillRoots: [
                homeURL.appending(path: ".gemini/skills", directoryHint: .isDirectory),
                homeURL.appending(path: ".agents/skills", directoryHint: .isDirectory),
                homeURL.appending(path: ".gemini/extensions", directoryHint: .isDirectory),
            ],
            pluginRoots: [homeURL.appending(path: ".gemini/extensions", directoryHint: .isDirectory)],
            capabilities: capabilities,
            runner: runner
        )
    }

    public func skillDestination(skillID: String, homeURL: URL) -> URL {
        homeURL.appending(path: ".gemini/skills/\(skillID)", directoryHint: .isDirectory)
    }
}

public struct ClientAdapterRegistry: Sendable {
    public let adapters: [any TargetAdapter]

    public init(adapters: [any TargetAdapter] = [ClaudeCodeAdapter(), CodexAdapter(), GeminiCLIAdapter()]) {
        self.adapters = adapters
    }

    public func adapter(for client: ClientKind) -> (any TargetAdapter)? {
        adapters.first { $0.client == client }
    }

    public func scanAll(homeURL: URL, runner: any CommandRunning) async -> [TargetObservation] {
        await withTaskGroup(of: TargetObservation.self) { group in
            for adapter in adapters {
                group.addTask { await adapter.scan(homeURL: homeURL, runner: runner) }
            }
            var observations: [TargetObservation] = []
            for await observation in group { observations.append(observation) }
            return observations.sorted { $0.surface.displayName < $1.surface.displayName }
        }
    }
}
